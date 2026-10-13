#import <Foundation/Foundation.h>
#import <stdatomic.h>
#import "ScrcpyVideoDecoder.h"
#import "ScrcpyMetalRenderer.h"
#include <assert.h>

static _Atomic(int) outputs, recoveries;
static int expectedWidth, expectedHeight;

static NSArray<NSData *> *packets(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    assert(data);
    NSMutableArray *result = [NSMutableArray array];
    const uint8_t *bytes = data.bytes;
    size_t offset = 0;
    while (offset < data.length) {
        assert(data.length - offset >= 4);
        uint32_t size;
        memcpy(&size, bytes + offset, 4);
        size = CFSwapInt32LittleToHost(size);
        offset += 4;
        assert(size && size <= data.length - offset);
        [result addObject:[data subdataWithRange:NSMakeRange(offset, size)]];
        offset += size;
    }
    assert(result.count == 16);
    return result;
}

static void testDecode(NSString *directory, NSString *extension, CMVideoCodecType codec) {
    atomic_store(&outputs, 0);
    atomic_store(&recoveries, 0);
    ScrcpyVideoDecoder *decoder = [[ScrcpyVideoDecoder alloc] initWithCodec:codec requireHardware:NO
        output:^(CVPixelBufferRef image, int64_t pts, BOOL keyframe) {
            assert(CVPixelBufferGetWidth(image) == expectedWidth);
            assert(CVPixelBufferGetHeight(image) == expectedHeight);
            assert(CVPixelBufferGetPlaneCount(image) == 2);
            assert(CVPixelBufferGetIOSurface(image));
            assert(keyframe == (pts == 0));
            atomic_fetch_add(&outputs, 1);
        } recovery:^(OSStatus status) { atomic_fetch_add(&recoveries, 1); }];
    for (int pass = 0; pass < 3; ++pass) {
        BOOL rotated = pass == 1;
        expectedWidth = rotated ? 192 : 128;
        expectedHeight = rotated ? 128 : 96;
        NSString *path = [directory stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@-%@.packets", extension, rotated ? @"large" : @"small"]];
        NSArray<NSData *> *frames = packets(path);
        int before = atomic_load(&outputs);
        for (NSUInteger i = 0; i < frames.count; ++i) {
            NSData *frame = frames[i];
            assert([decoder submitAnnexB:frame.bytes size:frame.length ptsUS:i * 8333 keyframe:NO]);
            // Separate decode correctness from a runner's hardware throughput.
            // Presenter tests independently stress bounded asynchronous work.
            [decoder drain];
        }
        assert(atomic_load(&outputs) - before == 16);
        assert(atomic_load(&recoveries) == 0);
        [decoder reset];
        // A fresh stream must not render inter-frames before an IDR.
        NSData *inter = frames[1];
        int current = atomic_load(&outputs);
        assert([decoder submitAnnexB:inter.bytes size:inter.length ptsUS:999999 keyframe:NO]);
        [decoder drain];
        assert(atomic_load(&outputs) == current);
        atomic_store(&recoveries, 0);
        [decoder reset];
    }
    // Exercise actual asynchronous submission, draining only at the boundary.
    expectedWidth = 128; expectedHeight = 96;
    NSArray<NSData *> *burst = packets([directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@-small.packets", extension]]);
    int beforeBurst = atomic_load(&outputs);
    for (NSUInteger i = 0; i < burst.count; ++i) {
        NSData *frame = burst[i];
        assert([decoder submitAnnexB:frame.bytes size:frame.length ptsUS:i * 8333 keyframe:NO]);
    }
    [decoder drain];
    assert(atomic_load(&outputs) > beforeBurst);
    assert(atomic_load(&recoveries) == 0);
    const uint8_t malformed[] = {1,2,3,4};
    assert(![decoder submitAnnexB:malformed size:sizeof(malformed) ptsUS:0 keyframe:NO]);
    assert(atomic_load(&recoveries) > 0);
    [decoder close];
    assert(![decoder submitAnnexB:malformed size:sizeof(malformed) ptsUS:0 keyframe:YES]);
    printf("PASS: %s native decode, dimensions, IOSurface, restart, IDR gate and invalid data\n", extension.UTF8String);
}

static CVPixelBufferRef colorFrame(OSType format, int y, int cb, int cr) {
    CVPixelBufferRef image = NULL;
    NSDictionary *attributes = @{
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES};
    assert(CVPixelBufferCreate(kCFAllocatorDefault, 16, 8, format,
        (__bridge CFDictionaryRef)attributes, &image) == noErr);
    CVPixelBufferLockBaseAddress(image, 0);
    BOOL ten = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
    for (int plane = 0; plane < 2; ++plane) {
        uint8_t *base = CVPixelBufferGetBaseAddressOfPlane(image, plane);
        size_t stride = CVPixelBufferGetBytesPerRowOfPlane(image, plane);
        for (size_t row = 0; row < CVPixelBufferGetHeightOfPlane(image, plane); ++row) {
            for (size_t x = 0; x < 16; ++x) {
                int value = plane ? (x % 2 ? cr : cb) : y;
                if (ten) { ((uint16_t *)(base + row * stride))[x] = value << 6; }
                else { base[row * stride + x] = value; }
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(image, 0);
    CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    return image;
}

static void checkMetalColor(ScrcpyMetalRenderer *renderer, OSType format, int y, int cb, int cr,
                            int red, int green, int blue) {
    id<MTLDevice> device = renderer.layer.device;
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
        MTLPixelFormatBGRA8Unorm width:16 height:16 mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget;
    descriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    assert(texture);
    CVPixelBufferRef image = colorFrame(format, y, cb, cr);
    assert([renderer renderPixelBuffer:image toTexture:texture] == ScrcpyMetalPresented);
    // The renderer must retain the IOSurface until GPU completion.
    CVPixelBufferRelease(image);
    [renderer drain];
    uint8_t pixels[16*16*4];
    [texture getBytes:pixels bytesPerRow:16*4 fromRegion:MTLRegionMake2D(0,0,16,16) mipmapLevel:0];
    uint8_t *center = pixels + (8*16+8)*4;
    assert(abs(center[0]-blue) <= 4 && abs(center[1]-green) <= 4 && abs(center[2]-red) <= 4);
    assert(pixels[0] == 0 && pixels[1] == 0 && pixels[2] == 0); // 2:1 -> square letterbox
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        assert(argc == 2);
        NSString *directory = @(argv[1]);
        testDecode(directory, @"h264", kCMVideoCodecType_H264);
        testDecode(directory, @"hevc", kCMVideoCodecType_HEVC);
        ScrcpyMetalRenderer *renderer = [ScrcpyMetalRenderer new];
        assert(renderer);
        checkMetalColor(renderer, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 16,128,128, 0,0,0);
        checkMetalColor(renderer, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 235,128,128, 255,255,255);
        checkMetalColor(renderer, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 63,102,240, 255,0,0);
        checkMetalColor(renderer, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 173,42,26, 0,255,0);
        checkMetalColor(renderer, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 32,240,118, 0,0,255);
        checkMetalColor(renderer, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, 54,99,255, 254,0,0);
        checkMetalColor(renderer, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, 64,512,512, 0,0,0);
        checkMetalColor(renderer, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, 940,512,512, 255,255,255);
        [renderer drain];
        puts("PASS: real Metal GPU pixels, NV12/full range/P010 SDR, red/white/black, letterbox, buffer lifetime");
    }
}
