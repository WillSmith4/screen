#import "ScrcpyVideoDecoder.h"
#import "native-video.h"

extern void ScrcpyTryResetVideo(void);

static CMVideoCodecType codecType(int codec) {
    return codec == SC_NATIVE_HEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264;
}

bool ScrcpyNativeVideoSupported(int codec) {
    // Hardware enforcement/introspection keys are available starting in iOS
    // 17. Older supported systems retain the existing FFmpeg/VT path.
    if (@available(iOS 17.0, *)) {
        return (codec == SC_NATIVE_H264 || codec == SC_NATIVE_HEVC)
            && VTIsHardwareDecodeSupported(codecType(codec));
    }
    return false;
}

void *ScrcpyNativeVideoCreate(int codec, sc_native_video_output output, void *userdata) {
    ScrcpyVideoDecoder *decoder = [[ScrcpyVideoDecoder alloc] initWithCodec:codecType(codec)
        requireHardware:YES output:^(CVPixelBufferRef buffer, int64_t pts) {
            output(userdata, buffer, (int)CVPixelBufferGetWidth(buffer), (int)CVPixelBufferGetHeight(buffer), pts);
        } recovery:^(OSStatus status) { ScrcpyTryResetVideo(); }];
    return (__bridge_retained void *)decoder;
}

bool ScrcpyNativeVideoPush(void *decoder, const uint8_t *data, size_t size, int64_t pts, bool keyframe) {
    @autoreleasepool {
        return [(__bridge ScrcpyVideoDecoder *)decoder submitAnnexB:data size:size ptsUS:pts keyframe:keyframe];
    }
}
void ScrcpyNativeVideoReset(void *decoder) { [(__bridge ScrcpyVideoDecoder *)decoder reset]; }
void ScrcpyNativeVideoDestroy(void *decoder) {
    ScrcpyVideoDecoder *owned = (__bridge_transfer ScrcpyVideoDecoder *)decoder;
    [owned close];
}
void ScrcpyRetainPixelBuffer(void *buffer) { CVPixelBufferRetain(buffer); }
void ScrcpyReleasePixelBuffer(void *buffer) { CVPixelBufferRelease(buffer); }
