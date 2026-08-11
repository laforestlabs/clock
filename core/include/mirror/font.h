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

/*
 * What a font is for. Declared by @role in the .font source.
 *
 * This is the one thing about a font its bitmaps cannot imply. A clock face and
 * an icon set both carry nothing but the digits, so asking "which fonts can
 * draw 23?" puts a numeral and a rain cloud in the same bucket and then picks
 * between them on height. Coverage answers what a font can draw; only the role
 * answers whether the result would be text.
 */
typedef enum {
    ML_FONT_TEXT = 0,  /* full printable range, safe for any string */
    ML_FONT_DIGITS,    /* clock and temperature faces: digits and a little punctuation */
    ML_FONT_ICONS      /* pictograms indexed by digit, never text */
} ml_font_role;

typedef struct {
    const char     *name;
    ml_font_role    role;
    uint8_t         first;     /* codepoint of glyph 0, normally 32 (space) */
    uint16_t        count;     /* number of glyphs */
    uint8_t         height;    /* rows per glyph */
    uint8_t         baseline;  /* rows from top to the text baseline */
    uint8_t         gap;       /* horizontal pixels inserted between glyphs */
    const uint8_t  *widths;    /* [count] ink width of each glyph */
    const uint16_t *offsets;   /* [count] byte offset of each glyph in bitmap */
    const uint8_t  *bitmap;    /* packed glyph rows */
    /*
     * The style this cut belongs to, e.g. "sans" or "digits". A layout that
     * names a family lets the engine pick the cut that fills the box; naming
     * an individual cut still pins exactly that cut.
     */
    const char     *family;
    /*
     * Whether fractional scales anti-alias. Smooth fonts grow a fraction of a
     * pixel at a time; a font with smooth off is deliberately blocky, and a
     * box-derived scale floors to a whole-pixel multiple to keep its hard
     * edges.
     */
    bool            smooth;
    /* This cut is a high-resolution master intended to render below 1x. */
    bool            downscale;
} ml_font;

/* Look up a font by name. Returns NULL if not registered. */
const ml_font *ml_font_find(const char *name);

/*
 * Whether name is a family with at least one registered cut, and not itself
 * the name of a cut. An exact cut always wins over a family of the same name.
 */
bool           ml_font_is_family(const char *name);

/* The font used when a layout names one that does not exist. Never NULL. */
const ml_font *ml_font_default(void);

/* Number of registered fonts, and indexed access, for the designer's font list. */
int            ml_font_count(void);
const ml_font *ml_font_at(int index);

/*
 * Whether this font has a glyph for a byte.
 *
 * Fonts cover different ranges: the clock faces carry 45 to 58 and nothing
 * else, wx16 carries ten icons. Drawing skips what it cannot find, so a font
 * asked for the wrong string quietly renders a shorter one. This lets a caller
 * ask first, which is how automatic font choice tells a body font from a clock
 * face without either of them having to declare a size or a family.
 *
 * Coverage cannot separate a clock face from an icon set, since the digits are
 * all either one carries. That is what ml_font_role is for.
 */
bool           ml_font_has_glyph(const ml_font *f, unsigned char ch);

/* Whether every byte of s has a glyph, so drawing s loses nothing. */
bool           ml_font_covers(const ml_font *f, const char *s);

/*
 * Scale is fixed-point with 8 fractional bits: ML_SCALE_1X draws unscaled,
 * 2 * ML_SCALE_1X doubles, and anything in between is a fractional scale.
 * ML_SCALE_MIN is the smallest supported render. Allowing fitted text below
 * 1x lets one high-resolution source face scale down cleanly instead of
 * switching among unrelated bitmap cuts as a box is dragged.
 *
 * A whole multiple of ML_SCALE_1X replicates each glyph pixel into a block,
 * exactly as bitmap fonts have always grown here. A fractional scale instead
 * anti-aliases: a source pixel straddling destination pixels inks each in
 * proportion to the area it covers. The coverage math is exact integer
 * arithmetic, so the panel and the preview still agree pixel for pixel, but
 * a box-derived scale can now grow text one panel pixel at a time instead of
 * jumping between whole multiples.
 */
#define ML_SCALE_1X 256
#define ML_SCALE_MIN 32

/* Advance width of a string in pixels, including inter-glyph gaps. */
int ml_text_width(const ml_font *f, const char *s, int scale_q8);

/* Height of one line in pixels at this scale. */
int ml_text_height(const ml_font *f, int scale_q8);

/*
 * Draw text with its top-left corner at (x, y). Returns the advance width.
 * Respects the canvas clip, so callers do not need to pre-truncate.
 */
int ml_text_draw(ml_canvas *c, const ml_font *f, int x, int y,
                 const char *s, ml_rgb color, int scale_q8);

/*
 * Draw text truncated to max_w pixels, appending a one-pixel ellipsis marker if
 * it did not fit. Used by the agenda and todo widgets, where entries routinely
 * overflow a 64px column.
 */
int ml_text_draw_clipped(ml_canvas *c, const ml_font *f, int x, int y,
                         int max_w, const char *s, ml_rgb color, int scale_q8);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_FONT_H */
