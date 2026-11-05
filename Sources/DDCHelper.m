@import Foundation;
@import IOKit;
@import CoreGraphics;
#include "ioregistry.h"
#include "DDCPacket.h"
#include <math.h>

extern IOReturn IOAVServiceReadI2C(IOAVServiceRef, uint32_t, uint32_t, void *, uint32_t);
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef, uint32_t, uint32_t, void *, uint32_t);

static NSString *lastError;
static NSData *lastReply;

static BOOL readBrightness(DDCTransport transport, BrightnessValue *value) {
    uint8_t query[] = {0x82, 0x01, 0x10, 0xac};
    for (int attempt = 0; attempt < 3; attempt++) {
        IOReturn result = IOAVServiceWriteI2C(transport.service, transport.chipAddress, 0x51, query, 4);
        if (result != kIOReturnSuccess) {
            lastError = [NSString stringWithFormat:@"DDC 请求失败（0x%x）", result];
            usleep(80000); continue;
        }
        usleep(80000);
        uint8_t reply[12] = {0};
        result = IOAVServiceReadI2C(transport.service, transport.chipAddress, 0x51, reply, sizeof(reply));
        lastReply = [NSData dataWithBytes:reply length:sizeof(reply)];
        if (result == kIOReturnSuccess && decodeBrightness(reply, sizeof(reply), value)) return YES;
        lastError = result == kIOReturnSuccess ? @"显示器未返回有效的亮度数据，请检查 DDC/CI 或 HDR 模式。" :
            [NSString stringWithFormat:@"DDC 读取失败（0x%x）", result];
        usleep(80000);
    }
    return NO;
}

static NSDictionary *errorResult(NSString *message) {
    return @{@"ok": @NO, @"error": message ?: @"无法读取显示器"};
}

static NSDictionary *brightnessResult(BrightnessValue value) {
    return @{@"ok": @YES, @"current": @(value.current), @"maximum": @(value.maximum),
             @"percent": @((double)value.current * 100.0 / value.maximum)};
}

static int emitJSON(id object, int code) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil];
    fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout);
    return code;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 2) return emitJSON(errorResult(@"用法：list | read UUID | set UUID 0…100 | write UUID 0…100 maximum"), 2);
        NSString *command = @(argv[1]);
        BOOL listing = [command isEqualToString:@"list"];
        BOOL reading = [command isEqualToString:@"read"];
        BOOL setting = [command isEqualToString:@"set"];
        BOOL live = [command isEqualToString:@"write"];
        if ((!listing && !reading && !setting && !live) || (listing && argc != 2) ||
            (reading && argc != 3) || (setting && argc != 4) || (live && argc != 5))
            return emitJSON(errorResult(@"参数不正确"), 2);
        double percent = 0;
        if (setting || live) {
            char *end = NULL; percent = strtod(argv[3], &end);
            if (end == argv[3] || *end || !isfinite(percent) || percent < 0 || percent > 100)
                return emitJSON(errorResult(@"亮度必须为 0 到 100 之间的数字"), 2);
        }
        long maximum = 0;
        if (live) {
            char *end = NULL; maximum = strtol(argv[4], &end, 10);
            if (end == argv[4] || *end || maximum < 1 || maximum > UINT16_MAX)
                return emitJSON(errorResult(@"最大亮度必须来自显示器检测结果"), 2);
        }
        DisplayInfos displays[MAX_DISPLAYS] = {0};
        CGDisplayCount count = getOnlineDisplayInfos(displays);
        NSMutableArray *items = [NSMutableArray array];
        BOOL found = NO;
        NSDictionary *response = nil;
        for (CGDisplayCount i = 0; i < count; i++) {
            DisplayInfos *display = &displays[i];
            if (CGDisplayIsBuiltin(display->id)) continue;
            if (!listing && ![display->uuid isEqualToString:@(argv[2])]) continue;
            found = YES;
            DDCTransport transport = getDisplayDDCTransport(display);
            NSMutableDictionary *item = [@{@"id": display->uuid ?: @"", @"displayID": @(display->id),
                @"name": display->productName ?: @"外接显示器"} mutableCopy];
            if (!transport.service) {
                [item addEntriesFromDictionary:errorResult(@"当前连接未提供 DDC 通道，请直连 USB-C / DisplayPort 并重试。")];
            } else {
                BrightnessValue value = {0};
                if (live) {
                    // While dragging, use the previously read range. Do not put
                    // two slow reads and a settle delay between every write.
                    uint16_t target = (uint16_t)lround(percent * maximum / 100.0);
                    uint8_t packet[6]; brightnessWritePacket(target, packet);
                    IOReturn result = IOAVServiceWriteI2C(transport.service, transport.chipAddress, 0x51, packet, sizeof(packet));
                    if (result != kIOReturnSuccess) {
                        [item addEntriesFromDictionary:errorResult([NSString stringWithFormat:@"亮度写入失败（0x%x）", result])];
                    } else {
                        [item addEntriesFromDictionary:@{@"ok": @YES, @"percent": @((double)target * 100.0 / maximum), @"verified": @NO}];
                    }
                } else if (!readBrightness(transport, &value)) {
                    [item addEntriesFromDictionary:errorResult(lastError)];
                } else if (!setting) {
                    [item addEntriesFromDictionary:brightnessResult(value)];
                } else {
                    uint16_t target = (uint16_t)lround(percent * value.maximum / 100.0);
                    uint8_t packet[6]; brightnessWritePacket(target, packet);
                    IOReturn result = IOAVServiceWriteI2C(transport.service, transport.chipAddress, 0x51, packet, sizeof(packet));
                    if (result != kIOReturnSuccess) {
                        [item addEntriesFromDictionary:errorResult([NSString stringWithFormat:@"亮度写入失败（0x%x）", result])];
                    } else {
                        usleep(180000);
                        BrightnessValue actual = {0};
                        if (!readBrightness(transport, &actual)) {
                            [item addEntriesFromDictionary:errorResult(@"已发送指令，但无法确认显示器的亮度，请重新检测。")];
                        } else if (actual.current != target) {
                            [item addEntriesFromDictionary:errorResult(@"显示器没有采用设定亮度，请检查显示器的 HDR / 画面模式。")];
                            item[@"percent"] = @((double)actual.current * 100.0 / actual.maximum);
                        } else {
                            [item addEntriesFromDictionary:brightnessResult(actual)];
                            item[@"verified"] = @YES;
                        }
                    }
                }
                CFRelease(transport.service);
            }
            [items addObject:item];
            if (!listing) response = item;
        }
        for (CGDisplayCount i = 0; i < count; i++) if (displays[i].adapter) IOObjectRelease(displays[i].adapter);
        if (listing) return emitJSON(@{@"ok": @YES, @"displays": items}, 0);
        if (!found) return emitJSON(errorResult(@"显示器已断开，请重新检测。"), 1);
        return emitJSON(response, [response[@"ok"] boolValue] ? 0 : 1);
    }
}
