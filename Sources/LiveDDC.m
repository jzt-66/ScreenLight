@import Foundation;
@import IOKit;
@import CoreGraphics;
#include "LiveDDC.h"
#include "ioregistry.h"
#include "DDCPacket.h"
#include <math.h>

extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef, uint32_t, uint32_t, void *, uint32_t);
extern IOReturn IOAVServiceReadI2C(IOAVServiceRef, uint32_t, uint32_t, void *, uint32_t);

// Accessed only by DDCClient's serial hardware queue. A connection is reused
// throughout tracking instead of rediscovering the display for every tick.
typedef struct {
    char uuid[UUID_SIZE];
    DDCTransport transport;
} LiveConnection;
static LiveConnection connections[MAX_DISPLAYS];

void SLResetBrightnessConnections(void) {
    for (int i = 0; i < MAX_DISPLAYS; i++) {
        if (connections[i].transport.service) CFRelease(connections[i].transport.service);
        memset(&connections[i], 0, sizeof(connections[i]));
    }
}

static LiveConnection *connectionForUUID(const char *uuid) {
    LiveConnection *available = NULL;
    for (int i = 0; i < MAX_DISPLAYS; i++) {
        if (connections[i].transport.service && strcmp(connections[i].uuid, uuid) == 0) return &connections[i];
        if (!connections[i].transport.service && !available) available = &connections[i];
    }
    if (!available) return NULL;
    DisplayInfos displays[MAX_DISPLAYS] = {0};
    CGDisplayCount count = getOnlineDisplayInfos(displays);
    for (CGDisplayCount i = 0; i < count; i++) {
        if (!CGDisplayIsBuiltin(displays[i].id) && [displays[i].uuid isEqualToString:@(uuid)]) {
            available->transport = getDisplayDDCTransport(&displays[i]);
            strlcpy(available->uuid, uuid, sizeof(available->uuid));
            break;
        }
    }
    for (CGDisplayCount i = 0; i < count; i++) if (displays[i].adapter) IOObjectRelease(displays[i].adapter);
    return available->transport.service ? available : NULL;
}

int32_t SLPrepareBrightnessConnection(const char *uuid) {
    @autoreleasepool {
        if (!uuid || strlen(uuid) != UUID_SIZE - 1) return kIOReturnBadArgument;
        return connectionForUUID(uuid) ? kIOReturnSuccess : kIOReturnNotFound;
    }
}

int32_t SLReadBrightness(const char *uuid, uint16_t *current, uint16_t *maximum) {
    @autoreleasepool {
        if (!uuid || strlen(uuid) != UUID_SIZE - 1 || !current || !maximum) return kIOReturnBadArgument;
        LiveConnection *connection = connectionForUUID(uuid);
        if (!connection) return kIOReturnNotFound;
        uint8_t query[] = {0x82, 0x01, 0x10, 0xac};
        IOReturn result = IOAVServiceWriteI2C(connection->transport.service, connection->transport.chipAddress, 0x51, query, sizeof(query));
        if (result != kIOReturnSuccess) return result;
        usleep(80000);
        uint8_t reply[12] = {0};
        result = IOAVServiceReadI2C(connection->transport.service, connection->transport.chipAddress, 0x51, reply, sizeof(reply));
        if (result != kIOReturnSuccess) return result;
        BrightnessValue value = {0};
        if (!decodeBrightness(reply, sizeof(reply), &value)) return kIOReturnError;
        *current = value.current;
        *maximum = value.maximum;
        return kIOReturnSuccess;
    }
}

int32_t SLWriteBrightness(const char *uuid, double percent, uint16_t maximum, double *appliedPercent) {
    @autoreleasepool {
        if (!uuid || strlen(uuid) != UUID_SIZE - 1 || !isfinite(percent) || percent < 0 || percent > 100 || !maximum)
            return kIOReturnBadArgument;
        LiveConnection *connection = connectionForUUID(uuid);
        if (!connection) return kIOReturnNotFound;
        uint16_t target = (uint16_t)lround(percent * maximum / 100.0);
        uint8_t packet[6]; brightnessWritePacket(target, packet);
        IOReturn result = IOAVServiceWriteI2C(connection->transport.service, connection->transport.chipAddress, 0x51, packet, sizeof(packet));
        if (result != kIOReturnSuccess) {
            CFRelease(connection->transport.service);
            memset(connection, 0, sizeof(*connection));
            return result;
        }
        if (appliedPercent) *appliedPercent = (double)target * 100.0 / maximum;
        return kIOReturnSuccess;
    }
}
