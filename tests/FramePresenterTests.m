#import <UIKit/UIKit.h>
#import <stdatomic.h>
#import "ScrcpyFramePresenter.h"

static _Atomic(int) created, released, delivered, lastSequence;
static dispatch_semaphore_t slowRenderer;
static NSString *resultPath;

static void finish(NSString *failure) {
    NSDictionary *result = @{ @"passed": @(failure == nil), @"failure": failure ?: @"",
        @"created": @(atomic_load(&created)), @"released": @(atomic_load(&released)),
        @"delivered": @(atomic_load(&delivered)) };
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
    OSStatus status = CVPixelBufferCreateWithBytes(kCFAllocatorDefault, 2, 2,
        kCVPixelFormatType_32ARGB, bytes, 8, releaseBytes, NULL, NULL, &frame);
    CHECK(status == noErr && frame);
    atomic_fetch_add(&created, 1);
    return frame;
}

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
    slowRenderer = dispatch_semaphore_create(0);
    self.presenter = [[ScrcpyFramePresenter alloc] initWithRenderer:^(CVPixelBufferRef frame,
            AVSampleBufferDisplayLayer *layer, CFTimeInterval deadline) {
        CHECK(!NSThread.isMainThread);
        CHECK(layer && deadline > 0);
        CVPixelBufferLockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
        int sequence = *(int *)CVPixelBufferGetBaseAddress(frame);
        atomic_store(&lastSequence, sequence);
        CVPixelBufferUnlockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
        if (sequence == 40000) {
            CHECK(dispatch_semaphore_wait(slowRenderer,
                dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0);
        }
        atomic_fetch_add(&delivered, 1);
    }];
    [self.presenter startWithFrameRate:120];
    // No attached clock yet: a stalled consumer must retain only one frame.
    for (int i = 0; i < 10000; ++i) {
        CVPixelBufferRef frame = makeFrame(i);
        [self.presenter submitPixelBuffer:frame];
        CVPixelBufferRelease(frame);
    }
    CHECK(atomic_load(&released) == 9999);
    [self.presenter attachToView:self.window.rootViewController.view hardwareDecoding:YES];
    [self waitForFirstFrame:100];
    return YES;
}

- (void)waitForFirstFrame:(int)attempts {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (!atomic_load(&delivered) && attempts > 0) {
            [self waitForFirstFrame:attempts - 1];
            return;
        }
        CHECK(atomic_load(&delivered) == 1);
        CHECK(atomic_load(&lastSequence) == 9999);
        [self.presenter setPaused:YES];
        for (int i = 0; i < 1000; ++i) {
            CVPixelBufferRef frame = makeFrame(i);
            [self.presenter submitPixelBuffer:frame];
            CVPixelBufferRelease(frame);
        }
        CHECK(atomic_load(&created) == atomic_load(&released));
        CHECK(atomic_load(&delivered) == 1);
        [self.presenter setPaused:NO];
        CVPixelBufferRef obsolete = makeFrame(20000);
        [self.presenter submitPixelBuffer:obsolete];
        CVPixelBufferRelease(obsolete);
        [self.presenter stop];
        CHECK(atomic_load(&created) == atomic_load(&released));
        [self.presenter startWithFrameRate:60];
        [self.presenter attachToView:self.window.rootViewController.view hardwareDecoding:YES];
        CVPixelBufferRef current = makeFrame(30000);
        [self.presenter submitPixelBuffer:current];
        CVPixelBufferRelease(current);
        [self waitForReconnect:100];
    });
}

- (void)waitForReconnect:(int)attempts {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (atomic_load(&lastSequence) != 30000 && attempts > 0) {
            [self waitForReconnect:attempts - 1];
            return;
        }
        CHECK(atomic_load(&lastSequence) == 30000);
        [self.presenter setPaused:YES];
        [self.presenter setPaused:NO];
        CVPixelBufferRef slow = makeFrame(40000);
        [self.presenter submitPixelBuffer:slow];
        CVPixelBufferRelease(slow);
        [self waitForSlowRenderer:100];
    });
}

- (void)waitForSlowRenderer:(int)attempts {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (atomic_load(&lastSequence) != 40000 && attempts > 0) {
            [self waitForSlowRenderer:attempts - 1];
            return;
        }
        CHECK(atomic_load(&lastSequence) == 40000);
        // A worker is stalled while the producer continues. UIKit must stay
        // responsive and only the in-flight frame plus the newest may survive.
        for (int i = 40001; i <= 50000; ++i) {
            CVPixelBufferRef frame = makeFrame(i);
            [self.presenter submitPixelBuffer:frame];
            CVPixelBufferRelease(frame);
        }
        CHECK(atomic_load(&created) - atomic_load(&released) == 2);
        dispatch_semaphore_signal(slowRenderer);
        [self waitForLatestAfterStall:100];
    });
}

- (void)waitForLatestAfterStall:(int)attempts {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (atomic_load(&lastSequence) != 50000 && attempts > 0) {
            [self waitForLatestAfterStall:attempts - 1];
            return;
        }
        CHECK(atomic_load(&lastSequence) == 50000);
        [self.presenter stop];
        CHECK(atomic_load(&created) == atomic_load(&released));
        finish(nil);
    });
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(PresenterTestDelegate.class)); }
}
