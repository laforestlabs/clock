#include "mirror/mock.h"

#include <stdio.h>
#include <string.h>

static void add_event(ml_model *m, const char *title, int start_min, bool all_day)
{
    if (m->event_count >= ML_MAX_EVENTS) return;
    ml_event *e = &m->events[m->event_count++];
    e->valid      = true;
    e->all_day    = all_day;
    e->start_min  = all_day ? -1 : start_min;
    e->end_min    = all_day ? -1 : start_min + 30;
    e->day_offset = 0;
    snprintf(e->title, sizeof(e->title), "%s", title);
}

static void add_todo(ml_model *m, const char *text, bool done, int priority)
{
    if (m->todo_count >= ML_MAX_TODOS) return;
    ml_todo *t = &m->todos[m->todo_count++];
    t->valid      = true;
    t->done       = done;
    t->priority   = priority;
    t->due_offset = ML_NO_DUE;
    snprintf(t->text, sizeof(t->text), "%s", text);
}

const char *ml_mock_name(int variant)
{
    switch (variant) {
    case ML_MOCK_COLD:     return "cold";
    case ML_MOCK_OVERFLOW: return "overflow";
    case ML_MOCK_EVENING:  return "evening";
    case ML_MOCK_TYPICAL:
    default:               return "typical";
    }
}

void ml_model_mock(ml_model *m, int variant)
{
    if (!m) return;
    ml_model_init(m);

    /* Fixed date so golden images stay stable: Wednesday 29 July 2026. */
    m->now.valid   = true;
    m->now.year    = 2026;
    m->now.month   = 7;
    m->now.day     = 29;
    m->now.weekday = 3;    /* Wednesday */
    m->now.yday    = 210;
    m->now.hour    = 9;
    m->now.minute  = 41;
    m->now.second  = 0;

    m->online    = true;
    m->wifi_rssi = -58;
    m->uptime_s  = 3600 * 26;

    switch (variant) {
    case ML_MOCK_COLD:
        /* Booted, no network yet. Everything invalid on purpose. */
        m->now.valid     = false;
        m->weather.valid = false;
        m->online        = false;
        m->wifi_rssi     = 0;
        m->uptime_s      = 4;
        return;

    case ML_MOCK_OVERFLOW:
        m->weather.valid        = true;
        m->weather.temp_c       = -8.5f;
        m->weather.feels_c      = -14.0f;
        m->weather.temp_min_c   = -11.0f;
        m->weather.temp_max_c   = -3.0f;
        m->weather.code         = 75;    /* heavy snow */
        m->weather.wind_kph     = 34.0f;
        m->weather.humidity_pct = 91;
        m->weather.precip_prob  = 95;
        m->weather.is_day       = true;
        snprintf(m->weather.place, sizeof(m->weather.place), "Longplacename");

        add_event(m, "Quarterly planning review with the whole team", 9 * 60 + 0, false);
        add_event(m, "1:1 Alex", 11 * 60 + 30, false);
        add_event(m, "Lunch and learn: distributed tracing", 12 * 60 + 15, false);
        add_event(m, "Dentist", 14 * 60 + 30, false);
        add_event(m, "Pick up parcel from the depot before 6", 17 * 60 + 0, false);
        add_event(m, "Anniversary", -1, true);

        add_todo(m, "Renew passport before the trip in September", false, 1);
        add_todo(m, "Groceries", false, 2);
        add_todo(m, "Reply to the landlord about the boiler service", false, 2);
        add_todo(m, "Water plants", true, 3);
        add_todo(m, "Book dentist follow-up", false, 3);
        return;

    case ML_MOCK_EVENING:
        m->now.hour   = 22;
        m->now.minute = 7;

        m->weather.valid        = true;
        m->weather.temp_c       = 11.2f;
        m->weather.feels_c      = 9.0f;
        m->weather.temp_min_c   = 9.0f;
        m->weather.temp_max_c   = 16.0f;
        m->weather.code         = 95;   /* thunderstorm */
        m->weather.wind_kph     = 22.0f;
        m->weather.humidity_pct = 88;
        m->weather.precip_prob  = 80;
        m->weather.is_day       = false;
        snprintf(m->weather.place, sizeof(m->weather.place), "Home");
        /* No events and no todos: exercises the empty-state strings. */
        return;

    case ML_MOCK_TYPICAL:
    default:
        m->weather.valid        = true;
        m->weather.temp_c       = 21.4f;
        m->weather.feels_c      = 20.0f;
        m->weather.temp_min_c   = 14.0f;
        m->weather.temp_max_c   = 24.0f;
        m->weather.code         = 2;    /* partly cloudy */
        m->weather.wind_kph     = 12.0f;
        m->weather.humidity_pct = 63;
        m->weather.precip_prob  = 15;
        m->weather.is_day       = true;
        snprintf(m->weather.place, sizeof(m->weather.place), "Home");

        add_event(m, "Standup", 10 * 60 + 0, false);
        add_event(m, "Design review", 11 * 60 + 30, false);
        add_event(m, "Dentist", 14 * 60 + 30, false);
        add_event(m, "Gym", 18 * 60 + 0, false);

        add_todo(m, "Groceries", false, 2);
        add_todo(m, "Renew passport", false, 1);
        add_todo(m, "Water plants", true, 3);
        return;
    }
}
