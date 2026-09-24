/*
 * traffic.h - commute travel time from TomTom's routing API.
 *
 * The one provider that needs a credential the owner has to supply, so it is
 * also the one that stays switched off until a route and a key are configured:
 * unconfigured, it makes no network call at all and the model simply stays
 * invalid, which makes the widget draw its placeholder.
 */
#ifndef MIRROR_TRAFFIC_H
#define MIRROR_TRAFFIC_H

#include "providers/provider.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Allocates the response and token buffers. Call once before starting the
 * provider task. */
esp_err_t traffic_init(void);

/* Table entry to hand to providers_start(). */
const ml_provider *traffic_provider(void);

/*
 * Drop the current reading immediately. Called when the owner changes the
 * route or the key: the previous route's travel time must never be shown as
 * the new one's while the first fetch is still in flight.
 */
void traffic_invalidate(void);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_TRAFFIC_H */
