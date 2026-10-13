#import "ScrcpyFramePresenter.h"
#import "frame-pacing.h"
#import "ScrcpyMetalRenderer.h"
#import "ScrcpyFrameQueue.h"
#import <QuartzCore/QuartzCore.h>
#import <os/lock.h>

// Standard buffering is adapted from VoidLink (2d9558e1), Acaki / TrueZhuanjia.
// Metal scheduling follows Moonlight Qt 57db2001: display-link drawable,
// preferredFrameLatency=1, latest pending frame, half-deadline arrival wait.
// See docs/cametaldisplaylink-pacing.md for attribution and iOS adaptation.

// Only decoded Metal images enter this mailbox. Replacing an unrendered image
// does not drop a compressed reference frame or affect VideoToolbox decoding.
@interface ScrcpyMetalMailbox : NSObject
@property(nonatomic, readonly) NSUInteger count;
- (BOOL)enqueue:(ScrcpyQueuedFrame *)frame;
- (ScrcpyQueuedFrame *)takeBefore:(CFTimeInterval)deadline;
- (void)interrupt;
- (void)clear;
@end
@implementation ScrcpyMetalMailbox {
    NSCondition *_condition;
    ScrcpyQueuedFrame *_latest;
    uint64_t _generation;
}
- (instancetype)init {
    if ((self = [super init])) { _condition = [NSCondition new]; }
    return self;
}
- (NSUInteger)count {
    [_condition lock];
    NSUInteger count = _latest ? 1 : 0;
    [_condition unlock];
    return count;
}
- (BOOL)enqueue:(ScrcpyQueuedFrame *)frame {
    [_condition lock];
    BOOL replaced = _latest != nil;
    _latest = frame;
    [_condition signal];
    [_condition unlock];
    return replaced;
}
- (ScrcpyQueuedFrame *)takeBefore:(CFTimeInterval)deadline {
    [_condition lock];
    uint64_t generation = _generation;
    while (!_latest && generation == _generation && !NSThread.currentThread.isCancelled) {
        CFTimeInterval remaining = deadline - CACurrentMediaTime();
        if (remaining <= 0) { break; }
        [_condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:remaining]];
    }
    ScrcpyQueuedFrame *frame = nil;
    if (generation == _generation && !NSThread.currentThread.isCancelled) {
        frame = _latest;
        _latest = nil;
    }
    [_condition unlock];
    return frame;
}
- (void)interrupt {
    [_condition lock];
    ++_generation;
    [_condition broadcast];
    [_condition unlock];
}
- (void)clear {
    [_condition lock];
    _latest = nil;
    ++_generation;
    [_condition broadcast];
    [_condition unlock];
}
@end

@interface ScrcpyFramePresenter () <CAMetalDisplayLinkDelegate>
@end
@implementation ScrcpyFramePresenter {
    os_unfair_lock _lock;
    NSThread *_renderThread;
    dispatch_semaphore_t _renderThreadExited;
    ScrcpyMetalMailbox *_metalFrames;
    CAMetalDisplayLink *_metalDisplayLink API_AVAILABLE(ios(17.0));
    NSRunLoop *_metalRunLoop;
    uint64_t _metalEmpty, _metalLate;
    CFTimeInterval _lastTick, _maxTickGap;
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
        _metalFrames = [ScrcpyMetalMailbox new];
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
    _ticks = _metalEmpty = _metalLate = 0;
    _lastTick = _maxTickGap = 0;
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
        NSLog(@"[FramePacing] renderer=%@ pendingFrames=1 prefill=off scheduling=CAMetalDisplayLink latency=1",
              _metal ? @"Metal (Experimental)" : @"Metal unavailable; select Standard and reconnect");
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

    if (!_useMetal && !_displayLink) {
        _displayLink = [view.window.screen displayLinkWithTarget:self selector:@selector(displayTick:)];
        [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSDefaultRunLoopMode];
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
    // Standard keeps its FIFO. Metal publishes the latest decoded IOSurface
    // to the display callback, as in Moonlight's CAMetalDisplayLink renderer.
    ScrcpyQueuedFrame *frame = _useMetal
        ? [[ScrcpyQueuedFrame alloc] initWithPixelBuffer:pixelBuffer keyframe:keyframe]
        : [_samples frameWithPixelBuffer:pixelBuffer ptsUS:pts keyframe:keyframe];
    if (frame) {
        ++_decoded;
        _replaced += _useMetal ? [_metalFrames enqueue:frame] : [_frames enqueue:frame];
    }
    os_unfair_lock_unlock(&_lock);
    CVPixelBufferRelease(pixelBuffer);
}

- (void)recordDisplayTick {
    CFTimeInterval now = CACurrentMediaTime();
    os_unfair_lock_lock(&_lock);
    ++_ticks;
    if (_lastTick > 0) { _maxTickGap = MAX(_maxTickGap, now - _lastTick); }
    _lastTick = now;
    if (now - _metricsStart >= 5.0) {
        double seconds = now - _metricsStart;
        uint64_t decoded = _decoded, replaced = _replaced, rendered = _renderCalls;
        NSUInteger queued = _useMetal ? _metalFrames.count : _frames.count;
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
            NSLog(@"[MetalDisplayLink] empty=%llu late=%llu maxCallbackGapMs=%.2f",
                  (unsigned long long)_metalEmpty, (unsigned long long)_metalLate, _maxTickGap * 1000);
            _metalEmpty = _metalLate = 0;
        }
        _ticks = 0;
        _maxTickGap = 0;
        _metricsStart = now;
        os_unfair_lock_lock(&_lock);
    }
    os_unfair_lock_unlock(&_lock);
}

- (void)displayTick:(CADisplayLink *)link {
    [self recordDisplayTick];
    [self renderStandardAtTarget:link.targetTimestamp];
}

- (CAMetalDisplayLink *)makeMetalDisplayLink:(CAMetalLayer *)layer API_AVAILABLE(ios(17.0)) {
    return [[CAMetalDisplayLink alloc] initWithMetalLayer:layer];
}

// A dedicated run loop prevents UIKit/SDL main-thread work from delaying the
// Metal callback. Unlike Moonlight's macOS main-run-loop integration, iOS input
// stays independent of the bounded wait for the next decoded image.
- (void)startMetalThread {
    NSAssert(NSThread.isMainThread, @"Metal thread lifecycle must run on main");
    if (!_useMetal || !_running || _paused || !_attached || !_metal || _renderThread) { return; }
    if (@available(iOS 17.0, *)) {
        int fps = _displayFrameRate;
        [_metal configureFrameRate:fps];
        dispatch_semaphore_t exited = dispatch_semaphore_create(0);
        _renderThreadExited = exited;
        __weak ScrcpyFramePresenter *weakSelf = self;
        _renderThread = [[NSThread alloc] initWithBlock:^{ @autoreleasepool {
            ScrcpyFramePresenter *owner = weakSelf;
            if (!owner) { dispatch_semaphore_signal(exited); return; }
            CAMetalDisplayLink *link = [owner makeMetalDisplayLink:owner->_metal.layer];
            link.preferredFrameRateRange = CAFrameRateRangeMake(fps, fps, fps);
            link.preferredFrameLatency = 1.0f;
            link.delegate = owner;
            NSRunLoop *runLoop = NSRunLoop.currentRunLoop;
            // Keep the loop alive even while the layer is temporarily hidden.
            NSPort *port = [NSPort port];
            [runLoop addPort:port forMode:NSDefaultRunLoopMode];
            os_unfair_lock_lock(&owner->_lock);
            owner->_metalDisplayLink = link;
            owner->_metalRunLoop = runLoop;
            os_unfair_lock_unlock(&owner->_lock);
            [link addToRunLoop:runLoop forMode:NSRunLoopCommonModes];
            while (!NSThread.currentThread.isCancelled) { @autoreleasepool {
                [runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            } }
            // Invalidate on the callback's thread before main drains the GPU.
            [link invalidate];
            link.delegate = nil;
            [runLoop removePort:port forMode:NSDefaultRunLoopMode];
            os_unfair_lock_lock(&owner->_lock);
            owner->_metalDisplayLink = nil;
            owner->_metalRunLoop = nil;
            os_unfair_lock_unlock(&owner->_lock);
            dispatch_semaphore_signal(exited);
        } }];
        _renderThread.name = @"ScrcpyMetalDisplayLink";
        _renderThread.qualityOfService = NSQualityOfServiceUserInteractive;
        [_renderThread start];
    }
}

- (void)metalDisplayLink:(CAMetalDisplayLink *)link needsUpdate:(CAMetalDisplayLinkUpdate *)update API_AVAILABLE(ios(17.0)) {
    os_unfair_lock_lock(&_lock);
    BOOL active = _running && !_paused && _attached && _metalDisplayLink == link;
    uint64_t generation = _generation;
    ScrcpyMetalMailbox *frames = _metalFrames;
    os_unfair_lock_unlock(&_lock);
    if (!active || NSThread.currentThread.isCancelled) { return; }
    [self recordDisplayTick];
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval remaining = update.targetTimestamp - now;
    if (remaining <= 0) { ++_metalLate; return; }
    // Keep the pending image if GPU capacity is exhausted. Never wait 100 ms
    // for presentation from inside a callback with an ~8 ms frame budget.
    if (![_metal tryAcquireGPUCapacity]) {
        os_unfair_lock_lock(&_lock); ++_metalBusy; os_unfair_lock_unlock(&_lock);
        return;
    }
    // Moonlight allows half of the remaining deadline for a new frame. Also
    // cap it to half a frame interval in case the OS supplies a distant target.
    CFTimeInterval wait = MIN(remaining, 1.0 / MAX(1, _displayFrameRate)) / 2;
    ScrcpyQueuedFrame *frame = [frames takeBefore:now + wait];
    os_unfair_lock_lock(&_lock);
    active = _running && !_paused && _attached && _generation == generation;
    os_unfair_lock_unlock(&_lock);
    if (!active || NSThread.currentThread.isCancelled || !frame) {
        [_metal releaseGPUCapacity];
        if (active && !frame) { ++_metalEmpty; }
        return;
    }
    ScrcpyMetalResult result = [_metal renderAcquiredPixelBuffer:frame.pixelBuffer drawable:update.drawable];
    os_unfair_lock_lock(&_lock);
    if (_generation == generation) {
        if (result == ScrcpyMetalPresented) { ++_renderCalls; }
        else if (result == ScrcpyMetalBusy) { ++_metalBusy; }
        else { ++_metalErrors; }
    }
    os_unfair_lock_unlock(&_lock);
}

- (void)stopMetalThread {
    NSAssert(NSThread.isMainThread, @"Metal thread lifecycle must run on main");
    if (!_renderThread) { return; }
    [_renderThread cancel];
    [_metalFrames interrupt];
    os_unfair_lock_lock(&_lock);
    NSRunLoop *runLoop = _metalRunLoop;
    os_unfair_lock_unlock(&_lock);
    if (runLoop) { CFRunLoopStop(runLoop.getCFRunLoop); CFRunLoopWakeUp(runLoop.getCFRunLoop); }
    // No callback dispatches synchronously to main. Join before layer changes.
    dispatch_semaphore_wait(_renderThreadExited, DISPATCH_TIME_FOREVER);
    _renderThread = nil;
    _renderThreadExited = nil;
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
    [_metalFrames clear];
    if (!paused) {
        _frames = [ScrcpyFrameQueue new];
        [_frames startWithFramesToBuffer:_framesToBuffer];
        // A callback from before pause must not consume a post-resume frame.
        _metalFrames = [ScrcpyMetalMailbox new];
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
    _ticks = _metalEmpty = _metalLate = 0;
    _lastTick = _maxTickGap = 0;
    _metricsStart = CACurrentMediaTime();
    [self startMetalThread];
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
    [_metalFrames clear];
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
