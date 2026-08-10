/*
 * game_invaders.c - the fifth game: a cannon, an alien wall, and bullets.
 *
 * The shooter, and the first game whose controls are not all directional:
 * Left, Right, and Shoot. It is also the first with a second actor on the
 * other side: the alien wall fights back with its own bullets, which is what
 * makes it the game that exercises the framework's "one host, one shared
 * board" model the most, even though it is still one player.
 *
 * The wall is 8 columns by 4 rows of 3x3 sprites; every position is
 * deterministic from the session PRNG, which picks the alien-shot cadence
 * and which column fires. The cannon has three lives; losing all of them, or
 * letting the wall march down to the cannon row, ends the game. Clearing a
 * wave refills the wall and marches it faster.
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
#define INV_GRID_H (INV_SPRITE_H + (INV_ROWS - 1) * INV_GAP_Y)   /* 15 */
#define INV_ASHOTS_MAX 8

enum { INV_PLAYING = 0, INV_OVER = 1 };

typedef struct {
    int16_t panel_w, panel_h;
    int16_t px;                  /* cannon left x */
    int16_t ax, ay;              /* alien grid origin */
    uint8_t dir;                 /* 1 right, 0 left */
    uint8_t step_ctr, step_interval;
    uint8_t shot_ctr, shot_interval;
    uint8_t n_alive;
    uint8_t lives;
    uint8_t status;
    uint8_t held_l, held_r;
    uint8_t pad;
    uint16_t score;
    uint32_t aliens;             /* bit r*8+c = alive */
    struct { int16_t x, y; uint8_t on; } pshot;          /* cannon bullet */
    struct { int16_t x, y; uint8_t on; } ashots[INV_ASHOTS_MAX];
} invaders_state;

typedef char invaders_state_fits[(sizeof(invaders_state) <= ML_SNAPSHOT_MAX) ? 1 : -1];

static const ml_control_def invaders_controls[] = {
    { .label = "Left",  .code = 0, .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "Right", .code = 1, .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "Shoot", .code = 2, .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
};

static bool alien_alive(const invaders_state *s, int row, int col)
{
    return (s->aliens & (1u << (row * INV_COLS + col))) != 0;
}

static void alien_kill(invaders_state *s, int row, int col)
{
    s->aliens &= ~(1u << (row * INV_COLS + col));
    s->n_alive--;
    s->score += (uint16_t)((row + 1) * 10);
}

static void refill_wave(invaders_state *s)
{
    s->aliens = 0xFFFFFFFFu;        /* all 32 aliens alive */
    s->n_alive = INV_COLS * INV_ROWS;
    s->ax = (int16_t)((s->panel_w - INV_GRID_W) / 2);
    s->ay = 3;
    s->dir = 1;
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
    refill_wave(s);
    s->px = (int16_t)((s->panel_w - INV_SPRITE_W) / 2);
    s->step_ctr = 0;
    s->step_interval = 12;
    s->shot_ctr = 0;
    s->shot_interval = 30;
    s->lives = 3;
    s->status = INV_PLAYING;
    s->score = 0;
    s->held_l = 0;
    s->held_r = 0;
    s->pshot.on = 0;
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
    case 2:  /* Shoot: press only, one bullet in flight at a time */
        if (e->value && !s->pshot.on) {
            s->pshot.x = (int16_t)(s->px + 1);
            s->pshot.y = (int16_t)(s->panel_h - 4);
            s->pshot.on = 1;
        }
        break;
    default: break;
    }
}

static void invaders_update(void *state, ml_game_ctx *ctx)
{
    invaders_state *s = state;
    if (s->status != INV_PLAYING) return;

    /* cannon moves 1 px/tick while held */
    if (s->held_l && s->px > 0) s->px--;
    if (s->held_r && s->px < s->panel_w - INV_SPRITE_W) s->px++;

    /* cannon bullet */
    if (s->pshot.on) {
        s->pshot.y -= 2;
        if (s->pshot.y < 0) s->pshot.on = 0;
    }

    /* cannon bullet vs aliens */
    if (s->pshot.on) {
        for (int row = 0; row < INV_ROWS && s->pshot.on; row++) {
            for (int col = 0; col < INV_COLS && s->pshot.on; col++) {
                if (!alien_alive(s, row, col)) continue;
                int x0 = s->ax + col * INV_GAP_X;
                int y0 = s->ay + row * INV_GAP_Y;
                if (s->pshot.x >= x0 && s->pshot.x <= x0 + INV_SPRITE_W - 1 &&
                    s->pshot.y >= y0 && s->pshot.y <= y0 + INV_SPRITE_H - 1) {
                    alien_kill(s, row, col);
                    s->pshot.on = 0;
                    if (s->n_alive == 0) {       /* wave cleared: refill, faster */
                        refill_wave(s);
                        s->step_interval = s->step_interval > 2 ? (uint8_t)(s->step_interval - 2) : 2;
                    }
                }
            }
        }
    }

    /* alien wall marches, faster as it thins out */
    if (++s->step_ctr >= s->step_interval) {
        s->step_ctr = 0;
        int edge_r = s->ax + INV_GRID_W - 1;
        if (s->dir == 1 && edge_r >= s->panel_w - 1) { s->dir = 0; s->ay += 3; }
        else if (s->dir == 0 && s->ax <= 1)         { s->dir = 1; s->ay += 3; }
        else if (s->dir == 1)                         s->ax++;
        else                                          s->ax--;
        if (s->ay + INV_GRID_H - 1 >= s->panel_h - 3) {
            s->status = INV_OVER;
            return;
        }
    }

    /* alien bullets: a random alive column fires on a random cadence */
    if (++s->shot_ctr >= s->shot_interval) {
        s->shot_ctr = 0;
        s->shot_interval = (uint8_t)(30 + ml_ctx_rng(ctx) % 40);
        int col = (int)(ml_ctx_rng(ctx) % INV_COLS);
        for (int row = INV_ROWS - 1; row >= 0; row--) {
            if (!alien_alive(s, row, col)) continue;
            for (int i = 0; i < INV_ASHOTS_MAX; i++) {
                if (s->ashots[i].on) continue;
                s->ashots[i].x = (int16_t)(s->ax + col * INV_GAP_X + 1);
                s->ashots[i].y = (int16_t)(s->ay + row * INV_GAP_Y + INV_SPRITE_H);
                s->ashots[i].on = 1;
                break;
            }
            break;
        }
    }

    /* alien bullets */
    for (int i = 0; i < INV_ASHOTS_MAX; i++) {
        if (!s->ashots[i].on) continue;
        s->ashots[i].y++;
        if (s->ashots[i].y >= s->panel_h) { s->ashots[i].on = 0; continue; }

        /* vs cannon */
        if (s->ashots[i].x >= s->px && s->ashots[i].x <= s->px + INV_SPRITE_W - 1 &&
            s->ashots[i].y >= s->panel_h - 2) {
            s->ashots[i].on = 0;
            s->pshot.on = 0;
            s->lives--;
            if (s->lives == 0) { s->status = INV_OVER; return; }
            for (int j = 0; j < INV_ASHOTS_MAX; j++) s->ashots[j].on = 0;
            continue;
        }

        /* vs cannon bullet: both die */
        if (s->pshot.on && s->ashots[i].x == s->pshot.x && s->ashots[i].y == s->pshot.y) {
            s->ashots[i].on = 0;
            s->pshot.on = 0;
        }
    }
}

static void invaders_draw(const void *state, const ml_view *view, ml_canvas *c,
                          const ml_game_ctx *ctx)
{
    (void)view; (void)ctx;
    const invaders_state *s = state;
    ml_canvas_clear(c, ml_black);
    int W = c->w, H = c->h;

    /* alien sprites: a little crab, two shades by row */
    for (int row = 0; row < INV_ROWS; row++) {
        ml_rgb col = (row & 1) ? ML_RGB(0, 200, 80) : ML_RGB(0, 240, 110);
        for (int c2 = 0; c2 < INV_COLS; c2++) {
            if (!alien_alive(s, row, c2)) continue;
            int x0 = s->ax + c2 * INV_GAP_X;
            int y0 = s->ay + row * INV_GAP_Y;
            ml_canvas_set(c, x0 + 1, y0, col);
            for (int x = 0; x < 3; x++) ml_canvas_set(c, x0 + x, y0 + 1, col);
            ml_canvas_set(c, x0,     y0 + 2, col);
            ml_canvas_set(c, x0 + 2, y0 + 2, col);
        }
    }

    /* cannon */
    ml_rgb pad = ML_RGB(0, 229, 255);
    for (int x = 0; x < 3; x++) {
        ml_canvas_set(c, s->px + x, H - 2, pad);
        ml_canvas_set(c, s->px + x, H - 1, pad);
    }

    /* bullets: cannon white, aliens red */
    if (s->pshot.on && s->pshot.y >= 0 && s->pshot.y < H)
        ml_canvas_set(c, s->pshot.x, s->pshot.y, ML_RGB(255, 255, 255));
    for (int i = 0; i < INV_ASHOTS_MAX; i++)
        if (s->ashots[i].on && s->ashots[i].y >= 0 && s->ashots[i].y < H)
            ml_canvas_set(c, s->ashots[i].x, s->ashots[i].y, ML_RGB(255, 60, 40));

    /* score */
    char buf[8];
    const ml_font *f = ml_font_find("digits10");
    if (!f) f = ml_font_default();
    snprintf(buf, sizeof(buf), "%u", (unsigned)s->score);
    ml_text_draw(c, f, 1, 1, buf, pad, ML_SCALE_1X);
    (void)W;
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

const ml_game_vt ml_game_invaders = {
    .id            = "invaders",
    .pref_w        = 0, .pref_h = 0,
    .fit           = ML_FIT_ADAPTIVE,
    .tick_ms       = 25,
    .max_players   = 1,
    .state_size    = sizeof(invaders_state),
    .controls      = invaders_controls,
    .control_count = 3,
    .init          = invaders_init,
    .reset         = invaders_reset,
    .input         = invaders_input,
    .update        = invaders_update,
    .draw          = invaders_draw,
    .snapshot      = invaders_snapshot,
    .restore       = invaders_restore,
};
