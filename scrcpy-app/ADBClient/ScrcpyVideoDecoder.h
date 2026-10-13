#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>

// Submission/reset/close are serialized by the scrcpy packet thread. Outputs
// are serialized separately and drained before a stream session changes.
@interface ScrcpyVideoDecoder : NSObject
- (instancetype)initWithCodec:(CMVideoCodecType)codec
             requireHardware:(BOOL)requireHardware
                      output:(void (^)(CVPixelBufferRef, int64_t, BOOL))output
                    recovery:(void (^)(OSStatus))recovery;
- (BOOL)submitAnnexB:(const uint8_t *)data size:(size_t)size
              ptsUS:(int64_t)pts keyframe:(BOOL)keyframe;
- (void)drain;
- (void)reset;
- (void)close;
@end
