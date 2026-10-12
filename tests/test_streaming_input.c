#include <assert.h>
#include <stdio.h>
#include "control-coalescing.h"
#include "input-coalescing.h"
#include "frame-pacing.h"

static struct sc_control_msg motion(uint64_t id, int x) {
    return (struct sc_control_msg) {
        .type = SC_CONTROL_MSG_TYPE_INJECT_TOUCH_EVENT,
        .inject_touch_event = {
            .action = AMOTION_EVENT_ACTION_MOVE, .pointer_id = id,
            .position = {.point = {x, 20}, .screen_size = {1080, 2400}},
            .pressure = 1.f,
        },
    };
}

static void test_controller_congestion(void) {
    struct sc_control_msg ring[8] = {0};
    // Wrapped queue: DOWN, MOVE finger 1, MOVE finger 2.
    ring[6] = motion(1, 0);
    ring[6].inject_touch_event.action = AMOTION_EVENT_ACTION_DOWN;
    ring[7] = motion(1, 1);
    ring[0] = motion(2, 2);
    for (int i = 3; i < 100003; ++i) {
        struct sc_control_msg msg = motion(i % 2 + 1, i);
        assert(sc_touch_replace_pending(ring, 8, 6, 3, &msg));
    }
    assert(ring[7].inject_touch_event.position.point.x == 100002);
    assert(ring[0].inject_touch_event.position.point.x == 100001);
    assert(ring[6].inject_touch_event.action == AMOTION_EVENT_ACTION_DOWN);
    struct sc_control_msg msg = motion(1, 200000);
    ring[1] = motion(2, 3);
    ring[1].inject_touch_event.action = AMOTION_EVENT_ACTION_UP;
    assert(!sc_touch_replace_pending(ring, 8, 6, 4, &msg));
    ring[1].type = SC_CONTROL_MSG_TYPE_INJECT_KEYCODE;
    assert(!sc_touch_replace_pending(ring, 8, 6, 4, &msg));
    // Never replace coordinates belonging to an old display configuration.
    msg.inject_touch_event.position.screen_size.width = 2400;
    assert(!sc_touch_replace_pending(ring, 8, 6, 3, &msg));
    msg = motion(1, 4);
    msg.inject_touch_event.action = AMOTION_EVENT_ACTION_DOWN;
    assert(!sc_touch_replace_pending(ring, 8, 6, 3, &msg));
}

static SDL_Event finger(uint32_t type, SDL_FingerID id, float x) {
    SDL_Event event = {0};
    event.type = type;
    event.tfinger.windowID = 1;
    event.tfinger.touchID = 1;
    event.tfinger.fingerID = id;
    event.tfinger.x = x;
    return event;
}

static void test_sdl_queue(void) {
    assert(SDL_Init(SDL_INIT_EVENTS));
    SDL_FlushEvents(SDL_EVENT_FIRST, SDL_EVENT_LAST);
    struct sc_pending_finger_motion pending = {.latest = finger(SDL_EVENT_FINGER_MOTION, 1, .1f)};
    SDL_Event events[] = {
        finger(SDL_EVENT_FINGER_MOTION, 2, .2f),
        finger(SDL_EVENT_FINGER_MOTION, 1, .8f),
        finger(SDL_EVENT_FINGER_UP, 1, .8f),
        finger(SDL_EVENT_FINGER_DOWN, 1, .3f),
        finger(SDL_EVENT_FINGER_MOTION, 1, .4f),
    };
    assert(SDL_PeepEvents(events, 5, SDL_ADDEVENT, 0, 0) == 5);
    SDL_FilterEvents(sc_coalesce_finger_motion, &pending);
    assert(pending.latest.tfinger.x == .8f);
    SDL_Event retained[5];
    int count = SDL_PeepEvents(retained, 5, SDL_GETEVENT, SDL_EVENT_FIRST, SDL_EVENT_LAST);
    assert(count == 4);
    assert(retained[0].tfinger.fingerID == 2);
    assert(retained[1].type == SDL_EVENT_FINGER_UP);
    assert(retained[2].type == SDL_EVENT_FINGER_DOWN);
    assert(retained[3].tfinger.x == .4f); // next stroke untouched
    SDL_Quit();
}

static void test_pressure_and_cancel(void) {
    SDL_Event event = finger(SDL_EVENT_FINGER_DOWN, 1, .5f);
    sc_normalize_finger_event(&event);
    assert(event.tfinger.pressure == 1.f);
    event.type = SDL_EVENT_FINGER_MOTION;
    event.tfinger.pressure = .25f;
    sc_normalize_finger_event(&event);
    assert(event.tfinger.pressure == .25f);
    event.tfinger.pressure = NAN;
    sc_normalize_finger_event(&event);
    assert(event.tfinger.pressure == 1.f);
    event.type = SDL_EVENT_FINGER_CANCELED;
    sc_normalize_finger_event(&event);
    assert(event.type == SDL_EVENT_FINGER_UP && event.tfinger.pressure == 0.f);
}

int main(void) {
    test_controller_congestion();
    test_sdl_queue();
    test_pressure_and_cancel();
    assert(sc_display_frame_rate(120, 60) == 60);
    assert(sc_display_frame_rate(120, 120) == 120);
    assert(sc_display_frame_rate(60, 120) == 60);
    assert(sc_display_frame_rate(240, 120) == 120);
    assert(sc_display_frame_rate(0, 120) == 120);
    assert(sc_display_frame_rate(120, 0) == 60);
    assert(sc_display_frame_rate(30, 120) == 30);
    puts("PASS: congested multi-touch, gesture boundaries, SDL queue, pressure, cancellation, frame rate limits");
}
