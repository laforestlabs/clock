#include "provider.h"

#include <string.h>

#include "esp_http_client.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "net/wifi.h"

static const char *TAG = "provider";

#define MAX_PROVIDERS 6
#define TICK_MS       1000

typedef struct {
    const ml_provider *def;
    int64_t next_due_us;
    int64_t last_ok_us;
    int     failures;
    bool    stale;
} provider_state;

static provider_state s_state[MAX_PROVIDERS];
static int            s_count;
static volatile bool  s_force_refresh;

/*
 * A connectivity failure means the request never reached the service: the
 * WiFi link is down, DNS did not resolve, or the connect/TLS handshake timed
 * out. There is no service to be polite to, so these retry at the healthy
 * cadence and catch recovery promptly instead of escalating. Only failures
 * where the service answered (non-2xx, bad payloads, rate limits) back off.
 */
static bool is_connectivity_error(esp_err_t err)
{
    return err == ESP_ERR_HTTP_CONNECT;
}

/*
 * Back off after failures, capped.
 *
 * Without this a provider whose service is down retries at its normal
 * interval forever, which is rude to the API and, on a rate-limited one,
 * self-defeating: the 429s keep the backoff from ever clearing.
 */
static int64_t backoff_us(const ml_provider *def, int failures, esp_err_t err)
{
    if (is_connectivity_error(err)) {
        return (int64_t)def->interval_s * 1000000;
    }

    /*
     * Never retry sooner than the provider polls when it is healthy. Clamping
     * flat to an hour did exactly that: the configurable range runs to six
     * hours, so a provider set to poll every six would come back after a
     * failure in one, hitting a service that is already unhappy six times as
     * often as when it was working.
     */
    const uint32_t ceiling = def->interval_s > 3600 ? def->interval_s : 3600;

    uint32_t seconds = def->interval_s;
    for (int i = 1; i < failures && seconds < ceiling; i++) seconds *= 2;
    if (seconds > ceiling) seconds = ceiling;
    return (int64_t)seconds * 1000000;
}

static void provider_task(void *arg)
{
    (void)arg;

    bool was_online = false;

    for (;;) {
        const int64_t now = esp_timer_get_time();
        const bool online = wifi_is_connected();

        /*
         * Catch up immediately when the link returns rather than sitting out
         * a backoff that was earned while the network was down. After a router
         * reboot the failures are the outage's fault, not the API's, so the
         * penalty should not outlive it.
         */
        if (online && !was_online) {
            ESP_LOGI(TAG, "link is back, refreshing everything now");
            providers_refresh_now();
        }
        was_online = online;

        if (s_force_refresh && online) {
            for (int i = 0; i < s_count; i++) {
                s_state[i].next_due_us = now;
                s_state[i].failures = 0;   /* clear the backoff, not the staleness */
            }
            s_force_refresh = false;
        }

        for (int i = 0; i < s_count; i++) {
            provider_state *st = &s_state[i];
            const ml_provider *def = st->def;

            /* Staleness is checked even while offline. An outage is exactly
             * when the display would otherwise quietly keep showing old data
             * as though it were current. */
            if (!st->stale && st->last_ok_us != 0 &&
                (now - st->last_ok_us) > (int64_t)def->grace_s * 1000000) {
                ESP_LOGW(TAG, "%s: no success for %us, marking stale",
                         def->name, def->grace_s);
                if (def->invalidate != NULL) def->invalidate();
                st->stale = true;
            }

            if (!online) continue;
            if (now < st->next_due_us) continue;

            const int64_t started = esp_timer_get_time();
            const esp_err_t err = def->refresh();
            const int64_t took_ms = (esp_timer_get_time() - started) / 1000;

            if (err == ESP_OK) {
                if (st->failures > 0) {
                    ESP_LOGI(TAG, "%s: recovered after %d failure(s)",
                             def->name, st->failures);
                }
                st->failures = 0;
                st->stale = false;
                st->last_ok_us = esp_timer_get_time();
                st->next_due_us = st->last_ok_us + (int64_t)def->interval_s * 1000000;
                ESP_LOGI(TAG, "%s: updated in %lldms, next in %us",
                         def->name, (long long)took_ms, def->interval_s);
            } else {
                st->failures++;
                const int64_t wait = backoff_us(def, st->failures, err);
                st->next_due_us = esp_timer_get_time() + wait;
                ESP_LOGW(TAG, "%s: failed (%s), attempt %d, retry in %llds",
                         def->name, esp_err_to_name(err), st->failures,
                         (long long)(wait / 1000000));
            }
        }

        vTaskDelay(pdMS_TO_TICKS(TICK_MS));
    }
}

esp_err_t providers_start(const ml_provider *table, int count)
{
    if (table == NULL || count <= 0) return ESP_ERR_INVALID_ARG;
    if (count > MAX_PROVIDERS) {
        ESP_LOGE(TAG, "%d providers exceeds the limit of %d", count, MAX_PROVIDERS);
        return ESP_ERR_INVALID_ARG;
    }

    memset(s_state, 0, sizeof(s_state));
    s_count = count;

    for (int i = 0; i < count; i++) {
        s_state[i].def = &table[i];
        /* Stagger the first fetch so several providers do not all open TLS
         * connections at once on a device with limited heap. */
        s_state[i].next_due_us = (int64_t)i * 2 * 1000000;
        ESP_LOGI(TAG, "registered %s, every %us, stale after %us",
                 table[i].name, table[i].interval_s, table[i].grace_s);
    }

    /* 6KB: TLS handshakes are the stack-hungry part of this task, not the
     * JSON parsing. */
    if (xTaskCreate(provider_task, "providers", 6144, NULL, 4, NULL) != pdPASS) {
        ESP_LOGE(TAG, "could not create the provider task");
        return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
}

void providers_refresh_now(void)
{
    s_force_refresh = true;
}
