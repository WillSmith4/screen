// Extend the existing controller queue without changing upstream's ABI.
// For our private type only, inject_text.text owns a fixed-size binary packet.
#define sc_control_msg_serialize sc_control_msg_serialize_orig
#define sc_control_msg_destroy sc_control_msg_destroy_orig
#define sc_control_msg_is_droppable sc_control_msg_is_droppable_orig
#define sc_control_msg_log sc_control_msg_log_orig
#include "control_msg.c"
#undef sc_control_msg_serialize
#undef sc_control_msg_destroy
#undef sc_control_msg_is_droppable
#undef sc_control_msg_log
#include "stylus-protocol.h"

size_t sc_control_msg_serialize(const struct sc_control_msg *msg, uint8_t *buf) {
    if ((unsigned) msg->type == SC_DRAWING_KEY_MESSAGE_TYPE) {
        struct sc_control_msg key = *msg;
        key.type = SC_CONTROL_MSG_TYPE_INJECT_KEYCODE;
        return sc_control_msg_serialize_orig(&key, buf);
    }
    if ((unsigned) msg->type != SC_STYLUS_MESSAGE_TYPE) {
        return sc_control_msg_serialize_orig(msg, buf);
    }
    memcpy(buf, msg->inject_text.text, SC_STYLUS_WIRE_SIZE);
    return SC_STYLUS_WIRE_SIZE;
}

void sc_control_msg_destroy(struct sc_control_msg *msg) {
    if ((unsigned) msg->type == SC_STYLUS_MESSAGE_TYPE) {
        free(msg->inject_text.text);
    } else {
        sc_control_msg_destroy_orig(msg);
    }
}

bool sc_control_msg_is_droppable(const struct sc_control_msg *msg) {
    if ((unsigned) msg->type == SC_DRAWING_KEY_MESSAGE_TYPE) { return false; }
    if ((unsigned) msg->type == SC_STYLUS_MESSAGE_TYPE) {
        uint8_t action = (uint8_t) msg->inject_text.text[2];
        // Under congestion only motion may be discarded. Never leave Android
        // with a missing DOWN, UP, CANCEL or hover boundary.
        return action == 2 || action == 7;
    }
    return sc_control_msg_is_droppable_orig(msg);
}

void sc_control_msg_log(const struct sc_control_msg *msg) {
    if ((unsigned) msg->type == SC_STYLUS_MESSAGE_TYPE) {
        LOGD("Stylus action=%u tool=%u", (uint8_t) msg->inject_text.text[2],
             (uint8_t) msg->inject_text.text[3]);
    } else {
        sc_control_msg_log_orig(msg);
    }
}
