#ifndef SC_NATIVE_RENDER_SDL_H
#define SC_NATIVE_RENDER_SDL_H

#include <SDL3/SDL.h>
#include "texture.h"
#include "util/sdl.h"

int ScrcpyEnableHardwareDecoding(void);

// The native layer owns the video image in mode 1. Keep screen.c's frame
// bookkeeping, window and input geometry, but never allocate its unused YUV
// texture or queue a second GPU pass underneath the native layer. Skipping
// only SDL_RenderPresent still lets clear/draw/flush acquire SDL drawables.
static inline bool
sc_native_texture_set_from_frame(struct sc_texture *tex, const AVFrame *frame) {
    return ScrcpyEnableHardwareDecoding() == 1
        || sc_texture_set_from_frame(tex, frame);
}

static inline bool
sc_native_set_draw_color(SDL_Renderer *renderer, Uint8 r, Uint8 g, Uint8 b, Uint8 a) {
    return ScrcpyEnableHardwareDecoding() == 1
        || SDL_SetRenderDrawColor(renderer, r, g, b, a);
}

static inline bool
sc_native_render_clear(SDL_Renderer *renderer) {
    return ScrcpyEnableHardwareDecoding() == 1 || sc_sdl_render_clear(renderer);
}

static inline bool
sc_native_render_texture(SDL_Renderer *renderer, SDL_Texture *texture,
                         const SDL_FRect *source, const SDL_FRect *destination) {
    return ScrcpyEnableHardwareDecoding() == 1
        || SDL_RenderTexture(renderer, texture, source, destination);
}

static inline bool
sc_native_render_texture_rotated(SDL_Renderer *renderer, SDL_Texture *texture,
                                 const SDL_FRect *source, const SDL_FRect *destination,
                                 double angle, const SDL_FPoint *center, SDL_FlipMode flip) {
    return ScrcpyEnableHardwareDecoding() == 1
        || SDL_RenderTextureRotated(renderer, texture, source, destination, angle, center, flip);
}

static inline void
sc_native_render_present(SDL_Renderer *renderer) {
    if (ScrcpyEnableHardwareDecoding() != 1) { sc_sdl_render_present(renderer); }
}
#endif
