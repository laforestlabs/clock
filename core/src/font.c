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
     * tom5x7 is the body font the widget defaults in render.c already name, so
     * pinning here keeps the two agreeing. Entry zero remains the backstop for
     * a build that somehow lacks it.
     */
    const ml_font *body = ml_font_find("tom5x7");
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

int ml_text_width(const ml_font *f, const char *s, int scale)
{
    if (!f || !s) return 0;
    if (scale < 1) scale = 1;

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
     * bunching up as it grows. */
    return total * scale;
}

/*
 * Blit one glyph with its top-left at (x, y). Returns the ink width.
 *
 * At scale > 1 each set bit becomes a scale by scale block. At scale 1 the
 * inner loops run exactly once and this reduces to the single ml_canvas_set it
 * has always been, which is what keeps unscaled output bit-identical.
 */
static int draw_glyph(ml_canvas *c, const ml_font *f, int idx,
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

int ml_text_draw(ml_canvas *c, const ml_font *f, int x, int y,
                 const char *s, ml_rgb color, int scale)
{
    if (!c || !f || !s) return 0;
    if (scale < 1) scale = 1;

    int pen = x;
    bool first = true;
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        int idx = glyph_index(f, *p);
        if (idx < 0) continue;
        if (!first) pen += f->gap * scale;
        pen += draw_glyph(c, f, idx, pen, y, color, scale);
        first = false;
    }
    return pen - x;
}

int ml_text_draw_clipped(ml_canvas *c, const ml_font *f, int x, int y,
                         int max_w, const char *s, ml_rgb color, int scale)
{
    if (!c || !f || !s || max_w <= 0) return 0;
    if (scale < 1) scale = 1;

    /* Fast path: it fits, so draw it whole and skip the truncation logic. */
    if (ml_text_width(f, s, scale) <= max_w) {
        return ml_text_draw(c, f, x, y, s, color, scale);
    }

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
        pen += draw_glyph(c, f, idx, pen, y, color, scale);
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
