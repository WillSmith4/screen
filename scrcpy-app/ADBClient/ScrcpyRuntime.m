//
//  ScrcpyRuntime.m
//  Scrcpy Remote
//
//  Created by Ethan on 1/1/25.
//
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <SDL3/SDL.h>
#import <math.h>
#import <libavutil/frame.h>
#import "ScrcpyRuntime.h"
#import "ScrcpyFramePresenter.h"
#import "frame-pacing.h"
#import "scrcpy-porting.h"
#import "app/config.h"

typedef enum : NSUInteger {
    // 0: disable hardware decoding
    ScrcpyHardwareDecodingDisabled = 0,
    // 1: enable hardware decoding with layer render
    ScrcpyHardwareDecodingLayerRender = 1,
    // 2: enable hardware decoding with sdl render
    ScrcpyHardwareDecodingSDLRender = 2,
} ScrcpyHardwareDecodingType;

static ScrcpyHardwareDecodingType bScrcpyHardwareDecodingEnabled = ScrcpyHardwareDecodingLayerRender;

// Application background state. Written from the main thread (app lifecycle),
// read from scrcpy's decoder/demuxer thread, so it is _Atomic.
static _Atomic(BOOL) bApplicationInBackground = NO;

// Follow remote orientation change feature
static BOOL bFollowRemoteOrientation = NO;
static int lastFrameWidth = 0;
static int lastFrameHeight = 0;
static BOOL lastWasLandscape = NO;

// Notification name for remote orientation change
NSString * const ScrcpyRemoteOrientationChangedNotification = @"ScrcpyRemoteOrientationChangedNotification";

// Standard samples and their cached format are prepared by the producer.
static void RenderSampleBufferFrame(CMSampleBufferRef sampleBuffer,
                                    AVSampleBufferDisplayLayer *displayLayer,
                                    CFTimeInterval targetTimestamp);

static ScrcpyFramePresenter *FramePresenter(void) {
    static ScrcpyFramePresenter *presenter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        presenter = [[ScrcpyFramePresenter alloc] initWithRenderer:^(CMSampleBufferRef buffer,
                AVSampleBufferDisplayLayer *layer, CFTimeInterval target) {
            RenderSampleBufferFrame(buffer, layer, target);
        }];
        presenter.recoveryHandler = ^{ ScrcpyTryResetVideo(); };
    });
    return presenter;
}

extern void ScrcpySetLowLatencyEventPump(bool enabled);

int ScrcpyVideoFrameRate(int requested) {
    UIScreen *screen = GetCurrentWindowScene().screen ?: UIScreen.mainScreen;
    return sc_display_frame_rate(requested, (int)screen.maximumFramesPerSecond);
}

void StartScrcpyVideoPresentation(int frameRate) {
    ScrcpySetLowLatencyEventPump(true);
    BOOL useMetal = [NSUserDefaults.standardUserDefaults integerForKey:@"settings.video.rendering_mode"] == 1;
    NSUserDefaults *settings = NSUserDefaults.standardUserDefaults;
    int frames = [settings objectForKey:@"settings.video.frames_to_buffer"]
        ? (int)[settings integerForKey:@"settings.video.frames_to_buffer"] : 1;
    BOOL asyncDequeue = [settings objectForKey:@"settings.video.async_frame_dequeue"]
        ? [settings boolForKey:@"settings.video.async_frame_dequeue"] : YES;
    [FramePresenter() startWithFrameRate:frameRate useMetal:useMetal framesToBuffer:frames
        asyncDequeue:asyncDequeue];
}

void StopScrcpyVideoPresentation(void) {
    [FramePresenter() stop];
    ScrcpySetLowLatencyEventPump(false);
}

void AttachScrcpyVideoPresentation(UIView *view) {
    [FramePresenter() attachToView:view hardwareDecoding:ScrcpyEnableHardwareDecoding() == 1];
}

bool ScrcpyGetViewSize(uint32_t windowID, int *width, int *height) {
    // Called by scrcpy's main-thread input/render path. The native window
    // property identifies the correct scene instead of the physical screen.
    if (!NSThread.isMainThread) { return false; }
    SDL_Window *window = SDL_GetWindowFromID(windowID);
    if (!window) { return false; }
    UIWindow *nativeWindow = (__bridge UIWindow *)SDL_GetPointerProperty(
        SDL_GetWindowProperties(window), SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, NULL);
    UIView *view = nativeWindow.rootViewController.view;
    if (!view || view.bounds.size.width <= 0 || view.bounds.size.height <= 0) { return false; }
    *width = (int)view.bounds.size.width;
    *height = (int)view.bounds.size.height;
    return true;
}

const char *ScrcpyCoreVersion(void)
{
    return SCRCPY_VERSION;
}

float ScrcpyRenderScreenScale(void)
{
    return [UIScreen mainScreen].nativeScale;
}

void SetScrcpyHardwareDecodingEnabled(BOOL enabled) {
    bScrcpyHardwareDecodingEnabled = enabled ? ScrcpyHardwareDecodingLayerRender : ScrcpyHardwareDecodingDisabled;
}

void SetApplicationBackgroundState(BOOL inBackground) {
    bApplicationInBackground = inBackground;
    if (NSThread.isMainThread) {
        [FramePresenter() setPaused:inBackground];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ [FramePresenter() setPaused:inBackground]; });
    }
    NSLog(@"[ScrcpyRuntime] SetApplicationBackgroundState → %@", inBackground ? @"background" : @"foreground");
}

// Read the cached background flag. When `update` is true, refresh it from the
// live UIApplication state first (safe to call from any thread). Used by
// decoder-porting.c to decide whether a decode error is an iOS-induced
// VideoToolbox session loss (background) rather than a real stream failure.
bool GetUpdateApplicationBackgroundState(bool update) {
    if (update) {
        bApplicationInBackground =
            (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground);
    }
    return bApplicationInBackground ? true : false;
}

void SetScrcpyFollowRemoteOrientation(BOOL enabled) {
    bFollowRemoteOrientation = enabled;
    // Reset tracking state when setting changes
    lastFrameWidth = 0;
    lastFrameHeight = 0;
    lastWasLandscape = NO;
    NSLog(@"📱 [ScrcpyRuntime] Follow remote orientation: %@", enabled ? @"YES" : @"NO");
}

void ResetScrcpyOrientationTracking(void) {
    // Reset orientation tracking state (called when disconnecting)
    lastFrameWidth = 0;
    lastFrameHeight = 0;
    lastWasLandscape = NO;
    NSLog(@"📱 [ScrcpyRuntime] Orientation tracking state reset");
}

BOOL IsRemoteOrientationKnown(void) {
    return (lastFrameWidth > 0 && lastFrameHeight > 0);
}

BOOL GetCurrentRemoteOrientation(int *outWidth, int *outHeight) {
    if (outWidth) *outWidth = lastFrameWidth;
    if (outHeight) *outHeight = lastFrameHeight;

    // Return YES if landscape (width > height), NO otherwise
    if (lastFrameWidth > 0 && lastFrameHeight > 0) {
        return (lastFrameWidth > lastFrameHeight);
    }
    return NO; // Unknown, default to portrait
}

static void CheckAndNotifyOrientationChange(int width, int height) {
    if (!bFollowRemoteOrientation) {
        return;
    }

    // Skip if dimensions are invalid
    if (width <= 0 || height <= 0) {
        return;
    }

    // Determine if current frame is landscape (width > height)
    BOOL isLandscape = (width > height);

    // Check if this is the first frame or if orientation changed
    BOOL isFirstFrame = (lastFrameWidth == 0 && lastFrameHeight == 0);
    BOOL orientationChanged = (!isFirstFrame && isLandscape != lastWasLandscape);

    // Update tracking state
    lastFrameWidth = width;
    lastFrameHeight = height;
    lastWasLandscape = isLandscape;

    // Notify on first frame OR when orientation changed
    // First frame notification ensures we set correct initial orientation
    if (isFirstFrame || orientationChanged) {
        NSLog(@"📱 [ScrcpyRuntime] Remote orientation %@: %@ (%dx%d)",
              isFirstFrame ? @"initial" : @"changed",
              isLandscape ? @"Landscape" : @"Portrait", width, height);

        dispatch_async(dispatch_get_main_queue(), ^{
            NSDictionary *userInfo = @{
                @"isLandscape": @(isLandscape),
                @"width": @(width),
                @"height": @(height),
                @"isFirstFrame": @(isFirstFrame)
            };
            [[NSNotificationCenter defaultCenter] postNotificationName:ScrcpyRemoteOrientationChangedNotification
                                                                object:nil
                                                              userInfo:userInfo];
        });
    }
}

int ScrcpyEnableHardwareDecoding(void)
{
    // To enable hardware decoding if target not simulator
#if TARGET_OS_SIMULATOR
    return ScrcpyHardwareDecodingDisabled;
#else
    return (int)bScrcpyHardwareDecodingEnabled;
#endif
}

float ScrcpyAudioVolumeScale(float update_scale)
{
    static float volume_scale = 1.0f;
    volume_scale = update_scale > 0 ? update_scale : volume_scale;
    return volume_scale;
}

static void RenderSampleBufferFrame(CMSampleBufferRef sampleBuffer,
                                    AVSampleBufferDisplayLayer *displayLayer,
                                    CFTimeInterval targetTimestamp) {
    // Match VoidLink renderFrame:atTime:. No custom timebase, extra frame
    // delay, per-frame format allocation or second readiness/drop policy.
    CMSampleBufferSetOutputPresentationTimeStamp(sampleBuffer,
        CMTimeMakeWithSeconds(targetTimestamp, NSEC_PER_SEC));
    if (GetUpdateApplicationBackgroundState(false)) { [displayLayer flush]; }
    else { [displayLayer enqueueSampleBuffer:sampleBuffer]; }
}

AVFrame * ScrcpyHandleFrame(AVFrame *frame) {
    if (!frame) {
        return frame;
    }
    
    // Get CVImageBufferRef
    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)frame->data[3];
    if (!pixelBuffer) {
        return frame;
    }
   
    if (ScrcpyEnableHardwareDecoding() == ScrcpyHardwareDecodingLayerRender) {
        CheckAndNotifyOrientationChange((int)CVPixelBufferGetWidth(pixelBuffer),
                                       (int)CVPixelBufferGetHeight(pixelBuffer));
        [FramePresenter() submitPixelBuffer:pixelBuffer ptsUS:frame->pts
            keyframe:(frame->flags & AV_FRAME_FLAG_KEY) != 0];
        return frame;
    }
    
    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

    // Set frame format to YUV420P
    frame->format = AV_PIX_FMT_YUV420P;
    
    uint8_t* y_plane = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
    int y_stride = (int)CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
    
    uint8_t* uv_plane = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
    int uv_stride = (int)CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
    
    static uint8_t* u_plane = NULL;
    if (!u_plane) u_plane = (uint8_t*)malloc((frame->width * frame->height) / 4);
    static uint8_t* v_plane = NULL;
    if (!v_plane) v_plane = (uint8_t*)malloc((frame->width * frame->height) / 4);

    if (!u_plane || !v_plane) {
        if (u_plane) free(u_plane);
        if (v_plane) free(v_plane);
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        return frame;
    }
    
    for (int i = 0; i < frame->height/2; i++) {
        for (int j = 0; j < frame->width/2; j++) {
            u_plane[i * (frame->width/2) + j] = uv_plane[i * uv_stride + j * 2];
            v_plane[i * (frame->width/2) + j] = uv_plane[i * uv_stride + j * 2 + 1];
        }
    }

    // Update to frame
    frame->data[0] = y_plane;
    frame->data[1] = u_plane;
    frame->data[2] = v_plane;
    frame->linesize[0] = y_stride;
    frame->linesize[1] = frame->width / 2;
    frame->linesize[2] = frame->width / 2;
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

    // Release frame->data[3] to prevent memory leak
    frame->data[3] = NULL;

    return frame;
}
