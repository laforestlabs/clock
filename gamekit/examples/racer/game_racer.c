/*
 * game_racer.c - Tilt Racer: steer a car down a road full of traffic.
 *
 * The first purely positional game of the set: the phone's angle IS the car's
 * column, so a held tilt holds the car at one of the road's 42 columns and a
 * level phone parks it in the middle. Buttons still work and move the car one
 * pixel per tick from wherever it already is, which is what the touch pad and
 * the keyboard use; the axis only takes over while a controller drives it.
 *
 * Traffic is six slots, each a Q8.8 row that only ever increases, so a car
 * comes down the road at 1/2 to 1 pixel per tick depending on how many have
 * got past. Both sides of every collision are swept: the player is tested at
 * every column between where it was and where the tilt put it (a full tilt
 * swings the car across the whole road in one tick, and a single test at the
 * destination would let it jump straight through a car), and each traffic car
 * is tested at every row it crossed. A car whose top row drives past row 30
 * has got by: it scores and feeds the difficulty, which shortens the spawn
 * interval and raises the traffic speed every ten cars.
 *
 * A collision costs one of three lives, clears the road and restarts the
 * spawn countdown; the car, its score and the difficulty stay where they were,
 * so the run resumes from the same column. Three collisions end the game.
 */
#include <stdio.h>
#include <string.h>

#include "mirror/font.h"
#include "mirror/game.h"
#include "mirror/gamerun.h"

/* The authored panel: 64x32, letterboxed by the runtime, so the simulation
 * always works in these coordinates whatever the physical panel is. */
#define RACER_W 64
#define RACER_H 32

#define ROAD_LEFT   8        /* the drawn road edges */
#define ROAD_RIGHT  55
#define ROAD_TOP    10       /* the playfield rows, shared with the HUD band */
#define PASS_ROW    30       /* a car whose top row is past this has got by */

#define PLAYER_TOP  26       /* the player car's top row, 4 tall */
#define CAR_W       3
#define CAR_H       4

#define PLAYER_X_MIN 10      /* the player's left column travel (both paths) */
#define PLAYER_X_MAX 51

#define RACER_LIVES 3
#define RACER_SLOTS 6
#define SPAWN_TOP   10       /* where a new car enters */

#define SPAWN_BASE  48       /* ticks to the first car: one every 48-4*diff */
#define PASS_SCORE  10
#define PASS_MAX    9999

enum { RACER_PLAYING = 0, RACER_OVER = 1 };

/* The four columns traffic enters at: one car wide each, spread across the
 * road, all of them clear of the drawn edges. */
static const int16_t LANES[] = { 13, 24, 35, 46 };
#define RACER_LANES ((int)(sizeof(LANES) / sizeof(LANES[0])))

typedef struct {
    int32_t y;      /* top row, Q8.8: only ever increases */
    int16_t x;      /* left column, in the panel */
    uint8_t on;
} racer_car;

typedef struct {
    int16_t  px;             /* the player car's left column */
    int16_t  spawn_timer;    /* ticks until the next spawn attempt */
    int16_t  tilt_x;         /* ML_AXIS_IDLE when nobody drives the axis */
    uint8_t  held_l, held_r; /* button levels, 0 or 1 */
    uint8_t  lives;
    uint8_t  status;
    uint16_t score;
    uint16_t passed;         /* cars that got by, which is the difficulty */
    racer_car cars[RACER_SLOTS];
} racer_state;

/* The snapshot broadcast reserves four bytes of the header, so the state must
 * fit what is left, not the nominal maximum. */
typedef char racer_state_fits[
    (sizeof(racer_state) <= ML_SNAPSHOT_MAX - 4) ? 1 : -1];

static const ml_control_def racer_controls[] = {
    { .label = "Left",  .code = 0, .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "Right", .code = 1, .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "TiltX", .code = 2, .caps = ML_CAP_ACCEL,  .type = ML_INPUT_AXIS },
};

static int racer_clampi(int v, int lo, int hi)
{
    return v < lo ? lo : (v > hi ? hi : v);
}

/* How hard the road is now: one step for every ten cars that got by, and the
 * top of the table after forty. */
static int racer_difficulty(const racer_state *s)
{
    int d = (int)(s->passed / 10);
    return d > 4 ? 4 : d;
}

/* Ticks between spawn attempts, and the Q8.8 speed of a car: 1/2 to 1 pixel
 * per tick. */
static int racer_interval(const racer_state *s)
{
    return SPAWN_BASE - 4 * racer_difficulty(s);
}

static int racer_speed(const racer_state *s)
{
    return 128 + 32 * racer_difficulty(s);
}

/* Two 3x4 cells overlap: strict on both axes, so cars side by side or nose to
 * tail touch without colliding. */
static bool racer_overlap(int ax, int ay, int bx, int by)
{
    return ax < bx + CAR_W && bx < ax + CAR_W &&
           ay < by + CAR_H && by < ay + CAR_H;
}

/* Whether the player car at left column [px] would be in a traffic car. */
static bool racer_player_hit(const racer_state *s, int px)
{
    for (int i = 0; i < RACER_SLOTS; i++) {
        const racer_car *car = &s->cars[i];
        if (!car->on) continue;
        if (racer_overlap(px, PLAYER_TOP, car->x, (int)(car->y >> 8)))
            return true;
    }
    return false;
}

static void racer_clear_traffic(racer_state *s)
{
    for (int i = 0; i < RACER_SLOTS; i++) s->cars[i].on = 0;
}

/* One collision: a life, a clear road, a fresh countdown. The player keeps its
 * column, its score and the difficulty, so play resumes where it was. */
static void racer_crash(racer_state *s)
{
    s->lives--;
    racer_clear_traffic(s);
    s->spawn_timer = (int16_t)racer_interval(s);
    if (s->lives == 0) s->status = RACER_OVER;
}

/* Put one car in the first free slot at a lane the RNG picks. No free slot is
 * a skipped spawn, not a dropped one: the countdown has already reloaded. */
static void racer_spawn(racer_state *s, ml_game_ctx *ctx)
{
    racer_car *car = NULL;
    for (int i = 0; i < RACER_SLOTS; i++) {
        if (!s->cars[i].on) { car = &s->cars[i]; break; }
    }
    if (!car) return;
    const uint32_t roll = ml_ctx_rng(ctx);
    car->x = LANES[roll % (uint32_t)RACER_LANES];
    car->y = (int32_t)SPAWN_TOP << 8;
    car->on = 1;
}

static void racer_init(void *state, const ml_game_cfg *cfg, ml_game_ctx *ctx)
{
    (void)cfg; (void)ctx;
    racer_state *s = state;
    memset(s, 0, sizeof(*s));
    s->tilt_x = ML_AXIS_IDLE;
}

static void racer_reset(void *state, ml_game_ctx *ctx)
{
    (void)ctx;
    racer_state *s = state;
    memset(s, 0, sizeof(*s));
    s->px = (int16_t)((PLAYER_X_MIN + PLAYER_X_MAX) / 2);
    s->lives = RACER_LIVES;
    s->status = RACER_PLAYING;
    s->tilt_x = ML_AXIS_IDLE;
    s->spawn_timer = SPAWN_BASE;
}

static void racer_input(void *state, const ml_input_event *e, ml_game_ctx *ctx)
{
    (void)ctx;
    racer_state *s = state;
    /* A button is a level and an axis is a position; anything sent as the
     * other kind, or as a touch point this game does not take, is ignored
     * rather than read as a value it was not measured as. */
    switch (e->code) {
    case 0:
        if (e->type == ML_INPUT_BUTTON) s->held_l = e->value ? 1 : 0;
        break;
    case 1:
        if (e->type == ML_INPUT_BUTTON) s->held_r = e->value ? 1 : 0;
        break;
    case 2:
        if (e->type == ML_INPUT_AXIS) s->tilt_x = e->value;
        break;
    default:
        break;
    }
}

static void racer_update(void *state, ml_game_ctx *ctx)
{
    racer_state *s = state;
    if (s->status != RACER_PLAYING) return;

    /* The player first, one column at a time. An engaged axis is an absolute
     * column and overrides the buttons; with no axis the buttons move from
     * wherever the car is, opposite ones cancelling. Either way the sweep only
     * commits the move once the whole path is clear, so a car cannot be jumped
     * over and a blocked move leaves the car exactly where it was. */
    int target = s->px;
    if (ml_axis_engaged(s->tilt_x)) {
        target = (int)ml_axis_map(s->tilt_x, PLAYER_X_MIN, PLAYER_X_MAX);
    } else {
        target += (s->held_r ? 1 : 0) - (s->held_l ? 1 : 0);
        target = racer_clampi(target, PLAYER_X_MIN, PLAYER_X_MAX);
    }
    if (target != s->px) {
        const int step = target > s->px ? 1 : -1;
        for (int x = s->px + step; ; x += step) {
            if (racer_player_hit(s, x)) { racer_crash(s); return; }
            if (x == target) break;
        }
        s->px = (int16_t)target;
    }

    /* Then the traffic, one row at a time, retiring what has driven past the
     * bottom of the road. */
    const int speed = racer_speed(s);
    for (int i = 0; i < RACER_SLOTS; i++) {
        racer_car *car = &s->cars[i];
        if (!car->on) continue;
        const int was = (int)(car->y >> 8);
        car->y += speed;
        const int now = (int)(car->y >> 8);
        for (int row = was + 1; row <= now; row++) {
            if (racer_overlap(s->px, PLAYER_TOP, car->x, row)) {
                racer_crash(s);
                return;
            }
        }
        if (now > PASS_ROW) {
            car->on = 0;
            if (s->score < PASS_MAX) {
                s->score = (uint16_t)(s->score + PASS_SCORE);
                if (s->score > PASS_MAX) s->score = PASS_MAX;
            }
            if (s->passed != UINT16_MAX) s->passed++;
        }
    }

    /* One spawn attempt per interval, even on a tick where the road was full
     * and the attempt came to nothing. */
    if (s->spawn_timer > 0) s->spawn_timer--;
    if (s->spawn_timer <= 0) {
        racer_spawn(s, ctx);
        s->spawn_timer = (int16_t)racer_interval(s);
    }
}

static void racer_fill(ml_canvas *c, int x, int y, int w, int h, ml_rgb color)
{
    for (int dy = 0; dy < h; dy++)
        for (int dx = 0; dx < w; dx++)
            ml_canvas_set(c, x + dx, y + dy, color);
}

static void racer_draw(const void *state, const ml_view *view, ml_canvas *c,
                       const ml_game_ctx *ctx)
{
    (void)view; (void)ctx;
    const racer_state *s = state;
    ml_canvas_clear(c, ml_black);
    const int W = c->w, H = c->h;

    const ml_font *num = ml_font_find("digits10");
    if (!num) num = ml_font_default();
    char buf[16];
    snprintf(buf, sizeof(buf), "%u", (unsigned)s->score);

    if (s->status == RACER_OVER) {
        /* The board is already cleared: the final score, then the ending. */
        ml_text_draw(c, num, 1, 0, buf, ml_white, ML_SCALE_1X);
        const ml_font *of = ml_font_find("sans10");
        if (!of) of = ml_font_default();
        ml_text_draw(c, of, (W - ml_text_width(of, "OVER", ML_SCALE_1X)) / 2,
                     17, "OVER", ML_RGB(255, 60, 60), ML_SCALE_1X);
        return;
    }

    /* Road edges, framing the playfield the traffic and the player share. */
    const ml_rgb wall = ML_RGB(0, 80, 255);
    ml_canvas_vline(c, ROAD_LEFT, ROAD_TOP, PASS_ROW - ROAD_TOP + 1, wall);
    ml_canvas_vline(c, ROAD_RIGHT, ROAD_TOP, PASS_ROW - ROAD_TOP + 1, wall);

    const ml_rgb hazard = ML_RGB(255, 60, 60);
    for (int i = 0; i < RACER_SLOTS; i++) {
        const racer_car *car = &s->cars[i];
        if (!car->on) continue;
        racer_fill(c, car->x, (int)(car->y >> 8), CAR_W, CAR_H, hazard);
    }

    racer_fill(c, s->px, PLAYER_TOP, CAR_W, CAR_H, ML_RGB(0, 255, 255));

    ml_text_draw(c, num, 1, 0, buf, ml_white, ML_SCALE_1X);
    for (int i = 0; i < s->lives; i++)
        ml_canvas_set(c, 1 + i, H - 1, ml_white);
}

static bool racer_snapshot(const void *state, uint8_t *buf, size_t cap, size_t *len)
{
    if (cap < sizeof(racer_state)) return false;
    memcpy(buf, state, sizeof(racer_state));
    *len = sizeof(racer_state);
    return true;
}

static void racer_restore(void *state, const uint8_t *buf, size_t len)
{
    /* Only a snapshot of exactly this game's state is this game's state. */
    if (len != sizeof(racer_state)) return;
    memcpy(state, buf, sizeof(racer_state));
}

static bool racer_is_over(const void *state)
{
    const racer_state *s = state;
    return s->status == RACER_OVER;
}

const ml_game_vt ml_game_racer = {
    .id            = "racer",
    .pref_w        = RACER_W, .pref_h = RACER_H,
    .fit           = ML_FIT_LETTERBOX,
    .tick_ms       = 25,
    .max_players   = 1,
    .state_size    = sizeof(racer_state),
    .controls      = racer_controls,
    .control_count = 3,
    .init          = racer_init,
    .reset         = racer_reset,
    .input         = racer_input,
    .update        = racer_update,
    .draw          = racer_draw,
    .snapshot      = racer_snapshot,
    .restore       = racer_restore,
    .is_over       = racer_is_over,
};
