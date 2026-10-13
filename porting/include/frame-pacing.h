#ifndef SC_FRAME_PACING_H
#define SC_FRAME_PACING_H

// A setting restored from another device must not request an unsupported
// local refresh rate. Zero means no source limit: use this display's maximum.
static inline int sc_display_frame_rate(int requested, int display_maximum) {
    int maximum = display_maximum > 0 ? display_maximum : 60;
    if (maximum > 120) { maximum = 120; }
    if (requested <= 0 || requested > maximum) { return maximum; }
    return requested;
}

#endif
