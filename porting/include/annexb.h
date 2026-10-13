#ifndef SC_ANNEXB_H
#define SC_ANNEXB_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct sc_nal { const uint8_t *data; size_t size; };

static inline size_t sc_annexb_prefix(const uint8_t *p, size_t n) {
    if (n >= 4 && !p[0] && !p[1] && !p[2] && p[3] == 1) { return 4; }
    if (n >= 3 && !p[0] && !p[1] && p[2] == 1) { return 3; }
    return 0;
}

// Accept both MediaCodec Annex-B prefix lengths, including leading/trailing
// zero bytes. The caller owns the input; returned slices never outlive it.
static inline bool sc_annexb_next(const uint8_t *data, size_t size,
                                  size_t *cursor, struct sc_nal *nal) {
    size_t start = *cursor, prefix = 0;
    while (start < size && !(prefix = sc_annexb_prefix(data + start, size - start))) { ++start; }
    if (!prefix) { *cursor = size; return false; }
    start += prefix;
    size_t end = start;
    while (end < size && !sc_annexb_prefix(data + end, size - end)) { ++end; }
    *cursor = end;
    size_t payload_end = end;
    while (payload_end > start && data[payload_end - 1] == 0) { --payload_end; }
    nal->data = data + start;
    nal->size = payload_end - start;
    return true;
}
#endif
