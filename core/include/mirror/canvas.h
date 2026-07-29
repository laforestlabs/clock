/*
 * canvas.h - RGB888 framebuffer with a small clip stack.
 *
 * The canvas never allocates unless you ask it to. On the device the pixel
 * storage is caller-provided so it can live in a specific memory region; on the
 * host the CLI harness lets it malloc.
 */
#ifndef MIRROR_CANVAS_H
#define MIRROR_CANVAS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "mirror/color.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int16_t x, y, w, h;
} ml_rect;

#define ML_RECT(xx, yy, ww, hh) \
    ((ml_rect){(int16_t)(xx), (int16_t)(yy), (int16_t)(ww), (int16_t)(hh)})

/* Intersection of two rects. Result may have w or h <= 0, meaning empty. */
ml_rect ml_rect_intersect(ml_rect a, ml_rect b);
bool    ml_rect_is_empty(ml_rect r);
bool    ml_rect_contains(ml_rect r, int x, int y);

#define ML_CLIP_STACK_DEPTH 8

typedef struct {
    int      w, h;
    ml_rgb  *px;    /* w*h pixels, row major, top-left origin */
    bool     owns;  /* true when ml_canvas_init allocated px */

    ml_rect  clip;
    ml_rect  clip_stack[ML_CLIP_STACK_DEPTH];
    int      clip_depth;
} ml_canvas;

/*
 * Initialize a canvas. Pass storage = NULL to malloc w*h pixels, or point it at
 * caller-owned memory of at least w*h ml_rgb. Returns false on bad dimensions
 * or allocation failure.
 */
bool ml_canvas_init(ml_canvas *c, int w, int h, ml_rgb *storage);
void ml_canvas_free(ml_canvas *c);

void ml_canvas_clear(ml_canvas *c, ml_rgb color);

/* Bounds-checked and clip-checked. Out-of-range writes are silently dropped. */
void   ml_canvas_set(ml_canvas *c, int x, int y, ml_rgb color);
ml_rgb ml_canvas_get(const ml_canvas *c, int x, int y);

/* Alpha in 0..255. 0 leaves the destination untouched, 255 replaces it. */
void ml_canvas_blend(ml_canvas *c, int x, int y, ml_rgb color, uint8_t alpha);

void ml_canvas_fill_rect(ml_canvas *c, ml_rect r, ml_rgb color);
void ml_canvas_draw_rect(ml_canvas *c, ml_rect r, ml_rgb color);
void ml_canvas_hline(ml_canvas *c, int x, int y, int len, ml_rgb color);
void ml_canvas_vline(ml_canvas *c, int x, int y, int len, ml_rgb color);

/*
 * Clip stack. Pushing intersects with the current clip, so a child can never
 * draw outside its parent. Pushing past ML_CLIP_STACK_DEPTH is a no-op that
 * returns false rather than corrupting the stack.
 */
bool ml_canvas_push_clip(ml_canvas *c, ml_rect r);
void ml_canvas_pop_clip(ml_canvas *c);

/*
 * Copy out as gamma-corrected packed RGB888 bytes, which is what the panel
 * wants and what the golden-image tests compare. dst must hold w*h*3 bytes.
 */
void ml_canvas_export_rgb888(const ml_canvas *c, uint8_t brightness, uint8_t *dst);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_CANVAS_H */
