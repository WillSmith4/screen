#import "ScrcpyMetalRenderer.h"
#import <Metal/Metal.h>
#import <simd/simd.h>
#import <stdatomic.h>
#import <TargetConditionals.h>
#import <os/lock.h>
#include <math.h>

// Metal pacing adapted from VoidLink (2d9558e1), Acaki / TrueZhuanjia.
// GPL-3.0; see docs/licenses/VoidLink-GPL-3.0.txt.

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
    os_unfair_lock _statisticsLock;
    ScrcpyMetalStatistics _statistics;
    CFTimeInterval _lastPresented;
    uint64_t _statisticsGeneration;
}

- (instancetype)init {
    if (!(self = [super init])) { return nil; }
    _statisticsLock = OS_UNFAIR_LOCK_INIT;
    [self configureFrameRate:60];
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

- (void)configureFrameRate:(int)fps {
    os_unfair_lock_lock(&_statisticsLock);
    ++_statisticsGeneration;
    _statistics = (ScrcpyMetalStatistics){ .averageGPUTime = 0.5 / MAX(1, fps) };
    _lastPresented = 0;
    os_unfair_lock_unlock(&_statisticsLock);
}
- (CFTimeInterval)averageGPUTime {
    os_unfair_lock_lock(&_statisticsLock);
    CFTimeInterval time = _statistics.averageGPUTime;
    os_unfair_lock_unlock(&_statisticsLock);
    return time;
}
- (ScrcpyMetalStatistics)takeStatistics {
    os_unfair_lock_lock(&_statisticsLock);
    ScrcpyMetalStatistics result = _statistics;
    _statistics.presented = _statistics.unpresentedCallbacks = 0;
    _statistics.maxPresentationGap = 0;
    os_unfair_lock_unlock(&_statisticsLock);
    return result;
}
- (void)recordPresentedTime:(CFTimeInterval)time generation:(uint64_t)generation {
    os_unfair_lock_lock(&_statisticsLock);
    if (generation == _statisticsGeneration) {
        if (time > 0 && isfinite(time)) {
            ++_statistics.presented;
            if (_lastPresented > 0 && time > _lastPresented) {
                _statistics.maxPresentationGap = MAX(_statistics.maxPresentationGap, time - _lastPresented);
            }
            _lastPresented = MAX(_lastPresented, time);
        } else {
            ++_statistics.unpresentedCallbacks;
        }
    }
    os_unfair_lock_unlock(&_statisticsLock);
}
- (void)recordGPUTime:(CFTimeInterval)time generation:(uint64_t)generation {
    os_unfair_lock_lock(&_statisticsLock);
    if (generation == _statisticsGeneration && time > 0 && isfinite(time)) {
        _statistics.averageGPUTime = .25 * time + .75 * _statistics.averageGPUTime;
    }
    os_unfair_lock_unlock(&_statisticsLock);
}
- (BOOL)waitForGPUCapacity {
    return dispatch_semaphore_wait(_slots, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) == 0;
}
- (void)releaseGPUCapacity { dispatch_semaphore_signal(_slots); }

- (void)drain {
    dispatch_group_wait(_inFlight, DISPATCH_TIME_FOREVER);
    CVMetalTextureCacheFlush(_cache, 0);
    // iOS may reject GPU work while the app enters the background. Lifecycle
    // drains must allow a fresh attempt after resume, rather than latch a
    // temporary command-buffer error until the next connection.
    atomic_store(&_failed, false);
}

- (void)dealloc {
    if (_cache) { CFRelease(_cache); }
    if (_srgb) { CGColorSpaceRelease(_srgb); }
    if (_rec709) { CGColorSpaceRelease(_rec709); }
}

- (ScrcpyMetalResult)renderPixelBuffer:(CVPixelBufferRef)buffer minimumDuration:(CFTimeInterval)duration {
    if (![self waitForGPUCapacity]) { return ScrcpyMetalBusy; }
    return [self renderAcquiredPixelBuffer:buffer minimumDuration:duration];
}

- (ScrcpyMetalResult)renderAcquiredPixelBuffer:(CVPixelBufferRef)buffer minimumDuration:(CFTimeInterval)duration {
    return [self renderPixelBuffer:buffer toTexture:nil minimumDuration:duration];
}

- (ScrcpyMetalResult)renderPixelBuffer:(CVPixelBufferRef)buffer toTexture:(id<MTLTexture>)texture {
    if (![self waitForGPUCapacity]) { return ScrcpyMetalBusy; }
    return [self renderPixelBuffer:buffer toTexture:texture minimumDuration:0];
}

- (ScrcpyMetalResult)renderPixelBuffer:(CVPixelBufferRef)buffer toTexture:(id<MTLTexture>)texture minimumDuration:(CFTimeInterval)duration {
    if (!buffer || atomic_load(&_failed)) { [self releaseGPUCapacity]; return ScrcpyMetalUnsupported; }
    OSType format = CVPixelBufferGetPixelFormatType(buffer);
    BOOL ten = format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
    BOOL full = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
             || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
    if ((!ten && format != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
              && format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            || CVPixelBufferGetPlaneCount(buffer) != 2) {
        [self releaseGPUCapacity];
        return ScrcpyMetalUnsupported;
    }
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
    CFTypeRef matrix = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, NULL);
    BOOL rec601 = matrix && CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4);
    if (matrix) { CFRelease(matrix); }
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
    os_unfair_lock_lock(&_statisticsLock);
    uint64_t generation = _statisticsGeneration;
    os_unfair_lock_unlock(&_statisticsLock);
    dispatch_group_enter(_inFlight);
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        if (completed.status == MTLCommandBufferStatusError) {
            atomic_store(&self->_failed, true);
            NSLog(@"[MetalVideo] GPU error: %@", completed.error);
        }
        if (completed.GPUStartTime > 0) {
            [self recordGPUTime:completed.GPUEndTime - completed.GPUStartTime generation:generation];
        }
        CFRelease(luma); CFRelease(chroma);
        CVPixelBufferRelease(buffer);
        CVMetalTextureCacheFlush(self->_cache, 0);
        dispatch_semaphore_signal(self->_slots);
        dispatch_group_leave(self->_inFlight);
    }];
    // VoidLink's Metal worker uses drawable/GPU backpressure, independently
    // of CADisplayLink. Minimum duration prevents burst submissions replacing
    // one another within a refresh. The simulator lacks device display timing.
    if (drawable) {
#if TARGET_OS_SIMULATOR || TARGET_OS_OSX
        [command presentDrawable:drawable];
#else
        // A successful command submission does not establish onscreen FPS.
        [drawable addPresentedHandler:^(id<MTLDrawable> displayed) {
            [self recordPresentedTime:displayed.presentedTime generation:generation];
        }];
        [command presentDrawable:drawable afterMinimumDuration:duration];
#endif
    }
    [command commit];
    if (drawable) { [command waitUntilCompleted]; }
    if (drawable && command.status == MTLCommandBufferStatusError) { return ScrcpyMetalUnsupported; }
    return ScrcpyMetalPresented;
}
@end
