#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

// The decoder may submit on its worker thread. All lifecycle methods belong
// to the main thread. Standard follows VoidLink's queue-buffering callbacks;
// Metal keeps its separate presentation worker.
@interface ScrcpyFramePresenter : NSObject
@property(nonatomic, copy) void (^recoveryHandler)(void);
- (instancetype)initWithRenderer:(void (^)(CMSampleBufferRef, AVSampleBufferDisplayLayer *, CFTimeInterval))renderer;
- (void)startWithFrameRate:(int)frameRate;
- (void)startWithFrameRate:(int)frameRate useMetal:(BOOL)useMetal;
- (void)startWithFrameRate:(int)frameRate useMetal:(BOOL)useMetal framesToBuffer:(int)frames asyncDequeue:(BOOL)asyncDequeue;
- (void)attachToView:(UIView *)view hardwareDecoding:(BOOL)hardwareDecoding;
- (void)submitPixelBuffer:(CVPixelBufferRef)pixelBuffer;
- (void)submitPixelBuffer:(CVPixelBufferRef)pixelBuffer ptsUS:(int64_t)pts keyframe:(BOOL)keyframe;
- (void)setPaused:(BOOL)paused;
- (void)stop;
@end
