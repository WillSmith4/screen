#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>

typedef NS_ENUM(NSInteger, ScrcpyMetalResult) {
    ScrcpyMetalUnsupported = 0, ScrcpyMetalPresented, ScrcpyMetalBusy
};

// Worker-thread rendering; main-thread layer attachment/sizing. A false result
// leaves presentation to AVSB (unsupported color format or GPU back-pressure).
@interface ScrcpyMetalRenderer : NSObject
@property(nonatomic, readonly) CAMetalLayer *layer;
- (ScrcpyMetalResult)renderPixelBuffer:(CVPixelBufferRef)buffer targetTime:(CFTimeInterval)target;
// Same shader/ownership path with a caller-provided output, used for GPU tests.
- (ScrcpyMetalResult)renderPixelBuffer:(CVPixelBufferRef)buffer toTexture:(id<MTLTexture>)texture;
- (void)drain;
@end
