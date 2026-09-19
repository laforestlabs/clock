#include "provider.h"

#include <string.h>

#include "esp_heap_caps.h"
#include "esp_http_client.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "esp_tls_errors.h"
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
 * True when the failure says nothing about the service's health: the request
 * never produced a usable answer, because the link, the socket, the TLS
 * handshake or the mirror's own memory gave way first. esp_http_client and
 * esp-tls report those as their own error families (and an mbedTLS code can
 * surface unchanged, negative), while a service that answered with something
 * unusable comes back as ESP_ERR_INVALID_RESPONSE.
 *
 * The distinction matters because the two need opposite treatment. There is no
 * service to be polite to when the mirror is the one that failed, so those
 * retry on the short ladder below and catch recovery in seconds; only failures
 * where the service answered (non-2xx, bad payloads, rate limits) back off.
 */
static bool is_local_failure(esp_err_t err)
{
    if (err < 0) return true;                        /* an mbedTLS code, raw */
    if (err == ESP_ERR_NO_MEM || err == ESP_ERR_TIMEOUT) return true;

    /* 0x7000..0x8fff: the HTTP client's and esp-tls's own error families. */
    return err >= ESP_ERR_HTTP_BASE && err < ESP_ERR_ESP_TLS_BASE + 0x1000;
}

/*
 * How long to wait before retrying a local failure, for the first few of them.
 *
 * The provider's own interval is up to six hours, and the mirror's first fetch
 * after a boot - when panel DMA, WiFi and the BT controller have just taken
 * their internal RAM - is exactly when a TLS handshake can lose its allocation
 * race. Waiting out the interval over a hiccup that clears in a second is the
 * difference between weather arriving on that boot and a quarter of an hour of
 * stale data, which is the bug this ladder exists to prevent. Three rungs,
 * then the ordinary cadence: a genuinely broken link still stops hammering.
 */
#define RETRY_FAST_FIRST_S 5
#define RETRY_FAST_FACTOR  3
#define RETRY_FAST_RUNGS   3

/*
 * Back off after failures, capped.
 *
 * Without this a provider whose service is down retries at its normal
 * interval forever, which is rude to the API and, on a rate-limited one,
 * self-defeating: the 429s keep the backoff from ever clearing.
 */
static int64_t backoff_us(const ml_provider *def, int failures, esp_err_t err)
{
    if (is_local_failure(err)) {
        if (failures > RETRY_FAST_RUNGS) {
            return (int64_t)def->interval_s * 1000000;
        }
        /* 5s, 15s, 45s. */
        int64_t seconds = RETRY_FAST_FIRST_S;
        for (int i = 1; i < failures; i++) seconds *= RETRY_FAST_FACTOR;
        return seconds * 1000000;
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
                /* The internal-RAM figures are the ones that matter and the
                 * ones nothing else reports: this board has megabytes of PSRAM
                 * and only a few KB of internal DRAM left once the panel's DMA
                 * buffers, WiFi and the BT controller have taken theirs, and a
                 * fetch that dies of an allocation failure looks like a
                 * transport error from here. */
                ESP_LOGW(TAG, "%s: failed (%s), attempt %d, retry in %llds "
                         "(internal RAM free %u, largest %u; DMA-capable %u/%u)",
                         def->name, esp_err_to_name(err), st->failures,
                         (long long)(wait / 1000000),
                         (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
                         (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL),
                         (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_DMA),
                         (unsigned)heap_caps_get_free_size(MALLOC_CAP_DMA));
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
