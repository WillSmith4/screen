#ifndef SC_CONTROL_COALESCING_H
#define SC_CONTROL_COALESCING_H

#include "control_msg.h"

static inline bool
sc_touch_is_motion(const struct sc_control_msg *msg) {
    return msg->type == SC_CONTROL_MSG_TYPE_INJECT_TOUCH_EVENT
        && msg->inject_touch_event.action == AMOTION_EVENT_ACTION_MOVE;
}

// Called with the controller mutex held. Only replace unsent motion in the
// current gesture segment; never cross a down/up, key, scroll or pen message.
// Each finger keeps its own slot, so a pinch cannot replace the other finger.
static inline bool
sc_touch_replace_pending(struct sc_control_msg *data, size_t capacity,
                         size_t origin, size_t count,
                         const struct sc_control_msg *msg) {
    if (!sc_touch_is_motion(msg)) {
        return false;
    }
    for (size_t i = count; i; --i) {
        struct sc_control_msg *pending = &data[(origin + i - 1) % capacity];
        if (!sc_touch_is_motion(pending)) {
            break;
        }
        if (pending->inject_touch_event.position.screen_size.width != msg->inject_touch_event.position.screen_size.width
                || pending->inject_touch_event.position.screen_size.height != msg->inject_touch_event.position.screen_size.height) {
            break;
        }
        if (pending->inject_touch_event.pointer_id == msg->inject_touch_event.pointer_id) {
            if (pending->inject_touch_event.buttons != msg->inject_touch_event.buttons
                    || pending->inject_touch_event.action_button != msg->inject_touch_event.action_button) {
                break;
            }
            *pending = *msg;
            return true;
        }
    }
    return false;
}

#endif
