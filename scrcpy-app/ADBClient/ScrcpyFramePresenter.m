#import "ScrcpyFramePresenter.h"
#import "frame-pacing.h"
#import "ScrcpyMetalRenderer.h"
#import "ScrcpyFrameQueue.h"
#import <QuartzCore/QuartzCore.h>
#import <os/lock.h>

@implementation ScrcpyFramePresenter {
    os_unfair_lock _lock;
    CVPixelBufferRef _pending;
    dispatch_queue_t _renderQueue;
    void (^_renderer)(CMSampleBufferRef, AVSampleBufferDisplayLayer *, CFTimeInterval);
    ScrcpyFrameQueue *_frames;
    ScrcpySampleBufferFactory *_samples;
    int _framesToBuffer;
    BOOL _asyncDequeue, _needRequeuing;
    CADisplayLink *_displayLink;
    AVSampleBufferDisplayLayer *_layer;
    __weak UIView *_view;
    BOOL _running, _paused, _workScheduled;
    int _requestedFrameRate;
    uint64_t _generation, _decoded, _replaced, _renderCalls, _ticks;
    CFTimeInterval _metricsStart;
    BOOL _useMetal;
    ScrcpyMetalRenderer *_metal;
}

- (instancetype)initWithRenderer:(void (^)(CMSampleBufferRef, AVSampleBufferDisplayLayer *, CFTimeInterval))renderer {
    if ((self = [super init])) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _renderer = [renderer copy];
        _frames = [ScrcpyFrameQueue new];
        _samples = [ScrcpySampleBufferFactory new];
        _renderQueue = dispatch_queue_create("scrcpy.video.presentation",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    }
    return self;
}

- (void)startWithFrameRate:(int)frameRate {
    [self startWithFrameRate:frameRate useMetal:NO];
}

- (void)startWithFrameRate:(int)frameRate useMetal:(BOOL)useMetal {
    [self startWithFrameRate:frameRate useMetal:useMetal framesToBuffer:1 asyncDequeue:YES];
}

- (void)startWithFrameRate:(int)frameRate useMetal:(BOOL)useMetal framesToBuffer:(int)frames asyncDequeue:(BOOL)asyncDequeue {
    NSAssert(NSThread.isMainThread, @"Presenter lifecycle must run on main");
    [self stop];
    _requestedFrameRate = frameRate;
    os_unfair_lock_lock(&_lock);
    _useMetal = useMetal;
    _framesToBuffer = MAX(0, MIN(5, frames));
    _asyncDequeue = asyncDequeue;
    _needRequeuing = _framesToBuffer > 0;
    _frames = [ScrcpyFrameQueue new];
    [_frames startWithFramesToBuffer:_framesToBuffer];
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
        [_metal drain];
        [_metal.layer removeFromSuperlayer];
        _metal = nil;
        [_layer removeFromSuperlayer];
        _view = view;
        _layer = nil;
    }
    if (hardwareDecoding && _useMetal && !_metal) {
        _metal = [ScrcpyMetalRenderer new];
        if (_metal) { [view.layer addSublayer:_metal.layer]; }
        NSLog(@"[FramePacing] renderer=%@", _metal ? @"Metal (Experimental)" : @"Metal unavailable; select Standard and reconnect");
    }
    if (hardwareDecoding && !_useMetal && !_layer) {
        _layer = [AVSampleBufferDisplayLayer layer];
        _layer.videoGravity = AVLayerVideoGravityResizeAspect;
        _layer.backgroundColor = UIColor.blackColor.CGColor;
        // VoidLink's Standard optimization: leave controlTimebase unset.
        [view.layer addSublayer:_layer];
        NSLog(@"[FramePacing] renderer=Standard queueBuffering=%d asyncDequeue=%d timebase=off", _framesToBuffer, _asyncDequeue);
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _layer.frame = view.bounds;
    _layer.contentsScale = view.window.screen.scale;
    _metal.layer.frame = view.bounds;
    _metal.layer.contentsScale = view.window.screen.scale;
    _metal.layer.drawableSize = CGSizeMake(view.bounds.size.width * view.window.screen.scale,
                                           view.bounds.size.height * view.window.screen.scale);
    [CATransaction commit];

    if (!_displayLink) {
        _displayLink = [view.window.screen displayLinkWithTarget:self selector:@selector(displayTick:)];
        // Match the reference's Standard/default and Metal/common modes.
        [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:_useMetal ? NSRunLoopCommonModes : NSDefaultRunLoopMode];
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
    [self submitPixelBuffer:pixelBuffer ptsUS:0 keyframe:NO];
}

- (void)submitPixelBuffer:(CVPixelBufferRef)pixelBuffer ptsUS:(int64_t)pts keyframe:(BOOL)keyframe {
    if (!pixelBuffer) { return; }
    CVPixelBufferRetain(pixelBuffer);
    os_unfair_lock_lock(&_lock);
    if (!_running || _paused) {
        os_unfair_lock_unlock(&_lock);
        CVPixelBufferRelease(pixelBuffer);
        return;
    }
    if (!_useMetal) {
        // Prepare the sample on the producer, as VoidLink does. The format is
        // cached; the display callback only changes output PTS and enqueues.
        ScrcpyQueuedFrame *frame = [_samples frameWithPixelBuffer:pixelBuffer ptsUS:pts keyframe:keyframe];
        if (frame) { ++_decoded; _replaced += [_frames enqueue:frame]; }
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
        NSLog(@"[FramePacing] callbacks=%.1f/s decoded=%.1f/s renderCalls=%.1f/s dropped=%llu queued=%lu mode=%@",
              _ticks / seconds, decoded / seconds, rendered / seconds, (unsigned long long)replaced,
              (unsigned long)(_useMetal ? (_pending != NULL) : _frames.count), _useMetal ? @"Metal" : @"Standard");
        _ticks = 0;
        _metricsStart = now;
        os_unfair_lock_lock(&_lock);
    }
    if (!_useMetal) {
        os_unfair_lock_unlock(&_lock);
        [self renderStandardAtTarget:link.targetTimestamp];
        return;
    }
    if (!_running || _paused || !_pending || _workScheduled || (!layer && !_metal)) {
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
                // The session's explicit setting selects exactly one backend.
                // Busy GPU work drops presentation, never switches renderers.
                [self->_metal renderPixelBuffer:frame targetTime:target];
                CVPixelBufferRelease(frame);
            }
            os_unfair_lock_lock(&self->_lock);
            if (frame) { ++self->_renderCalls; }
            self->_workScheduled = NO;
            os_unfair_lock_unlock(&self->_lock);
        }
    });
}

- (void)presentStandardFrame:(ScrcpyQueuedFrame *)frame target:(CFTimeInterval)target generation:(uint64_t)generation {
    NSAssert(NSThread.isMainThread, @"Standard presentation belongs to the display callback");
    if (!frame || !_running || _paused || _generation != generation || !_layer) { return; }
    CMSampleBufferSetOutputPresentationTimeStamp(frame.sampleBuffer, CMTimeMakeWithSeconds(target, NSEC_PER_SEC));
    _renderer(frame.sampleBuffer, _layer, target);
    os_unfair_lock_lock(&_lock);
    ++_renderCalls;
    os_unfair_lock_unlock(&_lock);
}

- (void)renderStandardAtTarget:(CFTimeInterval)target {
    if (!_running || _paused || !_layer) { return; }
    if (_layer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        [_layer flushAndRemoveImage];
        if (self.recoveryHandler) { self.recoveryHandler(); }
    }
    if (_needRequeuing && _frames.count <= MAX(_framesToBuffer - 1, 0)) { return; }
    _needRequeuing = NO;
    uint64_t generation = _generation;
    CFTimeInterval waitFor = target - CACurrentMediaTime();
    if (_asyncDequeue) {
        // Like VoidLink's dequeueWithTimeout:completion:, wait on a high-QoS
        // worker and deliver on main. Lifecycle generation rejects old results.
        ScrcpyFrameQueue *queue = _frames;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            ScrcpyQueuedFrame *frame = [queue dequeueWithTimeout:waitFor];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self presentStandardFrame:frame target:target generation:generation];
            });
        });
    } else {
        ScrcpyQueuedFrame *frame = [_frames dequeueWithTimeout:waitFor];
        [self presentStandardFrame:frame target:target generation:generation];
    }
}

- (void)setPaused:(BOOL)paused {
    NSAssert(NSThread.isMainThread, @"Presenter lifecycle must run on main");
    os_unfair_lock_lock(&_lock);
    _paused = paused;
    ++_generation;
    _decoded = _replaced = _renderCalls = 0;
    CVPixelBufferRef old = _pending;
    _pending = NULL;
    [_frames stop];
    if (!paused) {
        _frames = [ScrcpyFrameQueue new];
        [_frames startWithFramesToBuffer:_framesToBuffer];
    }
    [_samples reset];
    _needRequeuing = _framesToBuffer > 0;
    os_unfair_lock_unlock(&_lock);
    if (old) { CVPixelBufferRelease(old); }
    _displayLink.paused = paused;
    // No synchronous dispatch to main occurs on the presentation worker.
    dispatch_sync(_renderQueue, ^{ [self->_layer flush]; [self->_metal drain]; });
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
    [_frames stop];
    [_samples reset];
    os_unfair_lock_unlock(&_lock);
    if (old) { CVPixelBufferRelease(old); }
    dispatch_sync(_renderQueue, ^{ [self->_layer flushAndRemoveImage]; [self->_metal drain]; });
    [_metal.layer removeFromSuperlayer];
    _metal = nil;
    [_layer removeFromSuperlayer];
    _layer = nil;
    _view = nil;
}
@end
