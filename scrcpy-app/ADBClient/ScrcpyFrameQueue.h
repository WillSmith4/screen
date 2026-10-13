#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

@interface ScrcpyQueuedFrame : NSObject
@property(nonatomic, readonly) CMSampleBufferRef sampleBuffer;
@property(nonatomic, readonly) CVPixelBufferRef pixelBuffer;
@property(nonatomic, readonly) BOOL keyframe;
- (instancetype)initWithSampleBuffer:(CMSampleBufferRef)sample keyframe:(BOOL)keyframe;
- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)image keyframe:(BOOL)keyframe;
@end

// Serialized by the producer. Reuse the description until image metadata changes.
@interface ScrcpySampleBufferFactory : NSObject
@property(nonatomic, readonly) NSUInteger formatCreationCount;
- (ScrcpyQueuedFrame *)frameWithPixelBuffer:(CVPixelBufferRef)image ptsUS:(int64_t)pts keyframe:(BOOL)keyframe;
- (void)reset;
@end

@interface ScrcpyFrameQueue : NSObject
@property(nonatomic, readonly) NSUInteger count;
- (void)startWithFramesToBuffer:(int)frames;
- (void)stop;
- (NSUInteger)enqueue:(ScrcpyQueuedFrame *)frame;
- (ScrcpyQueuedFrame *)dequeue;
- (ScrcpyQueuedFrame *)dequeueWithTimeout:(CFTimeInterval)timeout;
// One Metal consumer sleeps without polling while the FIFO is empty. Stop or
// interrupt cancels the current wait; interrupt preserves queued frames.
- (BOOL)waitForEnqueue;
- (void)interruptWaiters;
@end
