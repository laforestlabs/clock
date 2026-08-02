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
 * Whether f may stand in for a font the box cannot hold.
 *
 * Icon sets are refused by role, not by coverage. wx16 carries exactly the ten
 * digit codepoints, so "23" is inside its coverage and no measurement of its
 * bitmaps reveals that the glyphs are weather pictograms. Only the declared role
 * separates a numeral from a rain cloud.
 *
 * Past that, coverage decides, so a clock face is never handed a word it would
 * drop most of. A caller with no sample to name draws strings this code cannot
 * see (the list widgets, a row at a time), and there only a full text font is
 * safe: substituting a 10px clock face for a 32px one would silently erase
 * every letter in an agenda.
 */
static bool can_stand_in(const ml_font *f, const char *sample)
{
    if (!f) return false;
    if (f->role == ML_FONT_ICONS) return false;
    if (!sample || !*sample) return f->role == ML_FONT_TEXT;
    return ml_font_covers(f, sample);
}

/*
 * The tallest cut of want's own family that stands in for the sample and fits
 * box_h, or the family's shortest when the box is under every cut, or NULL
 * when nothing in the family can carry the sample. The shortest cut is the
 * floor rather than the oversized one the layout asked for: a 5px box loses
 * the last row of a 6px font instead of showing the top five rows of a 16px
 * one, which is the difference between small text and wreckage.
 */
static const ml_font *family_fit(const ml_font *want, const char *sample, int box_h)
{
    const ml_font *best     = NULL;
    const ml_font *shortest = NULL;

    for (int i = 0; i < ml_font_count(); i++) {
        const ml_font *f = ml_font_at(i);
        if (strcmp(f->family, want->family) != 0) continue;
        if (!can_stand_in(f, sample)) continue;

        if (!shortest || f->height < shortest->height) shortest = f;
        if (f->height > box_h) continue;
        if (!best || f->height > best->height) best = f;
    }

    return best ? best : shortest;
}

/*
 * Choose a font that actually fits the box. A layout authored for 128x64 and
 * then dropped onto a 64x64 panel would otherwise render a clock as a row of
 * clipped stumps; falling back to a shorter font keeps it readable.
 *
 * The fallback stays in the family. The style is the author's choice and only
 * the size is the box's, so a widget that shrinks past its named cut steps
 * down to a shorter cut of the same face rather than switching styles.
 * Switching would also make a resize drag in the designer change what the
 * text looks like, which reads as a bug, not a service.
 *
 * Only when no cut of the family can carry the sample at all does the search
 * widen: a word asked of a clock face would draw nothing, and a list widget
 * with no single string to measure needs a full text font.
 */
static const ml_font *fit_font(const ml_font *want, const char *sample, int box_h)
{
    if (!want) return ml_font_default();
    if (want->height <= box_h) return want;

    const ml_font *kin = family_fit(want, sample, box_h);
    if (kin) return kin;

    const ml_font *best     = NULL;
    const ml_font *shortest = NULL;

    for (int i = 0; i < ml_font_count(); i++) {
        const ml_font *f = ml_font_at(i);
        if (!can_stand_in(f, sample)) continue;

        if (!shortest || f->height < shortest->height) shortest = f;
        if (f->height > box_h) continue;
        if (!best || f->height > best->height) best = f;
    }

    if (best)     return best;
    if (shortest) return shortest;
    return want;
}

/*
 * Largest scale of f that keeps sample inside the box, on both axes, in q8.
 *
 * Height alone used to decide this, which was fine while every fit widget held
 * one short string and wrong as soon as one did not: a 64 by 32 clock box put
 * digits16 at 2x on height and then drew 104px of "09:41" into 64px of box.
 *
 * The scale is continuous rather than the largest whole multiple. ml_text_width
 * is exactly linear in scale before its final rounding, so the widest scale
 * that still fits is a division rather than a search, and fractional scales
 * anti-alias, so a box growing one pixel grows the text by a fraction of a
 * pixel instead of leaving it parked until the next whole multiple. A NULL or
 * empty sample means the caller has no single string to fit, and only the
 * height is used.
 *
 * Never below 1x: a box too short for even one unscaled row still draws its
 * text clipped, which is visible and fixable, rather than silently shrinking
 * a 5x7 face into mush.
 */
static int fit_scale(const ml_font *f, const char *sample, int box_w, int box_h)
{
    if (!f || f->height <= 0) return ML_SCALE_1X;

    int s = box_h * ML_SCALE_1X / f->height;

    if (sample && *sample && box_w > 0) {
        const int unit = ml_text_width(f, sample, ML_SCALE_1X);
        if (unit > 0) {
            const int by_width = box_w * ML_SCALE_1X / unit;
            if (by_width < s) s = by_width;
        }
    }

    if (s < ML_SCALE_1X)            s = ML_SCALE_1X;
    if (s > ML_MAX_SCALE * ML_SCALE_1X) s = ML_MAX_SCALE * ML_SCALE_1X;
    return s;
}

/* Hold a q8 scale inside the global range. */
static int clamp_scale(int s)
{
    if (s < ML_SCALE_1X)                s = ML_SCALE_1X;
    if (s > ML_MAX_SCALE * ML_SCALE_1X) s = ML_MAX_SCALE * ML_SCALE_1X;
    return s;
}

/*
 * The q8 scale a widget draws at.
 *
 * With fit set the box decides, which is what makes dragging a widget in the
 * designer grow the text in it one pixel at a time. Otherwise the layout's own
 * whole-pixel scale stands, and the box is just a box.
 */
static int widget_scale(const ml_widget *w, const ml_font *f, const char *sample)
{
    int s = w->fit ? fit_scale(f, sample, w->rect.w, w->rect.h)
                   : (w->scale > 0 ? w->scale : 1) * ML_SCALE_1X;
    /* A deliberately blocky font never anti-aliases: a box-derived scale
     * floors to a whole-pixel multiple, keeping its hard edges. An explicit
     * scale is already whole, so this only touches fit. */
    if (w->fit && f && !f->smooth) s &= ~255;
    return clamp_scale(s);
}

/* Whether f at this q8 scale draws sample entirely inside the box. Compared
 * in q8, before any rounding to whole pixels. */
static bool scale_fits(const ml_font *f, const char *sample, int s,
                       const ml_rect *box)
{
    if (!f) return false;
    if (f->height * s > box->h * ML_SCALE_1X) return false;
    return ml_text_width(f, sample, s) <= box->w;
}

/* A q8 scale applied to a pixel count, rounded to whole pixels. Decorative
 * chrome (bullets, strike-throughs, gaps) lives in whole pixels; only the
 * text itself tracks the fractional scale exactly. */
static int px_of(int v, int scale_q8)
{
    return (v * scale_q8 + 128) >> 8;
}

/* The scale itself as a whole-pixel count, for chrome sized in scales. */
static int scale_px(int scale_q8)
{
    int p = (scale_q8 + 128) >> 8;
    return p < 1 ? 1 : p;
}

/*
 * Choose the font that fills the box best, out of those that can draw this
 * string at all.
 *
 * Membership is decided by what a font can draw rather than by declared
 * families: glyph coverage of the sample, plus a role that is not an icon set.
 * That keeps the clock faces out of a label and the weather pictograms out of
 * anything textual, and means a new .font joins the right group on its own.
 *
 * Ties go to the font the layout actually named. Choosing the size is a service;
 * quietly overruling a deliberate choice for no gain is not.
 */
static const ml_font *best_font(const ml_widget *w, const ml_font *want,
                                const char *sample, int *scale_out)
{
    /* Candidates are compared at the fit-derived scale, or at 1x when the
     * layout pins the scale: see family_pick for why the pin may not filter. */
    const int        want_s = w->fit ? widget_scale(w, want, sample) : ML_SCALE_1X;
    const ml_font *best     = want;
    int            best_h   = scale_fits(want, sample, want_s, &w->rect)
                                  ? want->height * want_s
                                  : -1;

    const ml_font *shortest = NULL;

    for (int i = 0; i < ml_font_count(); i++) {
        const ml_font *f = ml_font_at(i);
        if (!can_stand_in(f, sample)) continue;

        if (!shortest || f->height < shortest->height) shortest = f;
        if (f == want) continue;

        const int s = w->fit ? widget_scale(w, f, sample) : ML_SCALE_1X;
        if (!scale_fits(f, sample, s, &w->rect)) continue;

        const int h = f->height * s;
        if (h > best_h) {
            best   = f;
            best_h = h;
        }
    }

    /*
     * Nothing fits, the named font included. Fall to the shortest font that
     * can carry this string, drawn at the widget's scale and clipped: a box
     * this size is going to clip something, and clipping the least of the
     * smallest is the readable end of a bad situation.
     */
    if (best_h < 0 && shortest) best = shortest;

    *scale_out = widget_scale(w, best, sample);
    return best ? best : want;
}

/*
 * The cut of a family that fills the box best, and the scale to draw it at.
 * This is what a layout gets by naming a style, "digits" rather than
 * "digits16": the engine picks the size, the family keeps the style.
 *
 * Each cut is measured on its own metrics, because a 10px cut is not a linear
 * scaling of a 32px one. The tallest render wins; ties go to the taller cut,
 * which spends less of its scale on interpolation.
 */
static const ml_font *family_pick(const ml_widget *w, const char *family,
                                  const char *sample, int *scale_out)
{
    const ml_font *best     = NULL;
    int            best_h   = -1;
    const ml_font *shortest = NULL;

    for (int i = 0; i < ml_font_count(); i++) {
        const ml_font *f = ml_font_at(i);
        if (strcmp(f->family, family) != 0) continue;
        if (!can_stand_in(f, sample)) continue;

        if (!shortest || f->height < shortest->height) shortest = f;

        /*
         * Candidates are compared at the fit-derived scale, or at 1x when the
         * layout pins the scale. A pinned scale multiplies the chosen cut
         * afterwards; it must not filter here, or every step of the Scale
         * slider picks a different face, and the step where no cut fits at
         * the pinned scale comes out *smaller* than the one before it.
         */
        const int s = w->fit ? widget_scale(w, f, sample) : ML_SCALE_1X;
        if (!scale_fits(f, sample, s, &w->rect)) continue;

        const int h = f->height * s;
        if (h > best_h || (h == best_h && best && f->height > best->height)) {
            best   = f;
            best_h = h;
        }
    }

    /* The box is smaller than every cut at 1x: draw the shortest clipped,
     * the readable end of a bad situation. */
    if (!best) best = shortest;

    /* NULL when no cut can carry the string at all, so the caller can fall
     * back to its own default rather than rendering in a style the layout
     * never asked for. */
    if (!best) return NULL;

    *scale_out = widget_scale(w, best, sample);
    return best;
}

/*
 * The font and scale a widget draws with.
 *
 * One entry point, so every widget answers the question the same way. sample is
 * the string whose width has to be respected, or NULL for the list widgets,
 * which clip each row with an ellipsis by design: fitting those to their longest
 * entry would punish every row for one long title.
 */
static const ml_font *choose_font(const ml_widget *w, const char *fallback,
                                  const char *sample, int *scale_out)
{
    /* A named family resolves to its best cut for this box; a named cut, or
     * nothing usable at all, takes the exact path. A family that cannot carry
     * the string falls through to the exact path too, so an agenda naming a
     * digits-only family gets the body fallback, not digit stumps. */
    const ml_font *f;
    if (ml_font_is_family(w->font)) {
        f = family_pick(w, w->font, sample, scale_out);
        if (f) {
            if (w->auto_font && sample && *sample) {
                return best_font(w, f, sample, scale_out);
            }
            return f;
        }
    }

    f = fit_font(pick_font(w->font, fallback), sample, w->rect.h);
    *scale_out = widget_scale(w, f, sample);

    if (w->auto_font && sample && *sample) return best_font(w, f, sample, scale_out);
    return f;
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

        /*
         * Clamped inside the loops rather than after them. A format is only
         * ML_FORMAT_LEN bytes, but that is still room for enough digits to
         * overflow the accumulator, and layouts arrive over the network, so
         * the arithmetic itself has to stay defined. The ceiling is far above
         * the width and precision caps applied below.
         */
        int width = 0;
        while (*p >= '0' && *p <= '9') {
            if (width < 1000) width = width * 10 + (*p - '0');
            p++;
        }

        int prec = -1;
        if (*p == '.') {
            p++;
            prec = 0;
            while (*p >= '0' && *p <= '9') {
                if (prec < 1000) prec = prec * 10 + (*p - '0');
                p++;
            }
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

/*
 * The string a widget is sized and drawn against, formatted exactly the way
 * its draw function formats it. Shared between the draw functions and
 * ml_widget_resolve_font, so the drawn state the designer reports cannot
 * drift from what the panel draws. Each returns true when the string is a
 * placeholder for missing data, which the draw functions dim.
 */
static bool sample_text(const ml_widget *w, const ml_model *m, char *buf, size_t n)
{
    if (w->bind[0]) {
        bool        is_num = true;
        double      num    = 0.0;
        const char *sval   = NULL;

        if (ml_model_lookup(m, w->bind, &is_num, &num, &sval)) {
            fmt_value(w->format, is_num, num, sval, buf, n);
            return false;
        }
        /* Data has not arrived, or the path is wrong. Show a placeholder
         * rather than a stale or invented value. */
        snprintf(buf, n, "--");
        return true;
    }
    snprintf(buf, n, "%s", w->text);
    return false;
}

static bool sample_clock(const ml_widget *w, const ml_model *m, char *buf, size_t n)
{
    const char *fmt = w->format[0] ? w->format : "%H:%M";

    if (m->now.valid) {
        fmt_time(fmt, &m->now, buf, n);
        return false;
    }
    /* Same shape as a real time so the layout does not reflow once the
     * clock syncs. */
    snprintf(buf, n, "--:--");
    return true;
}

static bool sample_date(const ml_widget *w, const ml_model *m, char *buf, size_t n)
{
    const char *fmt = w->format[0] ? w->format : "%a %e %b";

    if (m->now.valid) {
        fmt_time(fmt, &m->now, buf, n);
        return false;
    }
    snprintf(buf, n, "--");
    return true;
}

/* The temperature line, the one line a weather widget is sized against. */
static void sample_temp(const ml_model *m, char *buf, size_t n)
{
    if (m->weather.valid) {
        snprintf(buf, n, "%d" ML_DEGREE "C", (int)(m->weather.temp_c + 0.5));
    } else {
        snprintf(buf, n, "--");
    }
}

/* The icon glyph for the current data, or false when there is nothing
 * sensible to draw. */
static bool sample_icon(const ml_widget *w, const ml_model *m, char glyph[2])
{
    int category = 0;
    if (w->bind[0]) {
        bool        is_num = true;
        double      num    = 0.0;
        const char *sval   = NULL;
        if (ml_model_lookup(m, w->bind, &is_num, &num, &sval) && is_num) {
            category = wx_category((int)num);
        } else {
            return false;  /* nothing sensible to draw without a code */
        }
    } else if (m->weather.valid) {
        category = wx_category(m->weather.code);
    } else {
        return false;
    }

    glyph[0] = (char)('0' + category);
    glyph[1] = '\0';
    return true;
}

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
    char buf[TEXT_BUF];
    const ml_rgb color =
        sample_text(w, m, buf, sizeof(buf)) ? dim(w->color) : w->color;

    /* Font after the text, because the text is what has to fit. */
    int sc = ML_SCALE_1X;
    const ml_font *f = choose_font(w, "tom5x7", buf, &sc);
    int tw = ml_text_width(f, buf, sc);
    int x  = align_x(w->align, w->rect, tw);
    int y  = valign_y(w->valign, w->rect, ml_text_height(f, sc));
    ml_text_draw_clipped(c, f, x, y, w->rect.w - (x - w->rect.x), buf, color, sc);
}

static void draw_clock_w(const ml_widget *w, const ml_model *m, ml_canvas *c)
{
    char buf[TEXT_BUF];
    const ml_rgb color =
        sample_clock(w, m, buf, sizeof(buf)) ? dim(w->color) : w->color;

    int sc = ML_SCALE_1X;
    const ml_font *f = choose_font(w, "digits16", buf, &sc);
    int tw = ml_text_width(f, buf, sc);
    int x  = align_x(w->align, w->rect, tw);
    int y  = valign_y(w->valign, w->rect, ml_text_height(f, sc));
    ml_text_draw(c, f, x, y, buf, color, sc);
}

static void draw_date_w(const ml_widget *w, const ml_model *m, ml_canvas *c)
{
    char buf[TEXT_BUF];
    const ml_rgb color =
        sample_date(w, m, buf, sizeof(buf)) ? dim(w->color) : w->color;

    int sc = ML_SCALE_1X;
    const ml_font *f = choose_font(w, "tom5x7", buf, &sc);
    int tw = ml_text_width(f, buf, sc);
    int x  = align_x(w->align, w->rect, tw);
    int y  = valign_y(w->valign, w->rect, ml_text_height(f, sc));
    ml_text_draw_clipped(c, f, x, y, w->rect.w - (x - w->rect.x), buf, color, sc);
}

static void draw_icon_w(const ml_widget *w, const ml_model *m, ml_canvas *c)
{
    const ml_font *f = pick_font(w->icon_set[0] ? w->icon_set : w->font, "wx16");
    if (!f) return;

    char glyph[2];
    if (!sample_icon(w, m, glyph)) return;

    /*
     * Scaled to the box like everything else, but never font-substituted. Icons
     * are indexed by digit, and every body font has digits, so letting
     * auto_font loose here would answer "which font can draw '3'?" with tom5x7
     * and quietly put the numeral 3 where the rain icon belongs.
     */
    const int sc = widget_scale(w, f, glyph);
    int  gw = ml_text_width(f, glyph, sc);
    int  x  = align_x(w->align, w->rect, gw);
    int  y  = valign_y(w->valign, w->rect, ml_text_height(f, sc));
    ml_text_draw(c, f, x, y, glyph, w->color, sc);
}

/*
 * Composite weather block: temperature, condition label, then the day's range.
 * Draws as many of those lines as the box has room for, so the same widget is
 * useful in a 64px column and in a 20px strip.
 */
static void draw_weather_w(const ml_widget *w, const ml_model *m, ml_canvas *c)
{
    char buf[TEXT_BUF];

    /*
     * Sized to the temperature, which is the one line drawn without clipping and
     * the one anybody reads from across a room. The rows under it are secondary
     * and clip with an ellipsis if the label is long.
     */
    sample_temp(m, buf, sizeof(buf));

    int sc = ML_SCALE_1X;
    const ml_font *f = choose_font(w, "tom5x7", buf, &sc);
    const int fh     = ml_text_height(f, sc);
    int line_h = fh + (w->line_gap > 0 ? w->line_gap : 0);

    int  y = w->rect.y;

    if (!m->weather.valid) {
        ml_text_draw(c, f, w->rect.x, y, "--", dim(w->color), sc);
        return;
    }

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
    /*
     * No sample, so the height decides the scale. A list clips each row with an
     * ellipsis by design, and fitting the whole widget to its longest entry
     * would shrink every row because one meeting has a long title.
     */
    int sc = ML_SCALE_1X;
    const ml_font *f = choose_font(w, "tom5x7", NULL, &sc);
    const int fh     = ml_text_height(f, sc);
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
            x += px_of(f->gap * 2, sc);
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
    /* Height decides, for the same reason as the agenda. */
    int sc = ML_SCALE_1X;
    const ml_font *f = choose_font(w, "tom5x7", NULL, &sc);
    const int fh     = ml_text_height(f, sc);
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
        int bullet_y = y + px_of(f->baseline - 3, sc);
        for (int by = 0; by < scale_px(sc); by++) {
            for (int bx = 0; bx < 2 * scale_px(sc); bx++) {
                ml_canvas_set(c, w->rect.x + bx, bullet_y + by, secondary(w));
            }
        }

        int x     = w->rect.x + 3 * scale_px(sc);
        int avail = w->rect.x + w->rect.w - x;
        if (avail > 0) {
            ml_text_draw_clipped(c, f, x, y, avail, t->text, color, sc);
            /* Strike through completed entries when they are still shown. */
            if (t->done) {
                int tw = ml_text_width(f, t->text, sc);
                if (tw > avail) tw = avail;
                /* Half way up the scaled glyph, and as many rows thick as the
                 * text is scaled, so the rule stays visible against it. */
                int strike_y = y + px_of(f->baseline, sc) / 2;
                for (int sy = 0; sy < scale_px(sc); sy++) {
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

/*
 * The font cut and scale a widget draws with against this model, or NULL when
 * it draws no text at all: a rect, a line, an icon with no data, a hidden or
 * zero-size widget. Pure, like everything else here: it measures what
 * ml_render_widget would draw rather than drawing it, so the designer can
 * report what a box resize changed without rendering one.
 */
const ml_font *ml_widget_resolve_font(const ml_widget *w, const ml_model *m,
                                      int *scale_q8)
{
    if (!w || !m) return NULL;
    if (!w->visible || w->rect.w <= 0 || w->rect.h <= 0) return NULL;

    char buf[TEXT_BUF];
    int  sc = ML_SCALE_1X;
    const ml_font *f;

    switch (w->type) {
    case ML_W_TEXT:
        sample_text(w, m, buf, sizeof(buf));
        f = choose_font(w, "tom5x7", buf, &sc);
        break;
    case ML_W_CLOCK:
        sample_clock(w, m, buf, sizeof(buf));
        f = choose_font(w, "digits16", buf, &sc);
        break;
    case ML_W_DATE:
        sample_date(w, m, buf, sizeof(buf));
        f = choose_font(w, "tom5x7", buf, &sc);
        break;
    case ML_W_WEATHER:
        sample_temp(m, buf, sizeof(buf));
        f = choose_font(w, "tom5x7", buf, &sc);
        break;
    case ML_W_ICON: {
        char glyph[2];
        f = pick_font(w->icon_set[0] ? w->icon_set : w->font, "wx16");
        if (!f || !sample_icon(w, m, glyph)) return NULL;
        sc = widget_scale(w, f, glyph);
        break;
    }
    case ML_W_AGENDA:
    case ML_W_TODO:
        f = choose_font(w, "tom5x7", NULL, &sc);
        break;
    default:
        return NULL;
    }

    if (!f) return NULL;
    if (scale_q8) *scale_q8 = sc;
    return f;
}

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
