/*
 * game_breakout.c - the fourth game: a paddle and a wall of bricks.
 *
 * The reflex game, and the first horizontal-control one: two buttons (Left,
 * Right) instead of rally's vertical pair. The physics are rally's, trimmed
 * to a single paddle: a Q8.8 ball, a fixed table of directions the hit column
 * picks from (the ball leaves the paddle at the angle its contact point
 * chose), integer wall bounces that reflect the ball by the distance it
 * overshot and so preserve that angle, and a serve that is the table's
 * 45-degree row. Every direction is under one cell per tick per axis, so the
 * ball can never tunnel through a brick, and the only RNG is none: the serve
 * is a fixed diagonal, which keeps every session a pure function of the input
 * stream.
 *
 * Bricks are one cell each, up to 8 rows across up to 128 columns, stored as
 * bit rows so 8x128 cells cost 128 bytes of state; a panel wider than that
 * keeps the wider arena but not a wider wall. A cleared wall refills a level
 * up; losing the ball costs a life out of three.
 */
#include <stdio.h>
#include <string.h>

#include "mirror/font.h"
#include "mirror/game.h"
#include "mirror/gamerun.h"

#define FX 8
#define FX_ONE (1 << FX)

#define BRICK_ROWS_MAX 8
#define BRICK_COLS_MAX 128  /* the bit-row storage bound, not the arena width */

/* The bounce directions, one per hit zone: eight ways off the paddle, four to
 * each side, all at about one pixel per tick. A hit at the paddle's edge leaves
 * at 60 degrees from vertical and one beside the centre at 15; nothing leaves
 * straight up, because a ball with no horizontal speed would bounce between the
 * same two bricks for the rest of the level. The pairs are sin and cos of
 * 15/30/45/60 degrees scaled by 256 and rounded, so every one is within one unit
 * of the 256 that one pixel per tick is. */
#define BOUNCE_DIRS 8
static const int16_t BOUNCE_VX[BOUNCE_DIRS] = { -222, -181, -128, -66, 66, 128, 181, 222 };
static const int16_t BOUNCE_VY[BOUNCE_DIRS] = { -128, -181, -222, -247, -247, -222, -181, -128 };

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
    uint8_t  intro;          /* ticks left of the new-level HUD blink */
    uint8_t  brick_rows;
    int16_t  tilt_x;         /* tilt axis, ML_AXIS_IDLE when nobody drives it */
    uint32_t bricks[BRICK_ROWS_MAX][4];  /* 8 rows x 128 bits */
} breakout_state;

typedef char breakout_state_fits[(sizeof(breakout_state) <= ML_SNAPSHOT_MAX) ? 1 : -1];

static const ml_control_def breakout_controls[] = {
    { .label = "Left",  .code = 0, .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "Right", .code = 1, .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "TiltX", .code = 2, .caps = ML_CAP_ACCEL,  .type = ML_INPUT_AXIS },
};

static void serve(breakout_state *s)
{
    s->bx = (s->panel_w / 2) << FX;
    s->by = (s->panel_h - 4) << FX;       /* just above the paddle */
    /* Up and to the right at 45 degrees, one of the table's own rows, so the
     * opening shot is played at the same speed as every bounce after it. */
    s->bvx = BOUNCE_VX[6];
    s->bvy = BOUNCE_VY[6];
}

/* Columns that are both drawable and storable: the wall is left-aligned in the
 * panel, so a panel wider than the storage keeps the wider arena but not a
 * wider wall. Bricks outside it are always dead. */
static int brick_cols(const breakout_state *s)
{
    return s->panel_w < BRICK_COLS_MAX ? s->panel_w : BRICK_COLS_MAX;
}

/* The wall of a level. Levels cycle through four shapes and each one is symmetric
 * about the centre column (it is built from the distance to the nearer edge), so
 * the ball meets the same wall from either side, and each leaves a way back down
 * for a ball that has passed through it. */
static bool brick_live(uint8_t level, int row, int col, int cols)
{
    int d = col < cols - 1 - col ? col : cols - 1 - col;    /* 0 at either edge */
    switch ((level - 1) & 3) {
    case 0:  return true;                        /* solid */
    case 1:  return ((d + (row & 1)) & 1) == 0;  /* brickwork */
    case 2:  return d >= row;                    /* pyramid */
    default: return ((d + row) & 1) == 0;        /* checkerboard */
    }
}

/* Set each active row's live columns, and only those: on a panel narrower than
 * the storage the dead columns stay zero, so clearing what the player sees
 * really does clear the wall. Never shifts by 32. */
static void refill_bricks(breakout_state *s)
{
    int live = brick_cols(s);
    for (int r = 0; r < BRICK_ROWS_MAX; r++) {
        for (int h = 0; h < 4; h++) {
            int base = h * 32;
            uint32_t bits = 0;
            if (r < s->brick_rows && base < live) {
                for (int b = 0; b < 32; b++) {
                    int col = base + b;
                    if (col >= live) break;
                    if (brick_live(s->level, r, col, live)) bits |= 1u << b;
                }
            }
            s->bricks[r][h] = bits;
        }
    }
}

static bool brick_at(const breakout_state *s, int x, int y)
{
    if (x < 0 || y < 0 || y >= s->brick_rows || y >= BRICK_ROWS_MAX) return false;
    if (x >= brick_cols(s)) return false;
    return (s->bricks[y][x >> 5] >> (x & 31)) & 1u;
}

static void brick_clear(breakout_state *s, int x, int y)
{
    if (x < 0 || y < 0 || y >= s->brick_rows || y >= BRICK_ROWS_MAX) return;
    if (x >= brick_cols(s)) return;
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

/* The paddle a level is played with: one pixel narrower per level, never under
 * three, so meeting the ball gets a little harder each time the wall comes back. */
static int level_paddle_w(int panel_w, uint8_t level)
{
    return clampi(panel_w / 10 - (int)(level - 1), 3, 10);
}

/* Where on the paddle the ball landed, as one of the eight bounce directions.
 * The offset is measured in half pixels from the paddle's centre so that a hit
 * one pixel either side of it is symmetric (a half-pixel bias would make the
 * left half of the paddle play differently from the right), then rounded onto
 * the table so the two end columns land on its ends. */
static int bounce_zone(const breakout_state *s, int bxp)
{
    int span = s->paddle_w > 1 ? s->paddle_w - 1 : 1;
    int rel2 = 2 * bxp + 1 - (2 * s->px + s->paddle_w);   /* -span .. +span */
    int zone = ((rel2 + span) * (BOUNCE_DIRS - 1) + span) / (2 * span);
    if (zone < 0) zone = 0;
    if (zone >= BOUNCE_DIRS) zone = BOUNCE_DIRS - 1;
    return zone;
}

static void breakout_init(void *state, const ml_game_cfg *cfg, ml_game_ctx *ctx)
{
    (void)ctx;
    breakout_state *s = state;
    memset(s, 0, sizeof(*s));
    s->panel_w = (int16_t)cfg->panel_w;
    s->panel_h = (int16_t)cfg->panel_h;
    int br = cfg->panel_h / 8;
    s->brick_rows = (uint8_t)clampi(br, 2, BRICK_ROWS_MAX);
}

static void breakout_reset(void *state, ml_game_ctx *ctx)
{
    (void)ctx;
    breakout_state *s = state;
    s->paddle_w = (int16_t)level_paddle_w(s->panel_w, 1);
    s->px = (int16_t)((s->panel_w - s->paddle_w) / 2);
    s->score = 0;
    s->lives = 3;
    s->level = 1;
    s->intro = 40;
    s->status = BREAKOUT_PLAYING;
    s->held_l = 0;
    s->held_r = 0;
    s->tilt_x = ML_AXIS_IDLE;
    refill_bricks(s);
    serve(s);
}

static void breakout_input(void *state, const ml_input_event *e, ml_game_ctx *ctx)
{
    (void)ctx;
    breakout_state *s = state;
    if (e->code == 0) s->held_l = e->value ? 1 : 0;
    else if (e->code == 1) s->held_r = e->value ? 1 : 0;
    else if (e->code == 2) s->tilt_x = e->value;
}

static void breakout_update(void *state, ml_game_ctx *ctx)
{
    (void)ctx;
    breakout_state *s = state;
    if (s->status != BREAKOUT_PLAYING) return;
    if (s->intro) s->intro--;

    /* paddle: the phone's angle is the paddle's position, so a held tilt holds
     * the paddle; buttons keep their rate, one or two px per tick */
    if (ml_axis_engaged(s->tilt_x)) {
        s->px = (int16_t)ml_axis_map(s->tilt_x, 0, s->panel_w - s->paddle_w);
    } else {
        int sp = s->panel_w / 64 + 1;
        if (s->held_l) s->px -= sp;
        if (s->held_r) s->px += sp;
        s->px = (int16_t)clampi(s->px, 0, s->panel_w - s->paddle_w);
    }

    /* ball */
    s->bx += s->bvx;
    s->by += s->bvy;
    int bxp = (int)(s->bx >> FX);
    int byp = (int)(s->by >> FX);

    /* Side walls and ceiling: reflect the ball by the distance it overshot and
     * flip that one axis, so the angle it arrived with is the angle it leaves
     * with. The tests are on the Q8.8 position, not on the pixel cell, so a ball
     * that has not actually left the panel is never reflected and cannot stick to
     * a wall waiting for its fractional part to carry. */
    if (s->bx < 0) {
        s->bx = -s->bx;
        s->bvx = -s->bvx;
    } else if (s->bx > (((int32_t)s->panel_w - 1) << FX)) {
        s->bx = 2 * (((int32_t)s->panel_w - 1) << FX) - s->bx;
        s->bvx = -s->bvx;
    }
    if (s->by < 0) {
        s->by = -s->by;
        s->bvy = -s->bvy;
    }
    bxp = (int)(s->bx >> FX);
    byp = (int)(s->by >> FX);

    /* paddle bounce: hit position steers the angle, rally-style */
    if (s->bvy > 0 && byp >= s->panel_h - 3 && byp < s->panel_h) {
        if (bxp >= s->px && bxp < s->px + s->paddle_w) {
            /* Where it hit is where it goes: the hit column picks the outgoing
             * direction, so the player aims the ball. Both components come from
             * the table and are under one cell per tick, which is the invariant
             * the brick test below relies on. This paddle has no velocity of its
             * own, so nothing else is added. */
            int zone = bounce_zone(s, bxp);
            s->bvx = BOUNCE_VX[zone];
            s->bvy = BOUNCE_VY[zone];
            s->by = (int32_t)(s->panel_h - 4) << FX;
        }
    }

    /* bricks: clear the cell the ball is in, reflect the dominant axis.
     * With |v| <= 1 cell/tick the ball lands in the cell it hits, so one
     * check per tick cannot miss a brick. The dominant axis is also the face
     * the ball came through: a 15-degree ball is moving mostly down, so it
     * entered the brick through a horizontal face, while a 60-degree ball is
     * moving mostly sideways and entered through a vertical one. */
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
            s->paddle_w = (int16_t)level_paddle_w(s->panel_w, s->level);
            s->intro = 40;
            s->px = (int16_t)clampi(s->px, 0, s->panel_w - s->paddle_w);
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

    /* The HUD line reads level:score — the level first, because it is the thing
     * that changes. It blinks for the first second of a level (intro counts down
     * from 40 ticks) so a player watching the ball still sees that the wall has
     * changed, and so the bricks behind it are uncovered half of the intro. */
    if (s->intro == 0 || ((s->intro / 5) & 1) == 0) {
        char buf[16];
        const ml_font *f = ml_font_find("digits10");
        if (!f) f = ml_font_default();
        snprintf(buf, sizeof(buf), "%u:%u", (unsigned)s->level, (unsigned)s->score);
        ml_text_draw(c, f, 1, 1, buf, ML_RGB(0, 180, 255), ML_SCALE_1X);
    }
    for (int i = 0; i < s->lives; i++)
        ml_canvas_set(c, 1 + i, H - 1, ML_RGB(220, 220, 220));

    if (s->status == BREAKOUT_OVER) {
        /* Two centred lines: "GAME OVER" on one line does not fit the shipped
         * 64-pixel panel at the smallest font and was clipped. */
        const ml_font *of = ml_font_find("sans10");
        if (!of) of = ml_font_default();
        int th = ml_text_height(of, ML_SCALE_1X);
        int w1 = ml_text_width(of, "GAME", ML_SCALE_1X);
        int w2 = ml_text_width(of, "OVER", ML_SCALE_1X);
        int ty = (H - (2 * th + 1)) / 2;   /* one-pixel gap between the lines */
        ml_text_draw(c, of, (W - w1) / 2, ty, "GAME",
                     ML_RGB(255, 60, 60), ML_SCALE_1X);
        ml_text_draw(c, of, (W - w2) / 2, ty + th + 1, "OVER",
                     ML_RGB(255, 60, 60), ML_SCALE_1X);
    }
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

static bool breakout_is_over(const void *state)
{
    const breakout_state *s = state;
    return s->status == BREAKOUT_OVER;
}

const ml_game_vt ml_game_breakout = {
    .id            = "breakout",
    .pref_w        = 0, .pref_h = 0,
    .fit           = ML_FIT_ADAPTIVE,
    .tick_ms       = 25,
    .max_players   = 1,
    .state_size    = sizeof(breakout_state),
    .controls      = breakout_controls,
    .control_count = 3,
    .init          = breakout_init,
    .reset         = breakout_reset,
    .input         = breakout_input,
    .update        = breakout_update,
    .draw          = breakout_draw,
    .snapshot      = breakout_snapshot,
    .restore       = breakout_restore,
    .is_over       = breakout_is_over,
};
