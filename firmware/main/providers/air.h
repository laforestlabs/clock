/*
 * air.h - outdoor air quality from Open-Meteo's air-quality API.
 *
 * The same service family as the weather provider and, like it, keyless: the
 * mirror has no air-quality credential to expire or leak either. Pollen comes
 * from the same response but only inside the CAMS Europe domain, which is why
 * the model carries a separate "valid" flag for it.
 */
#ifndef MIRROR_AIR_H
#define MIRROR_AIR_H

#include "providers/provider.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Allocates the response and token buffers. Call once before starting the
 * provider task. */
esp_err_t air_init(void);

/* Table entry to hand to providers_start(). */
const ml_provider *air_provider(void);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_AIR_H */
