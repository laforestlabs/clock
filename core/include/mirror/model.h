/*
 * model.h - the data widgets bind to.
 *
 * This struct is the seam that makes the desktop simulator trustworthy. The
 * firmware fills it from network providers; the designer fills it from mock
 * data. Rendering cannot tell the difference, so a layout that looks right in
 * the designer looks right on the panel.
 *
 * Everything is fixed-size and POD. No pointers, no allocation, so the whole
 * model can be memcpy'd or zeroed, and the renderer can stay allocation-free.
 */
#ifndef MIRROR_MODEL_H
#define MIRROR_MODEL_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ML_MAX_EVENTS   12
#define ML_MAX_TODOS    12
#define ML_TITLE_LEN    48
#define ML_PRECIP_HOURS 12   /* hourly precipitation slots, next 12 hours */
#define ML_FORECAST_DAYS 3   /* daily forecast slots, index 0 = today */
#define ML_POLLEN_TYPES  3   /* alder, birch, grass */
#define ML_TRAFFIC_LABEL 16  /* room for "MORNING COMMUTE" and a terminator */

/* The degree sign lives in the unused DEL slot every font carries. Written as
 * its own string literal because a hex escape would otherwise swallow a
 * following hex digit: "\x7fC" is one out-of-range character, not two. */
#define ML_DEGREE_GLYPH "\x7f"

typedef struct {
    bool valid;
    int  year;     /* full year, e.g. 2026 */
    int  month;    /* 1..12 */
    int  day;      /* 1..31 */
    int  hour;     /* 0..23 */
    int  minute;   /* 0..59 */
    int  second;   /* 0..59 */
    int  weekday;  /* 0 = Sunday .. 6 = Saturday */
    int  yday;     /* 1..366 */
    int64_t epoch_s;   /* UTC epoch seconds of now, valid only when valid */
} ml_time;

/* WMO weather codes, as used by Open-Meteo. */
typedef enum {
    ML_WX_CLEAR         = 0,
    ML_WX_MAINLY_CLEAR  = 1,
    ML_WX_PARTLY_CLOUDY = 2,
    ML_WX_OVERCAST      = 3,
    ML_WX_FOG           = 45,
    ML_WX_DRIZZLE       = 51,
    ML_WX_RAIN          = 61,
    ML_WX_FREEZING_RAIN = 66,
    ML_WX_SNOW          = 71,
    ML_WX_SHOWERS       = 80,
    ML_WX_THUNDERSTORM  = 95
} ml_wx_code;

/* One day of the multi-day forecast. Index 0 is today, so its range matches
 * the "current conditions" temp_min_c/temp_max_c above; the strip widget draws
 * whatever days[] holds rather than re-reading the current block. */
typedef struct {
    int   code;         /* WMO code, see ml_wx_code */
    float temp_max_c;
    float temp_min_c;
} ml_day;

typedef struct {
    bool  valid;
    float temp_c;
    float feels_c;
    float temp_min_c;
    float temp_max_c;
    int   code;          /* WMO code, see ml_wx_code */
    float wind_kph;
    int   humidity_pct;
    int   precip_prob;   /* 0..100 */
    bool  is_day;
    char  place[24];     /* short location label, may be empty */

    /* Next 12 hours of precipitation probability, 0..100, starting at the
     * current hour. Filled from Open-Meteo's hourly forecast; invalid until
     * that arrives, so the precip chart can draw a placeholder rather than a
     * confident flat zero. */
    int   precip_hourly[ML_PRECIP_HOURS];
    bool  precip_hourly_valid;

    /* Wind direction the air blows *from*, in degrees, meteorological. Only
     * meaningful when wind_dir_valid, because a provider that reports no
     * direction would otherwise render as a confident North. */
    float wind_dir_deg;
    bool  wind_dir_valid;
    float wind_gust_kph;

    /* Sunrise and sunset as minutes since local midnight, -1 when unknown.
     * The same convention ml_event.start_min uses, so a layout bound to it
     * gets a placeholder rather than a midnight it never saw. */
    int   sunrise_min;
    int   sunset_min;

    /* Daily forecast, index 0 = today upwards. day_count is how many leading
     * entries are filled, so a strip never pairs one day's icon with another
     * day's range. */
    ml_day days[ML_FORECAST_DAYS];
    int    day_count;
} ml_weather;

/* Outdoor air quality and pollen. aqi is the European AQI and aqi_us the US
 * one, because the two scales disagree about what counts as bad and a layout
 * may reasonably show either. */
typedef struct {
    bool  valid;
    int   aqi;          /* European AQI */
    int   aqi_us;       /* US AQI */
    float pm2_5;        /* ug/m3 */
    float pm10;         /* ug/m3 */
    float uv_index;
    /* Alder, birch, grass in grains/m3; -1 when that plant's field was absent
     * (the pollen series is Europe-only). pollen_valid is true when at least
     * one of the three parsed. */
    float pollen[ML_POLLEN_TYPES];
    bool  pollen_valid;
} ml_air;

/* A commute route's travel time, as reported by a routing service. */
typedef struct {
    bool valid;
    int  travel_s;      /* with current traffic */
    int  delay_s;       /* extra seconds against free flow; may be negative */
    int  free_flow_s;   /* without traffic */
    char label[ML_TRAFFIC_LABEL];   /* owner's name for the route, may be empty */
} ml_traffic;

typedef struct {
    bool valid;
    char title[ML_TITLE_LEN];
    int  start_min;   /* minutes since local midnight, -1 when all day */
    int  end_min;     /* minutes since local midnight, -1 when unknown */
    int  day_offset;  /* 0 = today, 1 = tomorrow, ... */
    bool all_day;
} ml_event;

typedef struct {
    bool valid;
    char text[ML_TITLE_LEN];
    bool done;
    int  priority;    /* 1 = highest. 0 when unset. */
    int  due_offset;  /* days from today, INT32_MIN when no due date */
} ml_todo;

#define ML_NO_DUE (-100000)

typedef struct {
    ml_time    now;
    ml_weather weather;
    ml_air     air;
    ml_traffic traffic;

    ml_event   events[ML_MAX_EVENTS];
    int        event_count;

    ml_todo    todos[ML_MAX_TODOS];
    int        todo_count;

    bool       online;
    int        wifi_rssi;   /* dBm, 0 when unknown */
    uint32_t   uptime_s;

    /*
     * Display settings, filled from the device config by the firmware and
     * from the designer's toolbar by the sim. They travel through the model
     * so the renderer stays pure: a given (layout, model) pair still renders
     * identically on the panel and in the preview.
     */
    bool clock_12h;   /* clock widgets without an explicit format use a
                       * 12-hour face (with AM/PM) when true */
    bool temp_f;      /* temperatures are shown in Fahrenheit when true */
} ml_model;

/* Zero the model and set sensible defaults (everything invalid, offline). */
void ml_model_init(ml_model *m);

/*
 * Resolve a dotted binding path such as "weather.temp_c" or "now.hour" against
 * the model. Returns false when the path is unknown or the underlying data is
 * not valid, in which case widgets render a placeholder rather than stale text.
 *
 * Exactly one of *out_num / *out_str is populated; is_num says which.
 */
bool ml_model_lookup(const ml_model *m, const char *path,
                     bool *is_num, double *out_num,
                     const char **out_str);

/* Human-readable short label for a WMO code, e.g. "Rain". Never NULL. */
const char *ml_wx_label(int code);

/* Band name for an air-quality index: the European scale when us is false,
 * the U.S. one when true. Title case, never NULL. */
const char *ml_aqi_label(int aqi, bool us);

/* Name of the 16-point compass sector the wind blows *from*, e.g. "NW".
 * Never NULL; deg_from is taken modulo the circle. */
const char *ml_wind_cardinal(float deg_from);

/*
 * Moon phase as a 0.0..1.0 fraction of the synodic month (0 = new, 0.5 =
 * full), from the model's clock. -1.0f when the clock has not synced, so a
 * widget can draw a placeholder rather than a phase it invented.
 */
float ml_moon_phase(const ml_model *m);

/* Phase name for a value from ml_moon_phase, or "--" for the -1 placeholder. */
const char *ml_moon_label(float phase);

/*
 * The two fixed-point helpers the moon widget and the moon.illum binding
 * share, so the drawn disc and the printed percentage cannot disagree:
 * ml_cos_q15 is cos(2*pi*phase) in q15, ml_moon_illum the lit fraction of the
 * disc in percent, 0..100.
 */
int ml_cos_q15(float phase);
int ml_moon_illum(float phase);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_MODEL_H */
