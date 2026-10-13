//
//  ScrcpyCommonRuntime.m
//  Scrcpy Remote
//
//  Created by Ethan on 6/28/25.
//

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <stdatomic.h>
#include <stdbool.h>

static atomic_bool g_lowLatencyEventPump = false;

__attribute__((visibility("default")))
void ScrcpySetLowLatencyEventPump(bool enabled) {
    atomic_store(&g_lowLatencyEventPump, enabled);
}

#define CFRunLoopNormalInterval     0.5f
#define CFRunLoopHandledSourceInterval 0.0002f

CFRunLoopRunResult CFRunLoopRunInMode_fix(CFRunLoopMode mode, CFTimeInterval seconds, Boolean returnAfterSourceHandled) {
    // SDL3 asks for a 2 us slice in both default and UITracking modes. A
    // half-second replacement keeps collecting touches before scrcpy can
    // consume them. Preserve the requested slice for active ADB sessions.
    if (atomic_load(&g_lowLatencyEventPump)) {
        return CFRunLoopRunInMode(mode, seconds, returnAfterSourceHandled);
    }
    static CFTimeInterval nextLoopInterval = CFRunLoopNormalInterval;
    CFRunLoopRunResult result = CFRunLoopRunInMode(mode, nextLoopInterval, returnAfterSourceHandled);
    if (result == kCFRunLoopRunHandledSource) {
        nextLoopInterval = CFRunLoopHandledSourceInterval;
    } else {
        nextLoopInterval = CFRunLoopNormalInterval;
    }
    return result;
}
