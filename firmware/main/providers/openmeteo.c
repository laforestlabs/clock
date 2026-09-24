#include "openmeteo.h"

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

static const char *TAG = "openmeteo";

/*
 * Comfortably above the roughly 1.8KB this query returns: three daily arrays
 * of sunrise/sunset strings and the extra hourly arrays add about 300 bytes to
 * the single-day version. Sized once at init and reused, so a device that runs
 * for months never fragments its heap on per-fetch allocations.
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

/* The same, for one specific day of a multi-day array. Element idx must exist;
 * a short array simply reads as absent. */
static bool daily_at(const ml_json *j, int daily, const char *key, int idx,
                     double *out)
{
    const int array = ml_json_member(j, daily, key);
    if (array < 0) return false;

    const int element = ml_json_array_at(j, array, idx);
    if (element < 0) return false;

    return ml_json_double(j, element, out);
}

/*
 * Sunrise and sunset arrive as local ISO8601 ("2026-07-29T05:12"), so this
 * reads the hour and minute straight after the 'T' rather than pulling in
 * strptime: newlib's is locale- and lock-heavy, and the shape of this one
 * field is fixed by the API. Returns minutes since local midnight, or -1 when
 * the value is missing or not shaped as expected.
 */
static int daily_hm(const ml_json *j, int daily, const char *key, int idx)
{
    const int array = ml_json_member(j, daily, key);
    if (array < 0) return -1;

    const int element = ml_json_array_at(j, array, idx);
    if (element < 0) return -1;

    char buf[32];
    if (!ml_json_str(j, element, buf, sizeof(buf))) return -1;

    const char *t = strchr(buf, 'T');
    if (!t || !t[1] || !t[2] || !t[3] || !t[4]) return -1;
    for (int i = 1; i <= 4; i++) {
        if (t[i] < '0' || t[i] > '9') return -1;
    }

    const int hour = (t[1] - '0') * 10 + (t[2] - '0');
    const int min  = (t[3] - '0') * 10 + (t[4] - '0');
    if (hour > 23 || min > 59) return -1;
    return hour * 60 + min;
}

/* Copy the first ML_PRECIP_HOURS entries of the "hourly" precipitation array.
 * Open-Meteo returns exactly 12 entries when forecast_hours=12 is requested,
 * starting at the current hour. */
static void hourly_precip(const ml_json *j, int hourly, ml_weather *w)
{
    const int arr = ml_json_member(j, hourly, "precipitation_probability");
    if (arr < 0) return;

    int n = ml_json_array_count(j, arr);
    if (n > ML_PRECIP_HOURS) n = ML_PRECIP_HOURS;

    for (int i = 0; i < n; i++) {
        int e     = ml_json_array_at(j, arr, i);
        int value = 0;
        if (e >= 0 && ml_json_int(j, e, &value)) {
            w->precip_hourly[i] = value;
        }
    }
    if (n > 0) w->precip_hourly_valid = true;
}

static esp_err_t openmeteo_refresh(void)
{
    char url[512];
    /* HTTPS by default, and http_get.c attaches the root bundle, so the response
     * is verified. The exception is the first fetch after a reboot, when the
     * clock is still unknown: with no RTC and SNTP over UDP 123 blocked - which
     * is exactly what a restrictive guest network does while leaving 80/443 open
     * - a handshake would fail its certificate date check. That single fetch
     * goes out cleartext, and it is the fetch that sets the clock, from its own
     * Date header. Every fetch after it is HTTPS and validated. The request and
     * the coordinates leak to the network in that first exchange; that is the
     * accepted trade for a clock the mirror could not otherwise get. */
    const char *scheme = sntp_time_is_synced() ? "https" : "http";
    snprintf(url, sizeof(url),
             "%s://api.open-meteo.com/v1/forecast"
             "?latitude=%s&longitude=%s"
             "&current=temperature_2m,apparent_temperature,relative_humidity_2m,"
             "weather_code,is_day,wind_speed_10m,wind_direction_10m,wind_gusts_10m"
             "&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max,"
             "weather_code,sunrise,sunset"
             "&hourly=precipitation_probability"
             "&forecast_days=3&forecast_hours=12&timezone=auto",
             scheme, mirror_config_latitude(), mirror_config_longitude());

    size_t len = 0;
    esp_err_t err = http_get(url, NULL, s_body, RESPONSE_CAP, &len, NULL, 10000);
    if (err != ESP_OK) {
        int cls = NETLOG_ERR_CONNECT;
        if (err == ESP_ERR_INVALID_RESPONSE) cls = NETLOG_ERR_HTTP;
        else if (err == ESP_ERR_NO_MEM)       cls = NETLOG_ERR_NOMEM;
        else if (err != ESP_ERR_HTTP_CONNECT) cls = NETLOG_ERR_HTTP;
        netlog_record(NETLOG_EVT_WEATHER_FETCH_FAIL, wifi_rssi(), cls);
        return err;
    }

    ml_json j;
    const int tokens = ml_json_parse(&j, s_body, len, s_tokens, TOKEN_CAP);
    if (tokens < 0) {
        ESP_LOGW(TAG, "response did not parse (code %d, %u bytes)", tokens, (unsigned)len);
        netlog_record(NETLOG_EVT_WEATHER_FETCH_FAIL, wifi_rssi(), NETLOG_ERR_PARSE);
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
        netlog_record(NETLOG_EVT_WEATHER_FETCH_FAIL, wifi_rssi(), NETLOG_ERR_PARSE);
        return ESP_ERR_INVALID_RESPONSE;
    }

    double value;
    if (!ml_json_get_double(&j, current, "temperature_2m", &value)) {
        /* Temperature is the one field the layout cannot sensibly do without,
         * so treat its absence as a failed fetch and keep the old reading. */
        ESP_LOGW(TAG, "no temperature in the response");
        netlog_record(NETLOG_EVT_WEATHER_FETCH_FAIL, wifi_rssi(), NETLOG_ERR_PARSE);
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
    if (ml_json_get_double(&j, current, "wind_direction_10m", &value)) {
        w.wind_dir_deg   = (float)value;
        w.wind_dir_valid = true;
    }
    if (ml_json_get_double(&j, current, "wind_gusts_10m", &value)) {
        w.wind_gust_kph = (float)value;
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
        w.sunrise_min = daily_hm(&j, daily, "sunrise", 0);
        w.sunset_min  = daily_hm(&j, daily, "sunset", 0);

        /*
         * The strip's days must be all-or-nothing apiece: an icon from one
         * response and a range from another would put two days' weather in one
         * column, and only sometimes. So a day counts only when its code and
         * both temperatures parsed, and day_count is the length of the leading
         * run that did.
         */
        const int codes = ml_json_member(&j, daily, "weather_code");
        for (int i = 0; i < ML_FORECAST_DAYS; i++) {
            double hi, lo;
            int    code;
            const int element = codes >= 0 ? ml_json_array_at(&j, codes, i) : -1;
            if (element < 0 || !ml_json_int(&j, element, &code)) break;
            if (!daily_at(&j, daily, "temperature_2m_max", i, &hi)) break;
            if (!daily_at(&j, daily, "temperature_2m_min", i, &lo)) break;
            w.days[i].code       = code;
            w.days[i].temp_max_c = (float)hi;
            w.days[i].temp_min_c = (float)lo;
            w.day_count          = i + 1;
        }
    }

    const int hourly = ml_json_member(&j, 0, "hourly");
    if (hourly >= 0) {
        hourly_precip(&j, hourly, &w);
    }

    w.valid = true;

    /* Lock held only for the copy, never across the fetch above. */
    model_store_lock();
    model_store_locked()->weather = w;
    model_store_unlock();

    ESP_LOGI(TAG, "%.1fC (feels %.1f), code %d, high %.0f low %.0f, %d%% rain, "
             "wind %.0f kph%s, sun %d..%d, %d forecast days",
             (double)w.temp_c, (double)w.feels_c, w.code,
             (double)w.temp_max_c, (double)w.temp_min_c, w.precip_prob,
             (double)w.wind_kph,
             w.wind_dir_valid ? " with a direction" : " (no direction)",
             w.sunrise_min, w.sunset_min, w.day_count);

    netlog_record(NETLOG_EVT_WEATHER_FETCH_OK, wifi_rssi(), 0);
    return ESP_OK;
}

static void openmeteo_invalidate(void)
{
    model_store_lock();
    model_store_locked()->weather.valid = false;
    model_store_unlock();
    netlog_record(NETLOG_EVT_WEATHER_STALE, wifi_rssi(), 0);
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
