/*
 * game_gallery.c - a crosshair, three drifting targets, a clock.
 *
 * The aiming game, and the first one whose whole surface is a position: the
 * crosshair *is* where the phone points, so TiltX and TiltY both keep the
 * phone's angle and a held tilt holds the aim. It is invaders' shooting
 * without the shooter's three lives: a 60-second round, three gold targets
 * that slide in from either edge, and a streak that pays more the longer the
 * player keeps connecting.
 *
 * The game authors at the shipped 64x32 panel and letterboxes onto anything
 * bigger, so the simulation never changes with the panel: the crosshair travel,
 * the target rows and the round clock are the same pixels and the same ticks on
 * every display, and a host replay matches the device tick for tick. State is
 * plain POD under ML_SNAPSHOT_MAX; the only randomness is which row and which
 * edge a target enters from, drawn from the session PRNG in update (never in
 * draw); nothing in the loop allocates or reads a wall clock.
 *
 * A shot is one hit against the lowest-index live target under the crosshair:
 * targets may overlap on purpose, and only the frontmost of the stack is
 * consumed, so a stack of three pays three times. Holding Shoot keeps firing
 * every eight ticks; letting go burns the cooldown so the next press fires at
 * once. The last tick of the round still resolves its shot before the clock
 * ends the game.
 */
#include <stdio.h>
#include <string.h>

#include "mirror/font.h"
#include "mirror/game.h"
#include "mirror/gamerun.h"

/* The authored logical panel. Letterbox scaling means the game never sees any
 * other size, but the constants are named so the intent survives. */
#define GW 64
#define GH 32

/* Crosshair travel, and the rows a target may occupy. Rows 0-9 are the HUD's
 * (digits10), 10-30 are play, and row 31 is the remaining-time bar. */
#define GX_MIN 1
#define GX_MAX 62
#define GY_MIN 11
#define GY_MAX 29

#define TARGETS 3
#define TARGET_ROWS 3
#define TARGET_W 3
#define TARGET_H 3
#define TX_MIN 0
#define TX_MAX (GW - TARGET_W)   /* 61: a 3-wide target still fits the right edge */

#define SPAWN_INTERVAL 40        /* ticks between spawn attempts */
#define SPAWN_FIRST 1            /* the first spawn lands on tick 1 */
#define MOVE_EVERY 4             /* ticks per pixel of inward drift */
#define TARGET_LIFE 120          /* ticks a target is on the board */
#define FIRE_COOLDOWN 8          /* ticks between shots while Shoot is held */
#define FLASH_TICKS 2            /* ticks the crosshair stays white after a shot */
#define ROUND_TICKS 2400         /* 60 seconds at 25ms a tick */
#define SCORE_MAX 9999

enum { GALLERY_PLAYING = 0, GALLERY_OVER = 1 };

/* Control codes, in the order the phone renders them, so the code is its index
 * in the declaration array. */
enum {
    GALLERY_UP = 0,
    GALLERY_DOWN,
    GALLERY_LEFT,
    GALLERY_RIGHT,
    GALLERY_SHOOT,
    GALLERY_TILT_X,
    GALLERY_TILT_Y,
};

typedef struct {
    int8_t  x, y;    /* left/top of the 3x3 sprite */
    int8_t  dir;     /* +1 entering from the left, -1 from the right, 0 parked */
    uint8_t on;
    uint8_t age;     /* ticks since spawn; reaches TARGET_LIFE and retires */
} gallery_target;

typedef struct {
    int16_t  cx, cy;         /* crosshair centre, whole pixels */
    uint16_t score;
    uint16_t ticks_left;     /* round clock, counts down to 0 */
    uint8_t  streak;         /* consecutive hits; a miss zeroes it */
    uint8_t  status;         /* GALLERY_* */
    uint8_t  flash;          /* ticks the crosshair still reads white */
    uint8_t  shoot_cd;       /* ticks until the held trigger fires again */
    uint8_t  spawn_ctr;      /* ticks until the next spawn attempt */
    uint8_t  held_up, held_down, held_left, held_right, held_shoot;
    int16_t  tilt_x, tilt_y; /* tilt axis, ML_AXIS_IDLE when nobody drives it */
    gallery_target targets[TARGETS];
} gallery_state;

/* The runtime prefixes every serialized snapshot with the host tick, so the
 * state must fit what is left of the payload - not the header's nominal max. */
typedef char gallery_state_fits
    [(sizeof(gallery_state) <= ML_SNAPSHOT_MAX - sizeof(uint32_t)) ? 1 : -1];

static const ml_control_def gallery_controls[] = {
    { .label = "Up",    .code = GALLERY_UP,     .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "Down",  .code = GALLERY_DOWN,   .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "Left",  .code = GALLERY_LEFT,   .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "Right", .code = GALLERY_RIGHT,  .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "Shoot", .code = GALLERY_SHOOT,  .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "TiltX", .code = GALLERY_TILT_X, .caps = ML_CAP_ACCEL,  .type = ML_INPUT_AXIS },
    { .label = "TiltY", .code = GALLERY_TILT_Y, .caps = ML_CAP_ACCEL,  .type = ML_INPUT_AXIS },
};

static int g_clamp(int v, int lo, int hi)
{
    return v < lo ? lo : (v > hi ? hi : v);
}

/* Bring one target in from an edge. A full board skips the attempt rather than
 * dropping an existing target; the lowest free slot takes it, so the slot order
 * the shot consumes is the order targets arrived in. */
static void gallery_spawn(gallery_state *s, ml_game_ctx *ctx)
{
    static const int8_t ROWS[TARGET_ROWS] = { 12, 18, 24 };
    int slot = -1;
    for (int i = 0; i < TARGETS; i++) {
        if (!s->targets[i].on) { slot = i; break; }
    }
    if (slot < 0) return;

    const int row = ROWS[ml_ctx_rng(ctx) % (uint32_t)TARGET_ROWS];
    const int from_right = (int)(ml_ctx_rng(ctx) & 1u);
    gallery_target *t = &s->targets[slot];
    t->x = (int8_t)(from_right ? TX_MAX : TX_MIN);
    t->y = (int8_t)row;
    t->dir = (int8_t)(from_right ? -1 : 1);   /* inward, one pixel every four ticks */
    t->age = 0;
    t->on = 1;
}

/* One shot at the crosshair's centre. Targets may overlap; only the lowest-index
 * live one under the centre is consumed, so a stack of three needs three shots.
 * A hit extends the streak and pays 10 per point of it up to five; a miss drops
 * the streak to zero. Either way the crosshair flashes. */
static void gallery_fire(gallery_state *s)
{
    int hit = -1;
    for (int i = 0; i < TARGETS; i++) {
        const gallery_target *t = &s->targets[i];
        if (!t->on) continue;
        if (s->cx >= t->x && s->cx < t->x + TARGET_W &&
            s->cy >= t->y && s->cy < t->y + TARGET_H) {
            hit = i;
            break;
        }
    }

    s->flash = FLASH_TICKS;
    if (hit < 0) {
        s->streak = 0;
        return;
    }

    s->targets[hit].on = 0;
    s->streak++;
    const int mult = s->streak > 5 ? 5 : (int)s->streak;
    const int next = (int)s->score + 10 * mult;
    s->score = (uint16_t)(next > SCORE_MAX ? SCORE_MAX : next);
}

static void gallery_init(void *state, const ml_game_cfg *cfg, ml_game_ctx *ctx)
{
    (void)cfg; (void)ctx;
    gallery_state *s = state;
    memset(s, 0, sizeof(*s));
    s->tilt_x = ML_AXIS_IDLE;
    s->tilt_y = ML_AXIS_IDLE;
}

static void gallery_reset(void *state, ml_game_ctx *ctx)
{
    (void)ctx;
    gallery_state *s = state;
    memset(s, 0, sizeof(*s));
    s->cx = (int16_t)ml_axis_map(0, GX_MIN, GX_MAX);   /* 31, the travel's middle */
    s->cy = (int16_t)ml_axis_map(0, GY_MIN, GY_MAX);   /* 20 */
    s->ticks_left = ROUND_TICKS;
    s->spawn_ctr = SPAWN_FIRST;
    s->status = GALLERY_PLAYING;
    s->tilt_x = ML_AXIS_IDLE;
    s->tilt_y = ML_AXIS_IDLE;
}

static void gallery_input(void *state, const ml_input_event *e, ml_game_ctx *ctx)
{
    (void)ctx;
    gallery_state *s = state;

    if (e->type == ML_INPUT_BUTTON) {
        switch (e->code) {
        case GALLERY_UP:    s->held_up    = (uint8_t)(e->value ? 1 : 0); break;
        case GALLERY_DOWN:  s->held_down  = (uint8_t)(e->value ? 1 : 0); break;
        case GALLERY_LEFT:  s->held_left  = (uint8_t)(e->value ? 1 : 0); break;
        case GALLERY_RIGHT: s->held_right = (uint8_t)(e->value ? 1 : 0); break;
        case GALLERY_SHOOT:
            if (e->value) {
                /* A fresh press fires on the next tick whatever the cooldown had
                 * left; a repeat of an already-held press must not re-arm it, or
                 * a controller that resends the level would machine-gun. */
                if (!s->held_shoot) { s->held_shoot = 1; s->shoot_cd = 0; }
            } else {
                s->held_shoot = 0;
                s->shoot_cd = 0;   /* letting go burns the cooldown */
            }
            break;
        default: break;            /* unknown code: ignored */
        }
    } else if (e->type == ML_INPUT_AXIS) {
        if (e->code == GALLERY_TILT_X) s->tilt_x = e->value;
        else if (e->code == GALLERY_TILT_Y) s->tilt_y = e->value;
    }
}

static void gallery_update(void *state, ml_game_ctx *ctx)
{
    gallery_state *s = state;
    if (s->status != GALLERY_PLAYING) return;

    if (s->flash) s->flash--;

    /* aim: an engaged axis is the crosshair's position and a held tilt holds it;
     * buttons take over an idle axis from wherever the crosshair already is.
     * Both axes move in one tick, so a diagonal nudge is a diagonal nudge. */
    if (ml_axis_engaged(s->tilt_x)) {
        s->cx = (int16_t)ml_axis_map(s->tilt_x, GX_MIN, GX_MAX);
    } else {
        if (s->held_left)  s->cx--;
        if (s->held_right) s->cx++;
        s->cx = (int16_t)g_clamp(s->cx, GX_MIN, GX_MAX);
    }
    if (ml_axis_engaged(s->tilt_y)) {
        s->cy = (int16_t)ml_axis_map(s->tilt_y, GY_MIN, GY_MAX);
    } else {
        if (s->held_up)   s->cy--;
        if (s->held_down) s->cy++;
        s->cy = (int16_t)g_clamp(s->cy, GY_MIN, GY_MAX);
    }

    /* spawn, drift and retire, in that order, so a target spawned this tick is
     * already live for the shot below */
    if (s->spawn_ctr > 0) s->spawn_ctr--;
    if (s->spawn_ctr == 0) {
        gallery_spawn(s, ctx);
        s->spawn_ctr = SPAWN_INTERVAL;
    }
    for (int i = 0; i < TARGETS; i++) {
        gallery_target *t = &s->targets[i];
        if (!t->on) continue;
        t->age++;
        if (t->age % MOVE_EVERY == 0)
            t->x = (int8_t)g_clamp(t->x + t->dir, TX_MIN, TX_MAX);
        if (t->age >= TARGET_LIFE) t->on = 0;
    }

    /* shoot after the targets have moved, so a shot lands where the player saw
     * the target at the start of the tick */
    if (s->held_shoot) {
        if (s->shoot_cd > 0) s->shoot_cd--;
        if (s->shoot_cd == 0) {
            gallery_fire(s);
            s->shoot_cd = FIRE_COOLDOWN;
        }
    }

    /* the clock runs last: a shot pressed on the final tick still resolves, and
     * a shot on the tick that ends the round is not a shot after it */
    if (s->ticks_left > 0) s->ticks_left--;
    if (s->ticks_left == 0) s->status = GALLERY_OVER;
}

static void gallery_draw(const void *state, const ml_view *view, ml_canvas *c,
                         const ml_game_ctx *ctx)
{
    (void)view; (void)ctx;
    const gallery_state *s = state;
    ml_canvas_clear(c, ml_black);
    const int W = c->w, H = c->h;

    const ml_font *digits = ml_font_find("digits10");
    if (!digits) digits = ml_font_default();
    const ml_rgb hud = ML_RGB(255, 255, 255);
    char buf[8];

    if (s->status != GALLERY_PLAYING) {
        /* The terminal board is just the score and the outcome: the playfield is
         * cleared, so the clock bar and the crosshair are gone with it. */
        snprintf(buf, sizeof(buf), "%u", (unsigned)s->score);
        ml_text_draw(c, digits, 1, 0, buf, hud, ML_SCALE_1X);
        const ml_font *word = ml_font_find("sans10");
        if (!word) word = ml_font_default();
        const int w = ml_text_width(word, "OVER", ML_SCALE_1X);
        ml_text_draw(c, word, (W - w) / 2, 17, "OVER",
                     ML_RGB(255, 60, 60), ML_SCALE_1X);
        return;
    }

    /* targets, gold 3x3 */
    const ml_rgb gold = ML_RGB(255, 200, 0);
    for (int i = 0; i < TARGETS; i++) {
        const gallery_target *t = &s->targets[i];
        if (!t->on) continue;
        for (int dy = 0; dy < TARGET_H; dy++)
            for (int dx = 0; dx < TARGET_W; dx++)
                ml_canvas_set(c, t->x + dx, t->y + dy, gold);
    }

    /* crosshair: five pixels, white for the couple of ticks after a shot */
    const ml_rgb hair = s->flash ? ML_RGB(255, 255, 255) : ML_RGB(0, 255, 255);
    ml_canvas_set(c, s->cx,     s->cy,     hair);
    ml_canvas_set(c, s->cx - 1, s->cy,     hair);
    ml_canvas_set(c, s->cx + 1, s->cy,     hair);
    ml_canvas_set(c, s->cx,     s->cy - 1, hair);
    ml_canvas_set(c, s->cx,     s->cy + 1, hair);

    /* score, in the HUD band rows 0-9 */
    snprintf(buf, sizeof(buf), "%u", (unsigned)s->score);
    ml_text_draw(c, digits, 1, 0, buf, hud, ML_SCALE_1X);

    /* remaining time, a full-width bar on the last row that shrinks to nothing */
    int bar = (int)((long)s->ticks_left * W / ROUND_TICKS);
    if (bar > W) bar = W;
    if (bar > 0) ml_canvas_hline(c, 0, H - 1, bar, hud);
}

static bool gallery_snapshot(const void *state, uint8_t *buf, size_t cap, size_t *len)
{
    if (cap < sizeof(gallery_state)) return false;
    memcpy(buf, state, sizeof(gallery_state));
    *len = sizeof(gallery_state);
    return true;
}

static void gallery_restore(void *state, const uint8_t *buf, size_t len)
{
    /* Only an exact-sized snapshot is ours; anything else leaves the state be. */
    if (len != sizeof(gallery_state)) return;
    memcpy(state, buf, sizeof(gallery_state));
}

static bool gallery_is_over(const void *state)
{
    const gallery_state *s = state;
    return s->status != GALLERY_PLAYING;
}

const ml_game_vt ml_game_gallery = {
    .id            = "gallery",
    .pref_w        = GW, .pref_h = GH,
    .fit           = ML_FIT_LETTERBOX,
    .tick_ms       = 25,
    .max_players   = 1,
    .state_size    = sizeof(gallery_state),
    .controls      = gallery_controls,
    .control_count = 7,
    .init          = gallery_init,
    .reset         = gallery_reset,
    .input         = gallery_input,
    .update        = gallery_update,
    .draw          = gallery_draw,
    .snapshot      = gallery_snapshot,
    .restore       = gallery_restore,
    .is_over       = gallery_is_over,
};
