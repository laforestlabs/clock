/*
 * game_snake.c - the second game: a one-player snake on any panel.
 *
 * The framework's second game is the smallest one that needs a different input
 * surface than rally: four directions instead of two, a d-pad instead of two
 * buttons. Everything else inherits the contract: the board is the whole panel
 * (adaptive, 1px cells), the state is plain POD under ML_SNAPSHOT_MAX, food is
 * placed with the session PRNG in update (never in draw), and nothing in the
 * loop allocates or reads a wall clock.
 *
 * The body is a ring buffer of at most 500 cells. That cap is the state-size
 * budget: 500 segments at 2 bytes plus a few fixed fields, all inside the
 * 1024-byte snapshot cap, so snapshot/restore stay a memcpy like rally and a
 * full-ring game is a win, not a wrap-around bug. A static assert below pins
 * the budget so a future edit that grows the state fails to compile.
 *
 * Speed is panel-constant, not panel-relative: the snake steps one cell every
 * w/16 ticks (min 1), so roughly 640 px/s on every panel. A 64-wide panel is
 * no faster than a 128-wide one; the width only changes how far there is to
 * go. That is rally's constant ball speed, in cell units.
 */
#include <stdio.h>
#include <string.h>

#include "mirror/font.h"
#include "mirror/game.h"
#include "mirror/gamerun.h"

/* body length cap: 2 bytes per segment, must keep state under ML_SNAPSHOT_MAX */
#define SNAKE_MAX 500

enum {
    SNAKE_PLAYING = 0,
    SNAKE_DEAD    = 1,   /* hit a wall or itself */
    SNAKE_WON     = 2,   /* filled the board, or hit the length cap */
};

/* discrete events for sound/haptics on the controller side */
enum { SNAKE_EVT_EAT = 1, SNAKE_EVT_DEATH = 2 };

typedef struct {
    int16_t  panel_w, panel_h;
    uint16_t len;            /* body length */
    uint16_t head;           /* ring index of the head segment */
    uint16_t score;          /* food eaten */
    uint8_t  dir;            /* 0 up, 1 right, 2 down, 3 left */
    uint8_t  next_dir;       /* queued turn, applied at the next step */
    uint8_t  grow;           /* growth owed, consumed one per step */
    uint8_t  status;         /* SNAKE_* */
    uint8_t  food_x, food_y;
    uint8_t  move_every;     /* ticks between steps: w/16, min 1 */
    uint8_t  pad;
    uint8_t  sx[SNAKE_MAX];  /* ring buffer, tail .. head */
    uint8_t  sy[SNAKE_MAX];
} snake_state;

typedef char snake_state_fits[(sizeof(snake_state) <= ML_SNAPSHOT_MAX) ? 1 : -1];

static const ml_control_def snake_controls[] = {
    { .label = "Up",    .code = 0, .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "Down",  .code = 1, .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "Left",  .code = 2, .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "Right", .code = 3, .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
};

static const int8_t DX[4] = { 0, 1, 0, -1 };
static const int8_t DY[4] = { -1, 0, 1, 0 };

/* Control codes are declared in UI order (Up, Down, Left, Right); direction
 * indices are compass order (0 up, 1 right, 2 down, 3 left), so the map is
 * not the identity. Input delivers codes; the step consumes indices. */
static const uint8_t DIR_OF_CODE[4] = { 0, 2, 3, 1 };

/* Segment i of the body, 0 = tail, len-1 = head. */
static int seg_index(const snake_state *s, int i)
{
    return (s->head + i + 1 + SNAKE_MAX - s->len) % SNAKE_MAX;
}

static bool cell_on_body(const snake_state *s, int x, int y)
{
    for (int i = 0; i < s->len; i++) {
        int idx = seg_index(s, i);
        if (s->sx[idx] == x && s->sy[idx] == y) return true;
    }
    return false;
}

/* Rejection-sample a free cell from the PRNG, then fall back to a scan so a
 * nearly full board cannot starve the game into a loop. */
static void place_food(snake_state *s, ml_game_ctx *ctx)
{
    int cells = s->panel_w * s->panel_h;
    if (s->len >= cells) { s->status = SNAKE_WON; return; }
    for (int t = 0; t < 64; t++) {
        uint32_t r = ml_ctx_rng(ctx) % (uint32_t)cells;
        int x = (int)(r % (uint32_t)s->panel_w);
        int y = (int)(r / (uint32_t)s->panel_w);
        if (!cell_on_body(s, x, y)) {
            s->food_x = (uint8_t)x; s->food_y = (uint8_t)y;
            return;
        }
    }
    for (int y = 0; y < s->panel_h; y++) {
        for (int x = 0; x < s->panel_w; x++) {
            if (!cell_on_body(s, x, y)) {
                s->food_x = (uint8_t)x; s->food_y = (uint8_t)y;
                return;
            }
        }
    }
    s->status = SNAKE_WON;
}

static void snake_init(void *state, const ml_game_cfg *cfg, ml_game_ctx *ctx)
{
    (void)ctx;
    snake_state *s = state;
    memset(s, 0, sizeof(*s));
    s->panel_w = (int16_t)cfg->panel_w;
    s->panel_h = (int16_t)cfg->panel_h;
    int me = cfg->panel_w / 16;
    s->move_every = (uint8_t)(me < 1 ? 1 : me);
}

static void snake_reset(void *state, ml_game_ctx *ctx)
{
    snake_state *s = state;
    int cx = s->panel_w / 2, cy = s->panel_h / 2;
    s->len = 3;
    s->head = 2;
    s->sx[0] = (uint8_t)(cx - 2); s->sy[0] = (uint8_t)cy;
    s->sx[1] = (uint8_t)(cx - 1); s->sy[1] = (uint8_t)cy;
    s->sx[2] = (uint8_t)cx;       s->sy[2] = (uint8_t)cy;
    s->dir = 1;                    /* heading right */
    s->next_dir = 1;
    s->grow = 0;
    s->score = 0;
    s->status = SNAKE_PLAYING;
    place_food(s, ctx);
}

static void snake_input(void *state, const ml_input_event *e, ml_game_ctx *ctx)
{
    (void)ctx;
    snake_state *s = state;
    if (!e->value) return;         /* presses only; held state is irrelevant */
    if (e->code >= 4) return;
    s->next_dir = DIR_OF_CODE[e->code];
}

static void snake_step(snake_state *s, ml_game_ctx *ctx)
{
    /* apply the queued turn unless it is a 180-degree reversal */
    int rev = (s->dir + 2) & 3;
    if (s->next_dir != s->dir && s->next_dir != rev) s->dir = s->next_dir;

    int nx = s->sx[s->head] + DX[s->dir];
    int ny = s->sy[s->head] + DY[s->dir];

    /* wall */
    if (nx < 0 || nx >= s->panel_w || ny < 0 || ny >= s->panel_h) {
        s->status = SNAKE_DEAD;
        ml_ctx_emit_event(ctx, SNAKE_EVT_DEATH, 0);
        return;
    }

    /* self: skip the tail cell only when it vacates this step (no growth
     * owed), which is the one cell the head may legally move into */
    int check = s->len - (s->grow > 0 ? 0 : 1);
    for (int i = 0; i < check; i++) {
        int idx = seg_index(s, i);
        if (s->sx[idx] == nx && s->sy[idx] == ny) {
            s->status = SNAKE_DEAD;
            ml_ctx_emit_event(ctx, SNAKE_EVT_DEATH, 0);
            return;
        }
    }

    /* advance the head, consuming one pending growth */
    s->head = (uint16_t)((s->head + 1) % SNAKE_MAX);
    s->sx[s->head] = (uint8_t)nx;
    s->sy[s->head] = (uint8_t)ny;
    if (s->grow > 0) {
        s->grow--;
        s->len++;
        if (s->len >= SNAKE_MAX) { s->status = SNAKE_WON; return; }
    }

    /* eat */
    if (nx == s->food_x && ny == s->food_y) {
        s->score++;
        s->grow++;
        place_food(s, ctx);
        ml_ctx_emit_event(ctx, SNAKE_EVT_EAT, s->score);
    }
}

static void snake_update(void *state, ml_game_ctx *ctx)
{
    snake_state *s = state;
    if (s->status != SNAKE_PLAYING) return;
    if (ml_ctx_tick(ctx) % s->move_every != 0) return;
    snake_step(s, ctx);
}

static void snake_draw(const void *state, const ml_view *view, ml_canvas *c,
                       const ml_game_ctx *ctx)
{
    (void)view; (void)ctx;
    const snake_state *s = state;
    ml_canvas_clear(c, ml_black);
    int W = c->w, H = c->h;

    ml_rgb body = ML_RGB(0, 200, 80);
    ml_rgb head = ML_RGB(130, 255, 150);
    ml_rgb food = ML_RGB(255, 60, 40);

    if (s->status != SNAKE_WON)
        ml_canvas_set(c, s->food_x, s->food_y, food);

    for (int i = 0; i < s->len; i++) {
        int idx = seg_index(s, i);
        int x = s->sx[idx], y = s->sy[idx];
        if (x < 0 || x >= W || y < 0 || y >= H) continue;
        ml_rgb col = body;
        if (i == s->len - 1)
            col = (s->status == SNAKE_DEAD) ? ML_RGB(255, 60, 60) : head;
        ml_canvas_set(c, x, y, col);
    }

    /* score in the corner, drawn after the body so it never hides behind it */
    char buf[8];
    const ml_font *f = ml_font_find("digits10");
    if (!f) f = ml_font_default();
    snprintf(buf, sizeof(buf), "%u", (unsigned)s->score);
    ml_text_draw(c, f, 1, 1, buf, body, ML_SCALE_1X);

    if (s->status == SNAKE_WON) {
        const ml_font *wf = ml_font_find("sans10");
        if (!wf) wf = ml_font_default();
        int tw = ml_text_width(wf, "WIN", ML_SCALE_1X);
        ml_text_draw(c, wf, (W - tw) / 2, (H - ML_SCALE_1X) / 2, "WIN",
                     ML_RGB(255, 220, 60), ML_SCALE_1X);
    }
}

static bool snake_snapshot(const void *state, uint8_t *buf, size_t cap, size_t *len)
{
    if (cap < sizeof(snake_state)) return false;
    memcpy(buf, state, sizeof(snake_state));
    *len = sizeof(snake_state);
    return true;
}

static void snake_restore(void *state, const uint8_t *buf, size_t len)
{
    size_t n = len < sizeof(snake_state) ? len : sizeof(snake_state);
    memcpy(state, buf, n);
}

const ml_game_vt ml_game_snake = {
    .id            = "snake",
    .pref_w        = 0, .pref_h = 0,
    .fit           = ML_FIT_ADAPTIVE,
    .tick_ms       = 25,
    .max_players   = 1,
    .state_size    = sizeof(snake_state),
    .controls      = snake_controls,
    .control_count = 4,
    .init          = snake_init,
    .reset         = snake_reset,
    .input         = snake_input,
    .update        = snake_update,
    .draw          = snake_draw,
    .snapshot      = snake_snapshot,
    .restore       = snake_restore,
};
