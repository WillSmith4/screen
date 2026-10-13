#ifndef SC_NATIVE_VIDEO_H
#define SC_NATIVE_VIDEO_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum sc_native_codec { SC_NATIVE_H264 = 1, SC_NATIVE_HEVC = 2 };
typedef void (*sc_native_video_output)(void *userdata, void *pixel_buffer,
                                      int width, int height, int64_t pts_us);
bool ScrcpyNativeVideoSupported(int codec);
void *ScrcpyNativeVideoCreate(int codec, sc_native_video_output output, void *userdata);
bool ScrcpyNativeVideoPush(void *decoder, const uint8_t *data, size_t size,
                          int64_t pts_us, bool keyframe);
void ScrcpyNativeVideoReset(void *decoder);
void ScrcpyNativeVideoDestroy(void *decoder);
void ScrcpyRetainPixelBuffer(void *buffer);
void ScrcpyReleasePixelBuffer(void *buffer);
#endif
