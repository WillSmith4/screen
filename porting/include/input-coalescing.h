#ifndef SC_INPUT_COALESCING_H
#define SC_INPUT_COALESCING_H

#include <SDL3/SDL.h>
#include <math.h>

struct sc_pending_finger_motion {
    SDL_Event latest;
    bool past_boundary;
};

// Called by SDL_FilterEvents after the oldest motion was polled. No SDL calls
// or allocations while SDL holds its lock. Do not cross a gesture boundary.
static inline bool SDLCALL
sc_coalesce_finger_motion(void *userdata, SDL_Event *queued) {
    struct sc_pending_finger_motion *pending = userdata;
    if (pending->past_boundary) { return true; }
    if (queued->type != SDL_EVENT_FINGER_MOTION) {
        pending->past_boundary = true;
        return true;
    }
    if (queued->tfinger.windowID == pending->latest.tfinger.windowID
            && queued->tfinger.touchID == pending->latest.tfinger.touchID
            && queued->tfinger.fingerID == pending->latest.tfinger.fingerID) {
        pending->latest = *queued;
        return false;
    }
    return true;
}

static inline void
sc_normalize_finger_event(SDL_Event *event) {
    if (event->type == SDL_EVENT_FINGER_CANCELED) {
        event->type = SDL_EVENT_FINGER_UP;
        event->tfinger.pressure = 0.f;
    } else if (event->type == SDL_EVENT_FINGER_DOWN
            || event->type == SDL_EVENT_FINGER_MOTION) {
        if (!isfinite(event->tfinger.pressure) || event->tfinger.pressure <= 0.f) {
            event->tfinger.pressure = 1.f;
        }
    }
}

#endif
