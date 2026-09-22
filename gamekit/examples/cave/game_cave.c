/*
 * game_cave.c - fly a ship through a scrolling cave.
 *
 * The panel is a 64x32 slot the cave slides through, one column at a time. The
 * rock is described by a centre row per column and a half-height opening around
 * it, so the whole cave is 64 bytes of state and a frame is a loop of vertical
 * lines. The centre walks by at most one row a column, which makes the tunnel
 * continuous and keeps it one walking hand away from a wall.
 *
 * The ship has no gravity: the phone's tilt *is* its altitude, so a steady
 * angle holds it still and a level phone puts it in the middle of the shaft.
 * That is what makes a wrist-sized motion enough to thread a hole, and why the
 * buttons step a fixed row a tick for a player on a pad.
 *
 * A crash costs one of three lives and the cave opens straight again for a
 * moment while the player re-finds the horizon. The distance, and so the score
 * and the cave's narrowness, survive: only the collision does not.
 */
#include <stdio.h>
#include <string.h>

#include "mirror/font.h"
#include "mirror/game.h"
#include "mirror/gamerun.h"

/* The logical panel the cave is authored for. Letterbox keeps drawing at this
 * size whatever the physical panel is and scales the result up whole, so the
 * tunnel is always 64 columns and the row arithmetic is always the same. */
#define CAVE_COLS 64
#define CAVE_H    32

/* Rows 0-9 are the digits10 score band, 10-30 are rock and open air, and the
 * last row carries the lives so a life pixel can never be mistaken for a wall. */
#define CAVE_ROW_TOP  10
#define CAVE_ROW_BOT  30
#define CAVE_LIFE_ROW (CAVE_H - 1)

#define CAVE_SHIP_X       10
#define CAVE_SHIP_W       3
#define CAVE_SHIP_H       2
#define CAVE_SHIP_START_Y 19

/* The travel the tilt can steer the ship's top row over: the whole open band,
 * so full tilt really does put the ship against the roof or the floor. */
#define CAVE_SHIP_TOP_MIN 10
#define CAVE_SHIP_TOP_MAX 29

#define CAVE_CENTRE      20   /* a straight tunnel runs down the middle */
#define CAVE_CENTRE_MIN  17   /* the walk's clamp: keeps a floor and a roof */
#define CAVE_CENTRE_MAX  23
/* The shaft pinches a row every this many columns, twice over: half height from
 * six down to four, and the pace from four ticks a column to two. */
#define CAVE_PINCH_EVERY 160
#define CAVE_GAP_MAX         6   /* the opening's half height at the start */
#define CAVE_GAP_MIN         4   /* and at its narrowest */
#define CAVE_PACE_MAX        4   /* ticks a column at the start */
#define CAVE_PACE_MIN        2   /* and at its quickest */

#define CAVE_LIVES          3
#define CAVE_SCORE_MAX   9999
#define CAVE_RECOVERY_TICKS 80

enum { CAVE_PLAYING = 0, CAVE_OVER = 1 };

typedef struct {
    int16_t  ship_y;         /* top row of the 3x2 ship */
    uint16_t score;          /* one point per column scrolled */
    uint16_t distance;       /* columns scrolled; drives pace and narrowing */
    uint8_t  lives;
    uint8_t  status;         /* CAVE_* */
    uint8_t  held_up, held_down;
    int16_t  tilt_y;         /* ML_AXIS_IDLE until a controller drives it */
    uint8_t  scroll_ctr;     /* ticks until the next column */
    uint8_t  recovery;       /* crash pause ticks left; 0 while flying */
    uint8_t  centre[CAVE_COLS];
} cave_state;

/* Four bytes are reserved by the runtime's broadcast for its own header, so the
 * effective bound is the smaller one, not the header's nominal maximum. */
typedef char cave_state_fits[(sizeof(cave_state) <= ML_SNAPSHOT_MAX - 4) ? 1 : -1];

static const ml_control_def cave_controls[] = {
    { .label = "Up",    .code = 0, .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "Down",  .code = 1, .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "TiltY", .code = 2, .caps = ML_CAP_ACCEL,  .type = ML_INPUT_AXIS },
};

/* The opening's half height: the shaft pinches by a row every CAVE_PINCH_EVERY
 * columns, from six down to four, so a run gets harder without ever closing. */
static int cave_half_gap(const cave_state *s)
{
    int pinch = (int)(s->distance / CAVE_PINCH_EVERY);
    if (pinch > CAVE_GAP_MAX - CAVE_GAP_MIN) pinch = CAVE_GAP_MAX - CAVE_GAP_MIN;
    return CAVE_GAP_MAX - pinch;
}

/* Ticks per column: four at the start, three once the shaft has pinched once,
 * two once it has pinched twice. Never less than two, so the cave always reads
 * as scrolling rather than flashing past. */
static int cave_scroll_interval(const cave_state *s)
{
    int iv = CAVE_PACE_MAX - (int)(s->distance / CAVE_PINCH_EVERY);
    return iv < CAVE_PACE_MIN ? CAVE_PACE_MIN : iv;
}

static void cave_straight(cave_state *s)
{
    for (int i = 0; i < CAVE_COLS; i++) s->centre[i] = CAVE_CENTRE;
}

/* A gameplay pixel is open when it is within the half gap of its column's
 * centre. Everything else in the band is rock. */
static bool cave_pixel_open(const cave_state *s, int x, int y, int gap)
{
    int d = y - (int)s->centre[x];
    if (d < 0) d = -d;
    return d <= gap;
}

/* The whole 3x2 ship, not its centre pixel: a column that pinches in around the
 * nose is as fatal as one that pinches in around the tail. */
static bool cave_footprint_ok(const cave_state *s, int top)
{
    const int gap = cave_half_gap(s);
    for (int x = CAVE_SHIP_X; x < CAVE_SHIP_X + CAVE_SHIP_W; x++)
        for (int y = top; y < top + CAVE_SHIP_H; y++)
            if (!cave_pixel_open(s, x, y, gap)) return false;
    return true;
}

/* Every integer row the ship passes through, ends included. A tilt is an
 * absolute request, so a wrist can ask for a jump from the roof to the floor in
 * one tick; testing only the destination would let the ship step over the rock
 * between them. */
static bool cave_sweep_ok(const cave_state *s, int from, int to)
{
    if (from > to) { int t = from; from = to; to = t; }
    for (int top = from; top <= to; top++)
        if (!cave_footprint_ok(s, top)) return false;
    return true;
}

/* Slide the cave one column left and grow a new one on the right: the previous
 * column's centre nudged by a walk step, clamped so the shaft never wanders into
 * the ship's travel. */
static void cave_scroll(cave_state *s, ml_game_ctx *ctx)
{
    const uint8_t tail = s->centre[CAVE_COLS - 1];
    for (int i = 0; i < CAVE_COLS - 1; i++) s->centre[i] = s->centre[i + 1];
    const int step = (int)(ml_ctx_rng(ctx) % 3u) - 1;   /* -1, 0 or +1 */
    int c = (int)tail + step;
    if (c < CAVE_CENTRE_MIN) c = CAVE_CENTRE_MIN;
    if (c > CAVE_CENTRE_MAX) c = CAVE_CENTRE_MAX;
    s->centre[CAVE_COLS - 1] = (uint8_t)c;
}

/* One crash. The last life ends the run; otherwise the cave opens straight and
 * the ship is put back in the middle of it for the recovery pause. Distance and
 * score are not touched, so the run keeps the ground it has covered. */
static void cave_crash(cave_state *s)
{
    if (s->lives > 0) s->lives--;
    if (s->lives == 0) {
        s->status = CAVE_OVER;
        return;
    }
    cave_straight(s);
    s->ship_y = CAVE_SHIP_START_Y;
    s->recovery = CAVE_RECOVERY_TICKS;
    s->scroll_ctr = (uint8_t)cave_scroll_interval(s);
}

static void cave_init(void *state, const ml_game_cfg *cfg, ml_game_ctx *ctx)
{
    (void)cfg; (void)ctx;
    cave_state *s = state;
    memset(s, 0, sizeof(*s));
    s->tilt_y = ML_AXIS_IDLE;
}

static void cave_reset(void *state, ml_game_ctx *ctx)
{
    (void)ctx;
    cave_state *s = state;
    s->ship_y = CAVE_SHIP_START_Y;
    s->score = 0;
    s->distance = 0;
    s->lives = CAVE_LIVES;
    s->status = CAVE_PLAYING;
    s->held_up = 0;
    s->held_down = 0;
    s->tilt_y = ML_AXIS_IDLE;
    s->recovery = 0;
    cave_straight(s);
    s->scroll_ctr = (uint8_t)cave_scroll_interval(s);
}

static void cave_input(void *state, const ml_input_event *e, ml_game_ctx *ctx)
{
    (void)ctx;
    cave_state *s = state;
    switch (e->code) {
    case 0:
        if (e->type == ML_INPUT_BUTTON) s->held_up = (uint8_t)(e->value ? 1 : 0);
        break;
    case 1:
        if (e->type == ML_INPUT_BUTTON) s->held_down = (uint8_t)(e->value ? 1 : 0);
        break;
    case 2:
        /* An axis is a position, not a press: it is latched whenever it arrives,
         * including while the phone is level. */
        if (e->type == ML_INPUT_AXIS) s->tilt_y = e->value;
        break;
    default:
        break;
    }
}

static void cave_update(void *state, ml_game_ctx *ctx)
{
    cave_state *s = state;
    if (s->status != CAVE_PLAYING) return;

    /* Fly. An engaged axis makes the phone's angle the ship's altitude, so a
     * held tilt holds it where it is; buttons step a row a tick from wherever
     * the ship already is, and a pair of opposite buttons holds it still. */
    int to;
    if (ml_axis_engaged(s->tilt_y)) {
        to = (int)ml_axis_map(s->tilt_y, CAVE_SHIP_TOP_MIN, CAVE_SHIP_TOP_MAX);
    } else {
        int dy = 0;
        if (s->held_up && !s->held_down) dy = -1;
        if (s->held_down && !s->held_up) dy = 1;
        to = (int)s->ship_y + dy;
        if (to < CAVE_SHIP_TOP_MIN) to = CAVE_SHIP_TOP_MIN;
        if (to > CAVE_SHIP_TOP_MAX) to = CAVE_SHIP_TOP_MAX;
    }
    if (!cave_sweep_ok(s, s->ship_y, to)) {
        cave_crash(s);
        return;
    }
    s->ship_y = (int16_t)to;

    /* Scroll. The recovery pause stops the world without winding the counter
     * down, so the cadence resumes where it left off rather than snapping a
     * column through on the first tick back. */
    if (s->recovery > 0) {
        s->recovery--;
        return;
    }
    if (s->scroll_ctr > 0) s->scroll_ctr--;
    if (s->scroll_ctr > 0) return;

    cave_scroll(s, ctx);
    if (s->distance != 0xffffu) s->distance++;
    if (s->score < CAVE_SCORE_MAX) s->score++;
    s->scroll_ctr = (uint8_t)cave_scroll_interval(s);

    /* The column that just arrived, and the pinch that may have come with it, is
     * tested against where the ship already is: the cave can close around it. */
    if (!cave_footprint_ok(s, s->ship_y)) cave_crash(s);
}

static void cave_draw_terminal(const cave_state *s, ml_canvas *c)
{
    char buf[8];
    const ml_font *df = ml_font_find("digits10");
    if (!df) df = ml_font_default();
    snprintf(buf, sizeof(buf), "%u", (unsigned)s->score);
    ml_text_draw(c, df, 1, 0, buf, ML_RGB(255, 255, 255), ML_SCALE_1X);

    const ml_font *of = ml_font_find("sans10");
    if (!of) of = ml_font_default();
    int w = ml_text_width(of, "OVER", ML_SCALE_1X);
    ml_text_draw(c, of, (CAVE_COLS - w) / 2, 17, "OVER",
                 ML_RGB(255, 60, 60), ML_SCALE_1X);
}

static void cave_draw(const void *state, const ml_view *view, ml_canvas *c,
                      const ml_game_ctx *ctx)
{
    (void)view; (void)ctx;
    const cave_state *s = state;
    ml_canvas_clear(c, ml_black);

    /* A finished run clears the board: the score stands alone, so nothing on it
     * can be read as a ship still flying. */
    if (s->status != CAVE_PLAYING) {
        cave_draw_terminal(s, c);
        return;
    }

    const ml_rgb wall = ML_RGB(0, 80, 255);
    const ml_rgb ship = ML_RGB(0, 255, 255);
    const ml_rgb hud  = ML_RGB(255, 255, 255);

    /* The rock is everything in the band that is not the opening: two vertical
     * runs per column, which is cheaper than testing each of the 21 rows. */
    const int gap = cave_half_gap(s);
    for (int x = 0; x < CAVE_COLS; x++) {
        int lo = (int)s->centre[x] - gap;
        int hi = (int)s->centre[x] + gap;
        if (lo < CAVE_ROW_TOP) lo = CAVE_ROW_TOP;
        if (hi > CAVE_ROW_BOT) hi = CAVE_ROW_BOT;
        if (lo > CAVE_ROW_TOP)
            ml_canvas_vline(c, x, CAVE_ROW_TOP, lo - CAVE_ROW_TOP, wall);
        if (hi < CAVE_ROW_BOT)
            ml_canvas_vline(c, x, hi + 1, CAVE_ROW_BOT - hi, wall);
    }

    for (int dx = 0; dx < CAVE_SHIP_W; dx++)
        for (int dy = 0; dy < CAVE_SHIP_H; dy++)
            ml_canvas_set(c, CAVE_SHIP_X + dx, s->ship_y + dy, ship);

    char buf[8];
    const ml_font *f = ml_font_find("digits10");
    if (!f) f = ml_font_default();
    snprintf(buf, sizeof(buf), "%u", (unsigned)s->score);
    ml_text_draw(c, f, 1, 0, buf, hud, ML_SCALE_1X);
    for (int i = 0; i < s->lives; i++)
        ml_canvas_set(c, 1 + i, CAVE_LIFE_ROW, hud);
}

static bool cave_snapshot(const void *state, uint8_t *buf, size_t cap, size_t *len)
{
    if (cap < sizeof(cave_state)) return false;
    memcpy(buf, state, sizeof(cave_state));
    *len = sizeof(cave_state);
    return true;
}

static void cave_restore(void *state, const uint8_t *buf, size_t len)
{
    /* Only a snapshot of exactly this game's state is a state at all: anything
     * else is a different game's or a truncated frame, and overwriting with it
     * would corrupt a running cave. */
    if (len != sizeof(cave_state)) return;
    memcpy(state, buf, sizeof(cave_state));
}

static bool cave_is_over(const void *state)
{
    return ((const cave_state *)state)->status == CAVE_OVER;
}

const ml_game_vt ml_game_cave = {
    .id            = "cave",
    .pref_w        = CAVE_COLS, .pref_h = CAVE_H,
    .fit           = ML_FIT_LETTERBOX,
    .tick_ms       = 25,
    .max_players   = 1,
    .state_size    = sizeof(cave_state),
    .controls      = cave_controls,
    .control_count = 3,
    .init          = cave_init,
    .reset         = cave_reset,
    .input         = cave_input,
    .update        = cave_update,
    .draw          = cave_draw,
    .snapshot      = cave_snapshot,
    .restore       = cave_restore,
    .is_over       = cave_is_over,
};
