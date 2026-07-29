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
} ml_weather;

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

    ml_event   events[ML_MAX_EVENTS];
    int        event_count;

    ml_todo    todos[ML_MAX_TODOS];
    int        todo_count;

    bool       online;
    int        wifi_rssi;   /* dBm, 0 when unknown */
    uint32_t   uptime_s;
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

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_MODEL_H */
