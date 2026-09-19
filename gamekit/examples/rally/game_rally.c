/*
 * game_rally.c - the reference game.
 *
 * Two paddles, one ball, integer fixed-point physics. It is the smallest game
 * that is honest about the two things this framework exists to solve: the board
 * is authored for a fixed panel (64x32, the size the hardware ships today; the
 * view letterboxes it onto anything larger), and two players share one host
 * (player 1 left, player 2 right, each on its own controller; an absent side
 * falls back to a deterministic AI so a single player is still playable). Every
 * paddle hit winds the ball up towards twice its serve speed, so a long rally is
 * also a fast one. The state is plain POD, snapshot/restore are a memcpy, and no
 * RNG is read anywhere: the serve is a fixed flat line and all the angle comes
 * from the paddles. One binary, one player or two, frames reproducible from a
 * seed.
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

/* The fastest ball a rally reaches: twice the serve's 0.75 px/tick, so a rally
 * winds up over several hits and then holds a playable pace. */
#define RALLY_SPEED_MAX (FX_ONE * 3 / 2)

enum { RALLY_UP = 0, RALLY_DOWN = 1, RALLY_TILT_Y = 2 };

/* rally is authored for the one panel the hardware ships: 64x32. The view
 * letterboxes this fixed board onto any larger panel; on 64x32 it is 1:1. */
#define RALLY_W 64
#define RALLY_H 32

typedef struct {
    int16_t panel_w, panel_h;
    int16_t paddle_h;
    int16_t paddle_w;
    int16_t face[2];        /* x of the playing face of each paddle */
    int16_t paddle_y[2];   /* top y, integer px */
    int16_t paddle_v[2];   /* px/tick, integer */
    int32_t bx, by;        /* ball position, Q8.8 */
    int32_t bvx, bvy;      /* ball velocity, Q8.8 px/tick */
    int16_t ball_speed;    /* the rally's current horizontal speed, Q8.8 */
    uint16_t score[2];
    uint8_t  present;       /* bitmask: bit0 player1, bit1 player2 */
    uint8_t  held[2];       /* per side: bit0 Up held, bit1 Down held */
    int16_t  tilt_y[2];     /* per side: tilt axis, ML_AXIS_IDLE when unused */
    uint8_t  serve_to;      /* 0 or 1, who serves next; 2 = ball live */
} rally_state;

static const ml_control_def rally_controls[] = {
    { .label = "Up",    .code = RALLY_UP,     .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "Down",  .code = RALLY_DOWN,   .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "TiltY", .code = RALLY_TILT_Y, .caps = ML_CAP_ACCEL,  .type = ML_INPUT_AXIS },
};

static int clampi(int v, int lo, int hi)
{
    return v < lo ? lo : (v > hi ? hi : v);
}

/* 1 px/tick at the 25ms tick: the paddle crosses the 32-row board in 32 ticks,
 * the pace tuned for the 64x32 panel rally targets. */
static int paddle_speed(void) { return 1; }

static void serve(rally_state *s, int to)
{
    s->bx = (s->panel_w / 2) << FX;
    s->by = (s->panel_h / 2) << FX;
    /* 0.75 px/tick: 30 px/s at the 25ms tick. The serve is the slowest ball of a
     * rally; every paddle hit winds it up from here. */
    s->ball_speed = FX_ONE * 3 / 4;
    int dir = (to == 0) ? -1 : 1;
    s->bvx = dir * s->ball_speed;
    /* Flat serve straight across the middle: the opening shot is always the
     * same line, and angle enters the rally only through the paddles. */
    s->bvy = 0;
    s->serve_to = 2;                                /* ball live */
}

static void rally_init(void *state, const ml_game_cfg *cfg, ml_game_ctx *ctx)
{
    (void)cfg; (void)ctx;
    /* Authored for the 64x32 panel regardless of the physical panel it lands
     * on: cfg->panel_w/h is deliberately ignored, and the ML_FIT_LETTERBOX view
     * scales this fixed board onto anything larger (1:1 on the 64x32 it is
     * tuned for, which is the only size the hardware currently ships). */
    rally_state *s = state;
    memset(s, 0, sizeof(*s));
    s->panel_w = RALLY_W;
    s->panel_h = RALLY_H;
    s->paddle_w = 2;
    s->paddle_h = 8;                            /* RALLY_H / 4 */
    s->face[0] = 1 + s->paddle_w;               /* left paddle's right face */
    s->face[1] = s->panel_w - 1 - s->paddle_w;  /* right paddle's left face */
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
    s->tilt_y[0] = ML_AXIS_IDLE;
    s->tilt_y[1] = ML_AXIS_IDLE;
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
    if (e->code == RALLY_TILT_Y) {
        /* The angle the phone is held at, as a position. Stored per side: a
         * second player's tilt must not steer the first player's paddle. */
        s->tilt_y[idx] = e->value;
        return;
    }
    if (e->code == RALLY_UP)        mask = 1u;
    else if (e->code == RALLY_DOWN) mask = 2u;
    else return;
    if (e->value) s->held[idx] |= mask;
    else          s->held[idx] &= (uint8_t)~mask;
    int sp = paddle_speed();
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
    int sp = paddle_speed() / 2;
    if (sp < 1) {
        /* Half of 1 px/tick, as a pixel step on alternate ticks. */
        if (tick & 1u) return;
        sp = 1;
    }
    if (dy > 0) s->paddle_y[idx] += sp;
    else if (dy < 0) s->paddle_y[idx] -= sp;
}

/* Bounce off paddle idx. Where on the paddle the ball hits steers the vertical
 * direction: the offset from the paddle's centre, normalised so a hit at the very
 * edge adds half a px/tick. The paddle's own motion adds half of its speed as
 * spin — it used to add all of it, twice what a hit at the edge adds, so the
 * player's motion decided the angle and their aim only nudged it. Every hit also
 * winds the ball up, so a long rally gets faster until it tops out at twice the
 * serve speed. */
static void paddle_bounce(rally_state *s, int idx, int byp)
{
    int ph = s->paddle_h;
    int rel = byp - (s->paddle_y[idx] + ph / 2);
    s->ball_speed = (int16_t)(s->ball_speed + s->ball_speed / 8);
    if (s->ball_speed > RALLY_SPEED_MAX) s->ball_speed = RALLY_SPEED_MAX;
    /* The ball leaves at the rally's speed, not at whatever it arrived with,
     * and it leaves the way it came from: the paddle reflects the sign. */
    s->bvx = s->bvx < 0 ? (int32_t)s->ball_speed : (int32_t)-s->ball_speed;
    s->bvy += (rel * FX_ONE) / ph;
    s->bvy += s->paddle_v[idx] * FX_ONE / 2;
}

/* Follow the phone's angle: the paddle's y *is* the tilt's position, so a
 * held angle is a held paddle and nothing drifts. paddle_v is derived from the
 * step taken rather than integrated, which keeps the bounce's spin term
 * (paddle_bounce) honest: a fast sweep imparts spin, a still phone does not. */
static void paddle_follow(rally_state *s, int idx)
{
    int y = (int)ml_axis_map(s->tilt_y[idx], 0, s->panel_h - s->paddle_h);
    s->paddle_v[idx] = (int16_t)(y - s->paddle_y[idx]);
    s->paddle_y[idx] = (int16_t)y;
}

static void rally_update(void *state, ml_game_ctx *ctx)
{
    rally_state *s = state;
    int ph = s->paddle_h;

    /* paddles: the AI chases, a controller on tilt follows the phone's angle,
     * a controller on buttons integrates its paddle_v */
    for (int i = 0; i < 2; i++) {
        if (!(s->present & (1u << i)))          ai_move(s, i, ml_ctx_tick(ctx));
        else if (ml_axis_engaged(s->tilt_y[i])) paddle_follow(s, i);
        else                                    s->paddle_y[i] += s->paddle_v[i];
        s->paddle_y[i] = (int16_t)clampi(s->paddle_y[i], 0, s->panel_h - ph);
    }

    /* ball */
    s->bx += s->bvx;
    s->by += s->bvy;

    int bxp = (int)(s->bx >> FX);
    int byp = (int)(s->by >> FX);

    /* Top and bottom walls: reflect the ball back by the distance it overshot,
     * rather than clamping it to the wall row and flipping its speed. Clamping
     * asks only "is the ball at or past this row?", which cannot tell the ball
     * that arrived there from the ball that is leaving: a ball sitting in the
     * wall's own row had its speed flipped every tick and never got out. At an
     * eighth of a pixel per tick - which is what a hit one row off the centre
     * of a still paddle makes (see paddle_bounce) - that pinned the ball to the
     * ceiling for the rest of the round. The row tests are strict for the same
     * reason: row 0 and the last row are rows the ball may be in, and only
     * leaving the panel is a bounce. */
    if (byp < 0) {
        s->by = -s->by;
        s->bvy = -s->bvy;
    } else if (byp > s->panel_h - 1) {
        s->by = 2 * (((int32_t)s->panel_h - 1) << FX) - s->by;
        s->bvy = -s->bvy;
    }
    /* The paddle tests below read byp, which the reflection has moved. */
    byp = (int)(s->by >> FX);

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

    /* Clamp the vertical speed so a rally can't send the ball straight across:
     * half again the ball's current speed, which is the same ceiling angle at
     * every speed in the ramp. */
    int max_v = s->ball_speed + s->ball_speed / 2;
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
    .pref_w        = 64, .pref_h = 32, .fit = ML_FIT_LETTERBOX,
    .tick_ms       = 25,
    .max_players   = 2,
    .state_size    = sizeof(rally_state),
    .controls      = rally_controls,
    .control_count = 3,
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