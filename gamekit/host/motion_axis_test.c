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
 * bright head cell, and the red dot (probe). Nothing here reads game state:
 * what is asserted is what the panel shows.
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
 *   - snake turns on a deliberate tilt only, and never reverses.
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
 * the field rect (origin 16, 32 wide on a 64-wide panel), above the stack. The
 * field frame is dim grey and sits at x=15 and x=48; the score text and the
 * next-piece preview are outside the rect. */
#define TETRIS_FIELD_X 16
#define TETRIS_FIELD_W 32

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
    /* paddle_w = clamp(64/10, 3, 10) = 6, so the travel is 0..58. Each phase
     * runs in a fresh session for a bounded number of frames: the ball is live
     * from the reset and three misses would end the round, and a finished
     * round stops reading input entirely. */
    ml_game_session *s = open_game("breakout", 1);
    if (!s) return;

    feed(s, BREAKOUT_TILT_X, 0, 50);
    const int centre = row_run_start(s, PANEL_H - 3, 3, 1, 1, 1);
    check(centre == 29, "neutral centres the paddle");

    hold(s, BREAKOUT_TILT_X, 0, 8);
    check(row_run_start(s, PANEL_H - 3, 3, 1, 1, 1) == centre, "a held angle does not drift");

    feed(s, BREAKOUT_TILT_X, 32767, 50);
    check(row_run_start(s, PANEL_H - 3, 3, 1, 1, 1) == 58, "+full is the right wall");
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
    /* On a 64x32 panel the field is 32 rows tall and gravity is one row per 20
     * ticks, so nothing locks inside this script and the piece keeps the
     * column history the assertions read. */
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

    /* Tilt right: the piece walks right, one field column per tick. */
    hold(s, TETRIS_TILT_X, 32767, 6);
    piece_span(s, &a, &b);
    check(a == spawn_a + 12, "the piece walks one column per tick");

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

int main(void)
{
    test_axis_map();
    test_rally();
    test_breakout();
    test_invaders();
    test_tetris();
    test_snake();
    test_probe();

    printf("\n%d checks, %d failures\n", g_checks, g_failures);
    if (g_failures) { printf("FAIL\n"); return 1; }
    printf("PASS\n");
    return 0;
}
