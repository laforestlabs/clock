#include "mirror/model.h"

#include <stdio.h>
#include <string.h>

void ml_model_init(ml_model *m)
{
    if (!m) return;
    memset(m, 0, sizeof(*m));

    /* Everything starts invalid on purpose. A widget bound to data that has
     * not arrived yet must render a placeholder, never a confident zero. A
     * mirror showing "0 C" is worse than one showing "--". */
    m->now.valid     = false;
    m->weather.valid = false;
    m->online        = false;

    /* Factory defaults: 12-hour clock, Fahrenheit. The firmware overwrites
     * these every frame from the owner config; the mock keeps them so the
     * designer's preview and the host CLI match a fresh device. */
    m->clock_12h = true;
    m->temp_f    = true;

    for (int i = 0; i < ML_MAX_TODOS; i++) m->todos[i].due_offset = ML_NO_DUE;

    /* Placeholder sentinels rather than zeros: a model nobody filled must
     * render "--", not a sunrise of midnight or an air quality of zero. */
    m->weather.sunrise_min = -1;
    m->weather.sunset_min  = -1;
    for (int i = 0; i < ML_POLLEN_TYPES; i++) m->air.pollen[i] = -1.0f;
}

const char *ml_wx_label(int code)
{
    /* WMO 4677 codes as emitted by Open-Meteo, collapsed to labels that fit a
     * narrow column. Ranges rather than exact matches, because the code space
     * is sparse and providers differ on which variants they report. */
    if (code == 0)                    return "Clear";
    if (code == 1)                    return "Fair";
    if (code == 2)                    return "Cloudy";
    if (code == 3)                    return "Overcast";
    if (code >= 45 && code <= 48)     return "Fog";
    if (code >= 51 && code <= 57)     return "Drizzle";
    if (code >= 61 && code <= 65)     return "Rain";
    if (code >= 66 && code <= 67)     return "Ice rain";
    if (code >= 71 && code <= 77)     return "Snow";
    if (code >= 80 && code <= 82)     return "Showers";
    if (code >= 85 && code <= 86)     return "Snow";
    if (code >= 95)                   return "Storm";
    return "Unknown";
}

/* The published AQI band names. The European and U.S. scales disagree about
 * where the bands fall, which is why the caller picks one rather than the
 * provider collapsing them into a single number. */
const char *ml_aqi_label(int aqi, bool us)
{
    if (us) {
        if (aqi < 50)  return "Good";
        if (aqi < 100) return "Moderate";
        if (aqi < 150) return "Sensitive";
        if (aqi < 200) return "Unhealthy";
        if (aqi < 300) return "Very unhealthy";
        return "Hazardous";
    }
    if (aqi < 20)  return "Good";
    if (aqi < 40)  return "Fair";
    if (aqi < 60)  return "Moderate";
    if (aqi < 80)  return "Poor";
    if (aqi < 100) return "Very poor";
    return "Extremely poor";
}

/* The 16-point compass, in the order the widget's arrow table uses. */
static const char *const k_cardinal16[16] = {
    "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
    "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"
};

const char *ml_wind_cardinal(float deg_from)
{
    /* Round to the nearest sector; the mask wraps 360 back to N, so a
     * provider reporting 359.9 lands on N rather than past the table. */
    int sector = (int)(deg_from / 22.5f + 0.5f);
    return k_cardinal16[sector & 15];
}

/* cos(2*pi*phase) in q15, over one 32-step cycle. The table is generated
 * rather than computed because the core links no libm, and both the moon
 * widget's terminator and the moon.illum binding read it, so the drawn disc
 * and the printed percentage cannot drift apart. */
static const int16_t k_cos_q15[33] = {
    32767, 32138, 30274, 27246, 23170, 18205, 12540, 6393,
    0, -6393, -12540, -18205, -23170, -27246, -30274, -32138,
    -32768, -32138, -30274, -27246, -23170, -18205, -12540, -6393,
    0, 6393, 12540, 18205, 23170, 27246, 30274, 32138, 32767
};

int ml_cos_q15(float phase)
{
    /* 33 entries, so an exact 1.0 (the new moon of the next cycle) indexes
     * the final entry rather than wrapping to the first; the mask handles
     * anything past it. */
    int idx = (int)(phase * 32.0f + 0.5f);
    if (idx < 0) idx = 0;
    if (idx > 32) idx &= 31;
    return k_cos_q15[idx];
}

/* The lit fraction of the disc, 0..100. A full moon is cos = -1, a new moon
 * cos = +1, and the terminator's own shape is what makes the percentage
 * honest: it is the same curve the widget draws. */
int ml_moon_illum(float phase)
{
    return (int)(((32767 - ml_cos_q15(phase)) * 100 + 32767) / 65534);
}

float ml_moon_phase(const ml_model *m)
{
    if (!m || !m->now.valid) return -1.0f;

    /* Synodic month in whole seconds and the 2000-01-06 18:14 UTC new moon,
     * both integer so the phase does not drift with float precision. */
    const int64_t k_synodic = 2551443;
    int64_t t = ((int64_t)m->now.epoch_s - 947182440LL) % k_synodic;
    if (t < 0) t += k_synodic;
    return (float)t / (float)k_synodic;
}

const char *ml_moon_label(float phase)
{
    if (phase < 0.0f) return "--";
    static const char *const names[8] = {
        "New", "Waxing crescent", "First quarter", "Waxing gibbous",
        "Full", "Waning gibbous", "Last quarter", "Waning crescent"
    };
    return names[(int)(phase * 8.0f + 0.5f) & 7];
}

/* Match "prefix.rest" and hand back the part after the dot. */
static const char *after_prefix(const char *path, const char *prefix)
{
    size_t n = strlen(prefix);
    if (strncmp(path, prefix, n) != 0) return NULL;
    if (path[n] != '.') return NULL;
    return path + n + 1;
}

static bool num(bool *is_num, double *out_num, double v)
{
    *is_num  = true;
    *out_num = v;
    return true;
}

static bool str(bool *is_num, const char **out_str, const char *v)
{
    *is_num  = false;
    *out_str = v;
    return true;
}

/* Scratch space for the display-facing string bindings (weather.temp, and the
 * sunrise/sunset pair). The model is POD by design, but a formatted value has
 * nowhere to live inside ml_weather, and the renderer copies the returned
 * string into the widget buffer before anything else can run, so these mutable
 * buffers are safe. Two, not one, because a single lookup returns one string
 * and the caller must not have it overwritten by a second buffer's write mid
 * read. */
static char s_temp_display[16];
static char s_hm_display[8];

static void format_temp_display(const ml_weather *w, bool f)
{
    if (f) {
        const double fv = w->temp_c * 9.0 / 5.0 + 32.0;
        snprintf(s_temp_display, sizeof(s_temp_display),
                 "%d" ML_DEGREE_GLYPH "F", (int)(fv + 0.5));
    } else {
        snprintf(s_temp_display, sizeof(s_temp_display),
                 "%d" ML_DEGREE_GLYPH "C", (int)(w->temp_c + 0.5));
    }
}

/* "HH:MM" for a minutes-since-midnight value. Only ever called with a value
 * the caller has already checked is >= 0. */
static void format_hm(int minutes)
{
    snprintf(s_hm_display, sizeof(s_hm_display), "%02d:%02d",
             (minutes / 60) % 24, minutes % 60);
}

/* The value a display-facing binding should serve: Celsius when the device
 * shows Celsius, Fahrenheit otherwise. The *_c paths stay raw so a layout
 * that wants the provider's own numbers can still have them. */
static double temp_display(bool f, double c)
{
    return f ? c * 9.0 / 5.0 + 32.0 : c;
}

/* Same convention as temp_display above, for the wind speed fields: mph when
 * the device shows Fahrenheit, km/h otherwise. */
static double wind_display(bool f, double kph)
{
    return f ? kph * 0.6213712 : kph;
}

bool ml_model_lookup(const ml_model *m, const char *path,
                     bool *is_num, double *out_num, const char **out_str)
{
    if (!m || !path || !is_num || !out_num || !out_str) return false;

    *is_num  = true;
    *out_num = 0.0;
    *out_str = NULL;

    const char *f;

    if ((f = after_prefix(path, "now")) != NULL) {
        if (!m->now.valid) return false;
        if (!strcmp(f, "hour"))    return num(is_num, out_num, m->now.hour);
        if (!strcmp(f, "minute"))  return num(is_num, out_num, m->now.minute);
        if (!strcmp(f, "second"))  return num(is_num, out_num, m->now.second);
        if (!strcmp(f, "day"))     return num(is_num, out_num, m->now.day);
        if (!strcmp(f, "month"))   return num(is_num, out_num, m->now.month);
        if (!strcmp(f, "year"))    return num(is_num, out_num, m->now.year);
        if (!strcmp(f, "weekday")) return num(is_num, out_num, m->now.weekday);
        return false;
    }

    if ((f = after_prefix(path, "weather")) != NULL) {
        if (!m->weather.valid) return false;
        if (!strcmp(f, "temp_c"))       return num(is_num, out_num, m->weather.temp_c);
        if (!strcmp(f, "feels_c"))      return num(is_num, out_num, m->weather.feels_c);
        if (!strcmp(f, "temp_min_c"))   return num(is_num, out_num, m->weather.temp_min_c);
        if (!strcmp(f, "temp_max_c"))   return num(is_num, out_num, m->weather.temp_max_c);
        /* Display-facing: follow the device's configured unit. */
        if (!strcmp(f, "temp")) {
            format_temp_display(&m->weather, m->temp_f);
            return str(is_num, out_str, s_temp_display);
        }
        if (!strcmp(f, "temp_min"))
            return num(is_num, out_num,
                       temp_display(m->temp_f, m->weather.temp_min_c));
        if (!strcmp(f, "temp_max"))
            return num(is_num, out_num,
                       temp_display(m->temp_f, m->weather.temp_max_c));
        if (!strcmp(f, "code"))         return num(is_num, out_num, m->weather.code);
        if (!strcmp(f, "wind_kph"))     return num(is_num, out_num, m->weather.wind_kph);
        /* Display-facing wind speed, following the device's unit like temp. */
        if (!strcmp(f, "wind"))
            return num(is_num, out_num,
                       wind_display(m->temp_f, m->weather.wind_kph));
        if (!strcmp(f, "wind_gust_kph"))
            return num(is_num, out_num, m->weather.wind_gust_kph);
        if (!strcmp(f, "wind_gust"))
            return num(is_num, out_num,
                       wind_display(m->temp_f, m->weather.wind_gust_kph));
        if (!strcmp(f, "wind_dir") && m->weather.wind_dir_valid)
            return num(is_num, out_num, m->weather.wind_dir_deg);
        if (!strcmp(f, "wind_dir_name") && m->weather.wind_dir_valid)
            return str(is_num, out_str, ml_wind_cardinal(m->weather.wind_dir_deg));
        if (!strcmp(f, "feels"))
            return num(is_num, out_num,
                       temp_display(m->temp_f, m->weather.feels_c));
        if (!strcmp(f, "sunrise_min") && m->weather.sunrise_min >= 0)
            return num(is_num, out_num, m->weather.sunrise_min);
        if (!strcmp(f, "sunset_min") && m->weather.sunset_min >= 0)
            return num(is_num, out_num, m->weather.sunset_min);
        if (!strcmp(f, "sunrise") && m->weather.sunrise_min >= 0) {
            format_hm(m->weather.sunrise_min);
            return str(is_num, out_str, s_hm_display);
        }
        if (!strcmp(f, "sunset") && m->weather.sunset_min >= 0) {
            format_hm(m->weather.sunset_min);
            return str(is_num, out_str, s_hm_display);
        }
        if (!strcmp(f, "humidity_pct")) return num(is_num, out_num, m->weather.humidity_pct);
        if (!strcmp(f, "precip_prob"))  return num(is_num, out_num, m->weather.precip_prob);
        if (!strcmp(f, "is_day"))       return num(is_num, out_num, m->weather.is_day ? 1 : 0);
        if (!strcmp(f, "label"))        return str(is_num, out_str, ml_wx_label(m->weather.code));
        if (!strcmp(f, "place"))        return str(is_num, out_str, m->weather.place);
        return false;
    }

    if ((f = after_prefix(path, "air")) != NULL) {
        /* The pollen paths stand on their own flag: the pollen series is
         * Europe-only, so a mirror elsewhere has an AQI and no pollen. */
        if (!strcmp(f, "pollen") || !strcmp(f, "pollen_type")) {
            if (!m->air.pollen_valid) return false;
            int best = 0;
            for (int i = 1; i < ML_POLLEN_TYPES; i++) {
                if (m->air.pollen[i] > m->air.pollen[best]) best = i;
            }
            if (!strcmp(f, "pollen")) return num(is_num, out_num, m->air.pollen[best]);
            static const char *const plants[ML_POLLEN_TYPES] = {"Alder", "Birch", "Grass"};
            return str(is_num, out_str, plants[best]);
        }

        if (!m->air.valid) return false;
        if (!strcmp(f, "aqi_eu"))   return num(is_num, out_num, m->air.aqi);
        if (!strcmp(f, "aqi_us"))   return num(is_num, out_num, m->air.aqi_us);
        if (!strcmp(f, "label_eu")) return str(is_num, out_str, ml_aqi_label(m->air.aqi, false));
        if (!strcmp(f, "label_us")) return str(is_num, out_str, ml_aqi_label(m->air.aqi_us, true));
        if (!strcmp(f, "pm25"))     return num(is_num, out_num, m->air.pm2_5);
        if (!strcmp(f, "pm10"))     return num(is_num, out_num, m->air.pm10);
        if (!strcmp(f, "uv_index")) return num(is_num, out_num, m->air.uv_index);
        return false;
    }

    if ((f = after_prefix(path, "traffic")) != NULL) {
        if (!m->traffic.valid) return false;
        /* Rounded to the nearest minute rather than truncated, so 90s reads
         * "2 min" the way a person would say it. */
        if (!strcmp(f, "travel_min"))
            return num(is_num, out_num, (m->traffic.travel_s + 30) / 60);
        if (!strcmp(f, "delay_min"))
            return num(is_num, out_num, (m->traffic.delay_s + 30) / 60);
        if (!strcmp(f, "free_flow_min"))
            return num(is_num, out_num, (m->traffic.free_flow_s + 30) / 60);
        if (!strcmp(f, "label")) return str(is_num, out_str, m->traffic.label);
        return false;
    }

    if ((f = after_prefix(path, "moon")) != NULL) {
        const float phase = ml_moon_phase(m);
        if (phase < 0.0f) return false;
        if (!strcmp(f, "phase")) return num(is_num, out_num, phase);
        if (!strcmp(f, "illum")) return num(is_num, out_num, ml_moon_illum(phase));
        if (!strcmp(f, "label")) return str(is_num, out_str, ml_moon_label(phase));
        return false;
    }

    if ((f = after_prefix(path, "system")) != NULL) {
        if (!strcmp(f, "online"))   return num(is_num, out_num, m->online ? 1 : 0);
        if (!strcmp(f, "rssi"))     return num(is_num, out_num, m->wifi_rssi);
        if (!strcmp(f, "uptime_s")) return num(is_num, out_num, (double)m->uptime_s);
        return false;
    }

    if ((f = after_prefix(path, "counts")) != NULL) {
        if (!strcmp(f, "events")) return num(is_num, out_num, m->event_count);
        if (!strcmp(f, "todos"))  return num(is_num, out_num, m->todo_count);
        return false;
    }

    return false;
}
