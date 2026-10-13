#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import "ScrcpyFrameQueue.h"
#include <assert.h>

// Minimal data adapter for the *unmodified* upstream enqueue policy below.
enum { FRAME_TYPE_IDR = 1, FRAME_TYPE_P = 2 };
@interface Frame : NSObject
@property int frameType;
@property int sequence;
- (void)setDurationFromNext:(Frame *)next;
@end
@implementation Frame
- (void)setDurationFromNext:(Frame *)next { /* Duration only affects upstream diagnostics. */ }
@end
@interface Metrics : NSObject
- (void)addValue:(float)value;
@end
@implementation Metrics
- (void)addValue:(float)value {}
@end
@interface ReferenceQueue : NSObject
@property(nonatomic, readonly) NSUInteger count;
- (int)_unsafeEnqueue:(Frame *)frame withDropTarget:(int)target;
- (Frame *)_popFrame;
@end
@implementation ReferenceQueue {
    NSMutableArray<Frame *> *_buffer;
    int _count, _framesIn, _currentSoftCap;
    BOOL _droppedLast;
    Metrics *_frameDropMetrics;
}
- (instancetype)init { if ((self = [super init])) { _buffer = [NSMutableArray new]; } return self; }
- (NSUInteger)count { return _count; }
- (void)_pushFrame:(Frame *)frame { [_buffer addObject:frame]; ++_count; }
- (Frame *)_popFrame { Frame *f = _buffer.firstObject; if (f) { [_buffer removeObjectAtIndex:0]; --_count; } return f; }
- (Frame *)_peekFrame { return _buffer.firstObject; }
- (void)_noteDroppedFrame:(Frame *)frame {}
#include "reference/VoidLinkQueuePolicy.inc"
@end

static CVPixelBufferRef image(size_t width) {
    CVPixelBufferRef buffer = NULL;
    assert(CVPixelBufferCreate(kCFAllocatorDefault, width, 8, kCVPixelFormatType_32ARGB, NULL, &buffer) == noErr);
    return buffer;
}
static int sequence(ScrcpyQueuedFrame *frame) {
    assert(frame);
    return (int)CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(frame.sampleBuffer), 1000000, kCMTimeRoundingMethod_Default).value;
}
int main(void) {
    @autoreleasepool {
        CVPixelBufferRef buffer = image(16);
        ScrcpySampleBufferFactory *samples = [ScrcpySampleBufferFactory new];
        for (int depth = 0; depth <= 5; ++depth) {
            ScrcpyFrameQueue *queue = [ScrcpyFrameQueue new];
            [queue startWithFramesToBuffer:depth];
            ReferenceQueue *reference = [ReferenceQueue new];
            uint32_t random = 12345;
            for (int i = 0; i < 10000; ++i) {
                @autoreleasepool {
                    random = random * 1664525 + 1013904223;
                    // Compare within the reference ring's physical capacity.
                    if (reference.count >= 14 || (random % 5 == 0 && reference.count)) {
                        assert(sequence([queue dequeue]) == [reference _popFrame].sequence);
                    } else {
                        Frame *frame = [Frame new];
                        frame.sequence = i;
                        frame.frameType = i % 97 == 0 ? FRAME_TYPE_IDR : FRAME_TYPE_P;
                        NSUInteger ours = [queue enqueue:[samples frameWithPixelBuffer:buffer ptsUS:i keyframe:frame.frameType == FRAME_TYPE_IDR]];
                        assert(ours == [reference _unsafeEnqueue:frame withDropTarget:MAX(1, depth)]);
                    }
                    assert(queue.count == reference.count);
                }
            }
            while (reference.count) { assert(sequence([queue dequeue]) == [reference _popFrame].sequence); }
            assert(![queue dequeue]);
        }
        assert(samples.formatCreationCount == 1);
        CVPixelBufferRef resized = image(32);
        assert([samples frameWithPixelBuffer:resized ptsUS:0 keyframe:YES]);
        assert(samples.formatCreationCount == 2);
        CVPixelBufferRelease(resized);
        ScrcpyFrameQueue *queue = [ScrcpyFrameQueue new];
        [queue startWithFramesToBuffer:0];
        ScrcpyQueuedFrame *arrival = [samples frameWithPixelBuffer:buffer ptsUS:123 keyframe:YES];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            [queue enqueue:arrival];
        });
        assert(sequence([queue dequeueWithTimeout:0.5]) == 123);
        CFTimeInterval start = CACurrentMediaTime();
        assert(![queue dequeueWithTimeout:0.01]);
        assert(CACurrentMediaTime() - start >= 0.009);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{ [queue stop]; });
        assert(![queue dequeueWithTimeout:0.5]);
        [queue startWithFramesToBuffer:1];
        for (int i = 0; i < 1000; ++i) { [queue enqueue:arrival]; }
        assert(queue.count == 15); // IDR storm stays memory-safe.
        [queue stop];
        assert(queue.count == 0);
        CVPixelBufferRelease(buffer);
        puts("PASS: 60,000 operations match unmodified VoidLink policy at depths 0-5; FIFO/alternate drops/IDR; format reuse and resize; deadline wait, stop and bounded IDR overflow");
    }
}
