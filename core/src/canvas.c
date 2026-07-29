#include "mirror/canvas.h"

#include <stdlib.h>
#include <string.h>

ml_rect ml_rect_intersect(ml_rect a, ml_rect b)
{
    int ax0 = a.x, ay0 = a.y, ax1 = a.x + a.w, ay1 = a.y + a.h;
    int bx0 = b.x, by0 = b.y, bx1 = b.x + b.w, by1 = b.y + b.h;

    int x0 = ax0 > bx0 ? ax0 : bx0;
    int y0 = ay0 > by0 ? ay0 : by0;
    int x1 = ax1 < bx1 ? ax1 : bx1;
    int y1 = ay1 < by1 ? ay1 : by1;

    if (x1 < x0) x1 = x0;
    if (y1 < y0) y1 = y0;

    return ML_RECT(x0, y0, x1 - x0, y1 - y0);
}

bool ml_rect_is_empty(ml_rect r)
{
    return r.w <= 0 || r.h <= 0;
}

bool ml_rect_contains(ml_rect r, int x, int y)
{
    return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h;
}

bool ml_canvas_init(ml_canvas *c, int w, int h, ml_rgb *storage)
{
    if (!c || w <= 0 || h <= 0) return false;

    /* Guard against absurd sizes so a malformed layout cannot request a
     * gigabyte allocation on a device with 512KB of SRAM. */
    if (w > 4096 || h > 4096) return false;

    memset(c, 0, sizeof(*c));
    c->w = w;
    c->h = h;

    if (storage) {
        c->px = storage;
        c->owns = false;
    } else {
        c->px = (ml_rgb *)calloc((size_t)w * (size_t)h, sizeof(ml_rgb));
        if (!c->px) return false;
        c->owns = true;
    }

    c->clip = ML_RECT(0, 0, w, h);
    c->clip_depth = 0;
    return true;
}

void ml_canvas_free(ml_canvas *c)
{
    if (!c) return;
    if (c->owns && c->px) free(c->px);
    c->px = NULL;
    c->owns = false;
    c->w = c->h = 0;
}

void ml_canvas_clear(ml_canvas *c, ml_rgb color)
{
    if (!c || !c->px) return;

    size_t n = (size_t)c->w * (size_t)c->h;
    if (color.r == color.g && color.g == color.b) {
        /* Uniform gray, including the common black case, packs to a memset. */
        memset(c->px, color.r, n * sizeof(ml_rgb));
        return;
    }
    for (size_t i = 0; i < n; i++) c->px[i] = color;
}

void ml_canvas_set(ml_canvas *c, int x, int y, ml_rgb color)
{
    if (!c || !c->px) return;
    if (!ml_rect_contains(c->clip, x, y)) return;
    if (x < 0 || y < 0 || x >= c->w || y >= c->h) return;
    c->px[(size_t)y * (size_t)c->w + (size_t)x] = color;
}

ml_rgb ml_canvas_get(const ml_canvas *c, int x, int y)
{
    if (!c || !c->px || x < 0 || y < 0 || x >= c->w || y >= c->h) return ml_black;
    return c->px[(size_t)y * (size_t)c->w + (size_t)x];
}

void ml_canvas_blend(ml_canvas *c, int x, int y, ml_rgb color, uint8_t alpha)
{
    if (alpha == 0) return;
    if (alpha == 255) {
        ml_canvas_set(c, x, y, color);
        return;
    }
    if (!c || !c->px) return;
    if (!ml_rect_contains(c->clip, x, y)) return;
    if (x < 0 || y < 0 || x >= c->w || y >= c->h) return;

    ml_rgb *dst = &c->px[(size_t)y * (size_t)c->w + (size_t)x];
    dst->r = (uint8_t)((color.r * alpha + dst->r * (255 - alpha) + 127) / 255);
    dst->g = (uint8_t)((color.g * alpha + dst->g * (255 - alpha) + 127) / 255);
    dst->b = (uint8_t)((color.b * alpha + dst->b * (255 - alpha) + 127) / 255);
}

void ml_canvas_fill_rect(ml_canvas *c, ml_rect r, ml_rgb color)
{
    if (!c || !c->px) return;

    ml_rect a = ml_rect_intersect(r, c->clip);
    a = ml_rect_intersect(a, ML_RECT(0, 0, c->w, c->h));
    if (ml_rect_is_empty(a)) return;

    for (int y = a.y; y < a.y + a.h; y++) {
        ml_rgb *row = &c->px[(size_t)y * (size_t)c->w];
        for (int x = a.x; x < a.x + a.w; x++) row[x] = color;
    }
}

void ml_canvas_draw_rect(ml_canvas *c, ml_rect r, ml_rgb color)
{
    if (!c || r.w <= 0 || r.h <= 0) return;
    ml_canvas_hline(c, r.x, r.y, r.w, color);
    ml_canvas_hline(c, r.x, r.y + r.h - 1, r.w, color);
    ml_canvas_vline(c, r.x, r.y, r.h, color);
    ml_canvas_vline(c, r.x + r.w - 1, r.y, r.h, color);
}

void ml_canvas_hline(ml_canvas *c, int x, int y, int len, ml_rgb color)
{
    if (len <= 0) return;
    ml_canvas_fill_rect(c, ML_RECT(x, y, len, 1), color);
}

void ml_canvas_vline(ml_canvas *c, int x, int y, int len, ml_rgb color)
{
    if (len <= 0) return;
    ml_canvas_fill_rect(c, ML_RECT(x, y, 1, len), color);
}

bool ml_canvas_push_clip(ml_canvas *c, ml_rect r)
{
    if (!c) return false;
    if (c->clip_depth >= ML_CLIP_STACK_DEPTH) return false;

    c->clip_stack[c->clip_depth++] = c->clip;
    /* Intersect rather than replace, so a child can never escape its parent. */
    c->clip = ml_rect_intersect(c->clip, r);
    return true;
}

void ml_canvas_pop_clip(ml_canvas *c)
{
    if (!c || c->clip_depth <= 0) return;
    c->clip = c->clip_stack[--c->clip_depth];
}

void ml_canvas_export_rgb888(const ml_canvas *c, uint8_t brightness, uint8_t *dst)
{
    if (!c || !c->px || !dst) return;

    size_t n = (size_t)c->w * (size_t)c->h;
    for (size_t i = 0; i < n; i++) {
        /* Brightness scales in linear space, then gamma maps to what the LED
         * drivers actually receive. Order matters: gamma last. */
        ml_rgb p = ml_rgb_scale(c->px[i], brightness);
        dst[i * 3 + 0] = ml_gamma8(p.r);
        dst[i * 3 + 1] = ml_gamma8(p.g);
        dst[i * 3 + 2] = ml_gamma8(p.b);
    }
}
