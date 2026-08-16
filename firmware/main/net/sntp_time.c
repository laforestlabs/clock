#include "config.h"
#include "sntp_time.h"

#include <string.h>
#include <time.h>

#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif_sntp.h"
#include "sdkconfig.h"

static const char *TAG = "time";

static bool s_started = false;
static esp_event_handler_instance_t s_ip_handler;

/*
 * Any year at or after this is taken as "the clock has been set".
 *
 * An unsynced ESP32 reports 1970. Rather than track a separate synced flag
 * that can drift out of step with the actual clock, the plausibility of the
 * clock is the flag.
 */
#define PLAUSIBLE_YEAR 2024

static void on_sync(struct timeval *tv)
{
    (void)tv;

    time_t now = time(NULL);
    struct tm local;
    localtime_r(&now, &local);

    char buf[64];
    strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S %Z", &local);
    ESP_LOGI(TAG, "clock synced: %s", buf);
}

static void sntp_on_got_ip(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg;
    (void)base;
    (void)id;
    (void)data;

    /* Idempotent: the link can drop and return later, but SNTP keeps its own
     * poll cycle once started, so it must not be re-initialised. */
    if (s_started) return;

    /* Several servers: lwIP falls through to the next one immediately when a
     * response is lost, instead of sitting out the 15s recv timeout plus an
     * exponential backoff on a single server. The configured server stays
     * first; the rest are public fallbacks that need no signup. */
    esp_sntp_config_t config = ESP_NETIF_SNTP_DEFAULT_CONFIG_MULTIPLE(
        4, ESP_SNTP_SERVER_LIST(CONFIG_MIRROR_SNTP_SERVER, "time.google.com",
                                "time.cloudflare.com", "time.nist.gov"));
    config.start = true;
    config.server_from_dhcp = false;
    config.sync_cb = on_sync;
    config.wait_for_sync = false;

    /* Smooth adjustment rather than a step. A clock that jumps backwards makes
     * an agenda flicker between two states. The first sync is still an
     * immediate step: lwIP's smooth mode steps when the offset is large, which
     * 1970-to-now certainly is. */
    config.smooth_sync = true;

    esp_err_t err = esp_netif_sntp_init(&config);
    if (err != ESP_OK) {
        /* Leave s_started false so a later IP event can retry. */
        ESP_LOGE(TAG, "SNTP init failed: %s", esp_err_to_name(err));
        return;
    }
    s_started = true;
    ESP_LOGI(TAG, "SNTP started on link-up (%s + 3 fallbacks)", CONFIG_MIRROR_SNTP_SERVER);
}

void sntp_time_start(void)
{
    /* Set the zone before the first sync so the very first rendered frame is
     * already local rather than briefly UTC. The value comes from NVS, set by
     * the phone app; the Kconfig default is just the factory seed. */
    setenv("TZ", mirror_config_timezone(), 1);
    tzset();
    ESP_LOGI(TAG, "timezone %s", mirror_config_timezone());

    /* Start SNTP only once the station has an address. A request sent before
     * the link is up dies with no route and no DNS, and lwIP's exponential
     * retry backoff (15s doubling to 150s) then delays the real sync by
     * minutes. Waiting for GOT_IP makes the first request succeed outright. */
    esp_err_t err = esp_event_handler_instance_register(
        IP_EVENT, IP_EVENT_STA_GOT_IP, sntp_on_got_ip, NULL, &s_ip_handler);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "could not register the IP handler: %s", esp_err_to_name(err));
    }
}

bool sntp_time_is_synced(void)
{
    time_t now = time(NULL);
    struct tm local;
    localtime_r(&now, &local);
    return (local.tm_year + 1900) >= PLAUSIBLE_YEAR;
}

void sntp_time_fill(ml_time *out)
{
    if (out == NULL) return;
    memset(out, 0, sizeof(*out));

    time_t now = time(NULL);
    struct tm local;
    localtime_r(&now, &local);

    if ((local.tm_year + 1900) < PLAUSIBLE_YEAR) {
        out->valid = false;
        return;
    }

    out->valid   = true;
    out->year    = local.tm_year + 1900;
    out->month   = local.tm_mon + 1;
    out->day     = local.tm_mday;
    out->hour    = local.tm_hour;
    out->minute  = local.tm_min;
    out->second  = local.tm_sec;
    out->weekday = local.tm_wday;   /* 0 = Sunday, same convention as ml_time */
    out->yday    = local.tm_yday + 1;
}
