#ifndef SCRCPY_STYLUS_PROTOCOL_H
#define SCRCPY_STYLUS_PROTOCOL_H

#include <math.h>
#include <stdint.h>
#include <string.h>

// Private, versioned extension understood by the Android server bundled with
// this app. Upstream message numbers and layouts are unchanged.
#define SC_STYLUS_MESSAGE_TYPE 128
// Queue-only tag: stock key event on the wire, but never dropped during squeeze.
#define SC_DRAWING_KEY_MESSAGE_TYPE 129
#define SC_STYLUS_WIRE_SIZE 34
#define SC_STYLUS_PI 3.14159265358979323846

struct sc_stylus_packet {
    uint8_t action, tool;
    int32_t x, y;
    uint16_t width, height;
    float pressure, tilt, orientation;
    uint32_t buttons;
    uint64_t timestamp_us;
};

static inline float sc_stylus_clamp(float v, float min, float max) {
    return !isfinite(v) ? min : v < min ? min : v > max ? max : v;
}

static inline void sc_stylus_write(uint8_t *p, uint64_t value, unsigned bytes) {
    for (unsigned i = 0; i < bytes; ++i) {
        p[bytes - i - 1] = (uint8_t) (value >> (i * 8));
    }
}

static inline void sc_stylus_serialize(const struct sc_stylus_packet *p,
                                     uint8_t out[SC_STYLUS_WIRE_SIZE]) {
    out[0] = SC_STYLUS_MESSAGE_TYPE;
    out[1] = 1; // version
    out[2] = p->action;
    out[3] = p->tool;
    sc_stylus_write(out + 4, (uint32_t) p->x, 4);
    sc_stylus_write(out + 8, (uint32_t) p->y, 4);
    sc_stylus_write(out + 12, p->width, 2);
    sc_stylus_write(out + 14, p->height, 2);
    sc_stylus_write(out + 16, lroundf(sc_stylus_clamp(p->pressure, 0, 1) * 65535), 2);
    sc_stylus_write(out + 18, lroundf(sc_stylus_clamp(p->tilt, 0, SC_STYLUS_PI / 2) * 65535 / (SC_STYLUS_PI / 2)), 2);
    sc_stylus_write(out + 20, (uint16_t) (int16_t) lroundf(sc_stylus_clamp(p->orientation, -SC_STYLUS_PI, SC_STYLUS_PI) * 32767 / SC_STYLUS_PI), 2);
    sc_stylus_write(out + 22, p->buttons, 4);
    sc_stylus_write(out + 26, p->timestamp_us, 8);
}

#endif
