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
    /* fontgen sorts by cell height, so entry zero is the smallest font and the
     * safest fallback: it fits anywhere a larger one would have. */
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

int ml_text_width(const ml_font *f, const char *s)
{
    if (!f || !s) return 0;

    int total = 0;
    bool first = true;
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        int idx = glyph_index(f, *p);
        if (idx < 0) continue;
        if (!first) total += f->gap;
        total += f->widths[idx];
        first = false;
    }
    return total;
}

/* Blit one glyph with its top-left at (x, y). Returns the ink width. */
static int draw_glyph(ml_canvas *c, const ml_font *f, int idx,
                      int x, int y, ml_rgb color)
{
    int width  = f->widths[idx];
    int stride = (width + 7) / 8;
    const uint8_t *bits = &f->bitmap[f->offsets[idx]];

    for (int row = 0; row < f->height; row++) {
        const uint8_t *rowbits = bits + (size_t)row * (size_t)stride;
        int py = y + row;

        /* Cheap reject: whole rows above or below the clip cost nothing. */
        if (py < c->clip.y || py >= c->clip.y + c->clip.h) continue;

        for (int col = 0; col < width; col++) {
            if (rowbits[col >> 3] & (0x80u >> (col & 7))) {
                ml_canvas_set(c, x + col, py, color);
            }
        }
    }
    return width;
}

int ml_text_draw(ml_canvas *c, const ml_font *f, int x, int y,
                 const char *s, ml_rgb color)
{
    if (!c || !f || !s) return 0;

    int pen = x;
    bool first = true;
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        int idx = glyph_index(f, *p);
        if (idx < 0) continue;
        if (!first) pen += f->gap;
        pen += draw_glyph(c, f, idx, pen, y, color);
        first = false;
    }
    return pen - x;
}

int ml_text_draw_clipped(ml_canvas *c, const ml_font *f, int x, int y,
                         int max_w, const char *s, ml_rgb color)
{
    if (!c || !f || !s || max_w <= 0) return 0;

    /* Fast path: it fits, so draw it whole and skip the truncation logic. */
    if (ml_text_width(f, s) <= max_w) {
        return ml_text_draw(c, f, x, y, s, color);
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
    const int marker_w = 4;
    int budget = max_w - marker_w;
    if (budget < 0) budget = 0;

    int pen = x;
    bool first = true;
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        int idx = glyph_index(f, *p);
        if (idx < 0) continue;

        int advance = f->widths[idx] + (first ? 0 : f->gap);
        if (pen - x + advance > budget) break;

        if (!first) pen += f->gap;
        pen += draw_glyph(c, f, idx, pen, y, color);
        first = false;
    }

    /* Two dots on the baseline row. One pixel would vanish, three would not fit. */
    int marker_y = y + f->baseline - 1;
    if (marker_y >= y + f->height) marker_y = y + f->height - 1;
    ml_canvas_set(c, pen + 1, marker_y, color);
    ml_canvas_set(c, pen + 3, marker_y, color);

    return (pen + 4) - x;
}
