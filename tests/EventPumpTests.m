#import <Foundation/Foundation.h>
#include <stdbool.h>
#include <assert.h>

extern void ScrcpySetLowLatencyEventPump(bool enabled);
extern CFRunLoopRunResult CFRunLoopRunInMode_fix(CFRunLoopMode mode, CFTimeInterval seconds, Boolean handled);

int main(void) {
    @autoreleasepool {
        // Keep this runloop alive so an empty loop cannot return immediately
        // and hide the old half-second timeout regression.
        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:60 repeats:YES block:^(NSTimer *t) {}];
        ScrcpySetLowLatencyEventPump(true);
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        for (int i = 0; i < 10; ++i) {
            CFRunLoopRunInMode_fix(kCFRunLoopDefaultMode, .000002, true);
        }
        CFAbsoluteTime duration = CFAbsoluteTimeGetCurrent() - start;
        assert(duration < .2);
        ScrcpySetLowLatencyEventPump(false);
        [timer invalidate];
        printf("PASS: ten SDL pump slices in %.6f seconds\n", duration);
    }
}
