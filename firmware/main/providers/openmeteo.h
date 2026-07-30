/*
 * openmeteo.h - weather from Open-Meteo.
 *
 * No API key, no signup, and generous limits for a device polling every
 * quarter of an hour. That matters more than it sounds: it means the mirror
 * has no credential to expire, leak, or re-provision.
 */
#ifndef MIRROR_OPENMETEO_H
#define MIRROR_OPENMETEO_H

#include "providers/provider.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Allocates the response and token buffers. Call once before starting the
 * provider task. */
esp_err_t openmeteo_init(void);

/* Table entry to hand to providers_start(). */
const ml_provider *openmeteo_provider(void);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_OPENMETEO_H */
