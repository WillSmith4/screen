#include "annexb.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    // Leading zeros, both prefix lengths, emulation prevention and padding.
    const uint8_t stream[] = {0,0,0,0,1,0x67,0xaa,0,0,1,0x68,0xbb,
        0,0,0,1,0x65,0,0,3,1,0xcc,0,0};
    const uint8_t picture[] = {0x65,0,0,3,1,0xcc};
    size_t cursor = 0;
    struct sc_nal nal;
    assert(sc_annexb_next(stream, sizeof stream, &cursor, &nal));
    assert(nal.size == 2 && nal.data[0] == 0x67 && nal.data[1] == 0xaa);
    assert(sc_annexb_next(stream, sizeof stream, &cursor, &nal));
    assert(nal.size == 2 && nal.data[0] == 0x68 && nal.data[1] == 0xbb);
    assert(sc_annexb_next(stream, sizeof stream, &cursor, &nal));
    assert(nal.size == sizeof picture && !memcmp(nal.data, picture, sizeof picture));
    assert(!sc_annexb_next(stream, sizeof stream, &cursor, &nal));
    const uint8_t empty_nal[] = {0,0,1,0,0,1,0x65};
    cursor = 0;
    assert(sc_annexb_next(empty_nal, sizeof empty_nal, &cursor, &nal) && !nal.size);
    assert(sc_annexb_next(empty_nal, sizeof empty_nal, &cursor, &nal) && nal.size == 1);
    const uint8_t zeros[] = {0,0,0,0};
    for (size_t size = 0; size <= sizeof zeros; ++size) {
        cursor = 0;
        assert(!sc_annexb_next(zeros, size, &cursor, &nal) && cursor == size);
    }
    // Every truncation is bounded and always advances the cursor.
    for (size_t size = 0; size <= sizeof stream; ++size) {
        cursor = 0;
        size_t previous = 0;
        while (sc_annexb_next(stream, size, &cursor, &nal)) {
            assert(cursor > previous && cursor <= size);
            assert(nal.data >= stream && nal.data + nal.size <= stream + size);
            previous = cursor;
        }
    }
    puts("PASS: Annex-B prefixes, bounds, padding, emulation prevention and empty NALs");
}
