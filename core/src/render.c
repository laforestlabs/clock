/*
 * render.c - widget dispatch and drawing.
 *
 * Everything here is pure. No clock reads, no I/O, no allocation. Time arrives
 * through ml_model so that a given (layout, model) pair renders identically on
 * the device and on the desktop, which is what makes the designer's preview
 * worth trusting.
 */
#include "mirror/render.h"

#include <stdio.h>
#include <string.h>

#include "mirror/font.h"

/* The degree sign lives in the unused DEL slot of tom5x7. Written as its own
 * string literal because a hex escape would otherwise swallow a following
 * hex digit: "\x7fC" is one out-of-range character, not two. */
#define ML_DEGREE "\x7f"

#define TEXT_BUF 96

/* ------------------------------------------------------------- utilities */

static const ml_font *pick_font(const char *name, const char *fallback_name)
{
    const ml_font *f = NULL;
    if (name && *name) f = ml_font_find(name);
    if (!f && fallback_name) f = ml_font_find(fallback_name);
    if (!f) f = ml_font_default();
    return f;
}

/*
 * Choose a font that actually fits the box. A layout authored for 128x64 and
 * then dropped onto a 64x64 panel would otherwise render a clock as a row of
 * clipped stumps; falling back to the small font keeps it readable.
 */
static const ml_font *fit_font(const ml_font *want, int box_h)
{
    if (!want) return ml_font_default();
    if (want->height <= box_h) return want;

    const ml_font *best = NULL;
    for (int i = 0; i < ml_font_count(); i++) {
        const ml_font *f = ml_font_at(i);
        if (f->height > box_h) continue;
        if (!best || f->height > best->height) best = f;
    }
    return best ? best : want;
}

/*
 * Largest whole-pixel scale of f that still fits the box height.
 *
 * Never below 1: a box too short for even one unscaled row still draws its text
 * clipped, which is visible and fixable, rather than silently drawing nothing.
 */
static int fit_scale(const ml_font *f, int box_h)
{
    if (!f || f->height <= 0) return 1;

    int s = box_h / f->height;
    if (s < 1)            s = 1;
    if (s > ML_MAX_SCALE) s = ML_MAX_SCALE;
    return s;
}

/*
 * The scale a widget draws at.
 *
 * With fit set the box decides, which is what makes dragging a widget taller in
 * the designer grow the text in it. Otherwise the layout's own scale stands,
 * and the box is just a box.
 */
static int widget_scale(const ml_widget *w, const ml_font *f)
{
    if (w->fit) return fit_scale(f, w->rect.h);
    return w->scale > 0 ? w->scale : 1;
}

/* Dimmed variant used for secondary rows and for missing-data placeholders. */
static ml_rgb dim(ml_rgb c)
{
    return ml_rgb_scale(c, 90);
}

static ml_rgb secondary(const ml_widget *w)
{
    return w->has_accent ? w->accent : dim(w->color);
}

static int align_x(ml_align a, ml_rect r, int text_w)
{
    if (a == ML_ALIGN_CENTER) return r.x + (r.w - text_w) / 2;
    if (a == ML_ALIGN_RIGHT)  return r.x + r.w - text_w;
    return r.x;
}

static int valign_y(ml_valign v, ml_rect r, int text_h)
{
    if (v == ML_VALIGN_MIDDLE) return r.y + (r.h - text_h) / 2;
    if (v == ML_VALIGN_BOTTOM) return r.y + r.h - text_h;
    return r.y;
}

/* ------------------------------------------------------------ formatting */

static const char *k_wday_short[7] = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
static const char *k_wday_long[7]  = {"Sunday", "Monday", "Tuesday", "Wednesday",
                                      "Thursday", "Friday", "Saturday"};
static const char *k_mon_short[12] = {"Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};
static const char *k_mon_long[12]  = {"January", "February", "March", "April",
                                      "May", "June", "July", "August",
                                      "September", "October", "November", "December"};

static void put(char *out, size_t cap, size_t *w, const char *s)
{
    for (; *s && *w + 1 < cap; s++) out[(*w)++] = *s;
}

static void put_int(char *out, size_t cap, size_t *w, int value, int pad)
{
    char tmp[16];
    snprintf(tmp, sizeof(tmp), "%0*d", pad, value);
    put(out, cap, w, tmp);
}

/*
 * strftime subset. Implemented by hand rather than calling strftime because
 * the core must not depend on the platform's locale or time.h, and because a
 * layout-supplied format string must never reach a variadic formatter.
 */
static void fmt_time(const char *fmt, const ml_time *t, char *out, size_t cap)
{
    if (!out || cap == 0) return;
    size_t w = 0;

    int wday = (t->weekday >= 0 && t->weekday < 7) ? t->weekday : 0;
    int mon  = (t->month >= 1 && t->month <= 12) ? t->month - 1 : 0;

    for (const char *p = fmt; *p && w + 1 < cap; p++) {
        if (*p != '%') { out[w++] = *p; continue; }

        p++;
        switch (*p) {
        case 'H': put_int(out, cap, &w, t->hour, 2); break;
        case 'k': put_int(out, cap, &w, t->hour, 1); break;
        case 'M': put_int(out, cap, &w, t->minute, 2); break;
        case 'S': put_int(out, cap, &w, t->second, 2); break;
        case 'd': put_int(out, cap, &w, t->day, 2); break;
        case 'e': put_int(out, cap, &w, t->day, 1); break;
        case 'm': put_int(out, cap, &w, t->month, 2); break;
        case 'Y': put_int(out, cap, &w, t->year, 4); break;
        case 'y': put_int(out, cap, &w, t->year % 100, 2); break;
        case 'a': put(out, cap, &w, k_wday_short[wday]); break;
        case 'A': put(out, cap, &w, k_wday_long[wday]); break;
        case 'b': put(out, cap, &w, k_mon_short[mon]); break;
        case 'B': put(out, cap, &w, k_mon_long[mon]); break;
        case 'I': {
            int h12 = t->hour % 12;
            if (h12 == 0) h12 = 12;
            put_int(out, cap, &w, h12, 2);
            break;
        }
        case 'l': {
            int h12 = t->hour % 12;
            if (h12 == 0) h12 = 12;
            put_int(out, cap, &w, h12, 1);
            break;
        }
        case 'p': put(out, cap, &w, t->hour < 12 ? "AM" : "PM"); break;
        case 'P': put(out, cap, &w, t->hour < 12 ? "am" : "pm"); break;
        case '%': out[w++] = '%'; break;
        case '\0': p--; break;
        default:
            /* Unknown specifier: show it verbatim so the author can see it. */
            if (w + 2 < cap) { out[w++] = '%'; out[w++] = *p; }
            break;
        }
    }
    out[w] = '\0';
}

/*
 * printf subset for bound values. The layout's format string is parsed here
 * and only ever handed to snprintf as a compile-time literal with width and
 * precision passed as arguments, so a hostile or mistyped format cannot cause
 * a type-confused variadic read.
 */
static void fmt_value(const char *fmt, bool is_num, double num, const char *sval,
                      char *out, size_t cap)
{
    if (!out || cap == 0) return;
    out[0] = '\0';
    size_t w = 0;

    if (!fmt || !*fmt) {
        if (!is_num) { put(out, cap, &w, sval ? sval : ""); out[w] = '\0'; return; }

        /* Print whole numbers without a pointless ".0". */
        long rounded = (long)(num < 0 ? num - 0.5 : num + 0.5);
        double delta = num - (double)rounded;
        if (delta < 0) delta = -delta;

        char tmp[32];
        if (delta < 1e-6) snprintf(tmp, sizeof(tmp), "%ld", rounded);
        else              snprintf(tmp, sizeof(tmp), "%.1f", num);
        put(out, cap, &w, tmp);
        out[w] = '\0';
        return;
    }

    for (const char *p = fmt; *p && w + 1 < cap; ) {
        if (*p != '%') { out[w++] = *p++; continue; }

        p++;
        if (*p == '%') { out[w++] = '%'; p++; continue; }

        bool zero = false, left = false;
        while (*p == '0' || *p == '-' || *p == '+' || *p == ' ') {
            if (*p == '0') zero = true;
            if (*p == '-') left = true;
            p++;
        }

        int width = 0;
        while (*p >= '0' && *p <= '9') width = width * 10 + (*p++ - '0');

        int prec = -1;
        if (*p == '.') {
            p++;
            prec = 0;
            while (*p >= '0' && *p <= '9') prec = prec * 10 + (*p++ - '0');
        }

        char conv = *p ? *p++ : 'd';

        /* Clamp so the scratch buffer below cannot be overrun. */
        if (width > 24) width = 24;
        if (prec  > 9)  prec  = 9;

        /* A string value asked to print as a number prints as a string. */
        if (!is_num && (conv == 'd' || conv == 'i' || conv == 'f' || conv == 'F'))
            conv = 's';

        char tmp[64];
        tmp[0] = '\0';

        switch (conv) {
        case 'd':
        case 'i': {
            long v = (long)(num < 0 ? num - 0.5 : num + 0.5);
            if      (left) snprintf(tmp, sizeof(tmp), "%-*ld", width, v);
            else if (zero) snprintf(tmp, sizeof(tmp), "%0*ld", width, v);
            else           snprintf(tmp, sizeof(tmp), "%*ld",  width, v);
            break;
        }
        case 'f':
        case 'F': {
            if (prec < 0) prec = 1;
            if      (left) snprintf(tmp, sizeof(tmp), "%-*.*f", width, prec, num);
            else if (zero) snprintf(tmp, sizeof(tmp), "%0*.*f", width, prec, num);
            else           snprintf(tmp, sizeof(tmp), "%*.*f",  width, prec, num);
            break;
        }
        case 's': {
            const char *s = sval ? sval : "";
            if (left) snprintf(tmp, sizeof(tmp), "%-*s", width, s);
            else      snprintf(tmp, sizeof(tmp), "%*s",  width, s);
            break;
        }
        default:
            snprintf(tmp, sizeof(tmp), "%%%c", conv);
            break;
        }

        put(out, cap, &w, tmp);
    }
    out[w] = '\0';
}

/* Map a WMO code to a wx16 icon category. */
static int wx_category(int code)
{
    if (code <= 0)                return 0;   /* clear */
    if (code == 1)                return 1;   /* fair */
    if (code == 2)                return 2;   /* cloudy */
    if (code == 3)                return 3;   /* overcast */
    if (code >= 45 && code <= 48) return 4;   /* fog */
    if (code >= 51 && code <= 57) return 5;   /* drizzle */
    if (code >= 61 && code <= 67) return 6;   /* rain */
    if (code >= 71 && code <= 77) return 7;   /* snow */
    if (code >= 80 && code <= 82) return 8;   /* showers */
    if (code >= 85 && code <= 86) return 7;   /* snow showers */
    if (code >= 95)               return 9;   /* storm */
    return 3;
}

/* ---------------------------------------------------------------- widgets */

static void draw_rect_w(const ml_widget *w, ml_canvas *c)
{
    if (w->has_bg) {
        ml_canvas_fill_rect(c, w->rect, w->bg);
        ml_canvas_draw_rect(c, w->rect, w->color);
    } else {
        ml_canvas_fill_rect(c, w->rect, w->color);
    }
}

static void draw_line_w(const ml_widget *w, ml_canvas *c)
{
    /* Orientation follows the rect's dominant axis, so a 1px-tall box is a
     * horizontal rule and a 1px-wide box is a vertical one. */
    if (w->rect.w >= w->rect.h) {
        ml_canvas_hline(c, w->rect.x, w->rect.y + w->rect.h / 2, w->rect.w, w->color);
    } else {
        ml_canvas_vline(c, w->rect.x + w->rect.w / 2, w->rect.y, w->rect.h, w->color);
    }
}

static void draw_text_w(const ml_widget *w, const ml_model *m, ml_canvas *c)
{
    const ml_font *f = fit_font(pick_font(w->font, "tom5x7"), w->rect.h);
    char buf[TEXT_BUF];
    ml_rgb color = w->color;

    if (w->bind[0]) {
        bool        is_num = true;
        double      num    = 0.0;
        const char *sval   = NULL;

        if (ml_model_lookup(m, w->bind, &is_num, &num, &sval)) {
            fmt_value(w->format, is_num, num, sval, buf, sizeof(buf));
        } else {
            /* Data has not arrived, or the path is wrong. Show a placeholder
             * rather than a stale or invented value. */
            snprintf(buf, sizeof(buf), "--");
            color = dim(w->color);
        }
    } else {
        snprintf(buf, sizeof(buf), "%s", w->text);
    }

    const int sc = widget_scale(w, f);
    int tw = ml_text_width(f, buf, sc);
    int x  = align_x(w->align, w->rect, tw);
    int y  = valign_y(w->valign, w->rect, f->height * sc);
    ml_text_draw_clipped(c, f, x, y, w->rect.w - (x - w->rect.x), buf, color, sc);
}

static void draw_clock_w(const ml_widget *w, const ml_model *m, ml_canvas *c)
{
    const ml_font *f = fit_font(pick_font(w->font, "digits16"), w->rect.h);
    const char *fmt  = w->format[0] ? w->format : "%H:%M";

    char buf[TEXT_BUF];
    ml_rgb color = w->color;

    if (m->now.valid) {
        fmt_time(fmt, &m->now, buf, sizeof(buf));
    } else {
        /* Same shape as a real time so the layout does not reflow once the
         * clock syncs. */
        snprintf(buf, sizeof(buf), "--:--");
        color = dim(w->color);
    }

    const int sc = widget_scale(w, f);
    int tw = ml_text_width(f, buf, sc);
    int x  = align_x(w->align, w->rect, tw);
    int y  = valign_y(w->valign, w->rect, f->height * sc);
    ml_text_draw(c, f, x, y, buf, color, sc);
}

static void draw_date_w(const ml_widget *w, const ml_model *m, ml_canvas *c)
{
    const ml_font *f = fit_font(pick_font(w->font, "tom5x7"), w->rect.h);
    const char *fmt  = w->format[0] ? w->format : "%a %e %b";

    char buf[TEXT_BUF];
    ml_rgb color = w->color;

    if (m->now.valid) {
        fmt_time(fmt, &m->now, buf, sizeof(buf));
    } else {
        snprintf(buf, sizeof(buf), "--");
        color = dim(w->color);
    }

    const int sc = widget_scale(w, f);
    int tw = ml_text_width(f, buf, sc);
    int x  = align_x(w->align, w->rect, tw);
    int y  = valign_y(w->valign, w->rect, f->height * sc);
    ml_text_draw_clipped(c, f, x, y, w->rect.w - (x - w->rect.x), buf, color, sc);
}

static void draw_icon_w(const ml_widget *w, const ml_model *m, ml_canvas *c)
{
    const ml_font *f = pick_font(w->icon_set[0] ? w->icon_set : w->font, "wx16");
    if (!f) return;

    int category = 0;
    if (w->bind[0]) {
        bool        is_num = true;
        double      num    = 0.0;
        const char *sval   = NULL;
        if (ml_model_lookup(m, w->bind, &is_num, &num, &sval) && is_num) {
            category = wx_category((int)num);
        } else {
            return;  /* nothing sensible to draw without a code */
        }
    } else if (m->weather.valid) {
        category = wx_category(m->weather.code);
    } else {
        return;
    }

    char glyph[2] = {(char)('0' + category), '\0'};
    const int sc = widget_scale(w, f);
    int  gw = ml_text_width(f, glyph, sc);
    int  x  = align_x(w->align, w->rect, gw);
    int  y  = valign_y(w->valign, w->rect, f->height * sc);
    ml_text_draw(c, f, x, y, glyph, w->color, sc);
}

/*
 * Composite weather block: temperature, condition label, then the day's range.
 * Draws as many of those lines as the box has room for, so the same widget is
 * useful in a 64px column and in a 20px strip.
 */
static void draw_weather_w(const ml_widget *w, const ml_model *m, ml_canvas *c)
{
    const ml_font *f = fit_font(pick_font(w->font, "tom5x7"), w->rect.h);
    const int sc     = widget_scale(w, f);
    const int fh     = f->height * sc;
    int line_h = fh + (w->line_gap > 0 ? w->line_gap : 0);

    char buf[TEXT_BUF];
    int  y = w->rect.y;

    if (!m->weather.valid) {
        ml_text_draw(c, f, w->rect.x, y, "--", dim(w->color), sc);
        return;
    }

    snprintf(buf, sizeof(buf), "%d" ML_DEGREE "C", (int)(m->weather.temp_c + 0.5));
    int tw = ml_text_width(f, buf, sc);
    ml_text_draw(c, f, align_x(w->align, w->rect, tw), y, buf, w->color, sc);
    y += line_h;

    if (y + fh <= w->rect.y + w->rect.h) {
        const char *label = ml_wx_label(m->weather.code);
        tw = ml_text_width(f, label, sc);
        ml_text_draw_clipped(c, f, align_x(w->align, w->rect, tw), y,
                             w->rect.w, label, secondary(w), sc);
        y += line_h;
    }

    if (y + fh <= w->rect.y + w->rect.h) {
        snprintf(buf, sizeof(buf), "H%d L%d",
                 (int)(m->weather.temp_max_c + 0.5),
                 (int)(m->weather.temp_min_c + 0.5));
        tw = ml_text_width(f, buf, sc);
        ml_text_draw_clipped(c, f, align_x(w->align, w->rect, tw), y,
                             w->rect.w, buf, secondary(w), sc);
    }
}

static void draw_agenda_w(const ml_widget *w, const ml_model *m, ml_canvas *c)
{
    const ml_font *f = fit_font(pick_font(w->font, "tom5x7"), w->rect.h);
    const int sc     = widget_scale(w, f);
    const int fh     = f->height * sc;
    int line_h = fh + (w->line_gap > 0 ? w->line_gap : 0);

    if (m->event_count == 0) {
        ml_text_draw_clipped(c, f, w->rect.x, w->rect.y, w->rect.w,
                             "No events", dim(w->color), sc);
        return;
    }

    int shown = 0;
    int y     = w->rect.y;

    for (int i = 0; i < m->event_count && i < ML_MAX_EVENTS; i++) {
        const ml_event *e = &m->events[i];
        if (!e->valid) continue;
        if (w->max_items > 0 && shown >= w->max_items) break;
        if (y + fh > w->rect.y + w->rect.h) break;

        int x = w->rect.x;

        if (w->show_time) {
            char when[12];
            if (e->all_day || e->start_min < 0) {
                snprintf(when, sizeof(when), "all");
            } else {
                /* Clamp before formatting. A provider that hands back a bogus
                 * start_min should produce a wrong time, not a truncated one. */
                int mins = e->start_min % (24 * 60);
                snprintf(when, sizeof(when), "%02d:%02d", mins / 60, mins % 60);
            }
            x += ml_text_draw(c, f, x, y, when, secondary(w), sc);
            x += f->gap * 2 * sc;
        }

        int avail = w->rect.x + w->rect.w - x;
        if (avail > 0) {
            ml_text_draw_clipped(c, f, x, y, avail, e->title, w->color, sc);
        }

        y += line_h;
        shown++;
    }
}

static void draw_todo_w(const ml_widget *w, const ml_model *m, ml_canvas *c)
{
    const ml_font *f = fit_font(pick_font(w->font, "tom5x7"), w->rect.h);
    const int sc     = widget_scale(w, f);
    const int fh     = f->height * sc;
    int line_h = fh + (w->line_gap > 0 ? w->line_gap : 0);

    int shown = 0;
    int y     = w->rect.y;

    for (int i = 0; i < m->todo_count && i < ML_MAX_TODOS; i++) {
        const ml_todo *t = &m->todos[i];
        if (!t->valid) continue;
        if (t->done && w->hide_done) continue;
        if (w->max_items > 0 && shown >= w->max_items) break;
        if (y + fh > w->rect.y + w->rect.h) break;

        ml_rgb color = t->done ? dim(w->color) : w->color;

        /* A two-pixel bullet on the baseline. A glyph would eat scarce width.
         * It grows with the text, or it vanishes beside scaled-up entries. */
        int bullet_y = y + (f->baseline - 3) * sc;
        for (int by = 0; by < sc; by++) {
            for (int bx = 0; bx < 2 * sc; bx++) {
                ml_canvas_set(c, w->rect.x + bx, bullet_y + by, secondary(w));
            }
        }

        int x     = w->rect.x + 3 * sc;
        int avail = w->rect.x + w->rect.w - x;
        if (avail > 0) {
            ml_text_draw_clipped(c, f, x, y, avail, t->text, color, sc);
            /* Strike through completed entries when they are still shown. */
            if (t->done) {
                int tw = ml_text_width(f, t->text, sc);
                if (tw > avail) tw = avail;
                /* Half way up the scaled glyph, and as many rows thick as the
                 * text is scaled, so the rule stays visible against it. */
                int strike_y = y + (f->baseline * sc) / 2;
                for (int sy = 0; sy < sc; sy++) {
                    ml_canvas_hline(c, x, strike_y + sy, tw, dim(w->color));
                }
            }
        }

        y += line_h;
        shown++;
    }

    if (shown == 0) {
        ml_text_draw_clipped(c, f, w->rect.x, w->rect.y, w->rect.w,
                             "All done", dim(w->color), sc);
    }
}

/* --------------------------------------------------------------- dispatch */

void ml_render_widget(const ml_widget *w, const ml_model *m, ml_canvas *c)
{
    if (!w || !m || !c) return;
    if (!w->visible || w->type == ML_W_UNKNOWN) return;
    if (w->rect.w <= 0 || w->rect.h <= 0) return;

    /* Clip to the widget box so no widget can scribble over a neighbour, and
     * so individual draw code never has to bounds check. */
    if (!ml_canvas_push_clip(c, w->rect)) return;

    /* A background fill is common to every text-bearing widget. */
    if (w->has_bg && w->type != ML_W_RECT) {
        ml_canvas_fill_rect(c, w->rect, w->bg);
    }

    switch (w->type) {
    case ML_W_RECT:    draw_rect_w(w, c);       break;
    case ML_W_LINE:    draw_line_w(w, c);       break;
    case ML_W_TEXT:    draw_text_w(w, m, c);    break;
    case ML_W_CLOCK:   draw_clock_w(w, m, c);   break;
    case ML_W_DATE:    draw_date_w(w, m, c);    break;
    case ML_W_WEATHER: draw_weather_w(w, m, c); break;
    case ML_W_ICON:    draw_icon_w(w, m, c);    break;
    case ML_W_AGENDA:  draw_agenda_w(w, m, c);  break;
    case ML_W_TODO:    draw_todo_w(w, m, c);    break;
    default: break;
    }

    ml_canvas_pop_clip(c);
}

void ml_render(const ml_layout *layout, const ml_model *model, ml_canvas *out)
{
    if (!layout || !model || !out) return;

    ml_canvas_clear(out, layout->bg);
    for (int i = 0; i < layout->count; i++) {
        ml_render_widget(&layout->widgets[i], model, out);
    }
}
