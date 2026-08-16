#include "openmeteo.h"

#include <stdio.h>
#include <string.h>

#include "config.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "mirror/json.h"
#include "model_store.h"
#include "net/http_get.h"
#include "sdkconfig.h"

static const char *TAG = "openmeteo";

/*
 * Comfortably above the roughly 1.5KB this query returns. Sized once at init
 * and reused, so a device that runs for months never fragments its heap on
 * per-fetch allocations.
 */
#define RESPONSE_CAP 6144
#define TOKEN_CAP    320

static char        *s_body;
static ml_json_tok *s_tokens;

esp_err_t openmeteo_init(void)
{
    /* PSRAM: only the CPU reads these, so internal SRAM is better spent on the
     * panel's DMA buffer, which genuinely cannot live anywhere else. */
    s_body = heap_caps_malloc(RESPONSE_CAP, MALLOC_CAP_SPIRAM);
    if (s_body == NULL) s_body = heap_caps_malloc(RESPONSE_CAP, MALLOC_CAP_INTERNAL);

    s_tokens = heap_caps_malloc(TOKEN_CAP * sizeof(ml_json_tok), MALLOC_CAP_SPIRAM);
    if (s_tokens == NULL) {
        s_tokens = heap_caps_malloc(TOKEN_CAP * sizeof(ml_json_tok), MALLOC_CAP_INTERNAL);
    }

    if (s_body == NULL || s_tokens == NULL) {
        /* Release whichever one did land. The caller disables the provider and
         * carries on, so this would otherwise strand a 6KB block for the life
         * of the device. */
        ESP_LOGE(TAG, "could not allocate the fetch buffers");
        heap_caps_free(s_body);
        heap_caps_free(s_tokens);
        s_body   = NULL;
        s_tokens = NULL;
        return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
}

/* Read one element of a "daily" array, which Open-Meteo returns as a list even
 * when only a single day was requested. */
static bool daily_first(const ml_json *j, int daily, const char *key, double *out)
{
    const int array = ml_json_member(j, daily, key);
    if (array < 0) return false;

    const int first = ml_json_array_at(j, array, 0);
    if (first < 0) return false;

    return ml_json_double(j, first, out);
}

static esp_err_t openmeteo_refresh(void)
{
    char url[512];
    /* Plain HTTP, deliberately: with no TLS certificate to validate there is
     * no dependency on the clock, so weather arrives in parallel with SNTP
     * rather than after it. The request and the coordinates are cleartext;
     * that is the accepted trade. */
    snprintf(url, sizeof(url),
             "http://api.open-meteo.com/v1/forecast"
             "?latitude=%s&longitude=%s"
             "&current=temperature_2m,apparent_temperature,relative_humidity_2m,"
             "weather_code,is_day,wind_speed_10m"
             "&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max"
             "&forecast_days=1&timezone=auto",
             mirror_config_latitude(), mirror_config_longitude());

    size_t len = 0;
    esp_err_t err = http_get(url, NULL, s_body, RESPONSE_CAP, &len, 10000);
    if (err != ESP_OK) return err;

    ml_json j;
    const int tokens = ml_json_parse(&j, s_body, len, s_tokens, TOKEN_CAP);
    if (tokens < 0) {
        ESP_LOGW(TAG, "response did not parse (code %d, %u bytes)", tokens, (unsigned)len);
        return ESP_ERR_INVALID_RESPONSE;
    }

    /*
     * Build the whole thing locally first. A half-updated model rendered
     * mid-write would show a new temperature next to yesterday's condition,
     * and only some of the time, which is a miserable bug to chase.
     */
    ml_weather w;
    memset(&w, 0, sizeof(w));
    snprintf(w.place, sizeof(w.place), "%s", mirror_config_place());

    const int current = ml_json_member(&j, 0, "current");
    if (current < 0) {
        ESP_LOGW(TAG, "no \"current\" block in the response");
        return ESP_ERR_INVALID_RESPONSE;
    }

    double value;
    if (!ml_json_get_double(&j, current, "temperature_2m", &value)) {
        /* Temperature is the one field the layout cannot sensibly do without,
         * so treat its absence as a failed fetch and keep the old reading. */
        ESP_LOGW(TAG, "no temperature in the response");
        return ESP_ERR_INVALID_RESPONSE;
    }
    w.temp_c = (float)value;

    if (ml_json_get_double(&j, current, "apparent_temperature", &value)) {
        w.feels_c = (float)value;
    } else {
        w.feels_c = w.temp_c;
    }

    int code = 0;
    if (ml_json_get_int(&j, current, "weather_code", &code)) w.code = code;

    int number = 0;
    if (ml_json_get_int(&j, current, "relative_humidity_2m", &number)) {
        w.humidity_pct = number;
    }
    if (ml_json_get_double(&j, current, "wind_speed_10m", &value)) {
        w.wind_kph = (float)value;
    }
    if (ml_json_get_int(&j, current, "is_day", &number)) {
        w.is_day = (number != 0);
    }

    const int daily = ml_json_member(&j, 0, "daily");
    if (daily >= 0) {
        if (daily_first(&j, daily, "temperature_2m_max", &value)) w.temp_max_c = (float)value;
        if (daily_first(&j, daily, "temperature_2m_min", &value)) w.temp_min_c = (float)value;
        if (daily_first(&j, daily, "precipitation_probability_max", &value)) {
            w.precip_prob = (int)value;
        }
    }

    w.valid = true;

    /* Lock held only for the copy, never across the fetch above. */
    model_store_lock();
    model_store_locked()->weather = w;
    model_store_unlock();

    ESP_LOGI(TAG, "%.1fC (feels %.1f), code %d, high %.0f low %.0f, %d%% rain",
             (double)w.temp_c, (double)w.feels_c, w.code,
             (double)w.temp_max_c, (double)w.temp_min_c, w.precip_prob);

    return ESP_OK;
}

static void openmeteo_invalidate(void)
{
    model_store_lock();
    model_store_locked()->weather.valid = false;
    model_store_unlock();
}

static const ml_provider s_provider = {
    .name = "weather",
    .interval_s = CONFIG_MIRROR_WEATHER_INTERVAL_S,
    /* Three missed polls before the display admits it does not know. Long
     * enough to ride out a router reboot, short enough that nobody dresses for
     * yesterday. */
    .grace_s = CONFIG_MIRROR_WEATHER_INTERVAL_S * 3,
    .refresh = openmeteo_refresh,
    .invalidate = openmeteo_invalidate,
};

const ml_provider *openmeteo_provider(void)
{
    return &s_provider;
}
