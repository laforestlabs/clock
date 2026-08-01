/*
 * view.c - fit a game's logical space into a physical panel.
 *
 * Pure arithmetic, no allocation. The runtime calls ml_view_compute before each
 * draw and passes the result in; games draw inside the active rect at the view's
 * scale and offset. Adaptive (the panel-shaped case) is the fast path: the
 * logical size is the panel size, scale is 1, and the host render path draws
 * straight into the panel canvas without a temp buffer.
 */
#include "mirror/game.h"

void ml_view_compute(ml_view *v, int pref_w, int pref_h, ml_fit_mode fit,
                     int pw, int ph)
{
    int lw, lh;            /* logical size */
    int sx, sy;            /* per-axis integer scale */

    v->pref_w = pref_w;
    v->pref_h = pref_h;

    if (fit == ML_FIT_ADAPTIVE || pref_w <= 0 || pref_h <= 0) {
        /* The game reads the canvas and lays itself out. */
        v->pref_w = lw = pw;
        v->pref_h = lh = ph;
        v->sx = v->sy = 1;
        v->ox = v->oy = 0;
        v->active = ML_RECT(0, 0, pw, ph);
        return;
    }

    lw = pref_w;
    lh = pref_h;

    switch (fit) {
    case ML_FIT_LETTERBOX: {
        /* Largest integer multiple that fits both axes; centred. */
        sx = (lw > 0) ? pw / lw : 1;
        sy = (lh > 0) ? ph / lh : 1;
        if (sx < 1) sx = 1;
        if (sy < 1) sy = 1;
        /* Letterbox keeps aspect: use the smaller scale on both axes. */
        int s = (sx < sy) ? sx : sy;
        sx = sy = s;
        v->sx = sx;
        v->sy = sy;
        v->ox = (pw - lw * sx) / 2;
        v->oy = (ph - lh * sy) / 2;
        break;
    }
    case ML_FIT_STRETCH: {
        /* Non-integer nearest fit on each axis; blurs aspect by design. */
        sx = (lw > 0) ? pw / lw : 1;
        sy = (lh > 0) ? ph / lh : 1;
        if (sx < 1) sx = 1;
        if (sy < 1) sy = 1;
        v->sx = sx;
        v->sy = sy;
        v->ox = (pw - lw * sx) / 2;
        v->oy = (ph - lh * sy) / 2;
        break;
    }
    case ML_FIT_CLIP:
    default: {
        /* 1:1 at the origin; anything past the panel is clipped by the canvas. */
        v->sx = v->sy = 1;
        v->ox = v->oy = 0;
        break;
    }
    }

    ml_rect r = ML_RECT(v->ox, v->oy, lw * v->sx, lh * v->sy);
    /* Active is the visible portion; intersect with the panel. */
    v->active = ml_rect_intersect(r, ML_RECT(0, 0, pw, ph));
}