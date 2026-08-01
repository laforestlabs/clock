#include "mirror_ffi.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mirror/mirror.h"
#include "mirror/mock.h"

struct ml_sim {
    ml_layout layout;
    ml_diag   diag;
    ml_model  model;

    int  variant;
    int  brightness;   /* -1 means defer to the layout */
    int  loaded;

    ml_canvas canvas;
    int       canvas_w, canvas_h;

    uint8_t *rgba;
    size_t   rgba_cap;

    char  *json;
    size_t json_cap;

    char error[160];
};

/* Empty string rather than NULL for every accessor, so Dart never has to
 * null check a char* before converting it. */
static const char *k_empty = "";

ml_sim *ml_sim_create(void)
{
    ml_sim *s = (ml_sim *)calloc(1, sizeof(ml_sim));
    if (!s) return NULL;

    s->brightness = -1;
    s->variant    = ML_MOCK_TYPICAL;
    ml_model_mock(&s->model, s->variant);
    ml_layout_init(&s->layout, 64, 64);
    ml_diag_reset(&s->diag);
    return s;
}

void ml_sim_destroy(ml_sim *s)
{
    if (!s) return;
    ml_canvas_free(&s->canvas);
    free(s->rgba);
    free(s->json);
    free(s);
}

int ml_sim_load(ml_sim *s, const char *json)
{
    if (!s) return 0;
    if (!json) {
        snprintf(s->error, sizeof(s->error), "no JSON supplied");
        return 0;
    }

    /*
     * Parse into a scratch layout first. A failed parse must leave the last
     * good layout untouched, so the designer can keep rendering while the user
     * is midway through breaking their JSON.
     */
    ml_layout next;
    ml_diag   next_diag;

    if (!ml_layout_parse(json, strlen(json), &next, &next_diag)) {
        snprintf(s->error, sizeof(s->error), "%s",
                 next_diag.count > 0 ? next_diag.msg[0] : "layout could not be parsed");
        s->diag = next_diag;
        return 0;
    }

    s->layout = next;
    s->diag   = next_diag;
    s->loaded = 1;
    s->error[0] = '\0';
    return 1;
}

const char *ml_sim_error(const ml_sim *s)
{
    return s ? s->error : k_empty;
}

int ml_sim_diag_count(const ml_sim *s)
{
    return s ? s->diag.count : 0;
}

const char *ml_sim_diag_at(const ml_sim *s, int index)
{
    if (!s || index < 0 || index >= s->diag.count) return k_empty;
    return s->diag.msg[index];
}

int ml_sim_width(const ml_sim *s)  { return s ? s->layout.w : 0; }
int ml_sim_height(const ml_sim *s) { return s ? s->layout.h : 0; }

const char *ml_sim_name(const ml_sim *s)
{
    return s ? s->layout.name : k_empty;
}

int ml_sim_widget_count(const ml_sim *s)
{
    return s ? s->layout.count : 0;
}

int ml_sim_widget_rect(const ml_sim *s, int index, int *x, int *y, int *w, int *h)
{
    if (!s || index < 0 || index >= s->layout.count) return 0;
    const ml_widget *wi = &s->layout.widgets[index];
    if (x) *x = wi->rect.x;
    if (y) *y = wi->rect.y;
    if (w) *w = wi->rect.w;
    if (h) *h = wi->rect.h;
    return 1;
}

const char *ml_sim_widget_type(const ml_sim *s, int index)
{
    if (!s || index < 0 || index >= s->layout.count) return k_empty;
    /* Report the spelling from the file, so an unknown type still shows the
     * user what they actually typed rather than "unknown". */
    return s->layout.widgets[index].type_name;
}

const char *ml_sim_widget_id(const ml_sim *s, int index)
{
    if (!s || index < 0 || index >= s->layout.count) return k_empty;
    return s->layout.widgets[index].id;
}

int ml_sim_hit_test(const ml_sim *s, int x, int y)
{
    if (!s) return -1;
    /* Back to front: later widgets draw over earlier ones, so the last match
     * is the one visible at that pixel. */
    for (int i = s->layout.count - 1; i >= 0; i--) {
        const ml_widget *wi = &s->layout.widgets[i];
        if (!wi->visible) continue;
        if (ml_rect_contains(wi->rect, x, y)) return i;
    }
    return -1;
}

void ml_sim_set_variant(ml_sim *s, int variant)
{
    if (!s) return;
    if (variant < 0 || variant >= ML_MOCK_VARIANTS) variant = ML_MOCK_TYPICAL;
    s->variant = variant;
    ml_model_mock(&s->model, variant);
}

int ml_sim_variant_count(void) { return ML_MOCK_VARIANTS; }

const char *ml_sim_variant_name(int variant)
{
    if (variant < 0 || variant >= ML_MOCK_VARIANTS) return k_empty;
    return ml_mock_name(variant);
}

void ml_sim_set_brightness(ml_sim *s, int brightness)
{
    if (!s) return;
    if (brightness > 255) brightness = 255;
    if (brightness < 0)   brightness = -1;   /* anything negative means "use layout" */
    s->brightness = brightness;
}

int ml_sim_rgba_size(const ml_sim *s)
{
    if (!s || !s->loaded) return 0;
    return s->layout.w * s->layout.h * 4;
}

const uint8_t *ml_sim_render_rgba(ml_sim *s)
{
    if (!s || !s->loaded) return NULL;

    int w = s->layout.w;
    int h = s->layout.h;
    if (w <= 0 || h <= 0) return NULL;

    /* Reallocate only when the canvas size actually changes, so dragging a
     * widget does not churn the allocator on every frame. */
    if (s->canvas_w != w || s->canvas_h != h || !s->canvas.px) {
        ml_canvas_free(&s->canvas);
        if (!ml_canvas_init(&s->canvas, w, h, NULL)) {
            snprintf(s->error, sizeof(s->error), "cannot allocate a %dx%d canvas", w, h);
            return NULL;
        }
        s->canvas_w = w;
        s->canvas_h = h;
    }

    size_t need = (size_t)w * (size_t)h * 4;
    if (s->rgba_cap < need) {
        uint8_t *grown = (uint8_t *)realloc(s->rgba, need);
        if (!grown) {
            snprintf(s->error, sizeof(s->error), "out of memory for the pixel buffer");
            return NULL;
        }
        s->rgba     = grown;
        s->rgba_cap = need;
    }

    ml_render(&s->layout, &s->model, &s->canvas);

    uint8_t brightness = s->brightness >= 0
                       ? (uint8_t)s->brightness
                       : s->layout.brightness;

    /*
     * Gamma then scale, matching ml_canvas_export_rgb888 exactly, which in
     * turn matches how the panel dims (OE modulation after its gamma LUT).
     *
     * This is the true panel output: no selection chrome and no mirror
     * dimming, both of which belong to the view layer.
     */
    size_t n = (size_t)w * (size_t)h;
    for (size_t i = 0; i < n; i++) {
        ml_rgb p = s->canvas.px[i];
        s->rgba[i * 4 + 0] = (uint8_t)((ml_gamma8(p.r) * brightness + 127) / 255);
        s->rgba[i * 4 + 1] = (uint8_t)((ml_gamma8(p.g) * brightness + 127) / 255);
        s->rgba[i * 4 + 2] = (uint8_t)((ml_gamma8(p.b) * brightness + 127) / 255);
        s->rgba[i * 4 + 3] = 255;
    }

    return s->rgba;
}

const char *ml_sim_to_json(ml_sim *s)
{
    if (!s) return k_empty;

    /* Ask for the required length first, then size the buffer once. */
    size_t need = ml_layout_write(&s->layout, NULL, 0) + 1;

    if (s->json_cap < need) {
        char *grown = (char *)realloc(s->json, need);
        if (!grown) return k_empty;
        s->json     = grown;
        s->json_cap = need;
    }

    ml_layout_write(&s->layout, s->json, s->json_cap);
    return s->json;
}

/* ------------------------------------------------------------- catalogue */

int ml_sim_font_count(void) { return ml_font_count(); }

const char *ml_sim_font_name(int index)
{
    const ml_font *f = ml_font_at(index);
    return f ? f->name : k_empty;
}

int ml_sim_font_height(int index)
{
    const ml_font *f = ml_font_at(index);
    return f ? f->height : 0;
}

int ml_sim_font_role(int index)
{
    const ml_font *f = ml_font_at(index);
    /* A bad index reads as text, the role that grants no special treatment. */
    return f ? (int)f->role : (int)ML_FONT_TEXT;
}

/* Kept in the same order as ml_widget_type so index maps straight to the enum. */
static const char *k_type_names[] = {
    "rect", "line", "text", "clock", "date", "weather", "icon", "agenda", "todo",
};

int ml_sim_type_count(void)
{
    return (int)(sizeof(k_type_names) / sizeof(k_type_names[0]));
}

const char *ml_sim_type_name(int index)
{
    if (index < 0 || index >= ml_sim_type_count()) return k_empty;
    return k_type_names[index];
}

/*
 * Everything ml_model_lookup understands. Kept next to the parser it mirrors so
 * the two are edited together; a stale entry here shows up immediately as a
 * placeholder in the designer.
 */
static const char *k_bind_paths[] = {
    "now.hour", "now.minute", "now.second",
    "now.day", "now.month", "now.year", "now.weekday",
    "weather.temp_c", "weather.feels_c", "weather.temp_min_c", "weather.temp_max_c",
    "weather.code", "weather.label", "weather.place",
    "weather.wind_kph", "weather.humidity_pct", "weather.precip_prob", "weather.is_day",
    "system.online", "system.rssi", "system.uptime_s",
    "counts.events", "counts.todos",
};

int ml_sim_bind_count(void)
{
    return (int)(sizeof(k_bind_paths) / sizeof(k_bind_paths[0]));
}

const char *ml_sim_bind_at(int index)
{
    if (index < 0 || index >= ml_sim_bind_count()) return k_empty;
    return k_bind_paths[index];
}

int ml_sim_render_version(void) { return ML_RENDER_VERSION; }

const char *ml_sim_version_string(void) { return ML_VERSION_STR; }
