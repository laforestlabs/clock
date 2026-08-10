/*
 * config.c - owner-set device configuration, stored in NVS.
 *
 * The phone app (Bluetooth) is the only writer. Kconfig values are the
 * factory defaults: on first boot every key is absent from NVS and gets
 * seeded from Kconfig, and everything the phone pushes afterwards overrides
 * them and survives reboots.
 *
 * The apply path validates the whole JSON object before touching anything,
 * on the same principle as the layout store: a bad push must never be able
 * to leave the device half-configured. A partial object only changes the
 * fields it names.
 */
#include "config.h"

#include <stdio.h>
#include <string.h>
#include <time.h>

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "mirror/json.h"
#include "nvs.h"
#include "providers/provider.h"
#include "sdkconfig.h"

static const char *TAG = "config";

#define NVS_NS        "mirror"
#define NVS_KEY_TZ    "tz"
#define NVS_KEY_LAT   "lat"
#define NVS_KEY_LON   "lon"
#define NVS_KEY_PLACE "place"

/* Validation limits, mirrored exactly in the Dart MirrorConfig.validate(). */
#define TZ_MAX_LEN    63   /* POSIX TZ strings are short; 63 keeps snprintf
                            * margins generous */
#define PLACE_MAX_LEN 23   /* fits ml_weather.place[24] */

/* Buffers for the formatted values. Latitude/longitude are stored as the
 * decimal strings the provider URL wants; 16 bytes covers any value the
 * validation ranges admit with room to spare. */
#define TZ_BUF_LEN    (TZ_MAX_LEN + 1)
#define PLACE_BUF_LEN (PLACE_MAX_LEN + 1)
#define COORD_BUF_LEN 16

static char        s_tz[TZ_BUF_LEN];
static char        s_lat[COORD_BUF_LEN];
static char        s_lon[COORD_BUF_LEN];
static char        s_place[PLACE_BUF_LEN];
static SemaphoreHandle_t s_lock;

static void lock(void) { xSemaphoreTake(s_lock, portMAX_DELAY); }
static void unlock(void) { xSemaphoreGive(s_lock); }

/*
 * Read one key, seeding it from the fallback when absent. A value that does
 * not fit its buffer is treated as corrupt (it could only have got there
 * through a bug) and replaced by the fallback rather than trusted.
 */
static void load_key(nvs_handle_t h, const char *key,
                     char *out, size_t outsz, const char *fallback)
{
    size_t len = outsz;
    esp_err_t err = nvs_get_str(h, key, out, &len);
    if (err == ESP_OK) return;

    if (err != ESP_ERR_NVS_NOT_FOUND) {
        ESP_LOGW(TAG, "key \"%s\" unreadable (%s), reseeding", key,
                 esp_err_to_name(err));
    }

    snprintf(out, outsz, "%s", fallback);
    if (nvs_set_str(h, key, fallback) == ESP_OK) {
        nvs_commit(h);
    }
}

esp_err_t mirror_config_init(void)
{
    s_lock = xSemaphoreCreateMutex();
    if (s_lock == NULL) return ESP_ERR_NO_MEM;

    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NS, NVS_READWRITE, &h);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "nvs open failed: %s", esp_err_to_name(err));
        return err;
    }

    load_key(h, NVS_KEY_TZ,    s_tz,    sizeof(s_tz),    CONFIG_MIRROR_TIMEZONE);
    load_key(h, NVS_KEY_LAT,   s_lat,   sizeof(s_lat),   CONFIG_MIRROR_LATITUDE);
    load_key(h, NVS_KEY_LON,   s_lon,   sizeof(s_lon),   CONFIG_MIRROR_LONGITUDE);
    load_key(h, NVS_KEY_PLACE, s_place, sizeof(s_place), CONFIG_MIRROR_PLACE_NAME);

    nvs_close(h);

    ESP_LOGI(TAG, "tz \"%s\", lat %s, lon %s, place \"%s\"",
             s_tz, s_lat, s_lon, s_place);
    return ESP_OK;
}

const char *mirror_config_timezone(void)  { return s_tz; }
const char *mirror_config_latitude(void)  { return s_lat; }
const char *mirror_config_longitude(void) { return s_lon; }
const char *mirror_config_place(void)     { return s_place; }

static void fail(char *err, size_t errsz, const char *msg)
{
    if (err != NULL && errsz > 0) snprintf(err, errsz, "%s", msg);
}

esp_err_t mirror_config_apply_json(const char *json, size_t len,
                                   char *err, size_t errsz)
{
    if (json == NULL || len == 0) {
        fail(err, errsz, "empty config");
        return ESP_ERR_INVALID_ARG;
    }

    ml_json_tok toks[16];
    ml_json j;
    const int n = ml_json_parse(&j, json, len, toks, 16);
    if (n < 0 || j.count == 0 || j.toks[0].type != ML_JSON_OBJECT) {
        fail(err, errsz, "expected a JSON object");
        return ESP_ERR_INVALID_ARG;
    }

    /* Parse and validate every present field into locals first. Nothing is
     * committed until all of them pass. */
    char   new_tz[TZ_BUF_LEN] = "";
    char   new_lat[COORD_BUF_LEN] = "";
    char   new_lon[COORD_BUF_LEN] = "";
    char   new_place[PLACE_BUF_LEN] = "";
    bool   have_tz = false, have_lat = false, have_lon = false, have_place = false;

    int t = ml_json_member(&j, 0, "timezone");
    if (t >= 0) {
        if (!ml_json_str(&j, t, new_tz, sizeof(new_tz))) {
            fail(err, errsz, "timezone must be a string");
            return ESP_ERR_INVALID_ARG;
        }
        if (new_tz[0] == '\0') {
            fail(err, errsz, "timezone must not be empty");
            return ESP_ERR_INVALID_ARG;
        }
        if (strlen(new_tz) > TZ_MAX_LEN) {
            fail(err, errsz, "timezone is too long (max 63)");
            return ESP_ERR_INVALID_ARG;
        }
        have_tz = true;
    }

    t = ml_json_member(&j, 0, "latitude");
    if (t >= 0) {
        double d;
        if (!ml_json_double(&j, t, &d) || d < -90.0 || d > 90.0) {
            fail(err, errsz, "latitude must be a number in [-90, 90]");
            return ESP_ERR_INVALID_ARG;
        }
        snprintf(new_lat, sizeof(new_lat), "%.7g", d);
        have_lat = true;
    }

    t = ml_json_member(&j, 0, "longitude");
    if (t >= 0) {
        double d;
        if (!ml_json_double(&j, t, &d) || d < -180.0 || d > 180.0) {
            fail(err, errsz, "longitude must be a number in [-180, 180]");
            return ESP_ERR_INVALID_ARG;
        }
        snprintf(new_lon, sizeof(new_lon), "%.7g", d);
        have_lon = true;
    }

    t = ml_json_member(&j, 0, "place");
    if (t >= 0) {
        if (!ml_json_str(&j, t, new_place, sizeof(new_place))) {
            fail(err, errsz, "place must be a string");
            return ESP_ERR_INVALID_ARG;
        }
        if (strlen(new_place) > PLACE_MAX_LEN) {
            fail(err, errsz, "place is too long (max 23)");
            return ESP_ERR_INVALID_ARG;
        }
        have_place = true;
    }

    /* Nothing named: a no-op, not an error. */
    if (!have_tz && !have_lat && !have_lon && !have_place) {
        fail(err, errsz, "no known fields");
        return ESP_ERR_INVALID_ARG;
    }

    /* Persist the changed fields, then apply them. */
    const bool tz_changed   = have_tz   && strcmp(new_tz, s_tz) != 0;
    const bool lat_changed  = have_lat  && strcmp(new_lat, s_lat) != 0;
    const bool lon_changed  = have_lon  && strcmp(new_lon, s_lon) != 0;
    const bool place_changed = have_place && strcmp(new_place, s_place) != 0;

    if (tz_changed || lat_changed || lon_changed || place_changed) {
        nvs_handle_t h;
        esp_err_t nvs_err = nvs_open(NVS_NS, NVS_READWRITE, &h);
        if (nvs_err != ESP_OK) {
            fail(err, errsz, "config storage unavailable");
            return nvs_err;
        }
        if (tz_changed)     nvs_set_str(h, NVS_KEY_TZ, new_tz);
        if (lat_changed)    nvs_set_str(h, NVS_KEY_LAT, new_lat);
        if (lon_changed)    nvs_set_str(h, NVS_KEY_LON, new_lon);
        if (place_changed)  nvs_set_str(h, NVS_KEY_PLACE, new_place);
        nvs_err = nvs_commit(h);
        nvs_close(h);
        if (nvs_err != ESP_OK) {
            fail(err, errsz, "config could not be saved");
            return nvs_err;
        }
    }

    lock();
    if (have_tz)     memcpy(s_tz, new_tz, sizeof(s_tz));
    if (have_lat)    memcpy(s_lat, new_lat, sizeof(s_lat));
    if (have_lon)    memcpy(s_lon, new_lon, sizeof(s_lon));
    if (have_place)  memcpy(s_place, new_place, sizeof(s_place));
    unlock();

    if (tz_changed) {
        ESP_LOGI(TAG, "timezone %s -> %s", mirror_config_timezone(), new_tz);
        setenv("TZ", new_tz, 1);
        tzset();
    }
    if (lat_changed || lon_changed || place_changed) {
        ESP_LOGI(TAG, "weather now at %s, %s (\"%s\")", s_lat, s_lon, s_place);
        providers_refresh_now();
    }

    return ESP_OK;
}
