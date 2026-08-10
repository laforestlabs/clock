/*
 * game_breakout.c - the fourth game: a paddle and a wall of bricks.
 *
 * The reflex game, and the first horizontal-control one: two buttons (Left,
 * Right) instead of rally's vertical pair. The physics are rally's, trimmed
 * to a single paddle: a Q8.8 ball, hit position steering the angle off the
 * paddle, integer wall bounces. Speeds are clamped to one cell per tick per
 * axis, so the ball can never tunnel through a brick, and the only RNG is
 * none: the serve is a fixed diagonal, which keeps every session a pure
 * function of the input stream.
 *
 * Bricks are one cell each, up to 8 rows across the full panel width, stored
 * as bit rows so 8x128 cells cost 128 bytes of state. A cleared wall refills
 * a level up; losing the ball costs a life out of three.
 */
#include <stdio.h>
#include <string.h>

#include "mirror/font.h"
#include "mirror/game.h"
#include "mirror/gamerun.h"

#define FX 8
#define FX_ONE (1 << FX)

#define BRICK_ROWS_MAX 8

enum { BREAKOUT_PLAYING = 0, BREAKOUT_OVER = 1 };

typedef struct {
    int16_t  panel_w, panel_h;
    int16_t  px;             /* paddle left x */
    int16_t  paddle_w;
    int32_t  bx, by;         /* ball, Q8.8 */
    int32_t  bvx, bvy;
    uint16_t score;
    uint8_t  lives;
    uint8_t  status;
    uint8_t  held_l, held_r;
    uint8_t  level;
    uint8_t  brick_rows;
    uint8_t  pad[2];
    uint32_t bricks[BRICK_ROWS_MAX][4];  /* 8 rows x 128 bits */
} breakout_state;

typedef char breakout_state_fits[(sizeof(breakout_state) <= ML_SNAPSHOT_MAX) ? 1 : -1];

static const ml_control_def breakout_controls[] = {
    { .label = "Left",  .code = 0, .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "Right", .code = 1, .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
};

static void serve(breakout_state *s)
{
    s->bx = (s->panel_w / 2) << FX;
    s->by = (s->panel_h - 4) << FX;       /* just above the paddle */
    s->bvx = FX_ONE * 3 / 4;              /* up-right at 45 degrees */
    s->bvy = -FX_ONE * 3 / 4;
}

static void refill_bricks(breakout_state *s)
{
    for (int r = 0; r < BRICK_ROWS_MAX; r++) {
        for (int h = 0; h < 4; h++)
            s->bricks[r][h] = (r < s->brick_rows) ? 0xFFFFFFFFu : 0;
    }
}

static bool brick_at(const breakout_state *s, int x, int y)
{
    if (y < 0 || y >= s->brick_rows || x < 0 || x >= s->panel_w) return false;
    return (s->bricks[y][x >> 5] >> (x & 31)) & 1u;
}

static void brick_clear(breakout_state *s, int x, int y)
{
    s->bricks[y][x >> 5] &= ~(1u << (x & 31));
}

static bool bricks_left(const breakout_state *s)
{
    for (int r = 0; r < s->brick_rows; r++)
        for (int h = 0; h < 4; h++)
            if (s->bricks[r][h]) return true;
    return false;
}

static int clampi(int v, int lo, int hi)
{
    return v < lo ? lo : (v > hi ? hi : v);
}

static void breakout_init(void *state, const ml_game_cfg *cfg, ml_game_ctx *ctx)
{
    (void)ctx;
    breakout_state *s = state;
    memset(s, 0, sizeof(*s));
    s->panel_w = (int16_t)cfg->panel_w;
    s->panel_h = (int16_t)cfg->panel_h;
    int pw = cfg->panel_w / 10;
    s->paddle_w = (int16_t)clampi(pw, 3, 10);
    int br = cfg->panel_h / 8;
    s->brick_rows = (uint8_t)clampi(br, 2, BRICK_ROWS_MAX);
}

static void breakout_reset(void *state, ml_game_ctx *ctx)
{
    (void)ctx;
    breakout_state *s = state;
    s->px = (int16_t)((s->panel_w - s->paddle_w) / 2);
    s->score = 0;
    s->lives = 3;
    s->level = 1;
    s->status = BREAKOUT_PLAYING;
    s->held_l = 0;
    s->held_r = 0;
    refill_bricks(s);
    serve(s);
}

static void breakout_input(void *state, const ml_input_event *e, ml_game_ctx *ctx)
{
    (void)ctx;
    breakout_state *s = state;
    if (e->code == 0) s->held_l = e->value ? 1 : 0;
    else if (e->code == 1) s->held_r = e->value ? 1 : 0;
}

static void breakout_update(void *state, ml_game_ctx *ctx)
{
    (void)ctx;
    breakout_state *s = state;
    if (s->status != BREAKOUT_PLAYING) return;

    /* paddle: 1 px/tick on small panels, 2 on big ones */
    int sp = s->panel_w / 64 + 1;
    if (s->held_l) s->px -= sp;
    if (s->held_r) s->px += sp;
    s->px = (int16_t)clampi(s->px, 0, s->panel_w - s->paddle_w);

    /* ball */
    s->bx += s->bvx;
    s->by += s->bvy;
    int bxp = (int)(s->bx >> FX);
    int byp = (int)(s->by >> FX);

    /* side walls and ceiling */
    if (bxp <= 0) { s->bx = 0; s->bvx = FX_ONE; }
    if (bxp >= s->panel_w - 1) { s->bx = (s->panel_w - 1) << FX; s->bvx = -FX_ONE; }
    if (byp <= 0) { s->by = 0; s->bvy = FX_ONE; }

    /* paddle bounce: hit position steers the angle, rally-style */
    if (s->bvy > 0 && byp >= s->panel_h - 3 && byp < s->panel_h) {
        if (bxp >= s->px && bxp < s->px + s->paddle_w) {
            int rel = bxp - (s->px + s->paddle_w / 2);
            s->bvy = -FX_ONE;
            s->bvx += (rel * FX_ONE) / s->paddle_w;
            s->by = (s->panel_h - 4) << FX;
            /* keep both axes within one cell per tick so nothing tunnels */
            if (s->bvx >  FX_ONE) s->bvx =  FX_ONE;
            if (s->bvx < -FX_ONE) s->bvx = -FX_ONE;
        }
    }

    /* bricks: clear the cell the ball is in, reflect the dominant axis.
     * With |v| <= 1 cell/tick the ball lands in the cell it hits, so one
     * check per tick cannot miss a brick. */
    if (brick_at(s, bxp, byp)) {
        brick_clear(s, bxp, byp);
        s->score += 10;
        /* reflect the dominant axis: a head-on hit flips y, a glancing one
         * flips x */
        int ax = s->bvx < 0 ? -s->bvx : s->bvx;
        int ay = s->bvy < 0 ? -s->bvy : s->bvy;
        if (ax >= ay) s->bvx = -s->bvx;
        else          s->bvy = -s->bvy;
        if (!bricks_left(s)) {          /* wall cleared: next level */
            s->level++;
            s->score += 100;
            refill_bricks(s);
            serve(s);
            return;
        }
    }

    /* lost the ball */
    if (byp >= s->panel_h) {
        s->lives--;
        if (s->lives == 0) {
            s->status = BREAKOUT_OVER;
            return;
        }
        serve(s);
    }
}

static ml_rgb breakout_row_color(int row)
{
    switch (row % 6) {
    case 0: return ML_RGB(255, 60, 60);     /* red */
    case 1: return ML_RGB(255, 160, 40);    /* orange */
    case 2: return ML_RGB(255, 220, 0);     /* yellow */
    case 3: return ML_RGB(0, 200, 80);      /* green */
    case 4: return ML_RGB(0, 180, 255);     /* cyan */
    default: return ML_RGB(140, 90, 255);   /* purple */
    }
}

static void breakout_draw(const void *state, const ml_view *view, ml_canvas *c,
                          const ml_game_ctx *ctx)
{
    (void)view; (void)ctx;
    const breakout_state *s = state;
    ml_canvas_clear(c, ml_black);
    int W = c->w, H = c->h;

    /* bricks, one cell each, coloured by row */
    for (int r = 0; r < s->brick_rows; r++) {
        ml_rgb col = breakout_row_color(r);
        for (int h = 0; h < 4; h++) {
            uint32_t bits = s->bricks[r][h];
            if (!bits) continue;
            for (int b = 0; b < 32; b++) {
                int bx = h * 32 + b;
                if (bx >= W) break;
                if (bits & (1u << b))
                    ml_canvas_set(c, bx, r, col);
            }
        }
    }

    /* paddle, two rows tall */
    ml_rgb pad = ML_RGB(220, 220, 220);
    for (int x = 0; x < s->paddle_w; x++) {
        ml_canvas_set(c, s->px + x, H - 3, pad);
        ml_canvas_set(c, s->px + x, H - 2, pad);
    }

    /* ball */
    int bxp = (int)(s->bx >> FX);
    int byp = (int)(s->by >> FX);
    if (bxp >= 0 && bxp < W && byp >= 0 && byp < H)
        ml_canvas_set(c, bxp, byp, ML_RGB(255, 255, 255));

    /* score and lives */
    char buf[8];
    const ml_font *f = ml_font_find("digits10");
    if (!f) f = ml_font_default();
    snprintf(buf, sizeof(buf), "%u", (unsigned)s->score);
    ml_text_draw(c, f, 1, 1, buf, ML_RGB(0, 180, 255), ML_SCALE_1X);
    for (int i = 0; i < s->lives; i++)
        ml_canvas_set(c, 1 + i, H - 1, ML_RGB(220, 220, 220));
    (void)W;
}

static bool breakout_snapshot(const void *state, uint8_t *buf, size_t cap, size_t *len)
{
    if (cap < sizeof(breakout_state)) return false;
    memcpy(buf, state, sizeof(breakout_state));
    *len = sizeof(breakout_state);
    return true;
}

static void breakout_restore(void *state, const uint8_t *buf, size_t len)
{
    size_t n = len < sizeof(breakout_state) ? len : sizeof(breakout_state);
    memcpy(state, buf, n);
}

const ml_game_vt ml_game_breakout = {
    .id            = "breakout",
    .pref_w        = 0, .pref_h = 0,
    .fit           = ML_FIT_ADAPTIVE,
    .tick_ms       = 25,
    .max_players   = 1,
    .state_size    = sizeof(breakout_state),
    .controls      = breakout_controls,
    .control_count = 2,
    .init          = breakout_init,
    .reset         = breakout_reset,
    .input         = breakout_input,
    .update        = breakout_update,
    .draw          = breakout_draw,
    .snapshot      = breakout_snapshot,
    .restore       = breakout_restore,
};
