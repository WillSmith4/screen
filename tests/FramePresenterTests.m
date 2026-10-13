#import <UIKit/UIKit.h>
#import <stdatomic.h>
#import "ScrcpyFramePresenter.h"
#import "ScrcpyMetalRenderer.h"
#import <QuartzCore/CAMetalLayer.h>

// Exercise the production tick's Standard branch with controlled deadlines,
// then let the real CADisplayLink deliver a final frame in the simulator.
@interface ScrcpyFramePresenter (TestClock)
- (void)renderStandardAtTarget:(CFTimeInterval)target;
- (ScrcpyMetalRenderer *)makeMetalRenderer;
@end
static _Atomic(int) created, released, delivered, lastSequence;
static NSString *resultPath;
static void finish(NSString *failure) {
    NSDictionary *result = @{ @"passed": @(failure == nil), @"failure": failure ?: @"",
        @"created": @(atomic_load(&created)), @"released": @(atomic_load(&released)),
        @"delivered": @(atomic_load(&delivered)), @"standardQueueBuffering": @YES };
    [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL]
        writeToFile:resultPath atomically:YES];
    exit(failure ? 1 : 0);
}
#define CHECK(condition) do { if (!(condition)) { finish(@#condition); } } while (0)
static void releaseBytes(void *context, const void *baseAddress) {
    free((void *)baseAddress);
    atomic_fetch_add(&released, 1);
}
static CVPixelBufferRef makeFrame(int sequence) {
    CVPixelBufferRef frame = NULL;
    int *bytes = calloc(16, 1);
    bytes[0] = sequence;
    CHECK(CVPixelBufferCreateWithBytes(kCFAllocatorDefault, 2, 2,
        kCVPixelFormatType_32ARGB, bytes, 8, releaseBytes, NULL, NULL, &frame) == noErr);
    atomic_fetch_add(&created, 1);
    return frame;
}
static void submit(ScrcpyFramePresenter *presenter, int sequence) {
    @autoreleasepool {
        CVPixelBufferRef frame = makeFrame(sequence);
        [presenter submitPixelBuffer:frame ptsUS:sequence keyframe:NO];
        CVPixelBufferRelease(frame);
    }
}

// A controllable GPU boundary exercises production scheduling while main is
// deliberately blocked (there are no CADisplayLink callbacks). Real shader
// output is covered separately by NativeVideoTests.
@interface TestMetalRenderer : ScrcpyMetalRenderer
@property(nonatomic, strong) dispatch_semaphore_t entered;
@property(nonatomic, strong) dispatch_semaphore_t releaseFirst;
@property(nonatomic, strong) dispatch_semaphore_t completed;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *sequences;
@end
@implementation TestMetalRenderer
- (instancetype)init {
    if ((self = [super init])) {
        _entered = dispatch_semaphore_create(0);
        _releaseFirst = dispatch_semaphore_create(0);
        _completed = dispatch_semaphore_create(0);
        _sequences = [NSMutableArray new];
    }
    return self;
}
- (ScrcpyMetalResult)renderPixelBuffer:(CVPixelBufferRef)buffer minimumDuration:(CFTimeInterval)duration {
    CHECK(!NSThread.isMainThread && duration > 0 && duration <= 1.0 / 30);
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    int sequence = *(int *)CVPixelBufferGetBaseAddress(buffer);
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    if (sequence == 50000) {
        dispatch_semaphore_signal(_entered);
        CHECK(dispatch_semaphore_wait(_releaseFirst, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    }
    [_sequences addObject:@(sequence)];
    dispatch_semaphore_signal(_completed);
    return sequence == 50001 ? ScrcpyMetalBusy : sequence == 50002 ? ScrcpyMetalUnsupported : ScrcpyMetalPresented;
}
@end
@interface TestPresenter : ScrcpyFramePresenter
@property(nonatomic, strong) TestMetalRenderer *testMetal;
@end
@implementation TestPresenter
- (ScrcpyMetalRenderer *)makeMetalRenderer {
    self.testMetal = [TestMetalRenderer new];
    return self.testMetal;
}
@end
@interface PresenterTestDelegate : UIResponder <UIApplicationDelegate>
@property(strong) UIWindow *window;
@property(strong) ScrcpyFramePresenter *presenter;
@end
@implementation PresenterTestDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    resultPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
        stringByAppendingPathComponent:@"presenter-results.json"];
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [UIViewController new];
    [self.window makeKeyAndVisible];
    self.presenter = [[TestPresenter alloc] initWithRenderer:^(CMSampleBufferRef sample,
            AVSampleBufferDisplayLayer *layer, CFTimeInterval deadline) {
        CHECK(NSThread.isMainThread);
        CHECK(layer && layer.controlTimebase == NULL && deadline > 0);
        CHECK(fabs(CMTimeGetSeconds(CMSampleBufferGetOutputPresentationTimeStamp(sample)) - deadline) < 0.000001);
        CVPixelBufferRef frame = CMSampleBufferGetImageBuffer(sample);
        CVPixelBufferLockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
        atomic_store(&lastSequence, *(int *)CVPixelBufferGetBaseAddress(frame));
        CVPixelBufferUnlockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
        CHECK(atomic_load(&lastSequence) != 40000); // No old-session delivery, even before the new frame.
        atomic_fetch_add(&delivered, 1);
    }];
    @autoreleasepool { [self exerciseStandard]; }
    // Old asynchronous completions may still own a buffer until main resumes.
    // The final check after reconnect verifies that all of them are released.
    [self.presenter startWithFrameRate:120 useMetal:NO framesToBuffer:1 asyncDequeue:YES];
    [self.presenter attachToView:self.window.rootViewController.view hardwareDecoding:YES];
    submit(self.presenter, 90000);
    [self waitForLiveClock:100];
    return YES;
}
- (void)exerciseStandard {
    UIView *view = self.window.rootViewController.view;
    [self.presenter startWithFrameRate:120 useMetal:NO framesToBuffer:1 asyncDequeue:NO];
    for (int i = 0; i < 10000; ++i) { submit(self.presenter, i); }
    CHECK(atomic_load(&released) == 9999);
    [self.presenter attachToView:view hardwareDecoding:YES];
    [self.presenter renderStandardAtTarget:CACurrentMediaTime()];
    CHECK(atomic_load(&lastSequence) == 9998); // Alternating drops, not latest-only.
    [self.presenter setPaused:YES];
    for (int i = 0; i < 1000; ++i) { submit(self.presenter, i); }
    [self.presenter stop];
    // Buffer=3 waits for its initial fill, then consumes FIFO.
    [self.presenter startWithFrameRate:120 useMetal:NO framesToBuffer:3 asyncDequeue:NO];
    [self.presenter attachToView:view hardwareDecoding:YES];
    int before = atomic_load(&delivered);
    submit(self.presenter, 20000); submit(self.presenter, 20001);
    [self.presenter renderStandardAtTarget:CACurrentMediaTime()];
    CHECK(atomic_load(&delivered) == before);
    submit(self.presenter, 20002);
    for (int i = 20000; i < 20003; ++i) {
        [self.presenter renderStandardAtTarget:CACurrentMediaTime()];
        CHECK(atomic_load(&lastSequence) == i);
    }
    // Empty queue still accepts a frame arriving before this display deadline.
    [self.presenter startWithFrameRate:120 useMetal:NO framesToBuffer:0 asyncDequeue:NO];
    [self.presenter attachToView:view hardwareDecoding:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        submit(self.presenter, 30000);
    });
    [self.presenter renderStandardAtTarget:CACurrentMediaTime() + 0.5];
    CHECK(atomic_load(&lastSequence) == 30000);
    // Queue an async completion, reconnect before main can execute it, and
    // verify its generation cannot deliver an old-session frame.
    [self.presenter startWithFrameRate:120 useMetal:NO framesToBuffer:0 asyncDequeue:YES];
    [self.presenter attachToView:view hardwareDecoding:YES];
    submit(self.presenter, 40000);
    [self.presenter renderStandardAtTarget:CACurrentMediaTime()];
    [self.presenter stop];
    [self.presenter startWithFrameRate:120 useMetal:YES framesToBuffer:3 asyncDequeue:YES];
    [self.presenter attachToView:view hardwareDecoding:YES];
    CHECK([self countLayers:CAMetalLayer.class inView:view] == 1);
    CHECK([self countLayers:AVSampleBufferDisplayLayer.class inView:view] == 0);
    TestMetalRenderer *metal = ((TestPresenter *)self.presenter).testMetal;
    submit(self.presenter, 50000);
    CHECK(dispatch_semaphore_wait(metal.entered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    // A burst while the GPU owns the first frame must remain FIFO, not replace
    // all three pending frames with only the newest one.
    submit(self.presenter, 50001); submit(self.presenter, 50002); submit(self.presenter, 50003);
    dispatch_semaphore_signal(metal.releaseFirst);
    for (int i = 0; i < 4; ++i) {
        CHECK(dispatch_semaphore_wait(metal.completed, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    }
    // Pause drains the production worker, making its counters stable.
    // Read before pause (which resets metrics) after an explicit serial drain.
    dispatch_sync([self.presenter valueForKey:@"renderQueue"], ^{});
    CHECK(([metal.sequences isEqualToArray:@[@50000, @50001, @50002, @50003]]));
    CHECK([[self.presenter valueForKey:@"renderCalls"] unsignedIntegerValue] == 2);
    CHECK([[self.presenter valueForKey:@"metalBusy"] unsignedIntegerValue] == 1);
    CHECK([[self.presenter valueForKey:@"metalErrors"] unsignedIntegerValue] == 1);
    [self.presenter setPaused:YES];
    submit(self.presenter, 59999);
    CHECK(metal.sequences.count == 4);
    [self.presenter setPaused:NO];
    submit(self.presenter, 60000);
    CHECK(dispatch_semaphore_wait(metal.completed, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    dispatch_sync([self.presenter valueForKey:@"renderQueue"], ^{});
    CHECK([metal.sequences.lastObject intValue] == 60000);
    // A producer can start before its UIView attaches. Bound and release this
    // backlog too, without scheduling work against an unattached CAMetalLayer.
    [self.presenter startWithFrameRate:120 useMetal:YES];
    for (int i = 70000; i < 80000; ++i) { submit(self.presenter, i); }
    [self.presenter startWithFrameRate:120 useMetal:NO];
    [self.presenter attachToView:view hardwareDecoding:YES];
    CHECK([self countLayers:CAMetalLayer.class inView:view] == 0);
    CHECK([self countLayers:AVSampleBufferDisplayLayer.class inView:view] == 1);
    [self.presenter stop];
}
- (void)waitForLiveClock:(int)attempts {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (atomic_load(&lastSequence) != 90000 && attempts > 0) { [self waitForLiveClock:attempts - 1]; return; }
        CHECK(atomic_load(&lastSequence) == 90000);
        [self.presenter stop];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            CHECK(atomic_load(&created) == atomic_load(&released));
            CHECK(atomic_load(&lastSequence) == 90000);
            finish(nil);
        });
    });
}
- (NSUInteger)countLayers:(Class)type inView:(UIView *)view {
    NSUInteger count = 0;
    for (CALayer *layer in view.layer.sublayers) { if ([layer isKindOfClass:type]) { ++count; } }
    return count;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(PresenterTestDelegate.class)); }
}
