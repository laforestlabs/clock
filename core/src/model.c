#include "mirror/model.h"

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

    for (int i = 0; i < ML_MAX_TODOS; i++) m->todos[i].due_offset = ML_NO_DUE;
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
        if (!strcmp(f, "code"))         return num(is_num, out_num, m->weather.code);
        if (!strcmp(f, "wind_kph"))     return num(is_num, out_num, m->weather.wind_kph);
        if (!strcmp(f, "humidity_pct")) return num(is_num, out_num, m->weather.humidity_pct);
        if (!strcmp(f, "precip_prob"))  return num(is_num, out_num, m->weather.precip_prob);
        if (!strcmp(f, "is_day"))       return num(is_num, out_num, m->weather.is_day ? 1 : 0);
        if (!strcmp(f, "label"))        return str(is_num, out_str, ml_wx_label(m->weather.code));
        if (!strcmp(f, "place"))        return str(is_num, out_str, m->weather.place);
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
