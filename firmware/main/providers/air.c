#include "air.h"

#include <stdio.h>
#include <string.h>

#include "config.h"
#include "esp_heap_caps.h"
#include "esp_http_client.h"
#include "esp_log.h"
#include "mirror/json.h"
#include "model_store.h"
#include "net/http_get.h"
#include "net/sntp_time.h"
#include "sdkconfig.h"
#include "netlog.h"
#include "net/wifi.h"

static const char *TAG = "air";

/*
 * The current block, the five hourly pollen arrays and the metadata that comes
 * with them all fit in well under a kilobyte; 4KB leaves room for the service
 * to grow its unit blocks without this becoming a silent truncation. Sized
 * once at init and reused, like every other provider.
 */
#define RESPONSE_CAP 4096
#define TOKEN_CAP    256

static char        *s_body;
static ml_json_tok *s_tokens;

esp_err_t air_init(void)
{
    /* PSRAM: only the CPU reads these, so internal SRAM stays free for the
     * panel's DMA buffer, which genuinely cannot live anywhere else. */
    s_body = heap_caps_malloc(RESPONSE_CAP, MALLOC_CAP_SPIRAM);
    if (s_body == NULL) s_body = heap_caps_malloc(RESPONSE_CAP, MALLOC_CAP_INTERNAL);

    s_tokens = heap_caps_malloc(TOKEN_CAP * sizeof(ml_json_tok), MALLOC_CAP_SPIRAM);
    if (s_tokens == NULL) {
        s_tokens = heap_caps_malloc(TOKEN_CAP * sizeof(ml_json_tok), MALLOC_CAP_INTERNAL);
    }

    if (s_body == NULL || s_tokens == NULL) {
        ESP_LOGE(TAG, "could not allocate the fetch buffers");
        heap_caps_free(s_body);
        heap_caps_free(s_tokens);
        s_body   = NULL;
        s_tokens = NULL;
        return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
}

/* The local hour, for indexing an hourly array the service padded out to a
 * whole day. Read under the store lock, then released: nothing below touches
 * the shared model again until the copy at the end. */
static int local_hour(void)
{
    int hour = 0;
    model_store_lock();
    const ml_model *m = model_store_locked();
    if (m->now.valid) hour = m->now.hour;
    model_store_unlock();
    return hour;
}

/*
 * One pollen series out of the hourly block.
 *
 * Pollen is documented under "hourly" rather than "current", and only for the
 * CAMS Europe domain. With forecast_hours=1 the array holds the current hour
 * alone, so element 0 is the answer; when the parameter is not honoured and
 * the array covers the whole day, element 0 is midnight and the local hour
 * picks the right one. Either way an absent series returns false, and the
 * caller leaves that plant at its -1 placeholder.
 */
static bool hourly_pollen(const ml_json *j, int hourly, const char *key,
                          int hour, float *out)
{
    const int arr = ml_json_member(j, hourly, key);
    if (arr < 0) return false;

    const int n = ml_json_array_count(j, arr);
    if (n <= 0) return false;

    int idx = 0;
    if (n > 1) idx = hour < 0 ? 0 : hour;
    if (idx >= n) idx = n - 1;

    const int e = ml_json_array_at(j, arr, idx);
    double v = 0.0;
    if (e < 0 || !ml_json_double(j, e, &v)) return false;

    *out = (float)v;
    return true;
}

static esp_err_t air_refresh(void)
{
    char url[512];
    /*
     * HTTPS by default, and http_get.c attaches the root bundle, so the
     * response is verified. The exception is the first fetch after a reboot,
     * when the clock is still unknown: a certificate's dates cannot be checked
     * against 1970, and this fetch may be the one that sets the clock from its
     * own Date header. The request and the coordinates leak to the network in
     * that one exchange, exactly as the weather provider's first fetch does.
     */
    const char *scheme = sntp_time_is_synced() ? "https" : "http";
    snprintf(url, sizeof(url),
             "%s://air-quality-api.open-meteo.com/v1/air-quality"
             "?latitude=%s&longitude=%s"
             "&current=european_aqi,us_aqi,pm2_5,pm10,uv_index"
             "&hourly=alder_pollen,birch_pollen,grass_pollen"
             "&forecast_hours=1&timezone=auto",
             scheme, mirror_config_latitude(), mirror_config_longitude());

    size_t len = 0;
    esp_err_t err = http_get(url, NULL, s_body, RESPONSE_CAP, &len, NULL, 10000);
    if (err != ESP_OK) {
        int cls = NETLOG_ERR_CONNECT;
        if (err == ESP_ERR_INVALID_RESPONSE) cls = NETLOG_ERR_HTTP;
        else if (err == ESP_ERR_NO_MEM)      cls = NETLOG_ERR_NOMEM;
        else if (err != ESP_ERR_HTTP_CONNECT) cls = NETLOG_ERR_HTTP;
        netlog_record(NETLOG_EVT_AIR_FETCH_FAIL, wifi_rssi(), cls);
        return err;
    }

    ml_json j;
    const int tokens = ml_json_parse(&j, s_body, len, s_tokens, TOKEN_CAP);
    if (tokens < 0) {
        ESP_LOGW(TAG, "response did not parse (code %d, %u bytes)", tokens, (unsigned)len);
        netlog_record(NETLOG_EVT_AIR_FETCH_FAIL, wifi_rssi(), NETLOG_ERR_PARSE);
        return ESP_ERR_INVALID_RESPONSE;
    }

    /* Built locally first: a half-updated model rendered mid-write would show
     * a new AQI beside the previous hour's pollen. */
    ml_air a;
    memset(&a, 0, sizeof(a));
    for (int i = 0; i < ML_POLLEN_TYPES; i++) a.pollen[i] = -1.0f;

    const int current = ml_json_member(&j, 0, "current");
    if (current < 0) {
        ESP_LOGW(TAG, "no \"current\" block in the response");
        netlog_record(NETLOG_EVT_AIR_FETCH_FAIL, wifi_rssi(), NETLOG_ERR_PARSE);
        return ESP_ERR_INVALID_RESPONSE;
    }

    /* Both index scales are served by the same response, so a missing one is
     * recorded as zero-invalid rather than a failed fetch; only losing both
     * means there is nothing to show. */
    int aqi = 0, aqi_us = 0;
    const bool have_eu = ml_json_get_int(&j, current, "european_aqi", &aqi);
    const bool have_us = ml_json_get_int(&j, current, "us_aqi", &aqi_us);
    if (!have_eu && !have_us) {
        ESP_LOGW(TAG, "no AQI in the response");
        netlog_record(NETLOG_EVT_AIR_FETCH_FAIL, wifi_rssi(), NETLOG_ERR_PARSE);
        return ESP_ERR_INVALID_RESPONSE;
    }
    a.aqi    = aqi;
    a.aqi_us = aqi_us;

    double value = 0.0;
    if (ml_json_get_double(&j, current, "pm2_5", &value))    a.pm2_5 = (float)value;
    if (ml_json_get_double(&j, current, "pm10", &value))     a.pm10 = (float)value;
    if (ml_json_get_double(&j, current, "uv_index", &value)) a.uv_index = (float)value;

    const int hourly = ml_json_member(&j, 0, "hourly");
    bool have_pollen = false;
    if (hourly >= 0) {
        const int hour = local_hour();
        static const char *const keys[ML_POLLEN_TYPES] = {
            "alder_pollen", "birch_pollen", "grass_pollen"
        };
        for (int i = 0; i < ML_POLLEN_TYPES; i++) {
            float v = 0.0f;
            if (hourly_pollen(&j, hourly, keys[i], hour, &v)) {
                a.pollen[i] = v;
                have_pollen = true;
            }
        }
    }
    a.pollen_valid = have_pollen;
    a.valid = true;

    /* Lock held only for the copy, never across the fetch above. */
    model_store_lock();
    model_store_locked()->air = a;
    model_store_unlock();

    ESP_LOGI(TAG, "AQI %d (US %d), pm2.5 %.1f, pm10 %.1f, UV %.1f, pollen %s",
             a.aqi, a.aqi_us, (double)a.pm2_5, (double)a.pm10,
             (double)a.uv_index, have_pollen ? "available" : "unavailable");

    netlog_record(NETLOG_EVT_AIR_FETCH_OK, wifi_rssi(), 0);
    return ESP_OK;
}

static void air_invalidate(void)
{
    model_store_lock();
    model_store_locked()->air.valid = false;
    model_store_unlock();
    netlog_record(NETLOG_EVT_AIR_STALE, wifi_rssi(), 0);
}

static const ml_provider s_provider = {
    .name = "air",
    .interval_s = CONFIG_MIRROR_AIR_INTERVAL_S,
    /* Three missed polls before the display admits it does not know. */
    .grace_s = CONFIG_MIRROR_AIR_INTERVAL_S * 3,
    .refresh = air_refresh,
    .invalidate = air_invalidate,
};

const ml_provider *air_provider(void)
{
    return &s_provider;
}
