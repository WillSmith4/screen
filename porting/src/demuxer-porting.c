//
//  demuxer-porting.c
//  scrcpy-module
//
//  Created by Ethan on 2023/5/20.
//

#define avcodec_alloc_context3(...)     avcodec_alloc_context3_hijack(__VA_ARGS__)
#define avcodec_open2(...)              avcodec_open2_hijack(__VA_ARGS__)

#include "demuxer.c"

#undef avcodec_alloc_context3
#undef avcodec_open2
#include "native-video.h"

int ScrcpyEnableHardwareDecoding(void);

static int native_codec(enum AVCodecID codec) {
    return codec == AV_CODEC_ID_H264 ? SC_NATIVE_H264
         : codec == AV_CODEC_ID_HEVC ? SC_NATIVE_HEVC : 0;
}

int avcodec_open2(AVCodecContext *, const AVCodec *, AVDictionary **);
int avcodec_open2_hijack(AVCodecContext *context, const AVCodec *codec, AVDictionary **options) {
    if (ScrcpyEnableHardwareDecoding() == 1
            && ScrcpyNativeVideoSupported(native_codec(context->codec_id))) {
        // The context still describes the stream to recording and screen sinks.
        // Compressed video goes directly to CoreMedia/VideoToolbox, not avcodec.
        return 0;
    }
    return avcodec_open2(context, codec, options);
}

AVCodecContext *avcodec_alloc_context3(const AVCodec *codec);
AVCodecContext *avcodec_alloc_context3_hijack(const AVCodec *codec) {
    AVCodecContext *context = avcodec_alloc_context3(codec);
    if (!context) { return NULL; }
    if (ScrcpyEnableHardwareDecoding() == 1
            && ScrcpyNativeVideoSupported(native_codec(context->codec_id))) {
        return context;
    }
    
    if (context->codec_type != AVMEDIA_TYPE_VIDEO ||
        ScrcpyEnableHardwareDecoding() == 0) {
        printf("hardware decoding is disabled, codec_type=%d(video=%d|audio=%d), ScrcpyEnableHardwareDecoding=%d\n",
               context->codec_type, AVMEDIA_TYPE_VIDEO, AVMEDIA_TYPE_AUDIO, ScrcpyEnableHardwareDecoding());
        return context;
    }
    
    // Create context with hardware decoder
    context->hw_device_ctx = av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_VIDEOTOOLBOX);
    if (!context->hw_device_ctx) {
        avcodec_free_context(&context);
        return NULL;
    }

    if (av_hwdevice_ctx_init(context->hw_device_ctx) < 0) {
        av_buffer_unref(&context->hw_device_ctx);
        avcodec_free_context(&context);
        return NULL;
    }

    return context;
}
