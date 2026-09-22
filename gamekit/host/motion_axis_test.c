/*
 * motion_axis_test.c - the proportional motion contract, game by game.
 *
 * A phone steered by tilt sends the ANGLE it is held at, as an absolute
 * position in the game's own travel (see ML_AXIS_IDLE / ml_axis_map in
 * mirror/game.h). The property the player feels is that the player changes
 * position only while the angle is changing: a held angle is a held position.
 * Every game used to be driven by held direction buttons instead, so nothing
 * moved until a tilt crossed a threshold and a held tilt kept driving the
 * player into the wall.
 *
 * Observable: real frames out of the FFI session, read at the pixel each game
 * draws its player at - the paddle's cyan run at column 1 (rally), the white
 * run in the row above the floor (breakout), the cannon's cyan run (invaders),
 * the piece's lit cells inside the field rect (tetris), the snake's uniquely
 * bright head cell, the red dot (probe), the cyan car's left edge (racer), the
 * cyan ship's top row (cave), the cyan collector's cell (maze) and the cyan
 * crosshair's centre (gallery). Nothing here reads game state: what is
 * asserted is what the panel shows.
 *
 * Script families, per game:
 *   - neutral (0) puts the player at the centre of its travel and KEEPS it
 *     there for many ticks (the regression: no drift under a held angle);
 *   - +/-32767 put it exactly at the two ends of the travel, and a half value
 *     lands proportionally between them;
 *   - ML_AXIS_IDLE holds the position, and the buttons still move it from
 *     there, so manual play is untouched;
 *   - tetris walks toward the column the phone points at and stops at the
 *     wall rather than teleporting into it;
 *   - snake turns on a deliberate tilt only, and never reverses;
 *   - racer drives its car to both road ends, and gallery its crosshair to all
 *     four corners of its travel;
 *   - cave maps the angle over the safe band its tunnel leaves: its true ends
 *     put the ship into the rock, which is a collision and not a position, so
 *     the crash is asserted as a reset rather than as an end of travel;
 *   - maze takes only a deliberate past-half tilt, one cell every four ticks,
 *     with neutral meaning stop and the walls refusing the step.
 *
 * Every step is 50ms, which is two 25ms ticks: rate-driven button motion in
 * these assertions is 2 px per frame at 1 px/tick.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "game_ffi.h"

#define PANEL_W 64
#define PANEL_H 32

/* The tilt axis each game declares, in its own code order (the codes are the
 * indices of the declared controls, which is what the phone writes). */
#define RALLY_TILT_Y    2
#define BREAKOUT_TILT_X 2
#define INVADERS_TILT_X 3
#define TETRIS_TILT_X   4
#define SNAKE_TILT_X    4
#define SNAKE_TILT_Y    5
#define PROBE_TILT_X    4
#define PROBE_TILT_Y    5

/* The new games' axes, again in declared code order, and the pad codes the
 * maze script presses by name (it picks its direction at run time). */
#define RACER_TILT_X   2
#define CAVE_TILT_Y    2
#define MAZE_TILT_X    4
#define MAZE_TILT_Y    5
#define MAZE_DOWN      1
#define MAZE_RIGHT     3
#define GALLERY_TILT_X 5
#define GALLERY_TILT_Y 6

/* Maze's field origin and cell size: one cell is a 2x2 block at
 * (1 + 2x, 10 + 2y) on the authored 64x32 panel. */
#define MAZE_FIELD_X  1
#define MAZE_FIELD_Y  10
#define MAZE_FIELD_PX 2

/* The value that means "nobody is driving this axis" (game.h). */
#define TILT_IDLE (-32768)

static int g_failures;
static int g_checks;

static void check(int ok, const char *what)
{
    g_checks++;
    if (!ok) {
        g_failures++;
        printf("  FAIL  %s\n", what);
    } else {
        printf("  ok    %s\n", what);
    }
}

/* ---- frame readers ------------------------------------------------------ */

/* Whether the pixel at (x,y) is bright in the channels named (1 = the channel
 * must be bright, 0 = it must be dark). Frames come out gamma-corrected the
 * way the panel shows them, so the thresholds are loose on purpose. */
static int lit(const uint8_t *rgba, int x, int y, int want_r, int want_g, int want_b)
{
    const uint8_t *p = rgba + ((size_t)y * PANEL_W + x) * 4;
    return (want_r ? p[0] > 120 : p[0] < 100)
        && (want_g ? p[1] > 120 : p[1] < 100)
        && (want_b ? p[2] > 120 : p[2] < 100);
}

/* Topmost y of the longest bright run in one column: the rally paddle. The
 * ball is a single pixel, so only a run of four or more counts. */
static int rally_paddle_top(ml_game_session *s)
{
    const uint8_t *rgba = ml_game_render_rgba(s);
    int run_start = -1, run_len = 0, best_start = -1, best_len = 0;
    for (int y = 0; y < PANEL_H; y++) {
        const int bright = lit(rgba, 1, y, 0, 1, 1); /* cyan: G and B */
        if (bright) {
            if (run_len == 0) run_start = y;
            run_len++;
        } else {
            if (run_len > best_len) { best_len = run_len; best_start = run_start; }
            run_len = 0;
        }
    }
    if (run_len > best_len) { best_len = run_len; best_start = run_start; }
    return best_len >= 4 ? best_start : -1;
}

/* Start x of the first bright run of at least [min_len] pixels in one row, or
 * -1. Used for the two horizontal paddles, where the ball shares the row. */
static int row_run_start(ml_game_session *s, int y, int min_len,
                         int want_r, int want_g, int want_b)
{
    const uint8_t *rgba = ml_game_render_rgba(s);
    int run_start = -1, run_len = 0;
    for (int x = 0; x <= PANEL_W; x++) {
        const int bright = x < PANEL_W && lit(rgba, x, y, want_r, want_g, want_b);
        if (bright) {
            if (run_len == 0) run_start = x;
            run_len++;
        } else {
            if (run_len >= min_len) return run_start;
            run_len = 0;
        }
    }
    return -1;
}

/* The centre of the red dot the probe draws, in whole cells. */
static int dot_centre(ml_game_session *s, int *out_x, int *out_y)
{
    const uint8_t *rgba = ml_game_render_rgba(s);
    int min_x = -1, max_x = -1, min_y = -1, max_y = -1;
    for (int y = 0; y < PANEL_H; y++) {
        for (int x = 0; x < PANEL_W; x++) {
            const uint8_t *p = rgba + ((size_t)y * PANEL_W + x) * 4;
            if (p[0] > 150 && p[1] < 90 && p[2] < 90) {
                if (min_x < 0 || x < min_x) min_x = x;
                if (x > max_x) max_x = x;
                if (min_y < 0 || y < min_y) min_y = y;
                if (y > max_y) max_y = y;
            }
        }
    }
    if (min_x < 0) {
        if (out_x) *out_x = -1;
        if (out_y) *out_y = -1;
        return 0;
    }
    if (out_x) *out_x = (min_x + max_x) / 2;
    if (out_y) *out_y = (min_y + max_y) / 2;
    return 1;
}

/* The snake's head: the one cell drawn in the bright green nothing else uses
 * (the body is a third as bright, the food is red). */
static void snake_head(ml_game_session *s, int *out_x, int *out_y)
{
    const uint8_t *rgba = ml_game_render_rgba(s);
    if (out_x) *out_x = -1;
    if (out_y) *out_y = -1;
    for (int y = 0; y < PANEL_H; y++) {
        for (int x = 0; x < PANEL_W; x++) {
            const uint8_t *p = rgba + ((size_t)y * PANEL_W + x) * 4;
            if (p[1] > 200 && p[0] > 30) {
                if (out_x) *out_x = x;
                if (out_y) *out_y = y;
                return;
            }
        }
    }
}

/* Leftmost and rightmost x of the falling tetris piece: the lit cells inside
 * the field rect (origin 22, 20 wide on a 64-wide panel, two pixels a cell),
 * above the stack. The field frame is dim grey and sits at x=21 and x=42; the
 * score text and the next-piece preview are outside the rect. */
#define TETRIS_FIELD_X 22
#define TETRIS_FIELD_W 20

static void piece_span(ml_game_session *s, int *min_x, int *max_x)
{
    const uint8_t *rgba = ml_game_render_rgba(s);
    *min_x = -1;
    *max_x = -1;
    for (int y = 0; y < PANEL_H / 2; y++) {
        for (int x = TETRIS_FIELD_X; x < TETRIS_FIELD_X + TETRIS_FIELD_W; x++) {
            const uint8_t *p = rgba + ((size_t)y * PANEL_W + x) * 4;
            if (p[0] > 90 || p[1] > 90 || p[2] > 90) {
                if (*min_x < 0 || x < *min_x) *min_x = x;
                if (x > *max_x) *max_x = x;
            }
        }
    }
}

/* ---- the four new games' readers ---------------------------------------- */

/* The bounding box of the cyan player pixels inside a window. Cyan is the
 * player colour in every one of the new games and nothing else on their boards
 * uses it: hazards and the locked exit are red, keys and targets gold, walls
 * blue, the unlocked exit green, and the HUD and the gallery's time bar white.
 * Returns 0 when the window holds no cyan. */
static int cyan_box(ml_game_session *s, int x0, int y0, int x1, int y1,
                    int *min_x, int *min_y, int *max_x, int *max_y)
{
    const uint8_t *rgba = ml_game_render_rgba(s);
    int found = 0;
    for (int y = y0; y <= y1 && y < PANEL_H; y++) {
        for (int x = x0; x <= x1 && x < PANEL_W; x++) {
            if (!lit(rgba, x, y, 0, 1, 1)) continue;
            if (!found) {
                *min_x = *max_x = x;
                *min_y = *max_y = y;
                found = 1;
            } else {
                if (x < *min_x) *min_x = x;
                if (x > *max_x) *max_x = x;
                if (y < *min_y) *min_y = y;
                if (y > *max_y) *max_y = y;
            }
        }
    }
    return found;
}

/* Racer: the left column of the cyan car on its fixed rows. The white life
 * pixels share the bottom row, so the window stops one above them. */
static int racer_car_x(ml_game_session *s)
{
    int min_x = -1, min_y = -1, max_x = -1, max_y = -1;
    if (!cyan_box(s, 0, 26, PANEL_W - 1, 30, &min_x, &min_y, &max_x, &max_y))
        return -1;
    return min_x;
}

/* Cave: the top row of the cyan ship, which flies at a fixed column. */
static int cave_ship_top(ml_game_session *s)
{
    int min_x = -1, min_y = -1, max_x = -1, max_y = -1;
    if (!cyan_box(s, 0, 10, PANEL_W - 1, 30, &min_x, &min_y, &max_x, &max_y))
        return -1;
    return min_y;
}

/* Gallery: the centre of the five-pixel cyan crosshair. The window stops above
 * the white time bar on the last row, and targets are drawn under the hair, so
 * nothing can hide a pixel of it. */
static int gallery_reticle(ml_game_session *s, int *cx, int *cy)
{
    int min_x = -1, min_y = -1, max_x = -1, max_y = -1;
    if (!cyan_box(s, 0, 10, PANEL_W - 1, 30, &min_x, &min_y, &max_x, &max_y))
        return 0;
    *cx = (min_x + max_x) / 2;
    *cy = (min_y + max_y) / 2;
    return 1;
}

/* Maze: the collector's cell, from the top-left pixel of its filled 2x2 cell
 * at (1 + 2x, 10 + 2y). */
static int maze_cell(ml_game_session *s, int *cx, int *cy)
{
    int min_x = -1, min_y = -1, max_x = -1, max_y = -1;
    if (!cyan_box(s, 0, 10, PANEL_W - 1, PANEL_H - 1,
                  &min_x, &min_y, &max_x, &max_y))
        return 0;
    *cx = (min_x - MAZE_FIELD_X) / MAZE_FIELD_PX;
    *cy = (min_y - MAZE_FIELD_Y) / MAZE_FIELD_PX;
    return 1;
}

/* ---- session helpers ---------------------------------------------------- */

static ml_game_session *open_game(const char *id, uint32_t seed)
{
    ml_game_session *s = ml_game_open(id, PANEL_W, PANEL_H, seed, 1);
    if (!s) { printf("open failed: %s\n", id); g_failures++; }
    return s;
}

/* One control of the frame, then advance ms of wall time (25ms ticks). */
static void feed(ml_game_session *s, uint16_t code, int16_t value, uint32_t ms)
{
    if (!s) return;
    ml_game_input(s, 1, code, value);
    ml_game_step(s, ms);
}

/* One frame of a two-axis round: both axes, then advance. */
static void tilt(ml_game_session *s, uint16_t code_x, uint16_t code_y,
                 int16_t x, int16_t y, uint32_t ms)
{
    feed(s, code_x, x, 0);
    feed(s, code_y, y, ms);
}

/* Hold one control for n frames. */
static void hold(ml_game_session *s, uint16_t code, int16_t value, int frames)
{
    for (int i = 0; i < frames; i++) feed(s, code, value, 50);
}

/* ---- the mapping itself ------------------------------------------------- */

static void test_axis_map(void)
{
    printf("ml_axis_map\n");
    check(ml_axis_map(0, 0, 24) == 12, "0 is the middle of an even travel");
    check(ml_axis_map(32767, 0, 24) == 24, "+32767 is the far end");
    check(ml_axis_map(-32767, 0, 24) == 0, "-32767 is the near end");
    check(ml_axis_map(16384, 0, 24) == 18, "half travel is halfway");
    check(ml_axis_map(0, 0, 3) == 1, "0 is the middle of an odd travel");
    check(ml_axis_map(32767, 0, 3) == 3, "the far end of an odd travel");
    check(ml_axis_map(-32767, 0, 3) == 0, "the near end of an odd travel");

    int last = -1, monotone = 1;
    for (int v = -32767; v <= 32767; v += 257) {
        const int p = (int)ml_axis_map((int16_t)v, 0, 61);
        if (p < last) monotone = 0;
        last = p;
    }
    check(monotone, "the map never goes backwards");

    check(!ml_axis_engaged(TILT_IDLE), "idle is not engaged");
    check(ml_axis_engaged(0), "neutral is engaged");
}

/* ---- rally -------------------------------------------------------------- */

static void test_rally(void)
{
    printf("rally: the paddle's y is the phone's angle\n");
    ml_game_session *s = open_game("rally", 1);
    if (!s) return;

    /* Neutral is the middle of the 0..24 travel, which is where reset puts the
     * paddle too, so the first frame of a motion round changes nothing. */
    feed(s, RALLY_TILT_Y, 0, 50);
    const int centre = rally_paddle_top(s);
    check(centre == 12, "neutral centres the paddle");

    /* The regression: a held angle is a held position. */
    hold(s, RALLY_TILT_Y, 0, 10);
    check(rally_paddle_top(s) == centre, "a held angle does not drift");

    /* +full is the far end of the canvas axis: down. */
    feed(s, RALLY_TILT_Y, 32767, 50);
    check(rally_paddle_top(s) == 24, "+full is the bottom of the travel");
    hold(s, RALLY_TILT_Y, 32767, 5);
    check(rally_paddle_top(s) == 24, "+full stays at the bottom");

    feed(s, RALLY_TILT_Y, -32767, 50);
    check(rally_paddle_top(s) == 0, "-full is the top of the travel");

    feed(s, RALLY_TILT_Y, 16384, 50);
    check(rally_paddle_top(s) == 18, "half travel sits halfway to the end");
    hold(s, RALLY_TILT_Y, 16384, 6);
    check(rally_paddle_top(s) == 18, "half travel holds its place");

    /* Idle: the player let go of the tilt. The paddle stays where it is, and
     * the buttons still move it from there at their own rate. */
    feed(s, RALLY_TILT_Y, TILT_IDLE, 50);
    const int parked = rally_paddle_top(s);
    check(parked == 18, "an idle axis holds the paddle");
    hold(s, 1, 1, 2); /* Down held: 1 px/tick, two ticks per frame */
    check(rally_paddle_top(s) == 22, "buttons still move it from there");

    ml_game_close(s);
}

/* ---- breakout ----------------------------------------------------------- */

static void test_breakout(void)
{
    printf("breakout: the paddle's x is the phone's angle\n");
    /* The starting paddle is 9 px wide, so the travel is 0..55. Each phase
     * runs in a fresh session for a bounded number of frames: the ball is live
     * from the reset and three misses would end the round, and a finished
     * round stops reading input entirely. */
    ml_game_session *s = open_game("breakout", 1);
    if (!s) return;

    feed(s, BREAKOUT_TILT_X, 0, 50);
    const int centre = row_run_start(s, PANEL_H - 3, 3, 1, 1, 1);
    check(centre == 27, "neutral centres the paddle");

    hold(s, BREAKOUT_TILT_X, 0, 8);
    check(row_run_start(s, PANEL_H - 3, 3, 1, 1, 1) == centre, "a held angle does not drift");

    feed(s, BREAKOUT_TILT_X, 32767, 50);
    check(row_run_start(s, PANEL_H - 3, 3, 1, 1, 1) == 55, "+full is the right wall");
    feed(s, BREAKOUT_TILT_X, -32767, 50);
    check(row_run_start(s, PANEL_H - 3, 3, 1, 1, 1) == 0, "-full is the left wall");

    feed(s, BREAKOUT_TILT_X, TILT_IDLE, 50);
    const int parked = row_run_start(s, PANEL_H - 3, 3, 1, 1, 1);
    check(parked == 0, "an idle axis holds the paddle");
    hold(s, 1, 1, 3); /* Right held: 2 px/tick on a 64-wide panel */
    check(row_run_start(s, PANEL_H - 3, 3, 1, 1, 1) == 12, "buttons still move it from there");

    ml_game_close(s);
}

/* ---- invaders ----------------------------------------------------------- */

static void test_invaders(void)
{
    printf("invaders: the cannon's x is the phone's angle\n");
    /* The cannon is 3 px wide, so the travel is 0..61. Fresh sessions with a
     * few frames each: the alien wall marches down and reaching the cannon row
     * ends the round, after which input is ignored. */
    ml_game_session *s = open_game("invaders", 1);
    if (!s) return;

    feed(s, INVADERS_TILT_X, 0, 50);
    const int centre = row_run_start(s, PANEL_H - 2, 3, 0, 1, 1);
    check(centre == 30, "neutral centres the cannon");

    hold(s, INVADERS_TILT_X, 0, 5);
    check(row_run_start(s, PANEL_H - 2, 3, 0, 1, 1) == centre, "a held angle does not drift");

    feed(s, INVADERS_TILT_X, 32767, 50);
    check(row_run_start(s, PANEL_H - 2, 3, 0, 1, 1) == 61, "+full is the right wall");
    feed(s, INVADERS_TILT_X, -32767, 50);
    check(row_run_start(s, PANEL_H - 2, 3, 0, 1, 1) == 0, "-full is the left wall");

    feed(s, INVADERS_TILT_X, TILT_IDLE, 50);
    const int parked = row_run_start(s, PANEL_H - 2, 3, 0, 1, 1);
    check(parked == 0, "an idle axis holds the cannon");
    hold(s, 1, 1, 3); /* Right held: 1 px/tick */
    check(row_run_start(s, PANEL_H - 2, 3, 0, 1, 1) == 6, "buttons still move it from there");

    ml_game_close(s);
}

/* ---- tetris ------------------------------------------------------------- */

static void test_tetris(void)
{
    printf("tetris: the piece walks toward the phone's column\n");
    /* On a 64x32 panel the field is 16 logical rows tall - 32 pixel rows - and
     * gravity is one row per 20 ticks, so nothing locks inside this script and
     * the piece keeps the column history the assertions read. */
    ml_game_session *s = open_game("tetris", 1);
    if (!s) return;

    int a, b;
    feed(s, TETRIS_TILT_X, 0, 50);
    piece_span(s, &a, &b);
    const int spawn_a = a, spawn_b = b;
    check(spawn_a >= TETRIS_FIELD_X && spawn_b < TETRIS_FIELD_X + TETRIS_FIELD_W,
          "the piece spawns inside the field");

    hold(s, TETRIS_TILT_X, 0, 4);
    piece_span(s, &a, &b);
    check(a == spawn_a && b == spawn_b, "a held angle does not drift");

    /* Tilt right: one field column a tick, two ticks a 50ms frame, so a single
     * frame already walks the piece two columns - four pixels - to the right. */
    hold(s, TETRIS_TILT_X, 32767, 1);
    piece_span(s, &a, &b);
    check(a == spawn_a + 4, "the piece walks one column per tick");

    /* Far enough and it is against the wall, and stays there. */
    hold(s, TETRIS_TILT_X, 32767, 8);
    piece_span(s, &a, &b);
    const int right_a = a, right_b = b;
    check(right_b == TETRIS_FIELD_X + TETRIS_FIELD_W - 1,
          "+full stops the piece at the right wall");
    hold(s, TETRIS_TILT_X, 32767, 4);
    piece_span(s, &a, &b);
    check(a == right_a && b == right_b, "and it stays there");

    /* Back the other way, all the way to the left wall: a tilt may walk the
     * piece but never teleport it out of the field. */
    hold(s, TETRIS_TILT_X, -32767, 20);
    piece_span(s, &a, &b);
    check(a == TETRIS_FIELD_X, "-full stops the piece at the left wall");

    ml_game_close(s);
}

/* ---- snake -------------------------------------------------------------- */

static void test_snake(void)
{
    printf("snake: a deliberate tilt picks the heading\n");
    /* The snake steps one cell per move_every = 64/16 = 4 ticks, so a 50ms
     * frame is half a cell: a heading change needs a few frames to show. */
    int x = 0, y = 0;

    ml_game_session *s = open_game("snake", 1);
    if (!s) return;
    snake_head(s, &x, &y);
    const int start_x = x, start_y = y;
    for (int i = 0; i < 6; i++) tilt(s, SNAKE_TILT_X, SNAKE_TILT_Y, 0, 0, 50);
    snake_head(s, &x, &y);
    check(x > start_x && y == start_y, "a level phone leaves it heading right");
    ml_game_close(s);

    /* A tilt inside the turn threshold is not an instruction. */
    ml_game_session *low = open_game("snake", 1);
    if (low) {
        snake_head(low, &x, &y);
        const int lx = x, ly = y;
        for (int i = 0; i < 6; i++)
            tilt(low, SNAKE_TILT_X, SNAKE_TILT_Y, 6000, 0, 50); /* under half */
        snake_head(low, &x, &y);
        check(x > lx && y == ly, "a small tilt does not turn the snake");
        ml_game_close(low);
    }

    /* Down: a deliberate tilt turns it, and it keeps that heading. */
    ml_game_session *down = open_game("snake", 1);
    if (down) {
        snake_head(down, &x, &y);
        const int dx0 = x, dy0 = y;
        for (int i = 0; i < 12; i++)
            tilt(down, SNAKE_TILT_X, SNAKE_TILT_Y, 0, 30000, 50);
        snake_head(down, &x, &y);
        check(y > dy0, "a downward tilt turns the snake down");
        check(x == dx0, "and it travels no further right");
        ml_game_close(down);
    }

    /* A reversal request must not fold the snake into itself. */
    ml_game_session *rev = open_game("snake", 1);
    if (rev) {
        snake_head(rev, &x, &y);
        const int rx = x;
        for (int i = 0; i < 6; i++)
            tilt(rev, SNAKE_TILT_X, SNAKE_TILT_Y, -32767, 0, 50);
        snake_head(rev, &x, &y);
        check(x > rx, "a reversal request is refused");
        ml_game_close(rev);
    }
}

/* ---- probe -------------------------------------------------------------- */

static void test_probe(void)
{
    printf("probe: the dot sits where the phone points\n");
    /* radius = max(min(64,32)/12, 2) = 2, so x travels 2..61 and y 2..29. */
    ml_game_session *s = open_game("probe", 1);
    if (!s) return;

    tilt(s, PROBE_TILT_X, PROBE_TILT_Y, 0, 0, 50);
    int cx = -1, cy = -1;
    if (!dot_centre(s, &cx, &cy)) { check(0, "the dot is on screen"); ml_game_close(s); return; }
    check(cx == 31 && cy == 15, "a level phone centres the dot");

    for (int i = 0; i < 8; i++) tilt(s, PROBE_TILT_X, PROBE_TILT_Y, 0, 0, 50);
    dot_centre(s, &cx, &cy);
    check(cx == 31 && cy == 15, "a held angle does not drift");

    tilt(s, PROBE_TILT_X, PROBE_TILT_Y, 32767, 0, 50);
    dot_centre(s, &cx, &cy);
    check(cx == 61, "+full puts the dot against the right edge");
    tilt(s, PROBE_TILT_X, PROBE_TILT_Y, 32767, 32767, 50);
    dot_centre(s, &cx, &cy);
    check(cy == 29, "+full on the vertical axis puts it at the floor");
    tilt(s, PROBE_TILT_X, PROBE_TILT_Y, 32767, -32767, 50);
    dot_centre(s, &cx, &cy);
    check(cy == 2, "-full puts it at the ceiling");
    tilt(s, PROBE_TILT_X, PROBE_TILT_Y, -32767, -32767, 50);
    dot_centre(s, &cx, &cy);
    check(cx == 2, "-full puts it against the left edge");

    /* Idle axes hand the dot back to the buttons, from where it is. */
    tilt(s, PROBE_TILT_X, PROBE_TILT_Y, TILT_IDLE, TILT_IDLE, 50);
    dot_centre(s, &cx, &cy);
    const int parked = cx;
    check(parked == 2, "an idle axis holds the dot");
    hold(s, 3, 1, 4); /* Right held: 2 px/tick at min(64,32)/16 */
    dot_centre(s, &cx, &cy);
    check(cx == parked + 16, "buttons still move the dot from there");

    ml_game_close(s);
}

/* ---- racer -------------------------------------------------------------- */

static void test_racer(void)
{
    printf("racer: the car's column is the phone's angle\n");
    /* The car is 3 px in a road edged at 8 and 55, so its column travels
     * 10..51: neutral is 30 and both ends stay clear of the paint. Traffic
     * enters on tick 48, so both scripts stay inside the first 48 ticks and
     * there is nothing on the road to sweep into. */
    ml_game_session *s = open_game("racer", 1);
    if (!s) return;

    feed(s, RACER_TILT_X, 0, 50);
    const int centre = racer_car_x(s);
    check(centre == 30, "neutral centres the car");

    hold(s, RACER_TILT_X, 0, 6);
    check(racer_car_x(s) == centre, "a held angle does not drift");

    feed(s, RACER_TILT_X, 32767, 50);
    check(racer_car_x(s) == 51, "+full is the right end of the road");
    hold(s, RACER_TILT_X, 32767, 3);
    check(racer_car_x(s) == 51, "+full holds its place");

    feed(s, RACER_TILT_X, -32767, 50);
    check(racer_car_x(s) == 10, "-full is the left end of the road");

    feed(s, RACER_TILT_X, 16384, 50);
    check(racer_car_x(s) == 40, "half travel sits halfway to the end");

    ml_game_close(s);

    /* An idle axis hands the car back to the buttons, from where it stands. */
    ml_game_session *idle = open_game("racer", 1);
    if (!idle) return;
    feed(idle, RACER_TILT_X, -32767, 50);
    check(racer_car_x(idle) == 10, "-full parks the car before the idle check");
    feed(idle, RACER_TILT_X, TILT_IDLE, 50);
    check(racer_car_x(idle) == 10, "an idle axis holds the car");
    hold(idle, 1, 1, 2); /* Right held: 1 px/tick, two ticks a frame */
    check(racer_car_x(idle) == 14, "buttons still move it from there");
    ml_game_close(idle);
}

/* ---- cave --------------------------------------------------------------- */

static void test_cave(void)
{
    printf("cave: the ship's altitude is the phone's angle\n");
    /* The travel is 10..29, but the tunnel at reset is open only for rows
     * 14..26, so +-full map the ship's top straight into the rock: those two
     * frames are a crash, which the collision fixtures own, not a position.
     * The mapping is therefore read over the widest band the tunnel leaves -
     * half tilt gives 24 and 15 - while the ship's fixed column still sits on
     * its straight, unscrolled centre. */
    ml_game_session *s = open_game("cave", 1);
    if (!s) return;

    feed(s, CAVE_TILT_Y, 0, 50);
    const int centre = cave_ship_top(s);
    check(centre == 19, "neutral centres the ship in the tunnel");

    hold(s, CAVE_TILT_Y, 0, 5);
    check(cave_ship_top(s) == centre, "a held angle does not drift");

    feed(s, CAVE_TILT_Y, 16384, 50);
    check(cave_ship_top(s) == 24, "half tilt toward the floor takes the low band");
    hold(s, CAVE_TILT_Y, 16384, 3);
    check(cave_ship_top(s) == 24, "the low band does not drift");

    feed(s, CAVE_TILT_Y, -16384, 50);
    check(cave_ship_top(s) == 15, "half tilt toward the roof takes the high band");

    ml_game_close(s);

    /* An idle axis hands the ship back to the buttons, from where it flies. */
    ml_game_session *idle = open_game("cave", 1);
    if (!idle) return;
    feed(idle, CAVE_TILT_Y, -16384, 50);
    check(cave_ship_top(idle) == 15, "half tilt parks the ship high");
    feed(idle, CAVE_TILT_Y, TILT_IDLE, 50);
    check(cave_ship_top(idle) == 15, "an idle axis holds the ship");
    hold(idle, 1, 1, 2); /* Down held: 1 px/tick */
    check(cave_ship_top(idle) == 19, "buttons still move it from there");
    ml_game_close(idle);

    /* The ends of the travel are a crash, and the crash puts the ship back in
     * the middle of a straight tunnel - the panel never shows it at 10 or 29.
     * One 25ms tick each, so each tilt asks for one sweep and costs one life;
     * the lives and the swept collision themselves are the fixtures' business. */
    ml_game_session *ends = open_game("cave", 1);
    if (!ends) return;
    feed(ends, CAVE_TILT_Y, 32767, 25);
    check(cave_ship_top(ends) == 19, "+full is a crash, not the floor");
    feed(ends, CAVE_TILT_Y, -32767, 25);
    check(cave_ship_top(ends) == 19, "-full is a crash, not the roof");
    ml_game_close(ends);
}

/* ---- gallery ------------------------------------------------------------ */

static void test_gallery(void)
{
    printf("gallery: the crosshair is where the phone points\n");
    /* The travel is x 1..62, y 11..29, and both axes move in one tick. Targets
     * spawn on tick 1 and every 40 after, entering at an edge on rows 12, 18 or
     * 24 and drifting a pixel every four ticks, so inside the first 40 ticks
     * they are still near the edge. The horizontal ends are read along the
     * bottom row where no target row can reach, and the five-pixel hair is
     * drawn over the targets, so its symmetric box centre is the point asked
     * for. */
    ml_game_session *s = open_game("gallery", 1);
    if (!s) return;

    int cx = -1, cy = -1;
    tilt(s, GALLERY_TILT_X, GALLERY_TILT_Y, 0, 0, 50);
    if (!gallery_reticle(s, &cx, &cy)) {
        check(0, "the crosshair is on screen");
        ml_game_close(s);
        return;
    }
    check(cx == 31 && cy == 20, "a level phone centres the crosshair");

    for (int i = 0; i < 5; i++)
        tilt(s, GALLERY_TILT_X, GALLERY_TILT_Y, 0, 0, 50);
    gallery_reticle(s, &cx, &cy);
    check(cx == 31 && cy == 20, "a held angle does not drift");

    tilt(s, GALLERY_TILT_X, GALLERY_TILT_Y, 32767, 32767, 50);
    gallery_reticle(s, &cx, &cy);
    check(cx == 62 && cy == 29, "+full is the bottom-right corner");

    tilt(s, GALLERY_TILT_X, GALLERY_TILT_Y, -32767, 32767, 50);
    gallery_reticle(s, &cx, &cy);
    check(cx == 1 && cy == 29, "-full on x is the bottom-left corner");

    tilt(s, GALLERY_TILT_X, GALLERY_TILT_Y, 0, -32767, 50);
    gallery_reticle(s, &cx, &cy);
    check(cx == 31 && cy == 11, "-full on y is the top of the travel");

    tilt(s, GALLERY_TILT_X, GALLERY_TILT_Y, 16384, 0, 50);
    gallery_reticle(s, &cx, &cy);
    check(cx == 46 && cy == 20, "half travel sits halfway to the right edge");

    ml_game_close(s);

    /* Idle axes hand the crosshair back to the pad, from where it is. */
    ml_game_session *idle = open_game("gallery", 1);
    if (!idle) return;
    tilt(idle, GALLERY_TILT_X, GALLERY_TILT_Y, 16384, 0, 50);
    check(gallery_reticle(idle, &cx, &cy) && cx == 46,
          "half travel parks the crosshair before the idle check");
    tilt(idle, GALLERY_TILT_X, GALLERY_TILT_Y, TILT_IDLE, TILT_IDLE, 50);
    check(gallery_reticle(idle, &cx, &cy) && cx == 46,
          "an idle axis holds the crosshair");
    hold(idle, 3, 1, 2); /* Right held: 1 px/tick */
    check(gallery_reticle(idle, &cx, &cy) && cx == 50,
          "buttons still move it from there");
    ml_game_close(idle);
}

/* ---- maze --------------------------------------------------------------- */

/* One tick of a deliberate right or down tilt (the other axis idle), then read
 * the collector's cell and count the single-cell steps it made. Returns the
 * number of steps, or -1 if a step ever crossed more than one cell. */
static int maze_push(ml_game_session *s, int down, int ticks, int *cx, int *cy)
{
    int moves = 0;
    for (int i = 0; i < ticks; i++) {
        if (down)
            tilt(s, MAZE_TILT_X, MAZE_TILT_Y, TILT_IDLE, 30000, 25);
        else
            tilt(s, MAZE_TILT_X, MAZE_TILT_Y, 30000, TILT_IDLE, 25);
        int px = -1, py = -1;
        maze_cell(s, &px, &py);
        if (px != *cx || py != *cy) {
            const int dx = px > *cx ? px - *cx : *cx - px;
            const int dy = py > *cy ? py - *cy : *cy - py;
            if (dx + dy != 1) return -1;   /* tunnelled or teleported */
            *cx = px;
            *cy = py;
            moves++;
        }
    }
    return moves;
}

static void test_maze(void)
{
    printf("maze: only a deliberate tilt steps the collector\n");
    /* Movement is one cell every MAZE_STEP_TICKS = 4 ticks, and only past half
     * travel - the same deliberate angle snake uses. Neutral is not a heading:
     * both axes at 0 stop the collector dead. The corner room at (1,1) has the
     * outer wall above and to its left, so exactly one of right/down must be
     * carved; the script finds that way out first, then asserts the cadence on
     * the move itself. */
    int open_dir = 0;   /* 1 = right, 2 = down */
    int cx = 1, cy = 1;

    ml_game_session *right = open_game("maze", 1);
    if (!right) return;
    if (maze_push(right, 0, 4, &cx, &cy) == 1) open_dir = 1;
    ml_game_close(right);

    if (!open_dir) {
        ml_game_session *down = open_game("maze", 1);
        if (!down) return;
        cx = 1; cy = 1;
        if (maze_push(down, 1, 4, &cx, &cy) == 1) open_dir = 2;
        ml_game_close(down);
    }
    check(open_dir != 0, "the corner room has a way out");
    if (!open_dir) return;

    ml_game_session *s = open_game("maze", 1);
    if (!s) return;

    if (!maze_cell(s, &cx, &cy)) {
        check(0, "the collector is on screen");
        ml_game_close(s);
        return;
    }
    check(cx == 1 && cy == 1, "the collector starts in the top-left room");

    /* Neutral stops: both axes engaged at 0 ask for no direction, so the
     * collector keeps its cell where every other game would keep moving. */
    for (int i = 0; i < 6; i++) tilt(s, MAZE_TILT_X, MAZE_TILT_Y, 0, 0, 50);
    maze_cell(s, &cx, &cy);
    check(cx == 1 && cy == 1, "a still phone does not move the collector");

    /* Inside the deliberate threshold is not an instruction either. */
    for (int i = 0; i < 4; i++)
        tilt(s, MAZE_TILT_X, MAZE_TILT_Y, 8000, 0, 50);
    maze_cell(s, &cx, &cy);
    check(cx == 1 && cy == 1, "a tilt inside the threshold is not a move");

    /* The outer walls: the same deliberate angle into them does nothing. */
    for (int i = 0; i < 4; i++)
        tilt(s, MAZE_TILT_X, MAZE_TILT_Y, -30000, 0, 50);
    maze_cell(s, &cx, &cy);
    check(cx == 1 && cy == 1, "a tilt into the left wall leaves it there");
    for (int i = 0; i < 4; i++)
        tilt(s, MAZE_TILT_X, MAZE_TILT_Y, 0, -30000, 50);
    maze_cell(s, &cx, &cy);
    check(cx == 1 && cy == 1, "a tilt into the top wall leaves it there");

    /* The deliberate tilt: exactly one cell in the four ticks of the cadence,
     * and it stays on the grid the maze draws. */
    cx = 1; cy = 1;
    const int moves = maze_push(s, open_dir == 2, 4, &cx, &cy);
    check(moves == 1, "a deliberate tilt steps one cell in four ticks");
    if (open_dir == 1)
        check(cx == 2 && cy == 1, "the step is one cell to the right");
    else
        check(cx == 1 && cy == 2, "the step is one cell down");

    /* Neutral again stops it where the step left it. */
    for (int i = 0; i < 6; i++) tilt(s, MAZE_TILT_X, MAZE_TILT_Y, 0, 0, 50);
    maze_cell(s, &cx, &cy);
    if (open_dir == 1)
        check(cx == 2 && cy == 1, "neutral stops it in the new cell");
    else
        check(cx == 1 && cy == 2, "neutral stops it in the new cell");
    ml_game_close(s);

    /* With both axes idle the pad drives the same step, same cadence. */
    ml_game_session *pad = open_game("maze", 1);
    if (!pad) return;
    for (int i = 0; i < 4; i++)
        feed(pad, open_dir == 1 ? MAZE_RIGHT : MAZE_DOWN, 1, 25);
    cx = -1; cy = -1;
    maze_cell(pad, &cx, &cy);
    if (open_dir == 1)
        check(cx == 2 && cy == 1, "the pad steps it one cell to the right");
    else
        check(cx == 1 && cy == 2, "the pad steps it one cell down");
    ml_game_close(pad);
}

int main(void)
{
    test_axis_map();
    test_rally();
    test_breakout();
    test_invaders();
    test_tetris();
    test_snake();
    test_probe();
    test_racer();
    test_cave();
    test_maze();
    test_gallery();

    printf("\n%d checks, %d failures\n", g_checks, g_failures);
    if (g_failures) { printf("FAIL\n"); return 1; }
    printf("PASS\n");
    return 0;
}
