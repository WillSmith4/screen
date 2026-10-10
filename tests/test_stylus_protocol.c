#include "stylus-protocol.h"
#include <assert.h>
#include <stdio.h>

int main(int argc, char **argv) {
    struct sc_stylus_packet packet = {
        .action = 2, .tool = 4, .x = 123456, .y = -42, .width = 2160, .height = 3840,
        .pressure = 0.5f, .tilt = SC_STYLUS_PI / 4, .orientation = -SC_STYLUS_PI / 2,
        .buttons = 32, .timestamp_us = UINT64_C(0x0123456789ABCDEF),
    };
    const uint8_t expected[] = {
        0x80, 1, 2, 4, 0, 1, 0xe2, 0x40, 0xff, 0xff, 0xff, 0xd6,
        8, 0x70, 0x0f, 0, 0x80, 0, 0x80, 0, 0xc0, 0, 0, 0, 0, 0x20,
        1, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
    };
    uint8_t actual[SC_STYLUS_WIRE_SIZE];
    sc_stylus_serialize(&packet, actual);
    assert(sizeof(expected) == SC_STYLUS_WIRE_SIZE);
    assert(!memcmp(actual, expected, sizeof(expected)));
    if (argc == 2) {
        FILE *file = fopen(argv[1], "wb");
        assert(file);
        assert(fwrite(actual, 1, sizeof(actual), file) == sizeof(actual));
        fclose(file);
    }
    packet.pressure = NAN;
    packet.tilt = -1;
    packet.orientation = INFINITY;
    sc_stylus_serialize(&packet, actual);
    assert(actual[16] == 0 && actual[17] == 0);
    assert(actual[18] == 0 && actual[19] == 0);
    packet.pressure = 8;
    packet.tilt = 9;
    sc_stylus_serialize(&packet, actual);
    assert(actual[16] == 255 && actual[17] == 255);
    assert(actual[18] == 255 && actual[19] == 255);
    puts("Stylus wire format, byte order, pressure endpoints and invalid values passed.");
}
