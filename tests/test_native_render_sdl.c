#include <assert.h>
#include <stdio.h>
#include "native-render-sdl.h"

// Exercise the actual routing helpers used by screen-porting.c. A native frame
// must not reach any SDL GPU operation, including a surviving icon texture or
// a rotated image. Other decoding modes must preserve failures and arguments.
static int mode, calls;
static bool success;
static SDL_Renderer *renderer;
static SDL_Texture *texture;
static SDL_FRect source, destination;
static SDL_FPoint center;
static struct sc_texture tex;
static AVFrame frame;
int ScrcpyEnableHardwareDecoding(void) { return mode; }
bool sc_texture_set_from_frame(struct sc_texture *t, const AVFrame *f) {
    assert(t == &tex && f == &frame); ++calls; return success;
}
bool SDL_SetRenderDrawColor(SDL_Renderer *r, Uint8 red, Uint8 g, Uint8 b, Uint8 a) {
    assert(r == renderer && red == 1 && g == 2 && b == 3 && a == 4); ++calls; return success;
}
bool sc_sdl_render_clear(SDL_Renderer *r) { assert(r == renderer); ++calls; return success; }
void sc_sdl_render_present(SDL_Renderer *r) { assert(r == renderer); ++calls; }
bool SDL_RenderTexture(SDL_Renderer *r, SDL_Texture *t, const SDL_FRect *s, const SDL_FRect *d) {
    assert(r == renderer && t == texture && s == &source && d == &destination); ++calls; return success;
}
bool SDL_RenderTextureRotated(SDL_Renderer *r, SDL_Texture *t, const SDL_FRect *s,
                              const SDL_FRect *d, double angle, const SDL_FPoint *c, SDL_FlipMode flip) {
    assert(r == renderer && t == texture && s == &source && d == &destination);
    assert(angle == 90 && c == &center && flip == SDL_FLIP_HORIZONTAL); ++calls; return success;
}
int main(void) {
    for (mode = 0; mode <= 2; ++mode) {
        for (int ok = 0; ok <= 1; ++ok) {
            success = ok;
            calls = 0;
            bool expected = mode == 1 || success;
            for (int i = 0; i < 12000; ++i) {
                assert(sc_native_texture_set_from_frame(&tex, &frame) == expected);
                assert(sc_native_set_draw_color(renderer, 1, 2, 3, 4) == expected);
                assert(sc_native_render_clear(renderer) == expected);
                assert(sc_native_render_texture(renderer, texture, &source, &destination) == expected);
                assert(sc_native_render_texture_rotated(renderer, texture, &source,
                    &destination, 90, &center, SDL_FLIP_HORIZONTAL) == expected);
                sc_native_render_present(renderer);
            }
            assert(calls == (mode == 1 ? 0 : 72000));
        }
    }
    puts("Native SDL routing: no duplicate GPU calls; software/error/rotation paths preserved");
    return 0;
}
