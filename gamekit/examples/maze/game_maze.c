/*
 * game_maze.c - a perfect maze walked by deliberate tilt.
 *
 * Maze Collector is the grid game that is steered by a tilt vector instead of a
 * d-pad. Where Snake turns toward the phone, this one reads the tilt as a
 * *direction request that is only honoured when it is deliberate*: the larger
 * component of the vector, once it is past half travel, is the way to go, and a
 * neutral or resting hand asks for nothing at all. That is the whole difference
 * from a held heading: standing still on purpose has to be possible, so an
 * idle tilt stops rather than continuing the last move.
 *
 * The board is a 15x5 grid of rooms at odd coordinates, connected by a
 * depth-first carver into a perfect maze (every room reachable, exactly one path
 * between any two). Three key rooms are drawn from the generator's own stream
 * and the exit is locked until all three are home. Three 60-second rounds are
 * played; finishing a round banks the whole seconds still on the clock and
 * deals a fresh maze, and the third completion is the win.
 *
 * The layout is authored at 64x32 and letterboxed: one grid cell is a 2x2 block
 * at (1 + 2x, 10 + 2y), so the 31x11 cell field fills the panel and leaves the
 * top ten rows to the HUD. Everything is integer and allocation-free, the state
 * is plain POD under the snapshot budget, and the generator's flood-fill
 * workspace lives on the stack rather than in the state.
 */
#include <stdio.h>
#include <string.h>

#include "mirror/font.h"
#include "mirror/game.h"
#include "mirror/gamerun.h"

#define MAZE_ROUNDS        3
#define MAZE_ROUND_TICKS   2400      /* 60 s at the fixed 25 ms tick */
#define MAZE_TICKS_PER_SEC 40

#define MAZE_COLS   31
#define MAZE_ROWS   11
#define MAZE_ROOMS_X 15
#define MAZE_ROOMS_Y 5
#define MAZE_ROOM_COUNT (MAZE_ROOMS_X * MAZE_ROOMS_Y)   /* 75 */

/* The top-left cell of the field and the size of one cell in pixels. The field
 * runs to row 31, the one game that uses the whole panel. */
#define MAZE_CELL_X0 1
#define MAZE_CELL_Y0 10
#define MAZE_CELL_PX 2

#define MAZE_START_X 1
#define MAZE_START_Y 1
#define MAZE_EXIT_X  29
#define MAZE_EXIT_Y  9

#define MAZE_KEY_COUNT 3

/* 31 live columns; bit set means wall. */
#define MAZE_ALL_WALLS 0x7FFFFFFFu

/* Move one cell every four ticks, and only past half travel, which is the same
 * deliberate angle Snake uses to pick a heading. */
#define MAZE_STEP_TICKS 4
#define MAZE_TILT_TURN  (32767 / 2)

enum { MAZE_PLAYING = 0, MAZE_WON = 1, MAZE_LOST = 2 };

typedef struct {
    int16_t  panel_w, panel_h;
    uint32_t maze[MAZE_ROWS];      /* one 31-bit row per board row, bit = wall */
    uint16_t timer;                /* ticks left in this round */
    uint16_t score;                /* clamped to 9999 */
    uint8_t  player_x, player_y;   /* player cell */
    uint8_t  key_x[MAZE_KEY_COUNT];
    uint8_t  key_y[MAZE_KEY_COUNT];
    uint8_t  keys_left;            /* bit k set: key k is still on the board */
    uint8_t  move_ctr;             /* ticks until the next cell step */
    uint8_t  round;                /* 1..MAZE_ROUNDS */
    uint8_t  status;               /* MAZE_* */
    uint8_t  held_up, held_down, held_left, held_right;
    int16_t  tilt_x, tilt_y;       /* ML_AXIS_IDLE when nobody is driving it */
} maze_state;

/* The runtime reserves four bytes of the snapshot header, so the usable budget
 * is four under the nominal maximum. A future edit that grows the state past it
 * fails to compile rather than wedging a peer. */
typedef char maze_state_fits[(sizeof(maze_state) <= ML_SNAPSHOT_MAX - 4) ? 1 : -1];

static const ml_control_def maze_controls[] = {
    { .label = "Up",    .code = 0, .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "Down",  .code = 1, .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "Left",  .code = 2, .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "Right", .code = 3, .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "TiltX", .code = 4, .caps = ML_CAP_ACCEL,  .type = ML_INPUT_AXIS },
    { .label = "TiltY", .code = 5, .caps = ML_CAP_ACCEL,  .type = ML_INPUT_AXIS },
};

/* Whether the cell is walkable; anything off the board is a wall. */
static bool maze_open(const maze_state *s, int x, int y)
{
    if (x < 0 || x >= MAZE_COLS || y < 0 || y >= MAZE_ROWS) return false;
    return ((s->maze[y] >> x) & 1u) == 0;
}

static void maze_carve(maze_state *s, int x, int y)
{
    s->maze[y] &= ~(1u << x);
}

static void maze_add_score(maze_state *s, int points)
{
    int v = (int)s->score + points;
    if (v > 9999) v = 9999;
    s->score = (uint16_t)v;
}

/*
 * Carve a perfect maze: every room at an odd coordinate is a node, and an
 * iterative depth-first walk links each unvisited neighbour through the even
 * cell between them. The enumeration order is fixed (up, right, down, left) and
 * the neighbour picked is drawn from the session stream, so the same seed deals
 * the same maze on every peer. Because the walk is a spanning tree, all 75 rooms
 * are reachable and there is exactly one path between any two.
 */
static void maze_generate(maze_state *s, ml_game_ctx *ctx)
{
    for (int y = 0; y < MAZE_ROWS; y++) s->maze[y] = MAZE_ALL_WALLS;

    for (int ry = 0; ry < MAZE_ROOMS_Y; ry++)
        for (int rx = 0; rx < MAZE_ROOMS_X; rx++)
            maze_carve(s, 2 * rx + 1, 2 * ry + 1);

    /* Generation workspace is local: it is rebuilt from the seed on reset and
     * never has to survive a snapshot. */
    uint8_t visited[MAZE_ROOM_COUNT];
    uint8_t stack[MAZE_ROOM_COUNT];
    memset(visited, 0, sizeof(visited));

    int sp = 0;
    stack[sp++] = 0;
    visited[0] = 1;

    while (sp > 0) {
        const int cur = stack[sp - 1];
        const int cx = cur % MAZE_ROOMS_X;
        const int cy = cur / MAZE_ROOMS_X;

        int cand[4];
        int nc = 0;
        if (cy > 0 && !visited[cur - MAZE_ROOMS_X])                 cand[nc++] = cur - MAZE_ROOMS_X;
        if (cx < MAZE_ROOMS_X - 1 && !visited[cur + 1])             cand[nc++] = cur + 1;
        if (cy < MAZE_ROOMS_Y - 1 && !visited[cur + MAZE_ROOMS_X])  cand[nc++] = cur + MAZE_ROOMS_X;
        if (cx > 0 && !visited[cur - 1])                            cand[nc++] = cur - 1;

        if (nc == 0) { sp--; continue; }

        const int pick = cand[ml_ctx_rng(ctx) % (uint32_t)nc];
        const int px = pick % MAZE_ROOMS_X;
        const int py = pick / MAZE_ROOMS_X;
        maze_carve(s, (2 * cx + 1 + 2 * px + 1) / 2,
                      (2 * cy + 1 + 2 * py + 1) / 2);
        visited[pick] = 1;
        stack[sp++] = (uint8_t)pick;
    }

    /* Three distinct key rooms, drawn by a partial Fisher-Yates from everything
     * but the start and exit rooms, so the picks are distinct by construction
     * rather than by retrying. */
    uint8_t rooms[MAZE_ROOM_COUNT - 2];
    int n = 0;
    for (int i = 0; i < MAZE_ROOM_COUNT; i++)
        if (i != 0 && i != MAZE_ROOM_COUNT - 1) rooms[n++] = (uint8_t)i;

    for (int k = 0; k < MAZE_KEY_COUNT; k++) {
        const int j = k + (int)(ml_ctx_rng(ctx) % (uint32_t)(n - k));
        const uint8_t tmp = rooms[k];
        rooms[k] = rooms[j];
        rooms[j] = tmp;
        s->key_x[k] = (uint8_t)(2 * (rooms[k] % MAZE_ROOMS_X) + 1);
        s->key_y[k] = (uint8_t)(2 * (rooms[k] / MAZE_ROOMS_X) + 1);
    }
    s->keys_left = (uint8_t)((1u << MAZE_KEY_COUNT) - 1u);
}

/*
 * The direction the tilt or the pad is asking for this tick. An engaged axis is
 * a position, so the larger component (Y on a tie) picks the axis and only past
 * the deliberate threshold; an idle component counts as zero. With neither axis
 * driven the buttons steer, opposite pairs cancel, and vertical wins the tie.
 */
static void maze_read_dir(const maze_state *s, int *dx, int *dy)
{
    *dx = 0;
    *dy = 0;

    const bool ex = ml_axis_engaged(s->tilt_x);
    const bool ey = ml_axis_engaged(s->tilt_y);

    if (ex || ey) {
        const int ax = ex ? (int)s->tilt_x : 0;
        const int ay = ey ? (int)s->tilt_y : 0;
        const int mx = ax < 0 ? -ax : ax;
        const int my = ay < 0 ? -ay : ay;
        if (mx > my) {
            if (mx < MAZE_TILT_TURN) return;
            *dx = ax > 0 ? 1 : -1;
        } else {
            if (my < MAZE_TILT_TURN) return;
            *dy = ay > 0 ? 1 : -1;
        }
        return;
    }

    const int vx = (s->held_right ? 1 : 0) - (s->held_left ? 1 : 0);
    const int vy = (s->held_down ? 1 : 0) - (s->held_up ? 1 : 0);
    if (vy != 0) *dy = vy;
    else if (vx != 0) *dx = vx;
}

/*
 * One cell step: move if the asked-for cell is walkable, then resolve a key on
 * the new cell and the exit. Returns true when the round ended (or was won), so
 * the caller leaves the freshly reset timer alone.
 */
static bool maze_step(maze_state *s, ml_game_ctx *ctx)
{
    int dx, dy;
    maze_read_dir(s, &dx, &dy);

    if (dx != 0 || dy != 0) {
        const int nx = s->player_x + dx;
        const int ny = s->player_y + dy;
        if (maze_open(s, nx, ny)) {
            s->player_x = (uint8_t)nx;
            s->player_y = (uint8_t)ny;
        }
    }

    for (int k = 0; k < MAZE_KEY_COUNT; k++) {
        if ((s->keys_left & (1u << k)) &&
            s->player_x == s->key_x[k] && s->player_y == s->key_y[k]) {
            s->keys_left &= (uint8_t)~(1u << k);
            maze_add_score(s, 100);
        }
    }

    if (s->keys_left == 0 &&
        s->player_x == MAZE_EXIT_X && s->player_y == MAZE_EXIT_Y) {
        /* Whole seconds still on the clock, rounded up, banked with the keys. */
        const int secs = (s->timer + (MAZE_TICKS_PER_SEC - 1)) / MAZE_TICKS_PER_SEC;
        maze_add_score(s, secs);
        s->round++;
        if (s->round > MAZE_ROUNDS) {
            s->status = MAZE_WON;
            return true;
        }
        maze_generate(s, ctx);
        s->player_x = MAZE_START_X;
        s->player_y = MAZE_START_Y;
        s->timer = MAZE_ROUND_TICKS;
        s->move_ctr = 0;
        return true;
    }
    return false;
}

static void maze_init(void *state, const ml_game_cfg *cfg, ml_game_ctx *ctx)
{
    (void)ctx;
    maze_state *s = state;
    memset(s, 0, sizeof(*s));
    s->panel_w = (int16_t)cfg->panel_w;
    s->panel_h = (int16_t)cfg->panel_h;
    s->tilt_x = s->tilt_y = ML_AXIS_IDLE;
}

static void maze_reset(void *state, ml_game_ctx *ctx)
{
    maze_state *s = state;
    s->score = 0;
    s->round = 1;
    s->status = MAZE_PLAYING;
    s->held_up = s->held_down = s->held_left = s->held_right = 0;
    s->tilt_x = s->tilt_y = ML_AXIS_IDLE;
    s->move_ctr = 0;
    maze_generate(s, ctx);
    s->player_x = MAZE_START_X;
    s->player_y = MAZE_START_Y;
    s->timer = MAZE_ROUND_TICKS;
}

static void maze_input(void *state, const ml_input_event *e, ml_game_ctx *ctx)
{
    (void)ctx;
    maze_state *s = state;

    if (e->type == ML_INPUT_AXIS) {
        /* An axis is a position, latched whenever it arrives, neutral included. */
        if (e->code == 4) s->tilt_x = e->value;
        else if (e->code == 5) s->tilt_y = e->value;
        return;
    }
    if (e->type != ML_INPUT_BUTTON) return;

    switch (e->code) {
    case 0: s->held_up    = (uint8_t)(e->value ? 1 : 0); break;
    case 1: s->held_down  = (uint8_t)(e->value ? 1 : 0); break;
    case 2: s->held_left  = (uint8_t)(e->value ? 1 : 0); break;
    case 3: s->held_right = (uint8_t)(e->value ? 1 : 0); break;
    default: break;
    }
}

static void maze_update(void *state, ml_game_ctx *ctx)
{
    maze_state *s = state;
    if (s->status != MAZE_PLAYING) return;

    if (s->move_ctr > 0) {
        s->move_ctr--;
    } else {
        s->move_ctr = MAZE_STEP_TICKS - 1;
        /* Movement, pickups and the exit all resolve before the clock is read,
         * so reaching the exit on the last tick beats the timeout, and a round
         * that just restarted keeps its full timer. */
        if (maze_step(s, ctx)) return;
    }

    if (s->timer > 0) s->timer--;
    if (s->timer == 0) s->status = MAZE_LOST;
}

static void maze_draw_cell(ml_canvas *c, int cell_x, int cell_y, ml_rgb col)
{
    const int px = MAZE_CELL_X0 + MAZE_CELL_PX * cell_x;
    const int py = MAZE_CELL_Y0 + MAZE_CELL_PX * cell_y;
    for (int dy = 0; dy < MAZE_CELL_PX; dy++) {
        for (int dx = 0; dx < MAZE_CELL_PX; dx++) {
            ml_canvas_set(c, px + dx, py + dy, col);
        }
    }
}

static void maze_draw_hud(ml_canvas *c, const char *text)
{
    const ml_font *f = ml_font_find("digits10");
    if (!f) f = ml_font_default();
    ml_text_draw(c, f, 1, 0, text, ml_white, ML_SCALE_1X);
}

static void maze_draw(const void *state, const ml_view *view, ml_canvas *c,
                      const ml_game_ctx *ctx)
{
    (void)view; (void)ctx;
    const maze_state *s = state;
    ml_canvas_clear(c, ml_black);
    const int W = c->w;

    if (s->status != MAZE_PLAYING) {
        char buf[8];
        snprintf(buf, sizeof(buf), "%u", (unsigned)s->score);
        maze_draw_hud(c, buf);

        const ml_font *rf = ml_font_find("sans10");
        if (!rf) rf = ml_font_default();
        const char *msg = (s->status == MAZE_WON) ? "WIN" : "OVER";
        const ml_rgb col = (s->status == MAZE_WON) ? ML_RGB(0, 220, 0)
                                                   : ML_RGB(255, 60, 60);
        const int tw = ml_text_width(rf, msg, ML_SCALE_1X);
        ml_text_draw(c, rf, (W - tw) / 2, 17, msg, col, ML_SCALE_1X);
        return;
    }

    const ml_rgb wall        = ML_RGB(0, 80, 255);
    const ml_rgb floor       = ml_black;
    const ml_rgb key_col     = ML_RGB(255, 200, 0);
    const ml_rgb player_col  = ML_RGB(0, 255, 255);
    const ml_rgb exit_locked = ML_RGB(255, 60, 60);
    const ml_rgb exit_open   = ML_RGB(0, 220, 0);

    for (int y = 0; y < MAZE_ROWS; y++) {
        for (int x = 0; x < MAZE_COLS; x++) {
            ml_rgb col = maze_open(s, x, y) ? floor : wall;

            if (x == MAZE_EXIT_X && y == MAZE_EXIT_Y)
                col = (s->keys_left == 0) ? exit_open : exit_locked;

            for (int k = 0; k < MAZE_KEY_COUNT; k++) {
                if ((s->keys_left & (1u << k)) &&
                    s->key_x[k] == x && s->key_y[k] == y)
                    col = key_col;
            }

            if (s->player_x == x && s->player_y == y) col = player_col;

            maze_draw_cell(c, x, y, col);
        }
    }

    char buf[8];
    const int secs = (s->timer + (MAZE_TICKS_PER_SEC - 1)) / MAZE_TICKS_PER_SEC;
    snprintf(buf, sizeof(buf), "%u", (unsigned)secs);
    maze_draw_hud(c, buf);
}

static bool maze_snapshot(const void *state, uint8_t *buf, size_t cap, size_t *len)
{
    if (cap < sizeof(maze_state)) return false;
    memcpy(buf, state, sizeof(maze_state));
    *len = sizeof(maze_state);
    return true;
}

static void maze_restore(void *state, const uint8_t *buf, size_t len)
{
    if (len != sizeof(maze_state)) return;   /* a partial state is not ours */
    memcpy(state, buf, sizeof(maze_state));
}

static bool maze_is_over(const void *state)
{
    const maze_state *s = state;
    return s->status != MAZE_PLAYING;
}

const ml_game_vt ml_game_maze = {
    .id            = "maze",
    .pref_w        = 64, .pref_h = 32,
    .fit           = ML_FIT_LETTERBOX,
    .tick_ms       = 25,
    .max_players   = 1,
    .state_size    = sizeof(maze_state),
    .controls      = maze_controls,
    .control_count = 6,
    .init          = maze_init,
    .reset         = maze_reset,
    .input         = maze_input,
    .update        = maze_update,
    .draw          = maze_draw,
    .snapshot      = maze_snapshot,
    .restore       = maze_restore,
    .is_over       = maze_is_over,
};
