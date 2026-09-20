/*
 * game_invaders.c - the fifth game: a cannon, an alien wall, and bullets.
 *
 * The shooter, and the first game whose controls are not all directional:
 * Left, Right, and Shoot. It is also the first with a second actor on the
 * other side: the alien wall fights back with its own bullets, which is what
 * makes it the game that exercises the framework's "one host, one shared
 * board" model the most, even though it is still one player.
 *
 * The wall is 8 columns by 4 rows of 3x3 sprites and every round of the game
 * brings a different one: the round's plan says which kind of alien sits on
 * each of the four rows, how fast the formation marches, how often and how
 * many of them fire at once, and how many of their bullets may be in the air.
 * A kind sets the sprite, the colour, what a kill is worth and what its bullet
 * does (a grunt's drops slowly, a zipper's twice as fast, a sniper aims at the
 * cannon, an anvil takes two hits). Past the sixth plan the last one repeats,
 * a tick faster and a shot heavier each round. A formation marches at the pace
 * its round set from its first alien to its last: the speed comes from the
 * round and never from how much of the wall is left, so thinning out is not
 * what turns the pressure up.
 *
 * The aliens that fire and the column each fires down are deterministic from
 * the session PRNG, as is the fire cadence. The cannon has three lives; losing
 * all of them, or letting the wall march down to the cannon row, ends the
 * game. Clearing a round refills the wall with the next round's enemies and
 * pays a bonus that grows with the round.
 *
 * Shoot fires one bullet per press and never waits for the last one to land:
 * a bullet in the air does not hold the next press back, so the cannon keeps
 * as many of its own bullets climbing as the player presses for. Each bullet
 * stops at its first hit, and a press never overwrites one already flying.
 */
#include <stdio.h>
#include <string.h>

#include "mirror/font.h"
#include "mirror/game.h"
#include "mirror/gamerun.h"

#define INV_COLS 8
#define INV_ROWS 4
#define INV_SPRITE_W 3
#define INV_SPRITE_H 3
#define INV_GAP_X 5              /* px between sprite origins */
#define INV_GAP_Y 4
#define INV_GRID_W (INV_SPRITE_W + (INV_COLS - 1) * INV_GAP_X)   /* 38 */
#define INV_ASHOTS_MAX 12       /* the array bound; each round's plan caps the air */
#define INV_PSHOTS_MAX 128      /* the array bound on the cannon's own bullets */
#define INV_ROUNDS 6            /* plans in the table; past it the last repeats harder */

/* The four things an alien can be. A team's kind sets its sprite and colour, what
 * a kill is worth, and what its bullet does; the round's plan sets how many of
 * them are on the wall, how fast it marches and how often it fires. */
enum { INV_GRUNT = 0, INV_ZIPPER, INV_SNIPER, INV_ANVIL, INV_KIND_COUNT };

enum { INV_PLAYING = 0, INV_OVER = 1 };

typedef struct {
    uint8_t kind[INV_ROWS];   /* row 0 is the top row of the wall */
    uint8_t step_interval;    /* ticks per formation step, the whole round */
    uint8_t shot_min, shot_span;  /* fire cadence: shot_min + rng % shot_span */
    uint8_t fire_count;       /* aliens that fire on one fire tick */
    uint8_t max_shots;        /* alien bullets allowed in the air at once */
} inv_round_plan;

static const inv_round_plan INV_PLANS[INV_ROUNDS] = {
    /* 1: the shipped wave — four rows of grunts, one slow shot at a time */
    { { INV_GRUNT,  INV_GRUNT,  INV_GRUNT,  INV_GRUNT  }, 12, 30, 40, 1, 1 },
    /* 2: zippers in the front rows, their shot falls twice as fast */
    { { INV_GRUNT,  INV_GRUNT,  INV_ZIPPER, INV_ZIPPER }, 11, 26, 36, 1, 2 },
    /* 3: snipers on top, aiming their shot at the cannon */
    { { INV_SNIPER, INV_SNIPER, INV_ZIPPER, INV_ZIPPER }, 10, 24, 32, 1, 3 },
    /* 4: anvils on top take two hits, and the wall marches sooner */
    { { INV_ANVIL,  INV_SNIPER, INV_ZIPPER, INV_GRUNT  },  9, 22, 30, 1, 3 },
    /* 5: two aliens fire together */
    { { INV_ANVIL,  INV_ANVIL,  INV_SNIPER, INV_ZIPPER },  8, 20, 28, 2, 4 },
    /* 6: three armour rows and two shots a volley */
    { { INV_ANVIL,  INV_ANVIL,  INV_ANVIL,  INV_SNIPER },  7, 18, 24, 2, 5 },
};

/* The plan for a round, written into *out. Past the table the last plan repeats
 * harder: the wall marches and fires a tick sooner per extra round, and the
 * volley gains a shot every third round. Pure — no state and no allocation — so
 * update and draw agree without sharing anything. */
static void inv_plan_for(uint8_t round, inv_round_plan *out)
{
    int i = round > 0 ? (int)round - 1 : 0;
    if (i >= INV_ROUNDS) {
        int extra = i - (INV_ROUNDS - 1);
        *out = INV_PLANS[INV_ROUNDS - 1];
        int si = (int)out->step_interval - extra;
        int lo = (int)out->shot_min - extra;
        int sp = (int)out->shot_span - extra;
        int fc = 2 + extra / 3;
        out->step_interval = (uint8_t)(si < 3 ? 3 : si);
        out->shot_min = (uint8_t)(lo < 8 ? 8 : lo);
        out->shot_span = (uint8_t)(sp < 12 ? 12 : sp);
        out->fire_count = (uint8_t)(fc > 5 ? 5 : fc);
        if (out->max_shots < INV_ASHOTS_MAX) out->max_shots++;
        return;
    }
    *out = INV_PLANS[i];
}

typedef struct {
    int16_t panel_w, panel_h;
    int16_t px;                  /* cannon left x */
    int16_t ax, ay;              /* alien grid origin */
    uint8_t dir;                 /* 1 right, 0 left */
    uint8_t step_ctr;
    uint8_t shot_ctr, shot_interval;
    uint8_t n_alive;
    uint8_t lives;
    uint8_t status;
    uint8_t held_l, held_r, held_s;
    int16_t steer_x;             /* tilt axis, ML_AXIS_IDLE when unused */
    uint16_t score;
    uint8_t round;               /* 1-based: which plan is in play */
    uint8_t intro;               /* ticks left of the new-round blink */
    uint32_t aliens;             /* bit r*8+c = alive */
    uint32_t armor;              /* bit set: this alien still wears armour */
    struct { int16_t x, y; uint8_t on; } pshots[INV_PSHOTS_MAX];  /* cannon bullets */
    struct { int16_t x, y; uint8_t on; uint8_t step; } ashots[INV_ASHOTS_MAX];
} invaders_state;

/* The runtime prefixes every serialized snapshot with the host tick, so the
 * state has to fit inside what is left of the payload. */
typedef char invaders_state_fits
    [(sizeof(invaders_state) <= ML_SNAPSHOT_MAX - sizeof(uint32_t)) ? 1 : -1];

static const ml_control_def invaders_controls[] = {
    { .label = "Left",  .code = 0, .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "Right", .code = 1, .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "Shoot", .code = 2, .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "TiltX", .code = 3, .caps = ML_CAP_ACCEL,  .type = ML_INPUT_AXIS },
};

static bool alien_alive(const invaders_state *s, int row, int col)
{
    return (s->aliens & (1u << (row * INV_COLS + col))) != 0;
}

/* A kind that came out of a restored or hand-built state must never index off
 * the tables below, so the helpers clamp it the way the rest of the game
 * clamps a panel coordinate. */
static int inv_kind_clamp(int kind)
{
    if (kind < 0) return 0;
    return kind >= INV_KIND_COUNT ? INV_KIND_COUNT - 1 : kind;
}

static uint16_t inv_kind_score(int kind)
{
    static const uint16_t s[INV_KIND_COUNT] = { 10, 20, 30, 40 };
    return s[inv_kind_clamp(kind)];
}

static uint8_t inv_kind_bullet(int kind) { return inv_kind_clamp(kind) == INV_ZIPPER ? 2 : 1; }
static bool    inv_kind_aimed(int kind)  { return inv_kind_clamp(kind) == INV_SNIPER; }
static bool    inv_kind_armored(int kind){ return inv_kind_clamp(kind) == INV_ANVIL; }

static ml_rgb inv_kind_color(int kind)
{
    switch (inv_kind_clamp(kind)) {
    case INV_GRUNT:  return ML_RGB(0, 240, 110);     /* green */
    case INV_ZIPPER: return ML_RGB(255, 160, 40);    /* amber */
    case INV_SNIPER: return ML_RGB(255, 60, 60);     /* red */
    default:         return ML_RGB(200, 200, 220);   /* steel */
    }
}

/* One alien dies: worth what its kind is worth this round. */
static void alien_kill(invaders_state *s, int row, int col)
{
    inv_round_plan plan;
    inv_plan_for(s->round, &plan);
    uint32_t bit = 1u << (row * INV_COLS + col);
    s->aliens &= ~bit;
    s->armor &= ~bit;
    s->n_alive--;
    s->score += inv_kind_score(plan.kind[row]);
}

/* A cannon bullet arrived at (row,col): armour takes the hit and cracks, worth a
 * fifth of the kill, and an unarmoured or already-cracked alien dies. Returns
 * whether the alien died. */
static bool alien_hit(invaders_state *s, int row, int col)
{
    uint32_t bit = 1u << (row * INV_COLS + col);
    if (s->armor & bit) {
        s->armor &= ~bit;
        s->score += 10;
        return false;
    }
    alien_kill(s, row, col);
    return true;
}

/* Fill the wall for a round: all 32 aliens alive, armour on the rows whose kind
 * wears it, the grid centred at the top and marching right. */
static void refill_wave(invaders_state *s, uint8_t round)
{
    inv_round_plan plan;
    inv_plan_for(round, &plan);
    s->aliens = 0xFFFFFFFFu;
    s->n_alive = INV_COLS * INV_ROWS;
    s->armor = 0;
    for (int row = 0; row < INV_ROWS; row++)
        if (inv_kind_armored(plan.kind[row]))
            for (int col = 0; col < INV_COLS; col++)
                s->armor |= 1u << (row * INV_COLS + col);
    s->ax = (int16_t)((s->panel_w - INV_GRID_W) / 2);
    s->ay = 3;
    s->dir = 1;
    s->step_ctr = 0;
}

/* Every cannon bullet is spent at once: the wall is cleared, the round is
 * refilled, or the cannon was hit. */
static void inv_clear_pshots(invaders_state *s)
{
    for (int i = 0; i < INV_PSHOTS_MAX; i++) s->pshots[i].on = 0;
}

/* The live formation's edges: the leftmost live sprite's left column, the
 * rightmost live sprite's right column, and the lowest live sprite's bottom
 * row. False when nothing is alive, which means there is no formation left to
 * bound. Only the aliens still on the wall are measured - the grid's own empty
 * cells are not part of it - so the wall neither turns a step early because of
 * a column it has cleared, nor invades from a row that holds nothing. */
static bool inv_live_bounds(const invaders_state *s, int *left, int *right,
                            int *bottom)
{
    int l = 0, r = 0, b = 0;
    bool any = false;
    for (int row = 0; row < INV_ROWS; row++) {
        for (int col = 0; col < INV_COLS; col++) {
            if (!alien_alive(s, row, col)) continue;
            const int x0 = s->ax + col * INV_GAP_X;
            const int y1 = s->ay + row * INV_GAP_Y + INV_SPRITE_H - 1;
            if (!any) { l = x0; r = x0 + INV_SPRITE_W - 1; b = y1; any = true; }
            else {
                if (x0 < l) l = x0;
                if (x0 + INV_SPRITE_W - 1 > r) r = x0 + INV_SPRITE_W - 1;
                if (y1 > b) b = y1;
            }
        }
    }
    *left = l;
    *right = r;
    *bottom = b;
    return any;
}

/* The formation's pace: the round's interval, the same on the first alien as
 * on the last one. Rounds get faster and a thinning wall does not, so the
 * pressure is the round's own and never an accident of how much of the wall
 * the player has cleared. */
static uint8_t march_interval(const invaders_state *s)
{
    inv_round_plan plan;
    inv_plan_for(s->round, &plan);
    return plan.step_interval;
}

static void invaders_init(void *state, const ml_game_cfg *cfg, ml_game_ctx *ctx)
{
    (void)ctx;
    invaders_state *s = state;
    memset(s, 0, sizeof(*s));
    s->panel_w = (int16_t)cfg->panel_w;
    s->panel_h = (int16_t)cfg->panel_h;
}

static void invaders_reset(void *state, ml_game_ctx *ctx)
{
    (void)ctx;
    invaders_state *s = state;
    inv_round_plan plan;
    s->round = 1;
    s->intro = 40;
    refill_wave(s, 1);
    s->px = (int16_t)((s->panel_w - INV_SPRITE_W) / 2);
    s->step_ctr = 0;
    s->shot_ctr = 0;
    inv_plan_for(s->round, &plan);
    s->shot_interval = plan.shot_min;
    s->lives = 3;
    s->status = INV_PLAYING;
    s->score = 0;
    s->held_l = 0;
    s->held_r = 0;
    s->held_s = 0;
    s->steer_x = ML_AXIS_IDLE;
    inv_clear_pshots(s);
    for (int i = 0; i < INV_ASHOTS_MAX; i++) s->ashots[i].on = 0;
}

static void invaders_input(void *state, const ml_input_event *e, ml_game_ctx *ctx)
{
    (void)ctx;
    invaders_state *s = state;
    if (s->status != INV_PLAYING) return;
    switch (e->code) {
    case 0: s->held_l = e->value ? 1 : 0; break;
    case 1: s->held_r = e->value ? 1 : 0; break;
    case 2:  /* Shoot: one bullet per press, however many are already flying */
        if (e->value) {
            /* The phone streams the whole held state every frame and the
             * keyboard repeats a held key, so a held Shoot arrives as a run of
             * value=1 events: fire once per press, not once per packet. A
             * release re-arms the next press. */
            if (!s->held_s) {
                for (int i = 0; i < INV_PSHOTS_MAX; i++) {
                    if (s->pshots[i].on) continue;
                    s->pshots[i].x = (int16_t)(s->px + 1);
                    s->pshots[i].y = (int16_t)(s->panel_h - 4);
                    s->pshots[i].on = 1;
                    break;
                }
            }
        }
        s->held_s = e->value ? 1 : 0;
        break;
    case 3:  /* Tilt: the phone's angle, as a position */
        s->steer_x = e->value;
        break;
    default: break;
    }
}

/* Alien fire: a random column that still has something alive in it, and its
 * front-most alien shoots. What the shot does is the kind's business — a grunt
 * sends a slow bullet down its own column, a zipper the same bullet twice as
 * fast, a sniper one aimed at the cannon's own column, an anvil a slow one. */
static void alien_fire(invaders_state *s, ml_game_ctx *ctx)
{
    inv_round_plan plan;
    inv_plan_for(s->round, &plan);
    for (int k = 0; k < plan.fire_count; k++) {
        int in_flight = 0, slot = -1;
        for (int i = 0; i < INV_ASHOTS_MAX; i++) {
            if (s->ashots[i].on) in_flight++;
            else if (slot < 0) slot = i;
        }
        if (slot < 0 || in_flight >= plan.max_shots) return;
        int col = -1, row = -1;
        int start = (int)(ml_ctx_rng(ctx) % INV_COLS);
        for (int i = 0; i < INV_COLS && col < 0; i++) {
            int c = (start + i) % INV_COLS;
            for (int r = INV_ROWS - 1; r >= 0; r--)
                if (alien_alive(s, r, c)) { col = c; row = r; break; }
        }
        if (col < 0) return;                       /* nothing left to shoot */
        int kind = plan.kind[row];
        int x = s->ax + col * INV_GAP_X + 1;
        if (inv_kind_aimed(kind)) {                /* the sniper leads the cannon */
            x = (int)s->px + INV_SPRITE_W / 2;
            if (x < 0) x = 0;
            if (x > s->panel_w - 1) x = s->panel_w - 1;
        }
        s->ashots[slot].x = (int16_t)x;
        s->ashots[slot].y = (int16_t)(s->ay + row * INV_GAP_Y + INV_SPRITE_H);
        s->ashots[slot].step = inv_kind_bullet(kind);
        s->ashots[slot].on = 1;
    }
}

static void invaders_update(void *state, ml_game_ctx *ctx)
{
    invaders_state *s = state;
    if (s->status != INV_PLAYING) return;
    if (s->intro) s->intro--;

    /* The wall is cleared: the next round refills it with the enemies that round
     * carries, pays a bonus that grows with the round, and blinks the new number.
     * The tick that killed the last alien returned below without marching or
     * firing, so the clear frame is what the player sees and a hostile bullet
     * already in the air cannot turn the kill into a loss. */
    if (s->n_alive == 0) {
        s->round++;
        s->score += (uint16_t)(25 * s->round);
        refill_wave(s, s->round);
        s->intro = 40;
        inv_clear_pshots(s);
        for (int i = 0; i < INV_ASHOTS_MAX; i++) s->ashots[i].on = 0;
        return;
    }

    /* cannon: on tilt it sits where the phone points, so a held angle holds
     * it; on buttons it moves 1 px/tick while held */
    if (ml_axis_engaged(s->steer_x)) {
        s->px = (int16_t)ml_axis_map(s->steer_x, 0, s->panel_w - INV_SPRITE_W);
    } else {
        if (s->held_l && s->px > 0) s->px--;
        if (s->held_r && s->px < s->panel_w - INV_SPRITE_W) s->px++;
    }

    /* cannon bullets: every one of them climbs two pixels, and the ones that
     * leave the panel are spent */
    for (int i = 0; i < INV_PSHOTS_MAX; i++) {
        if (!s->pshots[i].on) continue;
        s->pshots[i].y -= 2;
        if (s->pshots[i].y < 0) s->pshots[i].on = 0;
    }

    /* cannon bullets vs aliens: armour cracks first, a bare alien dies. Each
     * bullet stops at its first hit, so one bullet never kills two aliens
     * however many are in the air. */
    for (int i = 0; i < INV_PSHOTS_MAX; i++) {
        if (!s->pshots[i].on) continue;
        for (int row = 0; row < INV_ROWS; row++) {
            for (int col = 0; col < INV_COLS; col++) {
                if (!alien_alive(s, row, col)) continue;
                int x0 = s->ax + col * INV_GAP_X;
                int y0 = s->ay + row * INV_GAP_Y;
                if (s->pshots[i].x >= x0 && s->pshots[i].x <= x0 + INV_SPRITE_W - 1 &&
                    s->pshots[i].y >= y0 && s->pshots[i].y <= y0 + INV_SPRITE_H - 1) {
                    alien_hit(s, row, col);
                    s->pshots[i].on = 0;
                    break;
                }
            }
            if (!s->pshots[i].on) break;
        }
    }

    /* That was the last alien. The tick ends here rather than marching, firing
     * and taking hostile fire off a wall the player has just finished: the next
     * update brings the next round. */
    if (s->n_alive == 0) return;

    /* The wall marches: one pixel a step the way it is going, a row down when a
     * live sprite reaches either edge, at the pace the round set. The edges are
     * the live aliens' own, so a cleared column or row neither turns the wall
     * early nor lets it march off the panel. */
    if (++s->step_ctr >= march_interval(s)) {
        s->step_ctr = 0;
        int left, right, bottom;
        if (inv_live_bounds(s, &left, &right, &bottom)) {
            if (s->dir == 1 && right >= s->panel_w - 1) { s->dir = 0; s->ay += 3; }
            else if (s->dir == 0 && left <= 1)          { s->dir = 1; s->ay += 3; }
            else if (s->dir == 1)                         s->ax++;
            else                                          s->ax--;

            /* Invasion is the lowest surviving sprite reaching the cannon's own
             * first drawn row, not the hollow grid box around it: a wall whose
             * bottom rows are empty has not arrived. */
            if (inv_live_bounds(s, &left, &right, &bottom) &&
                bottom >= s->panel_h - 2) {
                s->status = INV_OVER;
                return;
            }
        }
    }

    /* alien fire: this round's volley, then a fresh cadence for the next one */
    if (++s->shot_ctr >= s->shot_interval) {
        s->shot_ctr = 0;
        inv_round_plan plan;
        inv_plan_for(s->round, &plan);
        s->shot_interval = (uint8_t)(plan.shot_min + ml_ctx_rng(ctx) % plan.shot_span);
        alien_fire(s, ctx);
    }

    /* alien bullets */
    for (int i = 0; i < INV_ASHOTS_MAX; i++) {
        if (!s->ashots[i].on) continue;
        s->ashots[i].y = (int16_t)(s->ashots[i].y + s->ashots[i].step);
        if (s->ashots[i].y >= s->panel_h) { s->ashots[i].on = 0; continue; }

        /* vs cannon: the hit spends every bullet the cannon has in the air */
        if (s->ashots[i].x >= s->px && s->ashots[i].x <= s->px + INV_SPRITE_W - 1 &&
            s->ashots[i].y >= s->panel_h - 2) {
            s->ashots[i].on = 0;
            inv_clear_pshots(s);
            s->lives--;
            if (s->lives == 0) { s->status = INV_OVER; return; }
            for (int j = 0; j < INV_ASHOTS_MAX; j++) s->ashots[j].on = 0;
            continue;
        }

        /* vs cannon bullets: both die, whichever bullets were in the way */
        for (int j = 0; j < INV_PSHOTS_MAX; j++) {
            if (!s->pshots[j].on) continue;
            if (s->ashots[i].x == s->pshots[j].x && s->ashots[i].y == s->pshots[j].y) {
                s->ashots[i].on = 0;
                s->pshots[j].on = 0;
                break;
            }
        }
    }
}

/* One 3x3 alien at the grid origin, in its kind's colour. The shapes are
 * deliberately unlike each other, and every one lights the centre cell: a crab
 * with legs (grunt), a winged row (zipper), a crosshair (sniper), and a solid
 * block that becomes the crab shape in steel once its armour has cracked (anvil). */
static void inv_draw_sprite(ml_canvas *c, int kind, bool armored, int x0, int y0)
{
    /* Bit 2 is the sprite's left column. */
    static const uint8_t SHAPE[5][INV_SPRITE_H] = {
        { 0x2, 0x7, 0x5 },   /* grunt: a crab */
        { 0x7, 0x2, 0x5 },   /* zipper: a winged row */
        { 0x2, 0x7, 0x2 },   /* sniper: a crosshair */
        { 0x7, 0x7, 0x7 },   /* anvil with its armour on: a solid block */
        { 0x2, 0x7, 0x5 },   /* anvil cracked: the crab shape in its own colour */
    };
    kind = inv_kind_clamp(kind);
    int shape = (kind == INV_ANVIL) ? (armored ? 3 : 4) : kind;
    ml_rgb col = inv_kind_color(kind);
    for (int r = 0; r < INV_SPRITE_H; r++)
        for (int x = 0; x < INV_SPRITE_W; x++)
            if (SHAPE[shape][r] & (1u << (INV_SPRITE_W - 1 - x)))
                ml_canvas_set(c, x0 + x, y0 + r, col);
}

static void invaders_draw(const void *state, const ml_view *view, ml_canvas *c,
                          const ml_game_ctx *ctx)
{
    (void)view; (void)ctx;
    const invaders_state *s = state;
    ml_canvas_clear(c, ml_black);
    int W = c->w, H = c->h;

    /* alien sprites: the round's plan decides what each row of the wall is */
    inv_round_plan plan;
    inv_plan_for(s->round, &plan);
    for (int row = 0; row < INV_ROWS; row++) {
        const int kind = plan.kind[row];
        for (int c2 = 0; c2 < INV_COLS; c2++) {
            if (!alien_alive(s, row, c2)) continue;
            const bool armored = (s->armor & (1u << (row * INV_COLS + c2))) != 0;
            inv_draw_sprite(c, kind, armored,
                            s->ax + c2 * INV_GAP_X, s->ay + row * INV_GAP_Y);
        }
    }

    /* cannon */
    ml_rgb pad = ML_RGB(0, 229, 255);
    for (int x = 0; x < 3; x++) {
        ml_canvas_set(c, s->px + x, H - 2, pad);
        ml_canvas_set(c, s->px + x, H - 1, pad);
    }

    /* bullets: cannon white, aliens red */
    for (int i = 0; i < INV_PSHOTS_MAX; i++)
        if (s->pshots[i].on && s->pshots[i].y >= 0 && s->pshots[i].y < H)
            ml_canvas_set(c, s->pshots[i].x, s->pshots[i].y, ML_RGB(255, 255, 255));
    for (int i = 0; i < INV_ASHOTS_MAX; i++)
        if (s->ashots[i].on && s->ashots[i].y >= 0 && s->ashots[i].y < H)
            ml_canvas_set(c, s->ashots[i].x, s->ashots[i].y, ML_RGB(255, 60, 40));

    /* The HUD line reads round:score — the round first, because it is the thing
     * that changes. It blinks for the first second of a round (intro counts down
     * from 40 ticks) so a player watching the wall still sees that it has
     * changed, and so the aliens behind it are uncovered half of the intro. */
    if (s->intro == 0 || ((s->intro / 5) & 1) == 0) {
        char buf[16];
        const ml_font *f = ml_font_find("digits10");
        if (!f) f = ml_font_default();
        snprintf(buf, sizeof(buf), "%u:%u", (unsigned)s->round, (unsigned)s->score);
        ml_text_draw(c, f, 1, 1, buf, pad, ML_SCALE_1X);
    }

    if (s->status == INV_OVER) {
        const ml_font *of = ml_font_find("sans10");
        if (!of) of = ml_font_default();
        int th = ml_text_height(of, ML_SCALE_1X);
        int top = (H - (2 * th + 1)) / 2;
        ml_text_draw(c, of, (W - ml_text_width(of, "GAME", ML_SCALE_1X)) / 2,
                     top, "GAME", ML_RGB(255, 60, 60), ML_SCALE_1X);
        ml_text_draw(c, of, (W - ml_text_width(of, "OVER", ML_SCALE_1X)) / 2,
                     top + th + 1, "OVER", ML_RGB(255, 60, 60), ML_SCALE_1X);
    }
}

static bool invaders_snapshot(const void *state, uint8_t *buf, size_t cap, size_t *len)
{
    if (cap < sizeof(invaders_state)) return false;
    memcpy(buf, state, sizeof(invaders_state));
    *len = sizeof(invaders_state);
    return true;
}

static void invaders_restore(void *state, const uint8_t *buf, size_t len)
{
    size_t n = len < sizeof(invaders_state) ? len : sizeof(invaders_state);
    memcpy(state, buf, n);
}

static bool invaders_is_over(const void *state)
{
    const invaders_state *s = state;
    return s->status == INV_OVER;
}

const ml_game_vt ml_game_invaders = {
    .id            = "invaders",
    .pref_w        = 0, .pref_h = 0,
    .fit           = ML_FIT_ADAPTIVE,
    .tick_ms       = 25,
    .max_players   = 1,
    .state_size    = sizeof(invaders_state),
    .controls      = invaders_controls,
    .control_count = 4,
    .init          = invaders_init,
    .reset         = invaders_reset,
    .input         = invaders_input,
    .update        = invaders_update,
    .draw          = invaders_draw,
    .snapshot      = invaders_snapshot,
    .restore       = invaders_restore,
    .is_over       = invaders_is_over,
};
