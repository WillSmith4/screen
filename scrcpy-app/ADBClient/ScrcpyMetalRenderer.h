#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>

typedef NS_ENUM(NSInteger, ScrcpyMetalResult) {
    ScrcpyMetalUnsupported = 0, ScrcpyMetalPresented, ScrcpyMetalBusy
};

typedef struct {
    uint64_t presented, unpresentedCallbacks;
    CFTimeInterval maxPresentationGap, averageGPUTime;
} ScrcpyMetalStatistics;

// Worker-thread rendering; main-thread layer attachment/sizing. Backpressure
// stays on the worker; the user-selected backend is fixed for the session.
@interface ScrcpyMetalRenderer : NSObject
@property(nonatomic, readonly) CAMetalLayer *layer;
@property(nonatomic, readonly) CFTimeInterval averageGPUTime;
// Lifecycle calls run after the render worker and GPU have drained.
- (void)configureFrameRate:(int)fps;
- (ScrcpyMetalStatistics)takeStatistics;
// Reserve capacity BEFORE taking a frame from the FIFO, like VoidLink.
- (BOOL)waitForGPUCapacity;
- (void)releaseGPUCapacity;
// Consumes a reserved slot on every return path (including errors).
- (ScrcpyMetalResult)renderAcquiredPixelBuffer:(CVPixelBufferRef)buffer minimumDuration:(CFTimeInterval)duration;
- (ScrcpyMetalResult)renderPixelBuffer:(CVPixelBufferRef)buffer minimumDuration:(CFTimeInterval)duration;
// Same shader/ownership path with a caller-provided output, used for GPU tests.
- (ScrcpyMetalResult)renderPixelBuffer:(CVPixelBufferRef)buffer toTexture:(id<MTLTexture>)texture;
- (void)drain;
@end
