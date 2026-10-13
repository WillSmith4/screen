#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>

typedef NS_ENUM(NSInteger, ScrcpyMetalResult) {
    ScrcpyMetalUnsupported = 0, ScrcpyMetalPresented, ScrcpyMetalBusy
};

// Worker-thread rendering; main-thread layer attachment/sizing. Backpressure
// stays on the worker; the user-selected backend is fixed for the session.
@interface ScrcpyMetalRenderer : NSObject
@property(nonatomic, readonly) CAMetalLayer *layer;
- (ScrcpyMetalResult)renderPixelBuffer:(CVPixelBufferRef)buffer minimumDuration:(CFTimeInterval)duration;
// Same shader/ownership path with a caller-provided output, used for GPU tests.
- (ScrcpyMetalResult)renderPixelBuffer:(CVPixelBufferRef)buffer toTexture:(id<MTLTexture>)texture;
- (void)drain;
@end
