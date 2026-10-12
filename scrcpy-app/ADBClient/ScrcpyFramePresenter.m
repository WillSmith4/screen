#import "ScrcpyFramePresenter.h"
#import "frame-pacing.h"
#import <QuartzCore/QuartzCore.h>
#import <os/lock.h>

@implementation ScrcpyFramePresenter {
    os_unfair_lock _lock;
    CVPixelBufferRef _pending;
    dispatch_queue_t _renderQueue;
    void (^_renderer)(CVPixelBufferRef, AVSampleBufferDisplayLayer *, CFTimeInterval);
    CADisplayLink *_displayLink;
    AVSampleBufferDisplayLayer *_layer;
    __weak UIView *_view;
    BOOL _running, _paused, _workScheduled;
    int _requestedFrameRate;
    uint64_t _generation, _decoded, _replaced, _renderCalls, _ticks;
    CFTimeInterval _metricsStart;
}

- (instancetype)initWithRenderer:(void (^)(CVPixelBufferRef, AVSampleBufferDisplayLayer *, CFTimeInterval))renderer {
    if ((self = [super init])) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _renderer = [renderer copy];
        _renderQueue = dispatch_queue_create("scrcpy.video.presentation",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    }
    return self;
}

- (void)startWithFrameRate:(int)frameRate {
    NSAssert(NSThread.isMainThread, @"Presenter lifecycle must run on main");
    [self stop];
    _requestedFrameRate = frameRate;
    os_unfair_lock_lock(&_lock);
    _running = YES;
    _paused = NO;
    _decoded = _replaced = _renderCalls = 0;
    os_unfair_lock_unlock(&_lock);
    _ticks = 0;
    _metricsStart = CACurrentMediaTime();
}

- (void)attachToView:(UIView *)view hardwareDecoding:(BOOL)hardwareDecoding {
    NSAssert(NSThread.isMainThread, @"View attachment must run on main");
    if (!_running || !view.window) { return; }
    if (_view != view) {
        // Drain presentation before moving its layer to a different view.
        dispatch_sync(_renderQueue, ^{});
        [_layer removeFromSuperlayer];
        _view = view;
        _layer = nil;
    }
    if (hardwareDecoding && !_layer) {
        _layer = [AVSampleBufferDisplayLayer layer];
        _layer.videoGravity = AVLayerVideoGravityResizeAspect;
        _layer.backgroundColor = UIColor.blackColor.CGColor;
        CMTimebaseRef timebase = NULL;
        CMClockRef clock = CMClockGetHostTimeClock();
        if (CMTimebaseCreateWithSourceClock(kCFAllocatorDefault, clock, &timebase) == noErr) {
            CMTimebaseSetTime(timebase, CMClockGetTime(clock));
            CMTimebaseSetRate(timebase, 1.0);
            _layer.controlTimebase = timebase;
            CFRelease(timebase);
        }
        [view.layer addSublayer:_layer];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _layer.frame = view.bounds;
    _layer.contentsScale = view.window.screen.scale;
    [CATransaction commit];

    if (!_displayLink) {
        _displayLink = [view.window.screen displayLinkWithTarget:self selector:@selector(displayTick:)];
        // Keep ticking during UIKit's touch/gesture tracking mode as well.
        [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    int fps = sc_display_frame_rate(_requestedFrameRate, (int)view.window.screen.maximumFramesPerSecond);
    if (@available(iOS 15.0, *)) {
        _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(fps, fps, fps);
    } else {
        _displayLink.preferredFramesPerSecond = fps;
    }
    _displayLink.paused = _paused;
}

- (void)submitPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) { return; }
    CVPixelBufferRetain(pixelBuffer);
    os_unfair_lock_lock(&_lock);
    if (!_running || _paused) {
        os_unfair_lock_unlock(&_lock);
        CVPixelBufferRelease(pixelBuffer);
        return;
    }
    CVPixelBufferRef previous = _pending;
    _pending = pixelBuffer;
    ++_decoded;
    if (previous) { ++_replaced; }
    os_unfair_lock_unlock(&_lock);
    if (previous) { CVPixelBufferRelease(previous); }
}

- (void)displayTick:(CADisplayLink *)link {
    ++_ticks;
    CFTimeInterval now = CACurrentMediaTime();
    AVSampleBufferDisplayLayer *layer = _layer;
    os_unfair_lock_lock(&_lock);
    if (now - _metricsStart >= 5.0) {
        double seconds = now - _metricsStart;
        uint64_t decoded = _decoded, replaced = _replaced, rendered = _renderCalls;
        _decoded = _replaced = _renderCalls = 0;
        os_unfair_lock_unlock(&_lock);
        NSLog(@"[FramePacing] callbacks=%.1f/s decoded=%.1f/s renderCalls=%.1f/s replaced=%llu pending<=1",
              _ticks / seconds, decoded / seconds, rendered / seconds, (unsigned long long)replaced);
        _ticks = 0;
        _metricsStart = now;
        os_unfair_lock_lock(&_lock);
    }
    if (!_running || _paused || !_pending || _workScheduled || !layer) {
        os_unfair_lock_unlock(&_lock);
        return;
    }
    _workScheduled = YES;
    uint64_t generation = _generation;
    os_unfair_lock_unlock(&_lock);
    CFTimeInterval target = link.targetTimestamp;
    dispatch_async(_renderQueue, ^{
        @autoreleasepool {
            os_unfair_lock_lock(&self->_lock);
            CVPixelBufferRef frame = NULL;
            if (self->_running && !self->_paused && self->_generation == generation) {
                // Take the newest frame when the job actually runs, not when
                // it is queued. Decoding never waits for rendering or UIKit.
                frame = self->_pending;
                self->_pending = NULL;
            }
            os_unfair_lock_unlock(&self->_lock);
            if (frame) {
                self->_renderer(frame, layer, target);
                CVPixelBufferRelease(frame);
            }
            os_unfair_lock_lock(&self->_lock);
            if (frame) { ++self->_renderCalls; }
            self->_workScheduled = NO;
            os_unfair_lock_unlock(&self->_lock);
        }
    });
}

- (void)setPaused:(BOOL)paused {
    NSAssert(NSThread.isMainThread, @"Presenter lifecycle must run on main");
    os_unfair_lock_lock(&_lock);
    _paused = paused;
    ++_generation;
    _decoded = _replaced = _renderCalls = 0;
    CVPixelBufferRef old = _pending;
    _pending = NULL;
    os_unfair_lock_unlock(&_lock);
    if (old) { CVPixelBufferRelease(old); }
    _displayLink.paused = paused;
    // No synchronous dispatch to main occurs on the presentation worker.
    dispatch_sync(_renderQueue, ^{ [self->_layer flush]; });
    _ticks = 0;
    _metricsStart = CACurrentMediaTime();
}

- (void)stop {
    NSAssert(NSThread.isMainThread, @"Presenter lifecycle must run on main");
    [_displayLink invalidate];
    _displayLink = nil;
    os_unfair_lock_lock(&_lock);
    _running = NO;
    ++_generation;
    CVPixelBufferRef old = _pending;
    _pending = NULL;
    os_unfair_lock_unlock(&_lock);
    if (old) { CVPixelBufferRelease(old); }
    dispatch_sync(_renderQueue, ^{ [self->_layer flushAndRemoveImage]; });
    [_layer removeFromSuperlayer];
    _layer = nil;
    _view = nil;
}
@end
