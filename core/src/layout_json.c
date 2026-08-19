#include "mirror/layout.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mirror/json.h"

/* ------------------------------------------------------------------ diag */

void ml_diag_reset(ml_diag *d)
{
    if (!d) return;
    d->count    = 0;
    d->overflow = 0;
    d->msg[0][0] = '\0';
}

void ml_diag_add(ml_diag *d, const char *fmt, ...)
{
    if (!d) return;
    if (d->count >= ML_DIAG_MAX) {
        d->overflow++;
        return;
    }
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(d->msg[d->count], ML_DIAG_LEN, fmt, ap);
    va_end(ap);
    d->count++;
}

/* ------------------------------------------------------------- type names */

static const struct {
    ml_widget_type type;
    const char    *name;
} k_types[] = {
    {ML_W_RECT,    "rect"},
    {ML_W_LINE,    "line"},
    {ML_W_TEXT,    "text"},
    {ML_W_CLOCK,   "clock"},
    {ML_W_DATE,    "date"},
    {ML_W_WEATHER, "weather"},
    {ML_W_ICON,    "icon"},
    {ML_W_AGENDA,  "agenda"},
    {ML_W_TODO,    "todo"},
    {ML_W_COUNTDOWN, "countdown"},
};

ml_widget_type ml_widget_type_from_name(const char *name)
{
    if (!name) return ML_W_UNKNOWN;
    for (size_t i = 0; i < sizeof(k_types) / sizeof(k_types[0]); i++) {
        if (strcmp(k_types[i].name, name) == 0) return k_types[i].type;
    }
    return ML_W_UNKNOWN;
}

const char *ml_widget_type_name(ml_widget_type t)
{
    for (size_t i = 0; i < sizeof(k_types) / sizeof(k_types[0]); i++) {
        if (k_types[i].type == t) return k_types[i].name;
    }
    return "unknown";
}

/* ---------------------------------------------------------------- layout */

void ml_layout_init(ml_layout *l, int w, int h)
{
    if (!l) return;
    memset(l, 0, sizeof(*l));
    l->w          = w;
    l->h          = h;
    l->bg         = ml_black;
    l->brightness = 255;
    snprintf(l->name, sizeof(l->name), "untitled");
}

static void widget_defaults(ml_widget *w)
{
    memset(w, 0, sizeof(*w));
    w->type      = ML_W_UNKNOWN;
    w->visible   = true;
    w->color     = ml_white;
    w->bg        = ml_black;
    w->has_bg    = false;
    w->accent    = ml_white;
    w->has_accent = false;
    w->align     = ML_ALIGN_LEFT;
    w->valign    = ML_VALIGN_TOP;
    w->max_items = 4;
    w->line_gap  = 1;
    w->show_time = true;
    w->hide_done = true;
    /* Unscaled unless the layout asks otherwise, so every layout written before
     * scale existed renders exactly as it did. */
    w->scale     = 1;
    w->fit       = false;
}

static ml_align parse_align(const char *s, ml_align fallback)
{
    if (!s) return fallback;
    if (!strcmp(s, "left"))   return ML_ALIGN_LEFT;
    if (!strcmp(s, "center") || !strcmp(s, "centre")) return ML_ALIGN_CENTER;
    if (!strcmp(s, "right"))  return ML_ALIGN_RIGHT;
    return fallback;
}

static ml_valign parse_valign(const char *s, ml_valign fallback)
{
    if (!s) return fallback;
    if (!strcmp(s, "top"))    return ML_VALIGN_TOP;
    if (!strcmp(s, "middle") || !strcmp(s, "center")) return ML_VALIGN_MIDDLE;
    if (!strcmp(s, "bottom")) return ML_VALIGN_BOTTOM;
    return fallback;
}

/* Read a color key, warning rather than failing when it is unparseable. */
static bool read_color(const ml_json *j, int obj, const char *key,
                       ml_rgb *out, ml_diag *diag, int widget_index)
{
    char buf[24];
    if (!ml_json_get_str(j, obj, key, buf, sizeof(buf))) return false;
    if (ml_color_parse(buf, out)) return true;

    ml_diag_add(diag, "widget %d: color '%s' for '%s' not understood",
                widget_index, buf, key);
    return false;
}

/* Accept a rect as [x,y,w,h] or as {"x":..,"y":..,"w":..,"h":..}. */
static bool read_rect(const ml_json *j, int obj, ml_rect *out)
{
    int t = ml_json_member(j, obj, "rect");
    if (t < 0) return false;

    if (j->toks[t].type == ML_JSON_ARRAY) {
        if (ml_json_array_count(j, t) < 4) return false;
        int v[4];
        for (int i = 0; i < 4; i++) {
            int e = ml_json_array_at(j, t, i);
            if (e < 0 || !ml_json_int(j, e, &v[i])) return false;
        }
        *out = ML_RECT(v[0], v[1], v[2], v[3]);
        return true;
    }

    if (j->toks[t].type == ML_JSON_OBJECT) {
        int x = 0, y = 0, w = 0, h = 0;
        ml_json_get_int(j, t, "x", &x);
        ml_json_get_int(j, t, "y", &y);
        if (!ml_json_get_int(j, t, "w", &w)) ml_json_get_int(j, t, "width",  &w);
        if (!ml_json_get_int(j, t, "h", &h)) ml_json_get_int(j, t, "height", &h);
        *out = ML_RECT(x, y, w, h);
        return true;
    }

    return false;
}

static void parse_widget(const ml_json *j, int obj, ml_widget *w,
                         ml_diag *diag, int index, int canvas_w, int canvas_h)
{
    widget_defaults(w);

    if (!ml_json_get_str(j, obj, "type", w->type_name, sizeof(w->type_name))) {
        ml_diag_add(diag, "widget %d: missing 'type', skipped", index);
        w->visible = false;
        return;
    }

    w->type = ml_widget_type_from_name(w->type_name);
    if (w->type == ML_W_UNKNOWN) {
        /*
         * Forward compatibility: a layout from a newer designer may carry
         * widget types this build has never heard of. Skip it and keep going,
         * so a partial render beats a blank panel or a rejected config.
         */
        ml_diag_add(diag, "widget %d: unknown type '%s', skipped", index, w->type_name);
        w->visible = false;
        return;
    }

    ml_json_get_str(j, obj, "id", w->id, sizeof(w->id));

    if (!read_rect(j, obj, &w->rect)) {
        ml_diag_add(diag, "widget %d (%s): missing or malformed 'rect', skipped",
                    index, w->type_name);
        w->visible = false;
        return;
    }

    if (w->rect.w <= 0 || w->rect.h <= 0) {
        ml_diag_add(diag, "widget %d (%s): rect has zero area, skipped",
                    index, w->type_name);
        w->visible = false;
        return;
    }

    /* Off-canvas is a warning, not a skip. The renderer clips, and a designer
     * mid-drag legitimately produces rects that hang over the edge. */
    if (w->rect.x < 0 || w->rect.y < 0 ||
        w->rect.x + w->rect.w > canvas_w ||
        w->rect.y + w->rect.h > canvas_h) {
        ml_diag_add(diag, "widget %d (%s): rect %d,%d %dx%d extends past the %dx%d canvas",
                    index, w->type_name, w->rect.x, w->rect.y,
                    w->rect.w, w->rect.h, canvas_w, canvas_h);
    }

    read_color(j, obj, "color", &w->color, diag, index);
    w->has_bg     = read_color(j, obj, "bg", &w->bg, diag, index);
    w->has_accent = read_color(j, obj, "accent", &w->accent, diag, index);

    /* Optional multi-colour palette for icon fonts, in plane order after the
     * primary colour. Absent means single colour, which is every layout that
     * predates palettes. */
    int colors_arr = ml_json_member(j, obj, "colors");
    if (colors_arr >= 0 && j->toks[colors_arr].type == ML_JSON_ARRAY) {
        int n = ml_json_array_count(j, colors_arr);
        if (n > ML_ICON_COLORS) {
            ml_diag_add(diag, "widget %d (%s): 'colors' has %d entries, "
                        "only the first %d are used",
                        index, w->type_name, n, ML_ICON_COLORS);
            n = ML_ICON_COLORS;
        }
        for (int i = 0; i < n; i++) {
            int  e   = ml_json_array_at(j, colors_arr, i);
            char buf[24];
            if (e < 0 || !ml_json_str(j, e, buf, sizeof(buf))) {
                ml_diag_add(diag, "widget %d (%s): colors[%d] is not a string",
                            index, w->type_name, i);
                continue;
            }
            if (!ml_color_parse(buf, &w->colors[i])) {
                ml_diag_add(diag, "widget %d (%s): colors[%d] '%s' not understood",
                            index, w->type_name, i, buf);
                continue;
            }
            w->color_count = i + 1;
        }
    }

    ml_json_get_str(j, obj, "font",   w->font,     sizeof(w->font));
    ml_json_get_str(j, obj, "format", w->format,   sizeof(w->format));
    ml_json_get_str(j, obj, "bind",   w->bind,     sizeof(w->bind));
    ml_json_get_str(j, obj, "text",   w->text,     sizeof(w->text));

    if (!ml_json_get_str(j, obj, "icon_set", w->icon_set, sizeof(w->icon_set)))
        ml_json_get_str(j, obj, "set", w->icon_set, sizeof(w->icon_set));

    double until_d = 0;
    if (ml_json_get_double(j, obj, "until", &until_d))
        w->until_s = (int64_t)until_d;

    char buf[16];
    if (ml_json_get_str(j, obj, "align", buf, sizeof(buf)))
        w->align = parse_align(buf, w->align);
    if (ml_json_get_str(j, obj, "valign", buf, sizeof(buf)))
        w->valign = parse_valign(buf, w->valign);

    if (!ml_json_get_int(j, obj, "max_items", &w->max_items))
        ml_json_get_int(j, obj, "maxItems", &w->max_items);
    if (w->max_items < 0) w->max_items = 0;

    ml_json_get_int(j, obj, "line_gap", &w->line_gap);

    /* Clamped rather than rejected. A layout arriving over the network with a
     * silly scale should draw something sensible, not refuse to load. */
    if (ml_json_get_int(j, obj, "scale", &w->scale)) {
        if (w->scale < 1)             w->scale = 1;
        if (w->scale > ML_MAX_SCALE)  w->scale = ML_MAX_SCALE;
    }

    ml_json_get_bool(j, obj, "fit",       &w->fit);
    ml_json_get_bool(j, obj, "auto_font", &w->auto_font);
    /* Tri-state: only a present key overrules the font's own smooth flag. */
    w->has_smooth = ml_json_get_bool(j, obj, "smooth", &w->smooth);
    ml_json_get_bool(j, obj, "show_time", &w->show_time);
    ml_json_get_bool(j, obj, "hide_done", &w->hide_done);
    ml_json_get_bool(j, obj, "visible",   &w->visible);
}

bool ml_layout_parse(const char *json, size_t len, ml_layout *out, ml_diag *diag)
{
    if (!json || !out) return false;
    ml_diag_reset(diag);

    /*
     * Token storage scales with input size. This is the only allocation the
     * core ever makes, it happens on config change rather than per frame, and
     * it is released before returning, so nothing long-lived can fragment the
     * device heap.
     */
    int cap = (int)(len / 3) + 32;
    if (cap < 128)  cap = 128;
    if (cap > 4096) cap = 4096;

    ml_json_tok *toks = (ml_json_tok *)malloc((size_t)cap * sizeof(ml_json_tok));
    if (!toks) {
        ml_diag_add(diag, "out of memory parsing layout");
        return false;
    }

    ml_json j;
    int n = ml_json_parse(&j, json, len, toks, cap);
    if (n < 0) {
        const char *why = (n == ML_JSON_ERR_NOMEM)   ? "too many tokens"
                        : (n == ML_JSON_ERR_PARTIAL) ? "truncated"
                                                     : "malformed";
        ml_diag_add(diag, "layout JSON is %s", why);
        free(toks);
        return false;
    }
    if (n == 0 || j.toks[0].type != ML_JSON_OBJECT) {
        ml_diag_add(diag, "layout root must be a JSON object");
        free(toks);
        return false;
    }

    /* Canvas may be an object, an [w,h] pair, or top-level width/height. */
    int w = 0, h = 0;
    int canvas = ml_json_member(&j, 0, "canvas");
    if (canvas >= 0 && j.toks[canvas].type == ML_JSON_OBJECT) {
        if (!ml_json_get_int(&j, canvas, "width",  &w)) ml_json_get_int(&j, canvas, "w", &w);
        if (!ml_json_get_int(&j, canvas, "height", &h)) ml_json_get_int(&j, canvas, "h", &h);
    } else if (canvas >= 0 && j.toks[canvas].type == ML_JSON_ARRAY &&
               ml_json_array_count(&j, canvas) >= 2) {
        ml_json_int(&j, ml_json_array_at(&j, canvas, 0), &w);
        ml_json_int(&j, ml_json_array_at(&j, canvas, 1), &h);
    } else {
        ml_json_get_int(&j, 0, "width",  &w);
        ml_json_get_int(&j, 0, "height", &h);
    }

    if (w <= 0 || h <= 0 || w > 1024 || h > 1024) {
        ml_diag_add(diag, "canvas size %dx%d is missing or out of range", w, h);
        free(toks);
        return false;
    }

    ml_layout_init(out, w, h);
    ml_json_get_str(&j, 0, "name", out->name, sizeof(out->name));

    ml_rgb bg;
    if (read_color(&j, 0, "background", &bg, diag, -1) ||
        read_color(&j, 0, "bg", &bg, diag, -1)) {
        out->bg = bg;
    }

    int brightness = 255;
    if (ml_json_get_int(&j, 0, "brightness", &brightness)) {
        if (brightness < 0)   brightness = 0;
        if (brightness > 255) brightness = 255;
        out->brightness = (uint8_t)brightness;
    }

    int arr = ml_json_member(&j, 0, "widgets");
    if (arr < 0 || j.toks[arr].type != ML_JSON_ARRAY) {
        ml_diag_add(diag, "no 'widgets' array, rendering an empty canvas");
        free(toks);
        return true;
    }

    int total = ml_json_array_count(&j, arr);
    for (int i = 0; i < total; i++) {
        if (out->count >= ML_MAX_WIDGETS) {
            ml_diag_add(diag, "layout has %d widgets, only the first %d are kept",
                        total, ML_MAX_WIDGETS);
            break;
        }
        int obj = ml_json_array_at(&j, arr, i);
        if (obj < 0 || j.toks[obj].type != ML_JSON_OBJECT) {
            ml_diag_add(diag, "widget %d is not an object, skipped", i);
            continue;
        }
        parse_widget(&j, obj, &out->widgets[out->count], diag, i, w, h);
        out->count++;
    }

    free(toks);
    return true;
}

/* ------------------------------------------------------------- serialize */

/* Append to a bounded buffer, tracking the length the output would have had.
 * Returning the would-be length lets callers detect truncation. */
static void appendf(char *buf, size_t cap, size_t *len, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);

    if (*len < cap) {
        int n = vsnprintf(buf + *len, cap - *len, fmt, ap);
        if (n > 0) *len += (size_t)n;
    } else {
        char scratch[256];
        int n = vsnprintf(scratch, sizeof(scratch), fmt, ap);
        if (n > 0) *len += (size_t)n;
    }
    va_end(ap);
}

/*
 * Worst case is six bytes of \uXXXX per input character, over the longest
 * string any field can hold.
 */
#define ESCAPE_BUF (6 * ML_BIND_LEN + 1)

/*
 * Escape a string for embedding in JSON.
 *
 * Every string written here is user-entered: a widget captioned 5" nail, or a
 * format holding a backslash, would otherwise close the string early. The
 * result of that is worse than a loud failure, because the document reparses
 * cleanly with the field silently truncated at the stray quote.
 *
 * Non-ASCII goes out as \uXXXX. Codepoint 127 is written back as ° rather
 * than  because that byte *is* the degree sign to the fonts, and a saved
 * layout should say so; the reader folds either spelling back to the same byte.
 */
static void json_escape(const char *in, char *out, size_t cap)
{
    if (!out || cap == 0) return;
    size_t w = 0;

    for (const unsigned char *p = (const unsigned char *)(in ? in : ""); *p; p++) {
        const char *esc = NULL;
        switch (*p) {
        case '"':  esc = "\\\""; break;
        case '\\': esc = "\\\\"; break;
        case '\n': esc = "\\n";  break;
        case '\r': esc = "\\r";  break;
        case '\t': esc = "\\t";  break;
        case '\b': esc = "\\b";  break;
        case '\f': esc = "\\f";  break;
        default: break;
        }

        if (esc != NULL) {
            if (w + 2 >= cap) break;
            out[w++] = esc[0];
            out[w++] = esc[1];
        } else if (*p < 0x20 || *p >= 0x7F) {
            if (w + 6 >= cap) break;
            snprintf(out + w, cap - w, "\\u%04X", *p == 127 ? 0xB0u : (unsigned)*p);
            w += 6;
        } else {
            if (w + 1 >= cap) break;
            out[w++] = (char)*p;
        }
    }

    out[w] = '\0';
}

static const char *align_name(ml_align a)
{
    return a == ML_ALIGN_CENTER ? "center" : a == ML_ALIGN_RIGHT ? "right" : "left";
}

static const char *valign_name(ml_valign v)
{
    return v == ML_VALIGN_MIDDLE ? "middle" : v == ML_VALIGN_BOTTOM ? "bottom" : "top";
}

size_t ml_layout_write(const ml_layout *l, char *buf, size_t cap)
{
    if (!l) return 0;
    if (!buf) cap = 0;

    size_t len = 0;
    char   esc[ESCAPE_BUF];

    json_escape(l->name, esc, sizeof(esc));
    appendf(buf, cap, &len, "{\n  \"name\": \"%s\",\n", esc);
    appendf(buf, cap, &len, "  \"canvas\": { \"width\": %d, \"height\": %d },\n", l->w, l->h);
    appendf(buf, cap, &len, "  \"background\": \"#%02X%02X%02X\",\n",
            l->bg.r, l->bg.g, l->bg.b);
    appendf(buf, cap, &len, "  \"brightness\": %u,\n", (unsigned)l->brightness);
    appendf(buf, cap, &len, "  \"widgets\": [\n");

    for (int i = 0; i < l->count; i++) {
        const ml_widget *w = &l->widgets[i];

        appendf(buf, cap, &len, "    { \"type\": \"%s\"", ml_widget_type_name(w->type));
        if (w->id[0]) {
            json_escape(w->id, esc, sizeof(esc));
            appendf(buf, cap, &len, ", \"id\": \"%s\"", esc);
        }

        appendf(buf, cap, &len, ", \"rect\": [%d, %d, %d, %d]",
                w->rect.x, w->rect.y, w->rect.w, w->rect.h);
        appendf(buf, cap, &len, ", \"color\": \"#%02X%02X%02X\"",
                w->color.r, w->color.g, w->color.b);

        if (w->color_count > 0) {
            appendf(buf, cap, &len, ", \"colors\": [");
            for (int k = 0; k < w->color_count; k++) {
                appendf(buf, cap, &len, "%s\"#%02X%02X%02X\"",
                        k > 0 ? ", " : "",
                        w->colors[k].r, w->colors[k].g, w->colors[k].b);
            }
            appendf(buf, cap, &len, "]");
        }

        if (w->has_bg)
            appendf(buf, cap, &len, ", \"bg\": \"#%02X%02X%02X\"", w->bg.r, w->bg.g, w->bg.b);
        if (w->has_accent)
            appendf(buf, cap, &len, ", \"accent\": \"#%02X%02X%02X\"",
                    w->accent.r, w->accent.g, w->accent.b);

        static const struct {
            size_t      offset;
            const char *key;
        } k_strings[] = {
            {offsetof(ml_widget, font),     "font"},
            {offsetof(ml_widget, format),   "format"},
            {offsetof(ml_widget, bind),     "bind"},
            {offsetof(ml_widget, text),     "text"},
            {offsetof(ml_widget, icon_set), "icon_set"},
        };

        for (size_t k = 0; k < sizeof(k_strings) / sizeof(k_strings[0]); k++) {
            const char *value = (const char *)w + k_strings[k].offset;
            if (!value[0]) continue;
            json_escape(value, esc, sizeof(esc));
            appendf(buf, cap, &len, ", \"%s\": \"%s\"", k_strings[k].key, esc);
        }

        if (w->align  != ML_ALIGN_LEFT)
            appendf(buf, cap, &len, ", \"align\": \"%s\"", align_name(w->align));
        if (w->valign != ML_VALIGN_TOP)
            appendf(buf, cap, &len, ", \"valign\": \"%s\"", valign_name(w->valign));

        if (w->type == ML_W_AGENDA || w->type == ML_W_TODO) {
            appendf(buf, cap, &len, ", \"max_items\": %d, \"line_gap\": %d",
                    w->max_items, w->line_gap);
            if (w->type == ML_W_AGENDA)
                appendf(buf, cap, &len, ", \"show_time\": %s", w->show_time ? "true" : "false");
            else
                appendf(buf, cap, &len, ", \"hide_done\": %s", w->hide_done ? "true" : "false");
        }
        if (w->type == ML_W_COUNTDOWN && w->until_s != 0)
            appendf(buf, cap, &len, ", \"until\": %lld", (long long)w->until_s);

        /* Written only when they differ from the default, to keep the output
         * as small as the layouts people hand-write. */
        if (w->scale > 1) appendf(buf, cap, &len, ", \"scale\": %d", w->scale);
        if (w->fit)       appendf(buf, cap, &len, ", \"fit\": true");
        if (w->auto_font) appendf(buf, cap, &len, ", \"auto_font\": true");
        /* Tri-state: written whenever set, false included, because absent
         * means the font decides. */
        if (w->has_smooth)
            appendf(buf, cap, &len, ", \"smooth\": %s", w->smooth ? "true" : "false");

        if (!w->visible) appendf(buf, cap, &len, ", \"visible\": false");

        appendf(buf, cap, &len, " }%s\n", (i + 1 < l->count) ? "," : "");
    }

    appendf(buf, cap, &len, "  ]\n}\n");

    if (cap > 0) buf[(len < cap) ? len : cap - 1] = '\0';
    return len;
}
