#import "ScrcpyMetalRenderer.h"
#import <Metal/Metal.h>
#import <simd/simd.h>
#import <stdatomic.h>

// Native bi-planar YUV -> RGB on the GPU. Textures reference the decoder's
// IOSurface. Per-frame constants use Metal's inline storage, not shared buffers
// that a later frame could overwrite while an earlier frame is still in flight.
static NSString * const shaderSource = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct V { float4 position [[position]]; float2 uv; };\n"
"vertex V sc_vertex(uint i [[vertex_id]], constant float2 &scale [[buffer(0)]]) {\n"
" const float2 p[4] = {float2(-1,1),float2(-1,-1),float2(1,1),float2(1,-1)};\n"
" const float2 uv[4] = {float2(0,0),float2(0,1),float2(1,0),float2(1,1)};\n"
" return {float4(p[i]*scale,0,1),uv[i]}; }\n"
"fragment float4 sc_yuv(V v [[stage_in]], texture2d<float> y [[texture(0)]],\n"
" texture2d<float> uv [[texture(1)]], constant float4 *m [[buffer(0)]]) {\n"
" constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
" float3 c=float3(y.sample(s,v.uv).r,uv.sample(s,v.uv).rg)*m[3].w-m[3].xyz;\n"
" return float4(dot(m[0].xyz,c),dot(m[1].xyz,c),dot(m[2].xyz,c),1); }\n";

@implementation ScrcpyMetalRenderer {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commands;
    id<MTLRenderPipelineState> _pipeline;
    CVMetalTextureCacheRef _cache;
    dispatch_semaphore_t _slots;
    dispatch_group_t _inFlight;
    CAMetalLayer *_layer;
    _Atomic(bool) _failed;
    CGColorSpaceRef _srgb, _rec709;
    BOOL _lastRec601;
}

- (instancetype)init {
    if (!(self = [super init])) { return nil; }
    _device = MTLCreateSystemDefaultDevice();
    if (!_device) { return nil; }
    NSError *error = nil;
    id<MTLLibrary> library = [_device newLibraryWithSource:shaderSource options:nil error:&error];
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"sc_vertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"sc_yuv"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    _pipeline = library ? [_device newRenderPipelineStateWithDescriptor:descriptor error:&error] : nil;
    _commands = [_device newCommandQueue];
    if (!_pipeline || !_commands || CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, _device, NULL, &_cache)) {
        NSLog(@"[MetalVideo] unavailable: %@", error);
        return nil;
    }
    _slots = dispatch_semaphore_create(3);
    _inFlight = dispatch_group_create();
    _layer = [CAMetalLayer layer];
    _layer.device = _device;
    _layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _layer.framebufferOnly = YES;
    _layer.maximumDrawableCount = 3;
    _layer.allowsNextDrawableTimeout = YES;
    _layer.opaque = YES;
    _srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    _rec709 = CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
    _layer.colorspace = _rec709;
    return self;
}

- (CAMetalLayer *)layer { return _layer; }

- (void)drain {
    dispatch_group_wait(_inFlight, DISPATCH_TIME_FOREVER);
    CVMetalTextureCacheFlush(_cache, 0);
}

- (void)dealloc {
    if (_cache) { CFRelease(_cache); }
    if (_srgb) { CGColorSpaceRelease(_srgb); }
    if (_rec709) { CGColorSpaceRelease(_rec709); }
}

- (ScrcpyMetalResult)renderPixelBuffer:(CVPixelBufferRef)buffer targetTime:(CFTimeInterval)target {
    return [self renderPixelBuffer:buffer toTexture:nil targetTime:target];
}

- (ScrcpyMetalResult)renderPixelBuffer:(CVPixelBufferRef)buffer toTexture:(id<MTLTexture>)texture {
    return [self renderPixelBuffer:buffer toTexture:texture targetTime:0];
}

- (ScrcpyMetalResult)renderPixelBuffer:(CVPixelBufferRef)buffer toTexture:(id<MTLTexture>)texture targetTime:(CFTimeInterval)target {
    if (atomic_load(&_failed)) { return ScrcpyMetalUnsupported; }
    OSType format = CVPixelBufferGetPixelFormatType(buffer);
    BOOL ten = format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
    BOOL full = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
             || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
    if ((!ten && format != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
              && format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            || CVPixelBufferGetPlaneCount(buffer) != 2) { return NO; }
    if (dispatch_semaphore_wait(_slots, DISPATCH_TIME_NOW)) { return ScrcpyMetalBusy; }
    CVMetalTextureRef luma = NULL, chroma = NULL;
    CVReturn status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _cache, buffer,
        NULL, ten ? MTLPixelFormatR16Unorm : MTLPixelFormatR8Unorm,
        CVPixelBufferGetWidthOfPlane(buffer, 0), CVPixelBufferGetHeightOfPlane(buffer, 0), 0, &luma);
    if (status == kCVReturnSuccess) {
        status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _cache, buffer,
            NULL, ten ? MTLPixelFormatRG16Unorm : MTLPixelFormatRG8Unorm,
            CVPixelBufferGetWidthOfPlane(buffer, 1), CVPixelBufferGetHeightOfPlane(buffer, 1), 1, &chroma);
    }
    id<CAMetalDrawable> drawable = status == kCVReturnSuccess && !texture ? [_layer nextDrawable] : nil;
    id<MTLTexture> destination = texture ?: drawable.texture;
    id<MTLCommandBuffer> command = status == kCVReturnSuccess && destination ? [_commands commandBuffer] : nil;
    if (!command) {
        if (luma) { CFRelease(luma); }
        if (chroma) { CFRelease(chroma); }
        dispatch_semaphore_signal(_slots);
        return status == kCVReturnSuccess ? ScrcpyMetalBusy : ScrcpyMetalUnsupported;
    }
    CFTypeRef matrix = CVBufferGetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, NULL);
    BOOL rec601 = matrix && CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4);
    if (rec601 != _lastRec601) {
        _layer.colorspace = rec601 ? _srgb : _rec709;
        _lastRec601 = rec601;
    }
    float kr = rec601 ? .299f : .2126f, kb = rec601 ? .114f : .0722f, kg = 1 - kr - kb;
    float maximum = ten ? 1023.f : 255.f;
    float ys = full ? 1.f : maximum / (ten ? 876.f : 219.f);
    float cs = full ? 1.f : maximum / (ten ? 896.f : 224.f);
    vector_float4 values[4] = {
        {ys, 0, (2-2*kr)*cs, 0},
        {ys, -kb*(2-2*kb)/kg*cs, -kr*(2-2*kr)/kg*cs, 0},
        {ys, (2-2*kb)*cs, 0, 0},
        {full ? 0 : (ten ? 64.f : 16.f)/maximum,
         (ten ? 512.f : 128.f)/maximum, (ten ? 512.f : 128.f)/maximum,
         ten ? 65535.f/(1023.f*64.f) : 1.f},
    };
    double sourceAspect = (double)CVPixelBufferGetWidth(buffer) / CVPixelBufferGetHeight(buffer);
    double targetAspect = (double)destination.width / destination.height;
    vector_float2 scale = sourceAspect > targetAspect
        ? (vector_float2){1, targetAspect/sourceAspect} : (vector_float2){sourceAspect/targetAspect, 1};
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = destination;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
    if (!encoder) {
        CFRelease(luma); CFRelease(chroma);
        dispatch_semaphore_signal(_slots);
        return NO;
    }
    [encoder setRenderPipelineState:_pipeline];
    [encoder setVertexBytes:&scale length:sizeof(scale) atIndex:0];
    [encoder setFragmentBytes:values length:sizeof(values) atIndex:0];
    [encoder setFragmentTexture:CVMetalTextureGetTexture(luma) atIndex:0];
    [encoder setFragmentTexture:CVMetalTextureGetTexture(chroma) atIndex:1];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];
    CVPixelBufferRetain(buffer);
    dispatch_group_enter(_inFlight);
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        if (completed.status == MTLCommandBufferStatusError) {
            atomic_store(&self->_failed, true);
            NSLog(@"[MetalVideo] GPU error: %@", completed.error);
        }
        CFRelease(luma); CFRelease(chroma);
        CVPixelBufferRelease(buffer);
        dispatch_semaphore_signal(self->_slots);
        dispatch_group_leave(self->_inFlight);
    }];
    // Target the same next-vsync deadline as AVSB, without a CPU wait for GPU
    // completion. Three slots bound outstanding drawables and frame ownership.
    if (drawable) { [command presentDrawable:drawable atTime:MAX(target, CACurrentMediaTime())]; }
    [command commit];
    return ScrcpyMetalPresented;
}
@end
