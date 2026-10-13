// Frame pacing policy adapted from VoidLink Utility/FrameQueue.m (2d9558e1).
// Original by Andy Grundman, ported by Acaki, modified by TrueZhuanjia.
// Copyright (c) 2025 Moonlight Stream; (c) 2026 TrueZhuanjia.
// GPL-3.0; see docs/licenses/VoidLink-GPL-3.0.txt and docs/voidlink-standard-pacing.md.
#import "ScrcpyFrameQueue.h"
#import <QuartzCore/QuartzCore.h>
#import <os/lock.h>
#include <unistd.h>

@implementation ScrcpyQueuedFrame {
    CMSampleBufferRef _sampleBuffer;
    CVPixelBufferRef _pixelBuffer;
    BOOL _keyframe;
}
- (instancetype)initWithSampleBuffer:(CMSampleBufferRef)sample keyframe:(BOOL)keyframe {
    if ((self = [super init])) { _sampleBuffer = (CMSampleBufferRef)CFRetain(sample); _keyframe = keyframe; }
    return self;
}
- (CMSampleBufferRef)sampleBuffer { return _sampleBuffer; }
- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)image keyframe:(BOOL)keyframe {
    if ((self = [super init])) { _pixelBuffer = CVPixelBufferRetain(image); _keyframe = keyframe; }
    return self;
}
- (CVPixelBufferRef)pixelBuffer {
    return _pixelBuffer ?: CMSampleBufferGetImageBuffer(_sampleBuffer);
}
- (BOOL)keyframe { return _keyframe; }
- (void)dealloc {
    if (_sampleBuffer) { CFRelease(_sampleBuffer); }
    if (_pixelBuffer) { CVPixelBufferRelease(_pixelBuffer); }
}
@end

@implementation ScrcpySampleBufferFactory {
    CMVideoFormatDescriptionRef _format;
    NSUInteger _formatCreationCount;
}
- (NSUInteger)formatCreationCount { return _formatCreationCount; }
- (ScrcpyQueuedFrame *)frameWithPixelBuffer:(CVPixelBufferRef)image ptsUS:(int64_t)pts keyframe:(BOOL)keyframe {
    if (!_format || !CMVideoFormatDescriptionMatchesImageBuffer(_format, image)) {
        CMVideoFormatDescriptionRef next = NULL;
        if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, image, &next) != noErr) { return nil; }
        if (_format) { CFRelease(_format); }
        _format = next;
        ++_formatCreationCount;
    }
    CMSampleTimingInfo timing = {kCMTimeInvalid, CMTimeMake(pts, 1000000), kCMTimeInvalid};
    CMSampleBufferRef sample = NULL;
    if (CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, image, _format, &timing, &sample) != noErr) { return nil; }
    ScrcpyQueuedFrame *frame = [[ScrcpyQueuedFrame alloc] initWithSampleBuffer:sample keyframe:keyframe];
    CFRelease(sample);
    return frame;
}
- (void)reset { if (_format) { CFRelease(_format); _format = NULL; } }
- (void)dealloc { [self reset]; }
@end

@implementation ScrcpyFrameQueue {
    os_unfair_lock _lock;
    ScrcpyQueuedFrame *_frames[15];
    NSUInteger _head, _tail, _count;
    int _highWaterMark;
    BOOL _droppedLast, _paused;
    uint64_t _generation;
}
- (instancetype)init {
    if ((self = [super init])) { _lock = OS_UNFAIR_LOCK_INIT; _paused = YES; }
    return self;
}
- (void)clearLocked {
    for (NSUInteger i = 0; i < 15; ++i) { _frames[i] = nil; }
    _head = _tail = _count = 0;
    _droppedLast = NO;
    ++_generation;
}
- (void)startWithFramesToBuffer:(int)frames {
    os_unfair_lock_lock(&_lock);
    [self clearLocked];
    _highWaterMark = MAX(1, MIN(5, frames));
    _paused = NO;
    os_unfair_lock_unlock(&_lock);
}
- (void)stop {
    os_unfair_lock_lock(&_lock);
    _paused = YES;
    [self clearLocked];
    os_unfair_lock_unlock(&_lock);
}
- (NSUInteger)count {
    os_unfair_lock_lock(&_lock);
    NSUInteger count = _count;
    os_unfair_lock_unlock(&_lock);
    return count;
}
- (ScrcpyQueuedFrame *)popLocked {
    ScrcpyQueuedFrame *frame = _frames[_head];
    _frames[_head] = nil;
    _head = (_head + 1) % 15;
    --_count;
    return frame;
}
- (void)pushLocked:(ScrcpyQueuedFrame *)frame {
    _frames[_tail] = frame;
    _tail = (_tail + 1) % 15;
    ++_count;
}
- (NSUInteger)enqueue:(ScrcpyQueuedFrame *)frame {
    os_unfair_lock_lock(&_lock);
    if (_paused) { os_unfair_lock_unlock(&_lock); return 0; }
    NSUInteger dropped = 0;
    // Safety at the physical ring limit: the reference permits IDRs past its
    // 15 slots. Never overwrite a live slot with an inconsistent count.
    if (_count == 15) { [self popLocked]; ++dropped; }
    if (frame.keyframe || _count < _highWaterMark) {
        [self pushLocked:frame];
        _droppedLast = NO;
    } else if (!_droppedLast) {
        ++dropped; // Alternate: discard the incoming frame...
        _droppedLast = YES;
    } else {
        // ...then the oldest non-IDR, retaining the incoming frame.
        if (!_frames[_head].keyframe) { [self popLocked]; ++dropped; }
        [self pushLocked:frame];
        _droppedLast = NO;
    }
    os_unfair_lock_unlock(&_lock);
    return dropped;
}
- (ScrcpyQueuedFrame *)dequeue {
    os_unfair_lock_lock(&_lock);
    ScrcpyQueuedFrame *frame = !_paused && _count ? [self popLocked] : nil;
    os_unfair_lock_unlock(&_lock);
    return frame;
}
- (ScrcpyQueuedFrame *)dequeueWithTimeout:(CFTimeInterval)timeout {
    CFTimeInterval deadline = CACurrentMediaTime() + timeout;
    os_unfair_lock_lock(&_lock);
    uint64_t generation = _generation;
    os_unfair_lock_unlock(&_lock);
    int round = 0;
    // Same 100us retry and at-least-one-attempt behavior as VoidLink.
    do {
        if (round++) { usleep(100); }
        os_unfair_lock_lock(&_lock);
        BOOL stopped = _paused || _generation != generation;
        ScrcpyQueuedFrame *frame = !stopped && _count ? [self popLocked] : nil;
        os_unfair_lock_unlock(&_lock);
        if (stopped || frame) { return frame; }
    } while (CACurrentMediaTime() < deadline);
    return nil;
}
@end
