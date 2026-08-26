/*
 * game_probe.c - a developer diagnostic: a red circle driven by raw input.
 *
 * Not a game in the usual sense: there is no win state and no score. The
 * circle is a probe for the phone controller path. Four direction buttons
 * step it by one speed unit per tick while held, and two analog axes
 * (TiltX/TiltY) move it proportionally to the phone's tilt. Running it while
 * watching the mirror shows, at a glance, how responsive the BLE input path
 * is and whether the motion mapping (dead zones, calibration, sign of each
 * axis) is correct.
 *
 * It deliberately takes both button and axis controls: manual mode drives the
 * buttons, motion mode drives the axes, and the same binary shows both. The
 * circle never ends, so is_over is NULL.
 */
#include <string.h>

#include "mirror/game.h"

/* fixed point: 8 fractional bits, so one pixel is 256 units */
#define FX 8
#define FX_ONE (1 << FX)

enum {
    PROBE_UP = 0,
    PROBE_DOWN,
    PROBE_LEFT,
    PROBE_RIGHT,
    PROBE_TILT_X,
    PROBE_TILT_Y,
};

typedef struct {
    int16_t panel_w, panel_h;
    int16_t radius;
    int32_t x, y;            /* circle centre, Q8.8 */
    uint8_t held_up, held_down, held_left, held_right;
    int16_t tilt_x, tilt_y;  /* most recent axis values */
} probe_state;

static const ml_control_def probe_controls[] = {
    { .label = "Up",    .code = PROBE_UP,    .caps = ML_CAP_DPAD,  .type = ML_INPUT_BUTTON },
    { .label = "Down",  .code = PROBE_DOWN,  .caps = ML_CAP_DPAD,  .type = ML_INPUT_BUTTON },
    { .label = "Left",  .code = PROBE_LEFT,  .caps = ML_CAP_DPAD,  .type = ML_INPUT_BUTTON },
    { .label = "Right", .code = PROBE_RIGHT, .caps = ML_CAP_DPAD,  .type = ML_INPUT_BUTTON },
    { .label = "TiltX", .code = PROBE_TILT_X, .caps = ML_CAP_ACCEL, .type = ML_INPUT_AXIS },
    { .label = "TiltY", .code = PROBE_TILT_Y, .caps = ML_CAP_ACCEL, .type = ML_INPUT_AXIS },
};

static void probe_fill_circle(ml_canvas *c, int cx, int cy, int r, ml_rgb color)
{
    if (r < 1) {
        ml_canvas_set(c, cx, cy, color);
        return;
    }
    int x = r, y = 0;
    int err = 1 - r;
    while (x >= y) {
        ml_canvas_hline(c, cx - x, cy + y, 2 * x + 1, color);
        ml_canvas_hline(c, cx - x, cy - y, 2 * x + 1, color);
        ml_canvas_hline(c, cx - y, cy + x, 2 * y + 1, color);
        ml_canvas_hline(c, cx - y, cy - x, 2 * y + 1, color);
        y++;
        if (err < 0) {
            err += 2 * y + 1;
        } else {
            x--;
            err += 2 * (y - x) + 1;
        }
    }
}

static int probe_speed(const probe_state *s)
{
    const int m = s->panel_w < s->panel_h ? s->panel_w : s->panel_h;
    const int sp = m / 16;
    return sp < 1 ? 1 : sp;
}

static void probe_init(void *state, const ml_game_cfg *cfg, ml_game_ctx *ctx)
{
    (void)ctx;
    probe_state *s = state;
    memset(s, 0, sizeof(*s));
    s->panel_w = (int16_t)cfg->panel_w;
    s->panel_h = (int16_t)cfg->panel_h;
    const int m = s->panel_w < s->panel_h ? s->panel_w : s->panel_h;
    s->radius = (int16_t)(m / 12);
    if (s->radius < 2) s->radius = 2;
}

static void probe_reset(void *state, ml_game_ctx *ctx)
{
    (void)ctx;
    probe_state *s = state;
    s->x = ((int32_t)s->panel_w / 2) << FX;
    s->y = ((int32_t)s->panel_h / 2) << FX;
    s->held_up = s->held_down = s->held_left = s->held_right = 0;
    s->tilt_x = s->tilt_y = 0;
}

static void probe_input(void *state, const ml_input_event *e, ml_game_ctx *ctx)
{
    (void)ctx;
    probe_state *s = state;
    switch (e->code) {
    case PROBE_UP:    s->held_up    = (uint8_t)(e->value ? 1 : 0); break;
    case PROBE_DOWN:  s->held_down  = (uint8_t)(e->value ? 1 : 0); break;
    case PROBE_LEFT:  s->held_left  = (uint8_t)(e->value ? 1 : 0); break;
    case PROBE_RIGHT: s->held_right = (uint8_t)(e->value ? 1 : 0); break;
    case PROBE_TILT_X: s->tilt_x = e->value; break;
    case PROBE_TILT_Y: s->tilt_y = e->value; break;
    default: break;
    }
}

static void probe_update(void *state, ml_game_ctx *ctx)
{
    (void)ctx;
    probe_state *s = state;
    const int32_t sp = (int32_t)probe_speed(s) << FX;

    int32_t dx = 0, dy = 0;
    if (s->held_left)  dx -= sp;
    if (s->held_right) dx += sp;
    if (s->held_up)    dy -= sp;
    if (s->held_down)  dy += sp;

    /* Axes move the circle proportionally to tilt: full tilt is about one
     * button step per tick, so motion and manual feel comparable. */
    dx += (int32_t)s->tilt_x * sp / 32768;
    dy += (int32_t)s->tilt_y * sp / 32768;

    s->x += dx;
    s->y += dy;

    const int32_t r = (int32_t)s->radius << FX;
    const int32_t minx = r;
    const int32_t maxx = ((int32_t)s->panel_w << FX) - r;
    const int32_t miny = r;
    const int32_t maxy = ((int32_t)s->panel_h << FX) - r;
    if (s->x < minx) s->x = minx;
    else if (s->x > maxx) s->x = maxx;
    if (s->y < miny) s->y = miny;
    else if (s->y > maxy) s->y = maxy;
}

static void probe_draw(const void *state, const ml_view *view, ml_canvas *c,
                       const ml_game_ctx *ctx)
{
    (void)view; (void)ctx;
    const probe_state *s = state;
    ml_canvas_clear(c, ml_black);

    const int cx = (int)(s->x >> FX);
    const int cy = (int)(s->y >> FX);
    const int r = s->radius;

    /* Centre crosshair so the dead zone is visible against the circle. */
    const ml_rgb hair = ML_RGB(40, 40, 40);
    ml_canvas_hline(c, cx - r, cy, 2 * r + 1, hair);
    ml_canvas_vline(c, cx, cy - r, 2 * r + 1, hair);

    probe_fill_circle(c, cx, cy, r, ML_RGB(255, 32, 32));
}

static bool probe_snapshot(const void *state, uint8_t *buf, size_t cap, size_t *len)
{
    if (cap < sizeof(probe_state)) return false;
    memcpy(buf, state, sizeof(probe_state));
    *len = sizeof(probe_state);
    return true;
}

static void probe_restore(void *state, const uint8_t *buf, size_t len)
{
    const size_t n = len < sizeof(probe_state) ? len : sizeof(probe_state);
    memcpy(state, buf, n);
}

const ml_game_vt ml_game_probe = {
    .id            = "probe",
    .pref_w        = 0, .pref_h = 0,
    .tick_ms       = 25,
    .max_players   = 1,
    .state_size    = sizeof(probe_state),
    .controls      = probe_controls,
    .control_count = 6,
    .init          = probe_init,
    .reset         = probe_reset,
    .input         = probe_input,
    .update        = probe_update,
    .draw          = probe_draw,
    .snapshot      = probe_snapshot,
    .restore       = probe_restore,
};
