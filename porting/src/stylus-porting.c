#include "scrcpy-stylus.h"
#include "stylus-protocol.h"
#include "screen.h"
#include "util/sdl.h"
#include <SDL3/SDL.h>
#include <stdlib.h>

// Upstream reserves the first SDL_EVENT_USER values in events.h. Our payload
// lives entirely inside SDL_Event, so abandoned events cannot leak pointers.
#define SC_STYLUS_SDL_EVENT (SDL_EVENT_USER + 128)
#define SC_DRAWING_KEY_SDL_EVENT (SDL_EVENT_USER + 129)
struct sc_stylus_sdl_event {
    uint32_t type, reserved;
    uint64_t timestamp;
    uint32_t window_id;
    float x, y;
    struct sc_stylus_packet packet;
};
_Static_assert(sizeof(struct sc_stylus_sdl_event) <= sizeof(SDL_Event), "Stylus event fits SDL");

bool ScrcpySendStylusEvent(uint32_t window_id, uint8_t action, uint8_t tool,
                          float x, float y, float pressure, float tilt,
                          float orientation, uint32_t buttons, uint64_t timestamp_us) {
    if (!window_id || !isfinite(x) || !isfinite(y)) {
        return false;
    }
    struct sc_stylus_sdl_event data = {
        .type = SC_STYLUS_SDL_EVENT, .window_id = window_id, .x = x, .y = y,
        .packet = {.action = action, .tool = tool, .pressure = pressure,
                   .tilt = tilt, .orientation = orientation, .buttons = buttons,
                   .timestamp_us = timestamp_us},
    };
    SDL_Event event = {0};
    memcpy(&event, &data, sizeof(data));
    return SDL_PushEvent(&event);
}

bool sc_stylus_handle_event(struct sc_screen *screen, const SDL_Event *event) {
    if (event->type != SC_STYLUS_SDL_EVENT && event->type != SC_DRAWING_KEY_SDL_EVENT) {
        return false;
    }
    struct sc_stylus_sdl_event data;
    memcpy(&data, event, sizeof(data));
    if (!screen->controller || !screen->video || screen->camera || screen->disconnected ||
        !screen->window || SDL_GetWindowID(screen->window) != data.window_id ||
        screen->rect.w <= 0 || screen->rect.h <= 0 ||
        !screen->frame_size.width || !screen->frame_size.height) {
        return true;
    }
    if (event->type == SC_DRAWING_KEY_SDL_EVENT) {
        struct sc_control_msg msg = {0};
        msg.type = (enum sc_control_msg_type) SC_DRAWING_KEY_MESSAGE_TYPE;
        msg.inject_keycode.action = data.packet.action;
        msg.inject_keycode.keycode = data.packet.x;
        msg.inject_keycode.metastate = data.packet.buttons;
        sc_controller_push_msg(screen->controller, &msg);
        return true;
    }
    struct sc_size win = sc_sdl_get_window_size(screen->window);
    int32_t x = lroundf(data.x * win.width);
    int32_t y = lroundf(data.y * win.height);
    if (data.packet.action == 0 && (x < screen->rect.x || y < screen->rect.y ||
        x >= screen->rect.x + screen->rect.w || y >= screen->rect.y + screen->rect.h)) {
        return true; // A stroke starting in a letterbox must not paint its edge.
    }
    struct sc_point point = sc_screen_convert_window_to_frame_coords(screen, x, y);
    struct sc_stylus_packet *p = &data.packet;
    p->width = screen->frame_size.width;
    p->height = screen->frame_size.height;
    p->x = (int32_t) sc_stylus_clamp(point.x, 0, p->width - 1);
    p->y = (int32_t) sc_stylus_clamp(point.y, 0, p->height - 1);
    // Transform the pen direction through the same rotation/reflection as its
    // position. Use a long vector to avoid integer rounding at small tilts.
    struct sc_point tip = sc_screen_convert_window_to_frame_coords(screen,
        x + lroundf(sinf(p->orientation) * 1024),
        y - lroundf(cosf(p->orientation) * 1024));
    p->orientation = atan2f(tip.x - point.x, point.y - tip.y);
    struct sc_control_msg msg = {0};
    msg.type = (enum sc_control_msg_type) SC_STYLUS_MESSAGE_TYPE;
    msg.inject_text.text = malloc(SC_STYLUS_WIRE_SIZE);
    if (!msg.inject_text.text) {
        return true;
    }
    sc_stylus_serialize(p, (uint8_t *) msg.inject_text.text);
    if (!sc_controller_push_msg(screen->controller, &msg)) {
        free(msg.inject_text.text);
    }
    return true;
}

bool ScrcpySendDrawingKey(uint32_t window_id, uint32_t keycode,
                          uint32_t metastate, bool down) {
    struct sc_stylus_sdl_event data = {
        .type = SC_DRAWING_KEY_SDL_EVENT, .window_id = window_id,
        .packet = {.action = down ? 0 : 1, .x = keycode, .buttons = metastate},
    };
    SDL_Event event = {0};
    memcpy(&event, &data, sizeof(data));
    return window_id && SDL_PushEvent(&event);
}
