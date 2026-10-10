#ifndef SCRCPY_STYLUS_H
#define SCRCPY_STYLUS_H

#include <stdbool.h>
#include <stdint.h>

// Android MotionEvent actions/tool types. Coordinates are normalized to the
// UIKit streaming view, before scrcpy's letterbox/rotation conversion.
bool ScrcpySendStylusEvent(uint32_t window_id, uint8_t action, uint8_t tool,
                          float x, float y, float pressure, float tilt,
                          float orientation, uint32_t buttons,
                          uint64_t timestamp_us);
bool ScrcpySendDrawingKey(uint32_t window_id, uint32_t keycode,
                          uint32_t metastate, bool down);

#endif
