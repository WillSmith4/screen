#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

// The decoder may submit on its worker thread. All lifecycle methods belong
// to the main thread; presentation itself runs on one bounded serial worker.
@interface ScrcpyFramePresenter : NSObject
- (instancetype)initWithRenderer:(void (^)(CVPixelBufferRef, AVSampleBufferDisplayLayer *, CFTimeInterval))renderer;
- (void)startWithFrameRate:(int)frameRate;
- (void)startWithFrameRate:(int)frameRate useMetal:(BOOL)useMetal;
- (void)attachToView:(UIView *)view hardwareDecoding:(BOOL)hardwareDecoding;
- (void)submitPixelBuffer:(CVPixelBufferRef)pixelBuffer;
- (void)setPaused:(BOOL)paused;
- (void)stop;
@end
