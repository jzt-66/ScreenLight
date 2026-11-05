#pragma once
#include <stdint.h>

int32_t SLWriteBrightness(const char *uuid, double percent, uint16_t maximum, double *appliedPercent);
int32_t SLPrepareBrightnessConnection(const char *uuid);
int32_t SLReadBrightness(const char *uuid, uint16_t *current, uint16_t *maximum);
void SLResetBrightnessConnections(void);
