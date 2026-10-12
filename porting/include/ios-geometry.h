#ifndef SC_IOS_GEOMETRY_H
#define SC_IOS_GEOMETRY_H

#include <SDL3/SDL.h>
#include "util/sdl.h"

// Main-thread bridge to the UIKit view that belongs to this SDL window.
// SDL's cached size can lag behind Slide Over / Stage Manager transitions.
bool ScrcpyGetViewSize(uint32_t window_id, int *width, int *height);

static inline struct sc_size
sc_ios_window_size(SDL_Window *window) {
    int width, height;
    if (ScrcpyGetViewSize(SDL_GetWindowID(window), &width, &height)
            && width > 0 && height > 0 && width <= UINT16_MAX && height <= UINT16_MAX) {
        return (struct sc_size) {width, height};
    }
    return sc_sdl_get_window_size(window);
}

#endif
