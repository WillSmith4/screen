#import "ScrcpyFramePresenter.h"
#import "frame-pacing.h"
#import "ScrcpyMetalRenderer.h"
#import "ScrcpyFrameQueue.h"
#import <QuartzCore/QuartzCore.h>
#import <os/lock.h>

// Metal thread/dequeue scheduling adapted from VoidLink (2d9558e1),
// Acaki / TrueZhuanjia. GPL-3.0; docs/licenses/VoidLink-GPL-3.0.txt.
@implementation ScrcpyFramePresenter {
    os_unfair_lock _lock;
    NSThread *_renderThread;
    dispatch_semaphore_t _renderThreadExited;
    ScrcpyFrameQueue *_metalFrames;
    void (^_renderer)(CMSampleBufferRef, AVSampleBufferDisplayLayer *, CFTimeInterval);
    ScrcpyFrameQueue *_frames;
    ScrcpySampleBufferFactory *_samples;
    int _framesToBuffer;
    BOOL _asyncDequeue, _needRequeuing;
    CADisplayLink *_displayLink;
    AVSampleBufferDisplayLayer *_layer;
    __weak UIView *_view;
    BOOL _running, _paused, _attached;
    int _requestedFrameRate, _displayFrameRate;
    uint64_t _generation, _decoded, _replaced, _renderCalls, _ticks, _metalBusy, _metalErrors;
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
    }
    return self;
}

- (void)startWithFrameRate:(int)frameRate {
    [self startWithFrameRate:frameRate useMetal:NO];
}

- (ScrcpyMetalRenderer *)makeMetalRenderer { return [ScrcpyMetalRenderer new]; }

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
    _decoded = _replaced = _renderCalls = _metalBusy = _metalErrors = 0;
    os_unfair_lock_unlock(&_lock);
    _ticks = 0;
    _metricsStart = CACurrentMediaTime();
}

- (void)attachToView:(UIView *)view hardwareDecoding:(BOOL)hardwareDecoding {
    NSAssert(NSThread.isMainThread, @"View attachment must run on main");
    if (!_running || !view.window) { return; }
    if (_view != view) {
        // Drain presentation before moving its layer to a different view.
        os_unfair_lock_lock(&_lock);
        _attached = NO;
        ++_generation;
        os_unfair_lock_unlock(&_lock);
        [self stopMetalThread];
        [_metal drain];
        [_metal.layer removeFromSuperlayer];
        _metal = nil;
        [_layer removeFromSuperlayer];
        _view = view;
        _layer = nil;
    }
    if (hardwareDecoding && _useMetal && !_metal) {
        _metal = [self makeMetalRenderer];
        if (_metal) { [view.layer addSublayer:_metal.layer]; }
        NSLog(@"[FramePacing] renderer=%@ fifoHighWaterMark=%d prefill=off scheduling=dedicated-thread gpuBudget=on",
              _metal ? @"Metal (Experimental)" : @"Metal unavailable; select Standard and reconnect", _framesToBuffer);
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
    _metal.layer.contentsScale = view.window.screen.nativeScale;
    _metal.layer.drawableSize = CGSizeMake(view.bounds.size.width * view.window.screen.nativeScale,
                                           view.bounds.size.height * view.window.screen.nativeScale);
    [CATransaction commit];

    if (!_displayLink) {
        _displayLink = [view.window.screen displayLinkWithTarget:self selector:@selector(displayTick:)];
        // Match the reference's Standard/default and Metal/common modes.
        [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:_useMetal ? NSRunLoopCommonModes : NSDefaultRunLoopMode];
    }
    int fps = sc_display_frame_rate(_requestedFrameRate, (int)view.window.screen.maximumFramesPerSecond);
    if (_renderThread && _displayFrameRate != fps) {
        os_unfair_lock_lock(&_lock);
        _attached = NO;
        ++_generation;
        os_unfair_lock_unlock(&_lock);
        [self stopMetalThread];
        [_metal drain];
    }
    os_unfair_lock_lock(&_lock);
    _displayFrameRate = fps;
    _attached = YES;
    os_unfair_lock_unlock(&_lock);
    [self startMetalThread];
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
    // Both backends use the reference FIFO/drop policy. Standard prepares its
    // sample on the producer; Metal retains the IOSurface-backed pixel buffer.
    ScrcpyQueuedFrame *frame = _useMetal
        ? [[ScrcpyQueuedFrame alloc] initWithPixelBuffer:pixelBuffer keyframe:keyframe]
        : [_samples frameWithPixelBuffer:pixelBuffer ptsUS:pts keyframe:keyframe];
    if (frame) { ++_decoded; _replaced += [_frames enqueue:frame]; }
    os_unfair_lock_unlock(&_lock);
    CVPixelBufferRelease(pixelBuffer);
}

- (void)displayTick:(CADisplayLink *)link {
    ++_ticks;
    CFTimeInterval now = CACurrentMediaTime();
    os_unfair_lock_lock(&_lock);
    if (now - _metricsStart >= 5.0) {
        double seconds = now - _metricsStart;
        uint64_t decoded = _decoded, replaced = _replaced, rendered = _renderCalls;
        NSUInteger queued = _frames.count;
        uint64_t busy = _metalBusy, errors = _metalErrors;
        _decoded = _replaced = _renderCalls = _metalBusy = _metalErrors = 0;
        os_unfair_lock_unlock(&_lock);
        NSLog(@"[FramePacing] callbacks=%.1f/s decoded=%.1f/s submitted=%.1f/s queueDrops=%llu gpuBusy=%llu gpuErrors=%llu queued=%lu mode=%@",
              _ticks / seconds, decoded / seconds, rendered / seconds, (unsigned long long)replaced,
              (unsigned long long)busy, (unsigned long long)errors,
              (unsigned long)queued, _useMetal ? @"Metal" : @"Standard");
        if (_useMetal && _metal) {
            ScrcpyMetalStatistics stats = [_metal takeStatistics];
            NSLog(@"[MetalPresentation] presented=%.1f/s unpresentedCallbacks=%llu maxPresentGapMs=%.2f gpuAverageMs=%.3f",
                  stats.presented / seconds, (unsigned long long)stats.unpresentedCallbacks,
                  stats.maxPresentationGap * 1000, stats.averageGPUTime * 1000);
        }
        _ticks = 0;
        _metricsStart = now;
        os_unfair_lock_lock(&_lock);
    }
    os_unfair_lock_unlock(&_lock);
    // In Metal this clock only requests ProMotion and reports metrics, as in
    // VoidLink. A frame arriving just after a tick need not wait another 8 ms.
    if (!_useMetal) { [self renderStandardAtTarget:link.targetTimestamp]; }
}

// Lifecycle runs on main. Unlike Standard, Metal never waits for a prefill or
// display-link tick. One persistent high-QoS thread sleeps on frame arrival.
- (void)startMetalThread {
    NSAssert(NSThread.isMainThread, @"Metal thread lifecycle must run on main");
    if (!_useMetal || !_running || _paused || !_attached || !_metal || _renderThread) { return; }
    uint64_t generation = _generation;
    ScrcpyFrameQueue *queue = _frames;
    _metalFrames = queue;
    ScrcpyMetalRenderer *metal = _metal;
    CFTimeInterval duration = 1.0 / MAX(1, _displayFrameRate);
    [metal configureFrameRate:_displayFrameRate];
    dispatch_semaphore_t exited = dispatch_semaphore_create(0);
    _renderThreadExited = exited;
    __weak ScrcpyFramePresenter *weakSelf = self;
    _renderThread = [[NSThread alloc] initWithBlock:^{
        while (!NSThread.currentThread.isCancelled) { @autoreleasepool {
            if (![metal waitForGPUCapacity]) {
                ScrcpyFramePresenter *owner = weakSelf;
                if (owner) {
                    os_unfair_lock_lock(&owner->_lock);
                    if (owner->_generation == generation) { ++owner->_metalBusy; }
                    os_unfair_lock_unlock(&owner->_lock);
                }
                continue;
            }
            if (NSThread.currentThread.isCancelled || ![queue waitForEnqueue]) {
                [metal releaseGPUCapacity];
                break;
            }
            ScrcpyQueuedFrame *frame = [queue dequeueWithTimeout:MAX(0, duration - metal.averageGPUTime)];
            ScrcpyFramePresenter *owner = weakSelf;
            BOOL active = NO;
            if (owner) {
                os_unfair_lock_lock(&owner->_lock);
                active = owner->_running && !owner->_paused && owner->_attached && owner->_generation == generation;
                os_unfair_lock_unlock(&owner->_lock);
            }
            if (!active || NSThread.currentThread.isCancelled || !frame) {
                [metal releaseGPUCapacity];
                if (!active || NSThread.currentThread.isCancelled) { break; }
                continue;
            }
            ScrcpyMetalResult result = [metal renderAcquiredPixelBuffer:frame.pixelBuffer minimumDuration:duration];
            os_unfair_lock_lock(&owner->_lock);
            if (owner->_generation == generation) {
                if (result == ScrcpyMetalPresented) { ++owner->_renderCalls; }
                else if (result == ScrcpyMetalBusy) { ++owner->_metalBusy; }
                else { ++owner->_metalErrors; }
            }
            os_unfair_lock_unlock(&owner->_lock);
        } }
        dispatch_semaphore_signal(exited);
    }];
    _renderThread.name = @"ScrcpyMetalVideoRenderer";
    _renderThread.qualityOfService = NSQualityOfServiceUserInteractive;
    [_renderThread start];
}

- (void)stopMetalThread {
    NSAssert(NSThread.isMainThread, @"Metal thread lifecycle must run on main");
    if (!_renderThread) { return; }
    [_renderThread cancel];
    [_metalFrames interruptWaiters];
    // No path in this worker dispatches synchronously to main. Wait until it
    // releases its reserved slot before draining/reusing/detaching the layer.
    dispatch_semaphore_wait(_renderThreadExited, DISPATCH_TIME_FOREVER);
    _renderThread = nil;
    _renderThreadExited = nil;
    _metalFrames = nil;
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
    // A producer may submit immediately on resume. Do not let it start a
    // continuously-fed Metal worker ahead of the synchronous drain below.
    BOOL attached = _attached;
    _attached = NO;
    ++_generation;
    _decoded = _replaced = _renderCalls = _metalBusy = _metalErrors = 0;
    [_frames stop];
    if (!paused) {
        _frames = [ScrcpyFrameQueue new];
        [_frames startWithFramesToBuffer:_framesToBuffer];
    }
    [_samples reset];
    _needRequeuing = _framesToBuffer > 0;
    os_unfair_lock_unlock(&_lock);
    _displayLink.paused = paused;
    [self stopMetalThread];
    [_layer flush];
    [_metal drain];
    os_unfair_lock_lock(&_lock);
    _attached = attached;
    os_unfair_lock_unlock(&_lock);
    [self startMetalThread];
    _ticks = 0;
    _metricsStart = CACurrentMediaTime();
}

- (void)stop {
    NSAssert(NSThread.isMainThread, @"Presenter lifecycle must run on main");
    [_displayLink invalidate];
    _displayLink = nil;
    os_unfair_lock_lock(&_lock);
    _running = NO;
    _attached = NO;
    ++_generation;
    [_frames stop];
    [_samples reset];
    os_unfair_lock_unlock(&_lock);
    [self stopMetalThread];
    [_layer flushAndRemoveImage];
    [_metal drain];
    [_metal.layer removeFromSuperlayer];
    _metal = nil;
    [_layer removeFromSuperlayer];
    _layer = nil;
    _view = nil;
}
@end
