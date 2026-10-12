// Normalize direct touch at consumption, rather than relying on mutation in
// an SDL event watcher (or leaving a process-global watcher after reconnect).
#include "ios-geometry.h"
#include "input-coalescing.h"

#define sc_sdl_get_window_size sc_ios_window_size
#define sc_input_manager_handle_event sc_input_manager_handle_event_orig
#include "input_manager.c"
#undef sc_input_manager_handle_event

void
sc_input_manager_handle_event(struct sc_input_manager *im, const SDL_Event *event) {
    SDL_Event current = *event;
    if (current.type == SDL_EVENT_FINGER_MOTION) {
        struct sc_pending_finger_motion pending = {.latest = current};
        SDL_FilterEvents(sc_coalesce_finger_motion, &pending);
        current = pending.latest;
    }
    sc_normalize_finger_event(&current);
    sc_input_manager_handle_event_orig(im, &current);
}
