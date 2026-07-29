/*
 * font.h - bitmap fonts.
 *
 * Fonts are generated from human-editable ASCII-art sources in the top-level
 * fonts directory by tools/fontgen.py, which emits the C tables into
 * core/src/fonts. Do not hand edit the generated tables; edit the .font
 * source and regenerate.
 *
 * Glyph bitmaps are row-major, one bit per pixel, MSB first, with each row
 * padded up to a whole number of bytes. So a 5px wide glyph uses 1 byte per
 * row, a 12px wide glyph uses 2.
 */
#ifndef MIRROR_FONT_H
#define MIRROR_FONT_H

#include <stdbool.h>
#include <stdint.h>

#include "mirror/canvas.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    const char     *name;
    uint8_t         first;     /* codepoint of glyph 0, normally 32 (space) */
    uint16_t        count;     /* number of glyphs */
    uint8_t         height;    /* rows per glyph */
    uint8_t         baseline;  /* rows from top to the text baseline */
    uint8_t         gap;       /* horizontal pixels inserted between glyphs */
    const uint8_t  *widths;    /* [count] ink width of each glyph */
    const uint16_t *offsets;   /* [count] byte offset of each glyph in bitmap */
    const uint8_t  *bitmap;    /* packed glyph rows */
} ml_font;

/* Look up a font by name. Returns NULL if not registered. */
const ml_font *ml_font_find(const char *name);

/* The font used when a layout names one that does not exist. Never NULL. */
const ml_font *ml_font_default(void);

/* Number of registered fonts, and indexed access, for the designer's font list. */
int            ml_font_count(void);
const ml_font *ml_font_at(int index);

/* Advance width of a string in pixels, including inter-glyph gaps. */
int ml_text_width(const ml_font *f, const char *s);

/*
 * Draw text with its top-left corner at (x, y). Returns the advance width.
 * Respects the canvas clip, so callers do not need to pre-truncate.
 */
int ml_text_draw(ml_canvas *c, const ml_font *f, int x, int y,
                 const char *s, ml_rgb color);

/*
 * Draw text truncated to max_w pixels, appending a one-pixel ellipsis marker if
 * it did not fit. Used by the agenda and todo widgets, where entries routinely
 * overflow a 64px column.
 */
int ml_text_draw_clipped(ml_canvas *c, const ml_font *f, int x, int y,
                         int max_w, const char *s, ml_rgb color);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_FONT_H */
