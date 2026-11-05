#pragma once
#include <stdint.h>
#include <stddef.h>

typedef struct { uint16_t current; uint16_t maximum; } BrightnessValue;

// DDC/CI Get VCP Feature Reply, VCP 0x10 (luminance) only.
static inline int decodeBrightness(const uint8_t *bytes, size_t length, BrightnessValue *value) {
    if (length < 11 || bytes[0] != 0x6e || bytes[1] != 0x88 || bytes[2] != 0x02 ||
        bytes[3] != 0 || bytes[4] != 0x10 || bytes[5] != 0) return 0;
    uint8_t checksum = 0x50;
    for (int i = 0; i < 11; ++i) checksum ^= bytes[i];
    if (checksum != 0) return 0;
    uint16_t maximum = ((uint16_t)bytes[6] << 8) | bytes[7];
    uint16_t current = ((uint16_t)bytes[8] << 8) | bytes[9];
    if (!maximum || current > maximum) return 0;
    value->maximum = maximum;
    value->current = current;
    return 1;
}

static inline void brightnessWritePacket(uint16_t value, uint8_t bytes[6]) {
    bytes[0] = 0x84; bytes[1] = 0x03; bytes[2] = 0x10;
    bytes[3] = value >> 8; bytes[4] = value & 0xff;
    bytes[5] = 0x6e ^ 0x51 ^ bytes[0] ^ bytes[1] ^ bytes[2] ^ bytes[3] ^ bytes[4];
}
