/*
 * font_audit.c - structural legibility audit for the registered bitmap fonts.
 *
 * WHY THIS EXISTS
 *
 * On a 64x32 HUB75 panel each pixel is one RGB emitter with dead space around
 * it, so anti-aliasing cannot place a sub-pixel edge the way it does on a
 * continuous display: a half-covered cell is a full-size emitter at half
 * light. Whether that reads as a softer edge or as a dirty smear is a question
 * for the panel and a human, but *which glyphs degrade, and at which scales*
 * is a question arithmetic can answer here, without hardware and without a
 * viewing trial.
 *
 * This tool renders every glyph of every registered font through the real
 * renderer (ml_text_draw, including draw_glyph_frac and its inverse-gamma
 * coverage; canvas values are passed through ml_gamma8 first, because the
 * panel applies gamma at scan-out and summing pre-gamma values would count a
 * half-covered cell as half bright when it emits a quarter of the light), and
 * reports:
 *
 *   - 1x structure: min stroke width, counters and the smallest of them. This
 *     is the authored pixel art as the panel shows it.
 *   - the scale sweep: at each scale the font is actually rendered at, how
 *     much light lands in fractional-coverage cells ("grey load"), whether any
 *     ink fell below half light, and whether a stroke split or a counter
 *     closed.
 *   - the confusability matrix: for the pairs that cost readers (0/O,
 *     1/l/I/|, 5/S, 8/B, ...), the pixels that actually carry a difference
 *     between the two glyphs, fewest first. That list is the redraw order.
 *
 * The output is a defect list, not a score. Its job is to name the glyphs to
 * edit in the .font art and the scales at which a cut should be marked
 * non-scalable, so the human trial that follows only has to break real ties.
 *
 * SCALE RELEVANCE
 *
 * Only scales the engine can actually pick are swept, or the numbers lie. A
 * non-smooth font's fitted scale floors to a whole multiple, so its fractional
 * rows would just re-report the 1x render. A scale below 1x is clamped to 1x
 * unless the font declares @downscale. Grey load, faint ink and confusability
 * are advisory; a split stroke, a closed counter and a blank glyph are
 * structural and can fail --strict.
 *
 * RELATION TO fontgen
 *
 * fontgen.py compiles art to tables. This runs after it, against the compiled
 * registry, so it audits what would ship. It is not wired into `make check`
 * yet: hand-drawn cuts legitimately carry hairlines and similar-looking pairs,
 * so the target is `make -f Makefile.host audit`, and --strict is there for the
 * day the art is clean enough to gate on.
 */
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mirror/canvas.h"
#include "mirror/color.h"
#include "mirror/font.h"

/* A cell counts as ink at or above this light level; below it is background.
 * 128 is half light, which is where coverage_alpha() puts a half-covered cell,
 * so the threshold matches the renderer's own notion of "half there". */
#define INK_MIN 128

#define MAX_SCALES  16
#define MAX_DEFECTS 24

/* ------------------------------------------------------------------ raster */

typedef struct {
    int      w, h;
    uint8_t *light;  /* gamma(ink) 0..255, row major, linear-light. */
} raster;

static void raster_free(raster *r)
{
    free(r->light);
    r->light = NULL;
    r->w = r->h = 0;
}

/* Render one codepoint alone on a black field, at an exact q8 scale. */
static bool raster_glyph(const ml_font *f, unsigned char cp, int scale_q8,
                         raster *out)
{
    char s[2] = { (char)cp, '\0' };
    int w = ml_text_width(f, s, scale_q8) + 2;
    int h = ml_text_height(f, scale_q8) + 2;
    if (w <= 2 || h <= 2) return false;

    ml_canvas c;
    if (!ml_canvas_init(&c, w, h, NULL)) return false;
    ml_canvas_clear(&c, ml_black);
    ml_text_draw(&c, f, 1, 1, s, ML_RGB(255, 255, 255), scale_q8);

    uint8_t *light = malloc((size_t)w * (size_t)h);
    if (!light) {
        ml_canvas_free(&c);
        return false;
    }
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            ml_rgb p = ml_canvas_get(&c, x, y);
            uint8_t v = p.r > p.g ? p.r : p.g;
            if (p.b > v) v = p.b;
            light[(size_t)y * (size_t)w + (size_t)x] = ml_gamma8(v);
        }
    }
    ml_canvas_free(&c);

    out->w = w;
    out->h = h;
    out->light = light;
    return true;
}

static inline int at(const raster *r, int x, int y)
{
    return r->light[(size_t)y * (size_t)r->w + (size_t)x];
}

/* --------------------------------------------------------- 1x structure */

typedef struct {
    int ink;         /* cells at or above INK_MIN */
    int min_run;     /* thinnest horizontal or vertical run of ink, 0 if none */
    int components;  /* 4-connected ink regions */
    int holes;       /* background regions fully enclosed by ink */
    int min_hole;    /* area of the smallest enclosed region, 0 if none */
} shape;

/* Flood one 4-connected region whose cells satisfy `want_ink`, marking seen.
 * Iterative: a glyph is small but a recursive flood is still the wrong shape
 * for generated art that may one day be tall. */
static int flood(const raster *r, uint8_t *seen, int sx, int sy, bool want_ink)
{
    const int w = r->w, h = r->h;
    int *st = malloc(sizeof(int) * (size_t)w * (size_t)h);
    if (!st) return 0;
    int sp = 0, area = 0;

    const int start = sy * w + sx;
    st[sp++] = start;
    seen[start] = 1;

    while (sp > 0) {
        const int i = st[--sp];
        const int x = i % w, y = i / w;
        area++;

        const int dx[4] = { 1, -1, 0, 0 };
        const int dy[4] = { 0, 0, 1, -1 };
        for (int k = 0; k < 4; k++) {
            const int nx = x + dx[k], ny = y + dy[k];
            if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
            const int ni = ny * w + nx;
            if (seen[ni]) continue;
            if ((at(r, nx, ny) >= INK_MIN) != want_ink) continue;
            seen[ni] = 1;
            st[sp++] = ni;
        }
    }
    free(st);
    return area;
}

static void measure(const raster *r, shape *sh)
{
    const int w = r->w, h = r->h;
    memset(sh, 0, sizeof *sh);
    sh->min_run = INT_MAX;

    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++)
            if (at(r, x, y) >= INK_MIN) sh->ink++;

    /* Thinnest run: a row run is a vertical stroke's width and a column run is
     * a horizontal stroke's height, so the minimum over both is the hairline
     * the cut is built from. */
    for (int y = 0; y < h; y++) {
        int run = 0;
        for (int x = 0; x <= w; x++) {
            if (x < w && at(r, x, y) >= INK_MIN) { run++; continue; }
            if (run > 0 && run < sh->min_run) sh->min_run = run;
            run = 0;
        }
    }
    for (int x = 0; x < w; x++) {
        int run = 0;
        for (int y = 0; y <= h; y++) {
            if (y < h && at(r, x, y) >= INK_MIN) { run++; continue; }
            if (run > 0 && run < sh->min_run) sh->min_run = run;
            run = 0;
        }
    }
    if (sh->min_run == INT_MAX) sh->min_run = 0;

    uint8_t *seen = calloc((size_t)w * (size_t)h, 1);
    if (!seen) return;

    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++)
            if (!seen[y * w + x] && at(r, x, y) >= INK_MIN)
                if (flood(r, seen, x, y, true) > 0) sh->components++;

    /* Background reachable from the border is outside the glyph. Any other
     * background cell is inside a counter. */
    memset(seen, 0, (size_t)w * (size_t)h);
    for (int x = 0; x < w; x++) {
        if (!seen[x] && at(r, x, 0) < INK_MIN) flood(r, seen, x, 0, false);
        if (!seen[(h - 1) * w + x] && at(r, x, h - 1) < INK_MIN)
            flood(r, seen, x, h - 1, false);
    }
    for (int y = 0; y < h; y++) {
        if (!seen[y * w] && at(r, 0, y) < INK_MIN) flood(r, seen, 0, y, false);
        if (!seen[y * w + w - 1] && at(r, w - 1, y) < INK_MIN)
            flood(r, seen, w - 1, y, false);
    }
    sh->min_hole = INT_MAX;
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            if (seen[y * w + x] || at(r, x, y) >= INK_MIN) continue;
            const int area = flood(r, seen, x, y, false);
            sh->holes++;
            if (area < sh->min_hole) sh->min_hole = area;
        }
    }
    if (sh->min_hole == INT_MAX) sh->min_hole = 0;

    free(seen);
}

/*
 * Grey load: the share of emitted light that lands in partially lit cells, and
 * the glyph's total light. A whole-scale render scores zero; a badly fitted
 * fractional scale approaches the share of the glyph sitting on cell edges.
 * This is the anti-aliasing a panel can only show as dimmer emitters.
 */
static void grey_load(const raster *r, double *grey, double *total)
{
    double g = 0.0, t = 0.0;
    for (int i = 0; i < r->w * r->h; i++) {
        const int v = r->light[i];
        if (v <= 0) continue;
        t += v;
        if (v < 255) g += v;
    }
    *grey  = t > 0.0 ? g / t : 0.0;
    *total = t;
}

/* ------------------------------------------------------- confusability */

/*
 * How two glyphs differ, compared from the same pen origin.
 *
 * Both rasters are drawn from the same starting pen, so comparing them at the
 * same offset is what a reader sees in a word. Aligning by ink bounding box
 * instead -- which this did at first -- throws away the vertical position that
 * separates P from p and a hyphen from an underscore, and reports those pairs
 * as identical. Counting the differing pixels is also done on a thresholded
 * mask rather than on coverage, so a mark counts as a mark however faintly it
 * is drawn.
 *
 * Two numbers, because they answer different questions. `overlap` is the share
 * of the union the two have in common -- how similar they look overall.
 * `distinct` is the count of cells exactly one of them inks: the pixels that
 * carry the difference, which is what a reader actually uses. Overlap alone
 * cannot judge this: a footed 1 and a tailed l are mostly identical by area
 * and unmistakable to the eye, and judging by overlap would call the marks
 * pointless. Distinct pixels count them.
 */
static void compare(const raster *a, const raster *b, int *distinct, double *overlap)
{
    *distinct = 0;
    *overlap = 0.0;
    if (a->w <= 0 || b->w <= 0) return;

    const int w = a->w > b->w ? a->w : b->w;
    const int h = a->h > b->h ? a->h : b->h;

    long diff = 0, span = 0;
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            const int va = (x < a->w && y < a->h) ? at(a, x, y) : 0;
            const int vb = (x < b->w && y < b->h) ? at(b, x, y) : 0;
            diff += va > vb ? va - vb : vb - va;
            span += va > vb ? va : vb;
            if ((va >= INK_MIN) != (vb >= INK_MIN)) (*distinct)++;
        }
    }
    if (span > 0) *overlap = 1.0 - (double)diff / (double)span;
}

/* --------------------------------------------------------------- config */

/* The pairs that cost a reader on a small panel. Only groups whose codepoints
 * are all present in a font are tested, so a digits cut silently skips the
 * letter pairs. */
static const char *const CONFUSE[] = {
    "0O", "0o", "Oo", "1Il|", "5S", "8B", "6G", "9gq", "2Z", "uv",
    "Vv", "CX", "KX", "Pp", "QO", "ce", "sz", "7?", "L1", "t1",
    ",.", "':", ";:", "-_",
};
#define CONFUSE_COUNT ((int)(sizeof CONFUSE / sizeof CONFUSE[0]))

typedef struct {
    int    distinct;  /* cells exactly one glyph inks */
    double overlap;   /* share of the union they have in common */
    int    a, b;
} pair_out;

typedef struct {
    int    scale_q8;
    bool   relevant;
    double grey_mean;   /* ink-weighted across glyphs */
    double grey_max;
    int    faint;       /* glyphs with ink below half light at this scale */
    int    faint_cp[MAX_DEFECTS], faint_n;
    int    split;       /* glyphs whose stroke broke into more components */
    int    closed;      /* glyphs whose counter closed */
    int    closed_cp[MAX_DEFECTS], closed_n;
} scale_out;

typedef struct {
    const ml_font *f;
    const char    *role;
    int    glyphs, blank, hairline, min_run, holes, min_hole;
    int    blank_cp[MAX_DEFECTS], blank_n;
    scale_out scales[MAX_SCALES];
    int    scale_n;
    pair_out pairs[CONFUSE_COUNT * 4];
    int    pair_n;
} report;

/* Whether the engine can ever pick this scale for this font. See the file
 * header: a non-smooth cut floors fitted scales to whole multiples, and a
 * scale under 1x is clamped back to 1x unless the cut is a @downscale master.
 * Sweeping a scale the engine would never use reports fiction. */
static bool scale_relevant(const ml_font *f, int scale_q8)
{
    if (scale_q8 % ML_SCALE_1X == 0) return true;
    if (!f->smooth) return false;
    if (scale_q8 < ML_SCALE_1X) return f->downscale;
    return true;
}

static void collect(const ml_font *f, const int *scales, int scale_count,
                    report *out)
{
    memset(out, 0, sizeof *out);
    out->f = f;
    out->role = f->role == ML_FONT_TEXT   ? "text"
              : f->role == ML_FONT_DIGITS ? "digits" : "icons";
    out->glyphs = (int)f->count;
    out->min_run = INT_MAX;
    out->min_hole = INT_MAX;

    for (int cp = f->first; cp < f->first + (int)f->count; cp++) {
        raster r;
        if (!raster_glyph(f, (unsigned char)cp, ML_SCALE_1X, &r)) continue;
        shape sh;
        measure(&r, &sh);
        if (sh.ink == 0 && cp != ' ') {
            if (out->blank_n < MAX_DEFECTS) out->blank_cp[out->blank_n++] = cp;
            out->blank++;
        }
        if (sh.ink > 0 && sh.min_run == 1) out->hairline++;
        if (sh.min_run > 0 && sh.min_run < out->min_run) out->min_run = sh.min_run;
        if (sh.holes > 0) {
            out->holes += sh.holes;
            if (sh.min_hole < out->min_hole) out->min_hole = sh.min_hole;
        }
        raster_free(&r);
    }
    if (out->min_run == INT_MAX) out->min_run = 0;
    if (out->min_hole == INT_MAX) out->min_hole = 0;

    for (int i = 0; i < scale_count && out->scale_n < MAX_SCALES; i++) {
        const int s = scales[i];
        scale_out *so = &out->scales[out->scale_n];
        so->scale_q8 = s;
        so->relevant = scale_relevant(f, s);
        if (!so->relevant) { out->scale_n++; continue; }

        double grey_sum = 0.0, light_sum = 0.0;
        for (int cp = f->first; cp < f->first + (int)f->count; cp++) {
            raster base, sc;
            if (!raster_glyph(f, (unsigned char)cp, ML_SCALE_1X, &base)) continue;
            if (!raster_glyph(f, (unsigned char)cp, s, &sc)) { raster_free(&base); continue; }

            shape shb, shs;
            measure(&base, &shb);
            measure(&sc, &shs);

            double g, t;
            grey_load(&sc, &g, &t);
            if (t > 0.0) {
                grey_sum += g * t;   /* ink-weighted: a blank glyph carries no vote */
                light_sum += t;
                if (g > so->grey_max) so->grey_max = g;
            }

            if (shb.ink > 0) {
                /* Ink below half light is a cell the eye reads as background:
                 * a faint smear, which at these sizes is legibility lost. */
                int faint_here = 0;
                for (int i2 = 0; i2 < sc.w * sc.h; i2++)
                    if (sc.light[i2] > 0 && sc.light[i2] < INK_MIN) faint_here = 1;
                if (faint_here) {
                    if (so->faint_n < MAX_DEFECTS) so->faint_cp[so->faint_n++] = cp;
                    so->faint++;
                }
                if (shs.components > shb.components) so->split++;
                if (s < ML_SCALE_1X && shb.holes > 0 && shs.holes < shb.holes) {
                    if (so->closed_n < MAX_DEFECTS) so->closed_cp[so->closed_n++] = cp;
                    so->closed++;
                }
            }
            raster_free(&base);
            raster_free(&sc);
        }
        so->grey_mean = light_sum > 0.0 ? grey_sum / light_sum : 0.0;
        out->scale_n++;
    }

    for (int g = 0; g < CONFUSE_COUNT; g++) {
        const char *grp = CONFUSE[g];
        const int len = (int)strlen(grp);
        for (int i = 0; i < len; i++) {
            if (!ml_font_has_glyph(f, (unsigned char)grp[i])) continue;
            for (int j = i + 1; j < len; j++) {
                if (!ml_font_has_glyph(f, (unsigned char)grp[j])) continue;
                if (out->pair_n >= (int)(sizeof out->pairs / sizeof out->pairs[0])) break;
                raster a, b;
                if (!raster_glyph(f, (unsigned char)grp[i], ML_SCALE_1X, &a)) continue;
                if (!raster_glyph(f, (unsigned char)grp[j], ML_SCALE_1X, &b)) { raster_free(&a); continue; }
                pair_out *p = &out->pairs[out->pair_n];
                compare(&a, &b, &p->distinct, &p->overlap);
                p->a = (unsigned char)grp[i];
                p->b = (unsigned char)grp[j];
                out->pair_n++;
                raster_free(&a);
                raster_free(&b);
            }
        }
    }
    if (out->pair_n > 1) {
        /* Insertion sort, ascending on the distinguishing pixels: the pairs at
         * the top of the list are the ones a reader cannot tell apart. */
        for (int i = 1; i < out->pair_n; i++) {
            pair_out key = out->pairs[i];
            int j = i - 1;
            while (j >= 0 && out->pairs[j].distinct > key.distinct) {
                out->pairs[j + 1] = out->pairs[j];
                j--;
            }
            out->pairs[j + 1] = key;
        }
    }
}

/* ------------------------------------------------------------ reporting */

static void cp_list(const int *cps, int n, int printed)
{
    printf("[");
    const int shown = n < printed ? n : printed;
    for (int i = 0; i < shown; i++) printf("%s%d", i ? " " : "", cps[i]);
    if (n > shown) printf(" ...");
    printf("]");
}

static void report_text(const report *r, int distinct_min, double mushy,
                        int *advisory, int *structural)
{
    const ml_font *f = r->f;
    printf("=== %s  [%s]  cell %dpx  smooth=%s downscale=%s\n",
           f->name, r->role, f->height,
           f->smooth ? "yes" : "no", f->downscale ? "yes" : "no");
    printf("    glyphs %d..%d (%d)  baseline %d  gap %d  planes %d\n",
           f->first, f->first + (int)f->count - 1, (int)f->count,
           f->baseline, f->gap, f->planes);
    printf("    structure: min stroke %dpx, %d hairline glyph(s), "
           "%d counter(s), smallest %dpx\n",
           r->min_run, r->hairline, r->holes, r->min_hole);
    if (r->blank > 0) {
        printf("    !! %d blank glyph(s) at 1x (excluding space): ", r->blank);
        cp_list(r->blank_cp, r->blank_n, MAX_DEFECTS);
        printf("\n");
        (*structural)++;
    }

    printf("    scale sweep:\n");
    for (int i = 0; i < r->scale_n; i++) {
        const scale_out *s = &r->scales[i];
        if (!s->relevant) continue;
        printf("      %5.3fx  grey %5.1f%% mean %5.1f%% max  ",
               s->scale_q8 / 256.0, s->grey_mean * 100.0, s->grey_max * 100.0);
        if (!s->faint && !s->split && !s->closed) {
            printf("clean\n");
        } else {
            if (s->faint) {
                printf("FAINT %d/%d ", s->faint, r->glyphs);
                cp_list(s->faint_cp, s->faint_n, 12);
            }
            if (s->split) printf("  SPLIT %d", s->split);
            if (s->closed) {
                printf("  COUNTER-CLOSED %d ", s->closed);
                cp_list(s->closed_cp, s->closed_n, 12);
            }
            printf("\n");
        }
        if (s->grey_mean > mushy)
            printf("              !! mean grey load above %.0f%%: strokes smear at this scale\n",
                   mushy * 100.0);
        if (s->faint)     (*advisory)++;
        if (s->split || s->closed) (*structural)++;
    }

    if (r->pair_n > 0) {
        printf("    confusability at 1x (fewest distinguishing pixels first):\n");
        const int show = r->pair_n < 10 ? r->pair_n : 10;
        for (int i = 0; i < show; i++) {
            const bool bad = r->pairs[i].distinct < distinct_min;
            printf("      %3dpx distinct  overlap %.2f  '%c' / '%c'%s\n",
                   r->pairs[i].distinct, r->pairs[i].overlap,
                   r->pairs[i].a, r->pairs[i].b, bad ? "   AMBIGUOUS" : "");
        }
        int extra = 0;
        for (int i = show; i < r->pair_n; i++)
            if (r->pairs[i].distinct < distinct_min) extra++;
        if (extra) printf("      ... and %d more under %dpx distinct\n", extra, distinct_min);
        for (int i = 0; i < r->pair_n; i++)
            if (r->pairs[i].distinct < distinct_min) (*advisory)++;
    }
    printf("\n");
}

static void json_escape(const char *s)
{
    for (; *s; s++) {
        if (*s == '"' || *s == '\\') putchar('\\');
        if ((unsigned char)*s < 0x20) {
            printf("\\u%04x", (unsigned)(unsigned char)*s);
            continue;
        }
        putchar(*s);
    }
}

static void json_cps(const int *cps, int n)
{
    printf("[");
    for (int i = 0; i < n; i++) printf("%s%d", i ? ", " : "", cps[i]);
    printf("]");
}

static void report_json(const report *r, int distinct_min, bool first)
{
    const ml_font *f = r->f;
    printf("%s  {\"name\": \"", first ? "" : ",\n");
    json_escape(f->name);
    printf("\", \"role\": \"%s\", \"height\": %d, \"baseline\": %d, \"gap\": %d,"
           " \"planes\": %d, \"smooth\": %s, \"downscale\": %s,"
           " \"glyphs\": %d, \"min_stroke\": %d, \"hairlines\": %d,"
           " \"holes\": %d, \"min_hole\": %d,\n",
           r->role, f->height, f->baseline, f->gap, f->planes,
           f->smooth ? "true" : "false", f->downscale ? "true" : "false",
           r->glyphs, r->min_run, r->hairline, r->holes, r->min_hole);
    printf("    \"blank\": ");
    json_cps(r->blank_cp, r->blank_n);
    printf(",\n    \"scales\": [");
    int written = 0;
    for (int i = 0; i < r->scale_n; i++) {
        const scale_out *s = &r->scales[i];
        if (!s->relevant) continue;
        printf("%s\n      {\"scale\": %.3f, \"grey_mean\": %.4f, \"grey_max\": %.4f,"
               " \"faint\": %d, \"split\": %d, \"closed\": %d}",
               written++ ? "," : "", s->scale_q8 / 256.0,
               s->grey_mean, s->grey_max, s->faint, s->split, s->closed);
    }
    printf("\n    ],\n    \"confusable\": [");
    for (int i = 0; i < r->pair_n; i++) {
        printf("%s\n      {\"a\": %d, \"b\": %d, \"distinct\": %d,"
               " \"overlap\": %.4f, \"ambiguous\": %s}",
               i ? "," : "", r->pairs[i].a, r->pairs[i].b, r->pairs[i].distinct,
               r->pairs[i].overlap,
               r->pairs[i].distinct < distinct_min ? "true" : "false");
    }
    printf("\n    ]\n  }");
}

/* --------------------------------------------------------------- driver */

typedef struct {
    int    distinct_min;   /* fewest distinguishing pixels a pair may have */
    double mushy;
    bool   json;
    bool   strict;
    int    scales[MAX_SCALES];
    int    scale_count;
    const char *only[64];
    int    only_count;
} options;

static void usage(const char *argv0)
{
    printf(
        "Legibility audit for the registered bitmap fonts.\n"
        "\n"
        "Usage: %s [options]\n"
        "\n"
        "  --font NAME       audit only NAME (repeatable)\n"
        "  --scales A,B,C    scales to sweep, in multiples of 1x\n"
        "                    (default 0.5,0.625,0.75,0.875,1,1.25,1.5,2)\n"
        "  --distinct N      fewest distinguishing pixels a confusable pair may\n"
        "                    have before it is flagged (default 3)\n"
        "  --mushy F         mean grey load above which a scale is called\n"
        "                    mushy (default 0.30)\n"
        "  --strict          exit non-zero when any cut reports a structural\n"
        "                    defect (split stroke, closed counter, blank glyph);\n"
        "                    grey load, faint ink and confusability are advisory\n"
        "  --json            machine-readable output\n"
        "  -h, --help        this message\n"
        "\n"
        "Only scales the engine can actually pick are swept: a non-smooth font's\n"
        "fitted scale floors to a whole multiple, and a scale under 1x is clamped\n"
        "back to 1x unless the cut declares @downscale.\n"
        "\n"
        "Exit status: 0 normally, 1 with --strict on a structural defect,\n"
        "2 on bad usage.\n",
        argv0);
}

int main(int argc, char **argv)
{
    options o = {
        .distinct_min  = 3,
        .mushy         = 0.30,
        .strict        = false,
        .json          = false,
        .scale_count   = 8,
    };
    const int default_scales[8] = { 128, 160, 192, 224, 256, 320, 384, 512 };
    memcpy(o.scales, default_scales, sizeof default_scales);

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "-h") || !strcmp(a, "--help")) { usage(argv[0]); return 0; }
        else if (!strcmp(a, "--strict")) o.strict = true;
        else if (!strcmp(a, "--json")) o.json = true;
        else if (!strcmp(a, "--distinct") && i + 1 < argc) o.distinct_min = atoi(argv[++i]);
        else if (!strcmp(a, "--mushy") && i + 1 < argc) o.mushy = atof(argv[++i]);
        else if (!strcmp(a, "--font") && i + 1 < argc) {
            /* Consume every following non-flag word so `--font a b` works. */
            while (i + 1 < argc && argv[i + 1][0] != '-') {
                if (o.only_count < 64) o.only[o.only_count++] = argv[++i];
                else i++;
            }
        } else if (!strcmp(a, "--scales") && i + 1 < argc) {
            o.scale_count = 0;
            char *tok = strtok(argv[++i], ",");
            while (tok && o.scale_count < MAX_SCALES) {
                o.scales[o.scale_count++] = (int)(atof(tok) * 256.0 + 0.5);
                tok = strtok(NULL, ",");
            }
        } else {
            fprintf(stderr, "unknown option %s\n", a);
            usage(argv[0]);
            return 2;
        }
    }

    int advisory = 0, structural = 0, audited = 0;
    if (o.json) printf("{\n  \"fonts\": [\n");

    for (int i = 0; i < ml_font_count(); i++) {
        const ml_font *f = ml_font_at(i);
        if (!f) continue;
        if (o.only_count > 0) {
            bool want = false;
            for (int k = 0; k < o.only_count; k++)
                if (!strcmp(f->name, o.only[k])) want = true;
            if (!want) continue;
        }
        report rep;
        collect(f, o.scales, o.scale_count, &rep);
        if (o.json) report_json(&rep, o.distinct_min, audited == 0);
        else        report_text(&rep, o.distinct_min, o.mushy, &advisory, &structural);
        audited++;
    }

    if (o.json) printf("\n  ]\n}\n");
    else printf("audited %d font(s): %d structural flag(s), %d advisory flag(s)\n",
                audited, structural, advisory);

    if (o.strict && structural > 0) {
        fprintf(stderr, "font-audit: %d structural defect(s) across %d font(s)\n",
                structural, audited);
        return 1;
    }
    return 0;
}
