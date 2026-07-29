#include "sntp_time.h"

#include <string.h>
#include <time.h>

#include "esp_log.h"
#include "esp_netif_sntp.h"
#include "sdkconfig.h"

static const char *TAG = "time";

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

void sntp_time_start(void)
{
    /* Set the zone before the first sync so the very first rendered frame is
     * already local rather than briefly UTC. */
    setenv("TZ", CONFIG_MIRROR_TIMEZONE, 1);
    tzset();
    ESP_LOGI(TAG, "timezone %s", CONFIG_MIRROR_TIMEZONE);

    esp_sntp_config_t config =
        ESP_NETIF_SNTP_DEFAULT_CONFIG(CONFIG_MIRROR_SNTP_SERVER);
    config.start = true;
    config.server_from_dhcp = false;
    config.sync_cb = on_sync;

    /* Smooth adjustment rather than a step. A clock that jumps backwards makes
     * an agenda flicker between two states. */
    config.smooth_sync = true;

    esp_err_t err = esp_netif_sntp_init(&config);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "SNTP init failed: %s", esp_err_to_name(err));
        return;
    }
    ESP_LOGI(TAG, "SNTP started against %s", CONFIG_MIRROR_SNTP_SERVER);
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
