/*
 * provider.h - scheduling for things that fetch data.
 *
 * One task walks a table of providers and refreshes each when it is due, with
 * exponential backoff on failure. Providers do their own locking around the
 * model, holding it only for the copy, never across I/O.
 *
 * The part worth understanding is staleness. Every provider declares a grace
 * period, and once it has gone that long without a successful fetch its slice
 * of the model is invalidated, so the widget falls back to a placeholder.
 *
 * That is deliberate. A mirror showing last Tuesday's temperature as though it
 * were now is worse than one showing "--": you cannot tell by looking that it
 * is wrong, so you dress for the wrong weather. Stale data must announce
 * itself.
 */
#ifndef MIRROR_PROVIDER_H
#define MIRROR_PROVIDER_H

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    const char *name;

    /* Seconds between successful refreshes. */
    uint32_t interval_s;

    /* Seconds without a success after which the data is considered stale and
     * invalidate() is called. Should be a comfortable multiple of interval_s
     * so a couple of failed polls do not blank the display. */
    uint32_t grace_s;

    /*
     * Do the work. Runs on the provider task and may block on the network.
     * Must not hold the model lock across I/O.
     */
    esp_err_t (*refresh)(void);

    /* Clear this provider's fields in the model. Called when data goes stale. */
    void (*invalidate)(void);
} ml_provider;

/*
 * Start the provider task. The table must outlive the call, so pass static
 * storage. Providers are refreshed in table order on the first pass.
 */
esp_err_t providers_start(const ml_provider *table, int count);

/* Force every provider to refresh on the next pass, ignoring its interval.
 * Used after WiFi reconnects so data catches up promptly. */
void providers_refresh_now(void);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_PROVIDER_H */
