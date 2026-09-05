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
#include "esp_mac.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "mirror/json.h"
#include "nvs.h"
#include "panel.h"
#include "providers/provider.h"
#include "sdkconfig.h"

static const char *TAG = "config";

#define NVS_NS        "mirror"
#define NVS_KEY_TZ    "tz"
#define NVS_KEY_LAT   "lat"
#define NVS_KEY_LON   "lon"
#define NVS_KEY_PLACE "place"
#define NVS_KEY_BRIGHTNESS "brightness"
#define NVS_KEY_CLOCK12H   "clock12h"
#define NVS_KEY_TEMP_UNIT  "temp_unit"
#define NVS_KEY_NAME       "name"

/* Validation limits, mirrored exactly in the Dart MirrorConfig.validate(). */
#define TZ_MAX_LEN    63   /* POSIX TZ strings are short; 63 keeps snprintf
                            * margins generous */
#define PLACE_MAX_LEN 23   /* fits ml_weather.place[24] */
#define NAME_MAX_LEN  24   /* fits the 31-byte BLE advertising packet next
                            * to the flags field, with room to spare */

/* Buffers for the formatted values. Latitude/longitude are stored as the
 * decimal strings the provider URL wants; 16 bytes covers any value the
 * validation ranges admit with room to spare. */
#define TZ_BUF_LEN    (TZ_MAX_LEN + 1)
#define PLACE_BUF_LEN (PLACE_MAX_LEN + 1)
#define COORD_BUF_LEN 16
#define NAME_BUF_LEN  (NAME_MAX_LEN + 1)

static char        s_tz[TZ_BUF_LEN];
static char        s_lat[COORD_BUF_LEN];
static char        s_lon[COORD_BUF_LEN];
static char        s_place[PLACE_BUF_LEN];
/* The owner's Bluetooth name, "" while the device still goes by the
 * generated verb-and-animal identity below. */
static char        s_name[NAME_BUF_LEN];
static char        s_auto_name[NAME_BUF_LEN];
/* -1 means "follow the layout"; 0..255 is a manual override. */
static int         s_brightness = CONFIG_MIRROR_BRIGHTNESS_DEFAULT;
/* Display settings; Kconfig values are the factory defaults, see the "Display"
 * menu. */
static bool        s_clock_12h;
static char        s_temp_unit;   /* 'F' or 'C' */
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

/* Same seeding contract as load_key, for the i32 brightness key. */
static void load_brightness(nvs_handle_t h)
{
    int32_t v;
    esp_err_t err = nvs_get_i32(h, NVS_KEY_BRIGHTNESS, &v);
    if (err == ESP_OK) {
        s_brightness = v;
        return;
    }

    if (err != ESP_ERR_NVS_NOT_FOUND) {
        ESP_LOGW(TAG, "brightness unreadable (%s), reseeding",
                 esp_err_to_name(err));
    }

    s_brightness = CONFIG_MIRROR_BRIGHTNESS_DEFAULT;
    if (nvs_set_i32(h, NVS_KEY_BRIGHTNESS, s_brightness) == ESP_OK) {
        nvs_commit(h);
    }
}

/* The Kconfig factory defaults for the display settings. A bool option is
 * defined exactly when it is enabled, so the clock defaults to 12-hour unless
 * the build turns it off. */
#if defined(CONFIG_MIRROR_CLOCK_12H)
#define CLOCK12H_DEFAULT 1
#else
#define CLOCK12H_DEFAULT 0
#endif

#if defined(CONFIG_MIRROR_TEMP_UNIT_C)
#define TEMP_UNIT_DEFAULT 'C'
#else
#define TEMP_UNIT_DEFAULT 'F'
#endif

/* Same seeding contract as load_key, for the display settings. clock12h is
 * stored as an i32 0/1; temp_unit as a one-character string ("F" or "C"). */
static void load_clock12h(nvs_handle_t h)
{
    int32_t v;
    esp_err_t err = nvs_get_i32(h, NVS_KEY_CLOCK12H, &v);
    if (err == ESP_OK) {
        s_clock_12h = v != 0;
        return;
    }
    if (err != ESP_ERR_NVS_NOT_FOUND) {
        ESP_LOGW(TAG, "clock12h unreadable (%s), reseeding",
                 esp_err_to_name(err));
    }
    s_clock_12h = CLOCK12H_DEFAULT != 0;
    if (nvs_set_i32(h, NVS_KEY_CLOCK12H, s_clock_12h ? 1 : 0) == ESP_OK) {
        nvs_commit(h);
    }
}

static void load_temp_unit(nvs_handle_t h)
{
    char v[2] = "";
    size_t len = sizeof(v);
    esp_err_t err = nvs_get_str(h, NVS_KEY_TEMP_UNIT, v, &len);
    if (err == ESP_OK && (v[0] == 'F' || v[0] == 'C')) {
        s_temp_unit = v[0];
        return;
    }
    if (err != ESP_ERR_NVS_NOT_FOUND) {
        ESP_LOGW(TAG, "temp_unit unreadable (%s), reseeding",
                 esp_err_to_name(err));
    }
    s_temp_unit = TEMP_UNIT_DEFAULT;
    char seed[2] = { s_temp_unit, '\0' };
    if (nvs_set_str(h, NVS_KEY_TEMP_UNIT, seed) == ESP_OK) {
        nvs_commit(h);
    }
}

/* ------------------------------------------------------ device name */

/*
 * The factory identity: a verb and an animal, picked by hashing the
 * station MAC. Every device gets its own combo, it is stable across
 * reboots and reflashes, and nothing is stored until the owner renames
 * the mirror. 64 x 64 combos, so two mirrors in one home collide about
 * once in four thousand pairings, and the setup wizard's rename is the
 * escape hatch. Words stay at 11 characters or fewer so "Verb Animal"
 * always fits NAME_MAX_LEN (longest live combo: 10 + space + 10).
 */
static const char *const s_name_verbs[] = {
    "Bouncing", "Charming", "Chasing", "Clicking",
    "Coasting", "Cracking", "Crunching", "Cycling",
    "Dancing", "Dashing", "Drifting", "Dreaming",
    "Drizzling", "Echoing", "Flashing", "Flipping",
    "Floating", "Flying", "Frolicking", "Galloping",
    "Gazing", "Gleaming", "Gliding", "Glowing",
    "Greeting", "Hopping", "Hovering", "Hurrying",
    "Hushing", "Jumping", "Leaping", "Lingering",
    "Marching", "Meandering", "Mingling", "Moseying",
    "Napping", "Painting", "Paddling", "Perching",
    "Pouncing", "Prancing", "Racing", "Rambling",
    "Rattling", "Riding", "Roaming", "Rolling",
    "Romping", "Running", "Sailing", "Scooting",
    "Scratching", "Skipping", "Sliding", "Sneaking",
    "Soaring", "Spinning", "Splashing", "Sprinting",
    "Strutting", "Swinging", "Tumbling", "Twirling",
};

static const char *const s_name_animals[] = {
    "Alligator", "Alpaca", "Antelope", "Anteater",
    "Badger", "Bandicoot", "Barracuda", "Beaver",
    "Bison", "Buffalo", "Butterfly", "Camel",
    "Cheetah", "Chimpanzee", "Chinchilla", "Cormorant",
    "Cougar", "Coyote", "Crane", "Dolphin",
    "Donkey", "Dragonfly", "Eagle", "Echidna",
    "Elephant", "Ferret", "Finch", "Flamingo",
    "Frog", "Gazelle", "Gecko", "Giraffe",
    "Gopher", "Gorilla", "Hedgehog", "Heron",
    "Hippo", "Horse", "Hyena", "Impala",
    "Jackal", "Jaguar", "Kangaroo", "Kingfisher",
    "Koala", "Lemur", "Leopard", "Llama",
    "Magpie", "Mallard", "Manatee", "Meerkat",
    "Moose", "Ocelot", "Octopus", "Okapi",
    "Opossum", "Orca", "Ostrich", "Otter",
    "Panther", "Penguin", "Wombat", "Zebra",
};

static void build_auto_name(void)
{
    uint8_t mac[6];
    esp_read_mac(mac, ESP_MAC_WIFI_STA);

    /* FNV-1a: the multiply avalanches the six bytes, so two boards that
     * share an OUI prefix still land on unrelated words. Two disjoint
     * six-bit slices of the hash choose the verb and the animal. */
    uint32_t h = 2166136261u;
    for (int i = 0; i < 6; i++) {
        h ^= mac[i];
        h *= 16777619u;
    }
    const size_t nverbs = sizeof(s_name_verbs) / sizeof(s_name_verbs[0]);
    const size_t nanimals =
        sizeof(s_name_animals) / sizeof(s_name_animals[0]);
    snprintf(s_auto_name, sizeof(s_auto_name), "%s %s",
             s_name_verbs[(h >> 16) % nverbs],
             s_name_animals[(h >> 26) % nanimals]);
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
    /* Computed before the override load: an absent NVS key leaves "" in
     * s_name, and "" means "go by the generated name". */
    build_auto_name();
    load_key(h, NVS_KEY_NAME, s_name, sizeof(s_name), "");
    load_brightness(h);
    load_clock12h(h);
    load_temp_unit(h);

    nvs_close(h);

    ESP_LOGI(TAG, "tz \"%s\", lat %s, lon %s, place \"%s\", brightness %d, "
             "clock %s, temp %c",
             s_tz, s_lat, s_lon, s_place, s_brightness,
             s_clock_12h ? "12h" : "24h", s_temp_unit);
    return ESP_OK;
}

const char *mirror_config_timezone(void)  { return s_tz; }
const char *mirror_config_latitude(void)  { return s_lat; }
const char *mirror_config_longitude(void) { return s_lon; }
const char *mirror_config_place(void)     { return s_place; }

const char *mirror_config_device_name(void)
{
    return s_name[0] != '\0' ? s_name : s_auto_name;
}

bool mirror_config_clock_12h(void)
{
    lock();
    const bool v = s_clock_12h;
    unlock();
    return v;
}

char mirror_config_temp_unit(void)
{
    lock();
    const char v = s_temp_unit;
    unlock();
    return v;
}

int mirror_config_brightness(void) { return s_brightness; }

uint8_t mirror_config_effective_brightness(uint8_t layout_brightness)
{
    lock();
    const int b = s_brightness;
    unlock();
    return b >= 0 ? (uint8_t)b : layout_brightness;
}

void mirror_config_clear_brightness(void)
{
    lock();
    s_brightness = -1;
    unlock();

    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) == ESP_OK) {
        nvs_set_i32(h, NVS_KEY_BRIGHTNESS, -1);
        nvs_commit(h);
        nvs_close(h);
    }
    ESP_LOGI(TAG, "brightness override cleared (follows the layout again)");
}

esp_err_t mirror_config_factory_reset(void)
{
    lock();

    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NS, NVS_READWRITE, &h);
    if (err == ESP_OK) {
        err = nvs_erase_all(h);
        if (err == ESP_OK) err = nvs_commit(h);
        nvs_close(h);
    }

    if (err == ESP_OK) {
        /* The namespace is gone, including the credentials and the station
         * hint that other modules keep here. Reload the in-RAM copies from
         * the Kconfig defaults (the same values the seeding contract in
         * mirror_config_init() produces on a virgin device) so a caller
         * that reboots immediately never serves a stale value in the
         * window before the restart. */
        snprintf(s_tz,    sizeof(s_tz),    "%s", CONFIG_MIRROR_TIMEZONE);
        snprintf(s_lat,   sizeof(s_lat),   "%s", CONFIG_MIRROR_LATITUDE);
        snprintf(s_lon,   sizeof(s_lon),   "%s", CONFIG_MIRROR_LONGITUDE);
        snprintf(s_place, sizeof(s_place), "%s", CONFIG_MIRROR_PLACE_NAME);
        s_name[0] = '\0';   /* the generated identity takes over again */
        s_brightness = CONFIG_MIRROR_BRIGHTNESS_DEFAULT;
        s_clock_12h  = CLOCK12H_DEFAULT != 0;
        s_temp_unit  = TEMP_UNIT_DEFAULT;
        ESP_LOGW(TAG, "factory reset: NVS namespace \"%s\" erased", NVS_NS);
    }

    unlock();
    return err;
}

static void fail(char *err, size_t errsz, const char *msg)
{
    if (err != NULL && errsz > 0) snprintf(err, errsz, "%s", msg);
}

/*
 * True when s has the shape newlib's tzset understands: a standard name of
 * three or more ASCII letters, then a numeric UTC offset, then only the
 * POSIX TZ alphabet (letters, digits, + - . , : /) for the DST name and the
 * transition rules.
 *
 * This is deliberately a shape check, not a full grammar parse. Its job is
 * to reject values tzset silently ignores, and the failure mode that
 * matters is an IANA name like "Europe/Berlin": it has no offset, so it
 * fails below, and instead of the clock quietly falling back to UTC the
 * push is rejected with a message. The rule ranges (M1..12, w1..5, ...) are
 * not validated here; a wrong range still degrades to UTC, but only for a
 * hand-typed rule that no preset emits. Mirrored exactly in the Dart
 * MirrorConfig.validate().
 */
static bool tz_is_posix(const char *s)
{
    size_t i = 0;

    size_t letters = 0;
    while ((s[i] >= 'A' && s[i] <= 'Z') || (s[i] >= 'a' && s[i] <= 'z')) {
        letters++;
        i++;
    }
    if (letters < 3) return false;

    if (s[i] == '+' || s[i] == '-') i++;

    size_t digits = 0;
    while (s[i] >= '0' && s[i] <= '9') {
        digits++;
        i++;
    }
    if (digits < 1 || digits > 2) return false;

    /* Optional :mm[:ss] after the hours. */
    if (s[i] == ':') {
        i++;
        digits = 0;
        while (s[i] >= '0' && s[i] <= '9') {
            digits++;
            i++;
        }
        if (digits != 2) return false;
        if (s[i] == ':') {
            i++;
            digits = 0;
            while (s[i] >= '0' && s[i] <= '9') {
                digits++;
                i++;
            }
            if (digits != 2) return false;
        }
    }

    /* The remainder (dst name and rules) uses only the POSIX TZ alphabet. */
    for (; s[i] != '\0'; i++) {
        const char c = s[i];
        const bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                        (c >= '0' && c <= '9') || c == '+' || c == '-' ||
                        c == '.' || c == ',' || c == ':' || c == '/';
        if (!ok) return false;
    }
    return true;
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
    char   new_name[NAME_BUF_LEN] = "";
    int    new_brightness = -1;
    bool   new_clock_12h = CLOCK12H_DEFAULT != 0;
    char   new_temp_unit = TEMP_UNIT_DEFAULT;
    bool   have_name = false, have_tz = false, have_lat = false, have_lon = false, have_place = false;
    bool   have_brightness = false, have_clock12h = false, have_temp_unit = false;

    int t = ml_json_member(&j, 0, "name");
    if (t >= 0) {
        /* The advertised name. ml_json_str decodes non-ASCII to '?' (its
         * contract serves the panel's bitmap fonts), and the Dart side
         * rejects non-printable text before pushing, mirroring the IANA
         * timezone lesson; the control-character sweep here is the
         * device's own guard for stray bytes. */
        char raw_name[NAME_BUF_LEN];
        if (!ml_json_str(&j, t, raw_name, sizeof(raw_name))) {
            fail(err, errsz, "name must be a string");
            return ESP_ERR_INVALID_ARG;
        }
        const size_t rlen = strlen(raw_name);
        size_t b = 0;
        while (b < rlen && (raw_name[b] == ' ' || raw_name[b] == '\t')) b++;
        size_t e = rlen;
        while (e > b && (raw_name[e - 1] == ' ' || raw_name[e - 1] == '\t')) e--;
        if (e == b) {
            fail(err, errsz, "name must not be empty");
            return ESP_ERR_INVALID_ARG;
        }
        if (e - b > NAME_MAX_LEN) {
            fail(err, errsz, "name is too long (max 24)");
            return ESP_ERR_INVALID_ARG;
        }
        for (size_t i = b; i < e; i++) {
            const unsigned char c = (unsigned char)raw_name[i];
            if (c < 0x20 || c == 0x7F) {
                fail(err, errsz, "name has unprintable characters");
                return ESP_ERR_INVALID_ARG;
            }
        }
        memcpy(new_name, raw_name + b, e - b);
        new_name[e - b] = '\0';
        have_name = true;
    }

    t = ml_json_member(&j, 0, "timezone");
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
        if (!tz_is_posix(new_tz)) {
            /* newlib only parses POSIX TZ strings; an IANA name would be
             * accepted here and silently degrade the clock to UTC. */
            fail(err, errsz, "timezone must be a POSIX TZ string");
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

    t = ml_json_member(&j, 0, "brightness");
    if (t >= 0) {
        /* Strictly an integer: ml_json_int rounds, and a 200.5 that quietly
         * became 201 would fight the Dart validation that mirrors this. */
        double d;
        if (!ml_json_double(&j, t, &d) || d != (int)d || d < 0 || d > 255) {
            fail(err, errsz, "brightness must be an integer in [0, 255]");
            return ESP_ERR_INVALID_ARG;
        }
        new_brightness = (int)d;
        have_brightness = true;
    }

    t = ml_json_member(&j, 0, "clock12h");
    if (t >= 0) {
        if (!ml_json_bool(&j, t, &new_clock_12h)) {
            fail(err, errsz, "clock12h must be a boolean");
            return ESP_ERR_INVALID_ARG;
        }
        have_clock12h = true;
    }

    t = ml_json_member(&j, 0, "temp_unit");
    if (t >= 0) {
        char unit[2] = "";
        if (!ml_json_str(&j, t, unit, sizeof(unit)) ||
            (unit[0] != 'F' && unit[0] != 'C')) {
            fail(err, errsz, "temp_unit must be \"F\" or \"C\"");
            return ESP_ERR_INVALID_ARG;
        }
        new_temp_unit = unit[0];
        have_temp_unit = true;
    }

    /* Nothing named: a no-op, not an error. */
    if (!have_name && !have_tz && !have_lat && !have_lon && !have_place &&
        !have_brightness && !have_clock12h && !have_temp_unit) {
        fail(err, errsz, "no known fields");
        return ESP_ERR_INVALID_ARG;
    }

    /* Persist the changed fields, then apply them. */
    const bool tz_changed   = have_tz   && strcmp(new_tz, s_tz) != 0;
    const bool lat_changed  = have_lat  && strcmp(new_lat, s_lat) != 0;
    const bool lon_changed  = have_lon  && strcmp(new_lon, s_lon) != 0;
    const bool place_changed = have_place && strcmp(new_place, s_place) != 0;
    const bool brightness_changed = have_brightness &&
                                    new_brightness != s_brightness;
    const bool clock12h_changed = have_clock12h &&
                                  new_clock_12h != s_clock_12h;
    const bool temp_unit_changed = have_temp_unit &&
                                   new_temp_unit != s_temp_unit;
    const bool name_changed = have_name && strcmp(new_name, s_name) != 0;

    if (tz_changed || lat_changed || lon_changed || place_changed ||
        brightness_changed || clock12h_changed || temp_unit_changed ||
        name_changed) {
        nvs_handle_t h;
        esp_err_t nvs_err = nvs_open(NVS_NS, NVS_READWRITE, &h);
        if (nvs_err != ESP_OK) {
            fail(err, errsz, "config storage unavailable");
            return nvs_err;
        }
        if (name_changed)     nvs_set_str(h, NVS_KEY_NAME, new_name);
        if (tz_changed)     nvs_set_str(h, NVS_KEY_TZ, new_tz);
        if (lat_changed)    nvs_set_str(h, NVS_KEY_LAT, new_lat);
        if (lon_changed)    nvs_set_str(h, NVS_KEY_LON, new_lon);
        if (place_changed)  nvs_set_str(h, NVS_KEY_PLACE, new_place);
        if (brightness_changed) nvs_set_i32(h, NVS_KEY_BRIGHTNESS,
                                            new_brightness);
        if (clock12h_changed) {
            nvs_set_i32(h, NVS_KEY_CLOCK12H, new_clock_12h ? 1 : 0);
        }
        if (temp_unit_changed) {
            char seed[2] = { new_temp_unit, '\0' };
            nvs_set_str(h, NVS_KEY_TEMP_UNIT, seed);
        }
        nvs_err = nvs_commit(h);
        nvs_close(h);
        if (nvs_err != ESP_OK) {
            fail(err, errsz, "config could not be saved");
            return nvs_err;
        }
    }

    lock();
    if (have_name)   memcpy(s_name, new_name, sizeof(s_name));
    if (have_tz)     memcpy(s_tz, new_tz, sizeof(s_tz));
    if (have_lat)    memcpy(s_lat, new_lat, sizeof(s_lat));
    if (have_lon)    memcpy(s_lon, new_lon, sizeof(s_lon));
    if (have_place)  memcpy(s_place, new_place, sizeof(s_place));
    if (have_brightness) s_brightness = new_brightness;
    if (have_clock12h)   s_clock_12h = new_clock_12h;
    if (have_temp_unit)  s_temp_unit = new_temp_unit;
    unlock();

    if (name_changed) {
        ESP_LOGI(TAG, "device is now advertised as \"%s\"",
                 mirror_config_device_name());
    }

    if (tz_changed) {
        ESP_LOGI(TAG, "timezone %s -> %s", mirror_config_timezone(), new_tz);
        setenv("TZ", new_tz, 1);
        tzset();
    }
    if (lat_changed || lon_changed || place_changed) {
        ESP_LOGI(TAG, "weather now at %s, %s (\"%s\")", s_lat, s_lon, s_place);
        providers_refresh_now();
    }
    if (have_brightness) {
        /* A config push names a manual override, so it wins immediately. */
        panel_set_brightness((uint8_t)s_brightness);
        ESP_LOGI(TAG, "brightness override set to %d", s_brightness);
    }
    if (have_clock12h) {
        ESP_LOGI(TAG, "clock set to %s", s_clock_12h ? "12-hour" : "24-hour");
    }
    if (have_temp_unit) {
        ESP_LOGI(TAG, "temperature unit set to %c", s_temp_unit);
    }

    return ESP_OK;
}
