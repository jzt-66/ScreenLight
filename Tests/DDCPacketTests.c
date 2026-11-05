#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "DDCPacket.h"

static void checksum(uint8_t reply[11]) {
    reply[10] = 0x50;
    for (int i = 0; i < 10; i++) reply[10] ^= reply[i];
}

int main(void) {
    BrightnessValue value = {0};
    uint8_t reply[11] = {0x6e, 0x88, 0x02, 0, 0x10, 0, 0, 100, 0, 50, 0};
    checksum(reply);
    assert(decodeBrightness(reply, 11, &value));
    assert(value.current == 50 && value.maximum == 100);
    assert(!decodeBrightness(reply, 10, &value));
    reply[10] ^= 1;
    assert(!decodeBrightness(reply, 11, &value));
    checksum(reply);
    reply[3] = 1; checksum(reply); // VCP feature unsupported
    assert(!decodeBrightness(reply, 11, &value));
    reply[3] = 0; reply[4] = 0x62; checksum(reply); // not luminance
    assert(!decodeBrightness(reply, 11, &value));
    reply[4] = 0x10; reply[7] = 0; checksum(reply); // zero maximum
    assert(!decodeBrightness(reply, 11, &value));
    reply[7] = 49; checksum(reply); // current above maximum
    assert(!decodeBrightness(reply, 11, &value));
    reply[6] = 1; reply[7] = 144; reply[8] = 1; reply[9] = 44; checksum(reply);
    assert(decodeBrightness(reply, 11, &value));
    assert(value.maximum == 400 && value.current == 300); // 16-bit big-endian
    memset(reply, 0, sizeof(reply));
    assert(!decodeBrightness(reply, 11, &value));
    for (int setting = 0; setting <= 65535; setting++) {
        uint8_t packet[6]; brightnessWritePacket((uint16_t)setting, packet);
        assert(packet[0] == 0x84 && packet[1] == 0x03 && packet[2] == 0x10);
        assert((((uint16_t)packet[3] << 8) | packet[4]) == setting);
        uint8_t sum = 0x6e ^ 0x51;
        for (int i = 0; i < 6; i++) sum ^= packet[i];
        assert(sum == 0);
    }
    puts("DDC packet validation passed, including all 65,536 write values.");
}
