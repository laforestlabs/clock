/*
 * game_rally.c - the reference game.
 *
 * Two paddles, one ball, integer fixed-point physics. It is deliberately the
 * smallest game that is honest about both things this framework exists to solve:
 * the board must fit any panel (it reads the canvas and lays itself out), and
 * two players must share one host (player 1 left, player 2 right, each on its own
 * controller; an absent side falls back to a deterministic AI so a single player
 * is still playable). The state is plain POD, snapshot/restore are a memcpy, and
 * no RNG is read anywhere: the serve is a fixed flat line and all the angle
 * comes from the paddles. That is the whole
 * point: the same binary runs on a 64x32 clock and a 128x128 mirror, one player
 * or two, and the frames are reproducible from a seed.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mirror/font.h"
#include "mirror/game.h"
#include "mirror/gamerun.h"

/* fixed point: 8 fractional bits, so one pixel is 256 units */
#define FX 8
#define FX_ONE   (1 << FX)
#define FX_PX(x) ((int)((x) << FX))

enum { RALLY_UP = 0, RALLY_DOWN = 1 };

typedef struct {
    int16_t panel_w, panel_h;
    int16_t paddle_h;
    int16_t paddle_w;
    int16_t face[2];        /* x of the playing face of each paddle */
    int16_t paddle_y[2];   /* top y, integer px */
    int16_t paddle_v[2];   /* px/tick, integer */
    int32_t bx, by;        /* ball position, Q8.8 */
    int32_t bvx, bvy;      /* ball velocity, Q8.8 px/tick */
    uint16_t score[2];
    uint8_t  present;       /* bitmask: bit0 player1, bit1 player2 */
    uint8_t  held[2];       /* per side: bit0 Up held, bit1 Down held */
    uint8_t  serve_to;      /* 0 or 1, who serves next; 2 = ball live */
} rally_state;

static const ml_control_def rally_controls[] = {
    { .label = "Up",   .code = RALLY_UP,   .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "Down", .code = RALLY_DOWN, .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
};

static int clampi(int v, int lo, int hi)
{
    return v < lo ? lo : (v > hi ? hi : v);
}

/* px/tick at the 25ms tick: 1 on a 32px panel, scaling with height. The same
 * px/s as h/16 gave at the old 50ms tick, but in single-pixel steps. */
static int paddle_speed(int h) { int s = h / 32; return s < 1 ? 1 : s; }
static int ball_speed(int w)
{
    /* Constant px/tick regardless of panel size, so a 128-wide panel
     * is no faster than a 64-wide one. The panel width only changes how long
     * a rally lasts, not how fast the ball flies past you. */
    (void)w;
    return 1;
}

static void serve(rally_state *s, int to)
{
    s->bx = (s->panel_w / 2) << FX;
    s->by = (s->panel_h / 2) << FX;
    /* 0.75 px/tick: 30 px/s at the 25ms tick, the pace the old 1.5 px/tick
     * had at 50ms. */
    int spd = ball_speed(s->panel_w) * FX_ONE * 3 / 4;
    int dir = (to == 0) ? -1 : 1;
    s->bvx = dir * spd;
    /* Flat serve straight across the middle: the opening shot is always the
     * same line, and angle enters the rally only through the paddles. */
    s->bvy = 0;
    s->serve_to = 2;                                /* ball live */
}

static void rally_init(void *state, const ml_game_cfg *cfg, ml_game_ctx *ctx)
{
    (void)ctx;
    rally_state *s = state;
    memset(s, 0, sizeof(*s));
    s->panel_w = (int16_t)cfg->panel_w;
    s->panel_h = (int16_t)cfg->panel_h;
    s->paddle_w = 2;
    s->paddle_h = (int16_t)clampi(s->panel_h / 4, 4, s->panel_h - 2);
    s->face[0] = 1 + s->paddle_w;          /* left paddle's right face */
    s->face[1] = s->panel_w - 1 - s->paddle_w; /* right paddle's left face */
}

static void rally_reset(void *state, ml_game_ctx *ctx)
{
    (void)ctx;
    rally_state *s = state;
    int16_t ph = s->paddle_h;
    s->paddle_y[0] = (int16_t)((s->panel_h - ph) / 2);
    s->paddle_y[1] = (int16_t)((s->panel_h - ph) / 2);
    s->paddle_v[0] = 0;
    s->paddle_v[1] = 0;
    s->held[0] = 0;
    s->held[1] = 0;
    s->score[0] = 0;
    s->score[1] = 0;
    s->serve_to = 0;
    serve(s, 0);
}

static void rally_join(void *state, const ml_player_caps *p, ml_game_ctx *ctx)
{
    (void)ctx;
    rally_state *s = state;
    if (!p) return;
    int idx = p->id - 1;        /* player 1 -> left (0), player 2 -> right (1) */
    if (idx < 0 || idx > 1) return;
    s->present |= (uint8_t)(1u << idx);
}

static void rally_leave(void *state, uint16_t player_id, ml_game_ctx *ctx)
{
    (void)ctx;
    rally_state *s = state;
    int idx = (int)player_id - 1;
    if (idx < 0 || idx > 1) return;
    s->present &= (uint8_t)~(1u << idx);
}

static void rally_input(void *state, const ml_input_event *e, ml_game_ctx *ctx)
{
    (void)ctx;
    rally_state *s = state;
    int idx = (int)e->player_id - 1;
    if (idx < 0 || idx > 1) return;
    /* Track which buttons are held and derive velocity from the pair. A
     * released event must not clobber the other button's press: hosts feed
     * the full held state every frame (Up then Down), and a momentary
     * set-to-zero here would erase the Up velocity every time. */
    uint8_t mask;
    if (e->code == RALLY_UP)        mask = 1u;
    else if (e->code == RALLY_DOWN) mask = 2u;
    else return;
    if (e->value) s->held[idx] |= mask;
    else          s->held[idx] &= (uint8_t)~mask;
    int sp = paddle_speed(s->panel_h);
    int dir = 0;
    if (s->held[idx] & 1u) dir -= 1;
    if (s->held[idx] & 2u) dir += 1;
    s->paddle_v[idx] = (int16_t)(dir * sp);
}

/* A side with no live controller becomes a deterministic chaser: it eases
 * toward the ball's y. Same on every host, no RNG, so it stays a fair wall.
 * Held to half the player's paddle speed so a human can outpace it, unlike a
 * perfect AI that would track the ball at paddle speed and never miss. */
static void ai_move(rally_state *s, int idx, uint32_t tick)
{
    int ph = s->paddle_h;
    int target = (int)((s->by >> FX) - ph / 2);
    int dy = target - s->paddle_y[idx];
    int sp = paddle_speed(s->panel_h) / 2;
    if (sp < 1) {
        /* Half of 1 px/tick, as a pixel step on alternate ticks. */
        if (tick & 1u) return;
        sp = 1;
    }
    if (dy > 0) s->paddle_y[idx] += sp;
    else if (dy < 0) s->paddle_y[idx] -= sp;
}

/* Bounce off paddle idx. Where on the paddle the ball hits steers the
 * vertical direction: the offset from the paddle's centre, normalised so a
 * hit at the very edge adds half a px/tick, biases the bounce up or down while
 * a centre hit leaves the incoming angle alone. The paddle's own motion still
 * adds on top, so a moving paddle imparts extra spin either way. */
static void paddle_bounce(rally_state *s, int idx, int byp)
{
    int ph = s->paddle_h;
    int rel = byp - (s->paddle_y[idx] + ph / 2);
    s->bvx = -s->bvx;
    s->bvy += (rel * FX_ONE) / ph;
    s->bvy += s->paddle_v[idx] * FX_ONE;
}

static void rally_update(void *state, ml_game_ctx *ctx)
{
    rally_state *s = state;
    int ph = s->paddle_h;

    /* paddles */
    for (int i = 0; i < 2; i++) {
        if (s->present & (1u << i)) s->paddle_y[i] += s->paddle_v[i];
        else                        ai_move(s, i, ml_ctx_tick(ctx));
        s->paddle_y[i] = (int16_t)clampi(s->paddle_y[i], 0, s->panel_h - ph);
    }

    /* ball */
    s->bx += s->bvx;
    s->by += s->bvy;

    int bxp = (int)(s->bx >> FX);
    int byp = (int)(s->by >> FX);

    /* top/bottom walls */
    if (byp <= 0) { s->by = 0; s->bvy = -s->bvy; }
    if (byp >= s->panel_h - 1) { s->by = (s->panel_h - 1) << FX; s->bvy = -s->bvy; }

    /* left paddle / left wall */
    if (s->bvx < 0 && bxp <= s->face[0] && bxp >= s->face[0] - 2) {
        if (byp >= s->paddle_y[0] && byp <= s->paddle_y[0] + ph)
            paddle_bounce(s, 0, byp);
    }
    if (bxp < 0) {              /* left miss -> player 2 scores */
        s->score[1]++;
        serve(s, 1);
        return;
    }

    /* right paddle / right wall */
    if (s->bvx > 0 && bxp >= s->face[1] && bxp <= s->face[1] + 2) {
        if (byp >= s->paddle_y[1] && byp <= s->paddle_y[1] + ph)
            paddle_bounce(s, 1, byp);
    }
    if (bxp >= s->panel_w) {    /* right miss -> player 1 scores */
        s->score[0]++;
        serve(s, 0);
        return;
    }

    /* clamp the vertical speed so a rally can't send the ball straight
     * across; twice the horizontal speed, the same ceiling angle as before */
    int max_v = 3 * FX_ONE / 2;
    if (s->bvy >  max_v) s->bvy =  max_v;
    if (s->bvy < -max_v) s->bvy = -max_v;
}

static void rally_draw(const void *state, const ml_view *view, ml_canvas *c,
                       const ml_game_ctx *ctx)
{
    (void)view; (void)ctx;
    const rally_state *s = state;
    ml_canvas_clear(c, ml_black);

    int W = c->w, H = c->h;
    int ph = s->paddle_h;

    char buf[8];
    ml_rgb cyan = ML_RGB(0, 229, 255);
    ml_rgb mag  = ML_RGB(255, 0, 128);
    ml_rgb white = ML_RGB(220, 220, 220);
    ml_rgb net = ML_RGB(40, 40, 40);

    /* dashed centre net */
    for (int y = 1; y < H - 1; y += 2)
        ml_canvas_set(c, W / 2, y, net);

    /* paddles */
    for (int x = 0; x < s->paddle_w; x++) {
        for (int y = 0; y < ph; y++) {
            ml_canvas_set(c, 1 + x, s->paddle_y[0] + y, cyan);
            ml_canvas_set(c, W - 1 - s->paddle_w + x, s->paddle_y[1] + y, mag);
        }
    }

    /* ball */
    int bxp = (int)(s->bx >> FX);
    int byp = (int)(s->by >> FX);
    if (bxp >= 0 && bxp < W && byp >= 0 && byp < H)
        ml_canvas_set(c, bxp, byp, white);

    /* scores in the tallest digit font that fits, at the top but set inward
     * of the paddles rather than tucked into the corners behind them */
    const ml_font *f = ml_font_find("digits10");
    if (!f) f = ml_font_default();
    const int fs = ML_SCALE_1X;
    snprintf(buf, sizeof(buf), "%u", (unsigned)s->score[0]);
    ml_text_draw(c, f, s->face[0] + 2, 1, buf, cyan, fs);
    snprintf(buf, sizeof(buf), "%u", (unsigned)s->score[1]);
    int rw = ml_text_width(f, buf, fs);
    ml_text_draw(c, f, s->face[1] - 2 - rw, 1, buf, mag, fs);
}

static bool rally_snapshot(const void *state, uint8_t *buf, size_t cap, size_t *len)
{
    if (cap < sizeof(rally_state)) return false;
    memcpy(buf, state, sizeof(rally_state));
    *len = sizeof(rally_state);
    return true;
}

static void rally_restore(void *state, const uint8_t *buf, size_t len)
{
    size_t n = len < sizeof(rally_state) ? len : sizeof(rally_state);
    memcpy(state, buf, n);
}

const ml_game_vt ml_game_rally = {
    .id            = "rally",
    .pref_w        = 0, .pref_h = 0,
    .tick_ms       = 25,
    .max_players   = 2,
    .state_size    = sizeof(rally_state),
    .controls      = rally_controls,
    .control_count = 2,
    .init          = rally_init,
    .reset         = rally_reset,
    .join          = rally_join,
    .leave         = rally_leave,
    .input         = rally_input,
    .update        = rally_update,
    .draw          = rally_draw,
    .snapshot      = rally_snapshot,
    .restore       = rally_restore,
};