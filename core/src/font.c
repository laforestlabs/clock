#include "mirror/font.h"

#include <string.h>

/* Provided by the generated core/src/fonts/font_registry.c. */
extern const ml_font *const ml_font_registry[];
extern const int              ml_font_registry_count;

int ml_font_count(void)
{
    return ml_font_registry_count;
}

const ml_font *ml_font_at(int index)
{
    if (index < 0 || index >= ml_font_registry_count) return NULL;
    return ml_font_registry[index];
}

const ml_font *ml_font_default(void)
{
    /*
     * Named rather than positional. fontgen sorts the registry by (height,
     * name), so entry zero moves the moment a shorter font is added, or even a
     * font of the same height whose name sorts earlier. Taking entry zero would
     * mean that dropping a new .font into the directory silently changes what
     * every widget that names no font renders as, which is a surprising way for
     * an unrelated addition to alter a layout.
     *
     * sans9 is the body font the widget defaults in render.c already name, so
     * pinning here keeps the two agreeing. Entry zero remains the backstop for
     * a build that somehow lacks it.
     */
    const ml_font *body = ml_font_find("sans9");
    if (body) return body;
    return ml_font_registry_count > 0 ? ml_font_registry[0] : NULL;
}

const ml_font *ml_font_find(const char *name)
{
    if (!name || !*name) return NULL;
    for (int i = 0; i < ml_font_registry_count; i++) {
        if (strcmp(ml_font_registry[i]->name, name) == 0) return ml_font_registry[i];
    }
    return NULL;
}

bool ml_font_is_family(const char *name)
{
    if (!name || !*name) return false;
    if (ml_font_find(name)) return false;
    for (int i = 0; i < ml_font_registry_count; i++) {
        if (strcmp(ml_font_registry[i]->family, name) == 0) return true;
    }
    return false;
}

/* Glyph index for a codepoint, or -1 when this font has no glyph for it. */
static int glyph_index(const ml_font *f, unsigned char ch)
{
    int idx = (int)ch - (int)f->first;
    if (idx < 0 || idx >= (int)f->count) return -1;
    return idx;
}

bool ml_font_has_glyph(const ml_font *f, unsigned char ch)
{
    return f && glyph_index(f, ch) >= 0;
}

bool ml_font_covers(const ml_font *f, const char *s)
{
    if (!f || !s || !*s) return false;

    /* Every byte, including the spaces. A font missing the space glyph does not
     * advance for it, so words would run together rather than merely look
     * different, and that is not a font that can render this string. */
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        if (glyph_index(f, *p) < 0) return false;
    }
    return true;
}

static int normalized_scale(const ml_font *f, int scale_q8)
{
    /* Early callers used 1 for the unscaled case before the public API exposed
     * q8 values. Keep that shorthand compatible while reserving 32 and above
     * for genuine fractional scales. */
    if (scale_q8 > 0 && scale_q8 < ML_SCALE_MIN) return scale_q8 * ML_SCALE_1X;
    const int minimum = f && f->downscale ? ML_SCALE_MIN : ML_SCALE_1X;
    return scale_q8 < minimum ? minimum : scale_q8;
}

int ml_text_width(const ml_font *f, const char *s, int scale_q8)
{
    if (!f || !s) return 0;
    scale_q8 = normalized_scale(f, scale_q8);

    int total = 0;
    bool first = true;
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        int idx = glyph_index(f, *p);
        if (idx < 0) continue;
        if (!first) total += f->gap;
        total += f->widths[idx];
        first = false;
    }
    /* Gaps scale with the glyphs, so the text stays proportional rather than
     * bunching up as it grows. The product is exact in q8; only the return
     * rounds, to the nearest whole pixel. Whole multiples of ML_SCALE_1X come
     * out unchanged, which is what keeps width exactly linear in scale. */
    return (total * scale_q8 + 128) / 256;
}

int ml_text_height(const ml_font *f, int scale_q8)
{
    if (!f) return 0;
    scale_q8 = normalized_scale(f, scale_q8);
    return (f->height * scale_q8 + 128) / 256;
}

/*
 * Blit one glyph with its top-left at (x, y), at a whole-pixel scale.
 * Returns the ink width.
 *
 * Each set bit becomes a scale by scale block. At scale 1 the inner loops run
 * exactly once and this reduces to the single ml_canvas_set it has always
 * been, which is what keeps unscaled output bit-identical.
 */
static int draw_glyph_whole(ml_canvas *c, const ml_font *f, int idx,
                            int x, int y, ml_rgb color, int scale)
{
    int width  = f->widths[idx];
    int stride = (width + 7) / 8;
    const uint8_t *bits = &f->bitmap[f->offsets[idx]];

    for (int row = 0; row < f->height; row++) {
        const uint8_t *rowbits = bits + (size_t)row * (size_t)stride;
        int py = y + row * scale;

        /* Cheap reject: whole rows above or below the clip cost nothing. A
         * scaled row spans scale pixels, so both edges account for that. */
        if (py + scale <= c->clip.y || py >= c->clip.y + c->clip.h) continue;

        for (int col = 0; col < width; col++) {
            if (!(rowbits[col >> 3] & (0x80u >> (col & 7)))) continue;
            for (int sy = 0; sy < scale; sy++) {
                for (int sx = 0; sx < scale; sx++) {
                    ml_canvas_set(c, x + col * scale + sx, py + sy, color);
                }
            }
        }
    }
    return width * scale;
}

/* Coverage is a fraction of emitted light, but canvas values are passed
 * through the panel's gamma curve at export. Feeding raw coverage to blend
 * applies gamma twice and makes anti-aliased stems nearly disappear. Map the
 * desired luminous coverage back through the inverse gamma curve first. */
static uint8_t coverage_alpha(int cover)
{
    int target = (cover * 255 + 32768) / 65536;
    if (target <= 0) return 0;
    if (target >= 255) return 255;

    int lo = 0, hi = 255;
    while (lo < hi) {
        int mid = (lo + hi) / 2;
        if (ml_gamma8((uint8_t)mid) < target) lo = mid + 1;
        else                                  hi = mid;
    }
    return (uint8_t)lo;
}

/*
 * Splat one isolated source pixel at a fractional position and size, inking
 * each destination pixel it touches by covered area. Only exact for a source
 * pixel whose inked neighbours share no destination pixel with it; the
 * ellipsis marker's dots are two source pixels apart, which guarantees that.
 */
static void splat(ml_canvas *c, int fx, int fy, int scale_q8, ml_rgb color)
{
    const int x1 = fx + scale_q8;
    const int y1 = fy + scale_q8;

    for (int py = fy >> 8; py <= (y1 - 1) >> 8; py++) {
        const int row_end = (py + 1) << 8;
        const int oy = (y1 < row_end ? y1 : row_end) - (fy > (py << 8) ? fy : (py << 8));
        for (int px = fx >> 8; px <= (x1 - 1) >> 8; px++) {
            const int col_end = (px + 1) << 8;
            const int ox = (x1 < col_end ? x1 : col_end) - (fx > (px << 8) ? fx : (px << 8));
            const int cover = ox * oy;
            if (cover >= 65536)  ml_canvas_set(c, px, py, color);
            else if (cover > 0)  ml_canvas_blend(c, px, py, color,
                                                 coverage_alpha(cover));
        }
    }
}

/*
 * Blit one glyph at a fractional scale. x_q8 is the pen position in q8, y the
 * integer row the text starts on. Returns the q8 advance.
 *
 * Iterates destination pixels rather than source pixels. Each destination
 * pixel receives the summed area of every source pixel that overlaps it. At
 * scales below 1x this naturally averages several source pixels into one
 * destination pixel; above 1x it distributes a source pixel across several.
 * The same path therefore supports continuous shrinking and growth without a
 * ladder of visually different bitmap cuts.
 *
 * Summing before blending matters: a destination pixel straddling the seam
 * between two inked source pixels is fully covered, and blending each
 * contribution separately would leave a darker seam inside solid stems.
 */
static int draw_glyph_frac(ml_canvas *c, const ml_font *f, int idx,
                           int x_q8, int y, ml_rgb color, int scale_q8)
{
    const int width  = f->widths[idx];
    const int stride = (width + 7) / 8;
    const uint8_t *bits = &f->bitmap[f->offsets[idx]];
    const int gy = y << 8;

    const int py2 = (gy + f->height * scale_q8 - 1) >> 8;
    const int px2 = (x_q8 + width * scale_q8 - 1) >> 8;

    for (int py = gy >> 8; py <= py2; py++) {
        /* Cheap reject: whole rows above or below the clip cost nothing. */
        if (py < c->clip.y || py >= c->clip.y + c->clip.h) continue;

        const int row_lo = py << 8;
        const int row_hi = row_lo + 256;
        /* Clamped to the glyph: the last partial row or column reaches past
         * the glyph's extent, and an unclamped index would read the padding
         * bits of the next glyph as phantom ink. */
        int sr0 = row_lo > gy ? (row_lo - gy) / scale_q8 : 0;
        int sr1 = (row_hi - 1 - gy) / scale_q8;
        if (sr1 > f->height - 1) sr1 = f->height - 1;

        for (int px = x_q8 >> 8; px <= px2; px++) {
            const int col_lo = px << 8;
            const int col_hi = col_lo + 256;
            const int sc0 = col_lo > x_q8 ? (col_lo - x_q8) / scale_q8 : 0;
            int sc1 = (col_hi - 1 - x_q8) / scale_q8;
            if (sc1 > width - 1) sc1 = width - 1;

            int cover = 0;
            for (int sr = sr0; sr <= sr1; sr++) {
                const uint8_t *rowbits = bits + (size_t)sr * (size_t)stride;
                const int r1 = gy + (sr + 1) * scale_q8;
                const int oy = (r1 < row_hi ? r1 : row_hi)
                             - (gy + sr * scale_q8 > row_lo ? gy + sr * scale_q8 : row_lo);
                for (int sc = sc0; sc <= sc1; sc++) {
                    if (!(rowbits[sc >> 3] & (0x80u >> (sc & 7)))) continue;
                    const int c1 = x_q8 + (sc + 1) * scale_q8;
                    const int ox = (c1 < col_hi ? c1 : col_hi)
                                 - (x_q8 + sc * scale_q8 > col_lo ? x_q8 + sc * scale_q8 : col_lo);
                    cover += ox * oy;
                }
            }

            /* Source pixels tile exactly, so cover can reach but never exceed
             * the destination pixel's 256x256 area. A fully covered pixel goes
             * through set rather than blend at 255, keeping full ink exact. */
            if (cover >= 65536)  ml_canvas_set(c, px, py, color);
            else if (cover > 0)  ml_canvas_blend(c, px, py, color,
                                                 coverage_alpha(cover));
        }
    }
    return width * scale_q8;
}

int ml_text_draw(ml_canvas *c, const ml_font *f, int x, int y,
                 const char *s, ml_rgb color, int scale_q8)
{
    if (!c || !f || !s) return 0;
    scale_q8 = normalized_scale(f, scale_q8);

    /* Whole multiples keep the exact block replication they have always had,
     * so unscaled and integrally scaled output stays bit-identical. */
    if ((scale_q8 & 255) == 0) {
        const int scale = scale_q8 >> 8;
        int pen = x;
        bool first = true;
        for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
            int idx = glyph_index(f, *p);
            if (idx < 0) continue;
            if (!first) pen += f->gap * scale;
            pen += draw_glyph_whole(c, f, idx, pen, y, color, scale);
            first = false;
        }
        return pen - x;
    }

    /* The pen runs in q8 so per-glyph rounding never accumulates; only the
     * returned advance rounds to whole pixels. */
    int pen = x << 8;
    bool first = true;
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        int idx = glyph_index(f, *p);
        if (idx < 0) continue;
        if (!first) pen += f->gap * scale_q8;
        pen += draw_glyph_frac(c, f, idx, pen, y, color, scale_q8);
        first = false;
    }
    return (pen - (x << 8) + 128) >> 8;
}

int ml_text_draw_clipped(ml_canvas *c, const ml_font *f, int x, int y,
                         int max_w, const char *s, ml_rgb color, int scale_q8)
{
    if (!c || !f || !s || max_w <= 0) return 0;
    scale_q8 = normalized_scale(f, scale_q8);

    /* Fast path: it fits, so draw it whole and skip the truncation logic. */
    if (ml_text_width(f, s, scale_q8) <= max_w) {
        return ml_text_draw(c, f, x, y, s, color, scale_q8);
    }

    if ((scale_q8 & 255) == 0) {
        const int scale = scale_q8 >> 8;

        /*
         * It does not fit. Reserve room for the ellipsis marker and draw as many
         * whole glyphs as fit before it. A marker beats a half-drawn glyph, which
         * at this size reads as a different letter entirely.
         *
         * The marker spans 4px, not 2: its dots sit at pen+1 and pen+3. Reserving
         * only the ink width would push the second dot past the right edge, where
         * it gets clipped and the marker reads as a single dot.
         */
        const int marker_w = 4 * scale;
        int budget = max_w - marker_w;
        if (budget < 0) budget = 0;

        int pen = x;
        bool first = true;
        for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
            int idx = glyph_index(f, *p);
            if (idx < 0) continue;

            int advance = (f->widths[idx] + (first ? 0 : f->gap)) * scale;
            if (pen - x + advance > budget) break;

            if (!first) pen += f->gap * scale;
            pen += draw_glyph_whole(c, f, idx, pen, y, color, scale);
            first = false;
        }

        /*
         * Two dots on the baseline row. One pixel would vanish, three would not fit.
         * The dots scale with the text: a single pixel next to 3x glyphs reads as
         * dirt on the panel rather than as a truncation marker.
         */
        int marker_y  = y + (f->baseline - 1) * scale;
        int last_row  = y + (f->height - 1) * scale;
        if (marker_y > last_row) marker_y = last_row;

        for (int sy = 0; sy < scale; sy++) {
            for (int sx = 0; sx < scale; sx++) {
                ml_canvas_set(c, pen + 1 * scale + sx, marker_y + sy, color);
                ml_canvas_set(c, pen + 3 * scale + sx, marker_y + sy, color);
            }
        }

        return (pen + 4 * scale) - x;
    }

    /* The same truncation in q8: the budget, the advances and the marker all
     * track the fractional scale exactly. */
    const int marker_w = 4 * scale_q8;
    int budget = (max_w << 8) - marker_w;
    if (budget < 0) budget = 0;

    int pen = x << 8;
    bool first = true;
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        int idx = glyph_index(f, *p);
        if (idx < 0) continue;

        int advance = (f->widths[idx] + (first ? 0 : f->gap)) * scale_q8;
        if (pen - (x << 8) + advance > budget) break;

        if (!first) pen += f->gap * scale_q8;
        pen += draw_glyph_frac(c, f, idx, pen, y, color, scale_q8);
        first = false;
    }

    int marker_y = (y << 8) + (f->baseline - 1) * scale_q8;
    int last_row = (y << 8) + (f->height - 1) * scale_q8;
    if (marker_y > last_row) marker_y = last_row;

    splat(c, pen + 1 * scale_q8, marker_y, scale_q8, color);
    splat(c, pen + 3 * scale_q8, marker_y, scale_q8, color);

    return (pen + marker_w - (x << 8) + 128) >> 8;
}
