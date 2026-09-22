/*
 * maze_behavior_test.c - regression fixture for Maze Collector.
 *
 * Maze Collector is the deliberate-tilt grid game, and the behaviours that are
 * easy to get subtly wrong are the ones this pins:
 *
 * - the maze is perfect. Every seed's field is a spanning tree over its 75
 *   rooms, so the three keys and the exit are reachable (there is exactly one
 *   path to each), which is what makes the round winnable at all: a carver that
 *   dropped one connection, or picked a key room inside a wall, could leave a
 *   key sealed off. The cases below check all 32 seeds by flooding the field.
 * - neutral means stop. An idle or resting tilt must walk nowhere, and only a
 *   deliberate dominant-axis tilt moves; when the tilt is idle the buttons
 *   steer, opposite pairs cancel, and vertical wins a tie.
 * - the step cadence is one cell per four ticks, whether the cell ahead is open
 *   (move) or a wall (stand).
 * - a round that completes on the last tick beats the timeout, banks whole
 *   remaining seconds rounded up, deals a fresh field, and leaves the new
 *   timer untouched; the third completion is the win and running out of time is
 *   the loss.
 *
 * Observable: the game's own state after its real update. The fixture includes
 * the maze translation unit - which reaches the runtime only through
 * ml_ctx_rng - and provides that one service itself, the same xorshift the
 * runtime uses, so a case can drive the game tick by tick and still choose the
 * maze it starts from. The Makefile links this fixture with neither the runtime
 * (whose ml_ctx_rng this file replaces) nor the game's own object (which it
 * includes here).
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "../examples/maze/game_maze.c"

/* The game reaches the runtime's PRNG through ctx. The fixture owns it instead
 * of opening a session, so a case can drive the game and choose its seed: the
 * same xorshift the runtime uses, so the rolls are as deterministic as the game
 * expects. A missing service would be a link error, which is the point. */
static uint32_t fx_rng_state = 1u;
uint32_t ml_ctx_rng(ml_game_ctx *ctx)
{
    (void)ctx;
    uint32_t x = fx_rng_state;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return (fx_rng_state = x);
}

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

/* ---- fixture ------------------------------------------------------------ */

typedef struct {
    maze_state st;
    ml_game_cfg cfg;
    ml_view    view;
    ml_canvas  cv;
} fixture;

static bool fx_open(fixture *f, uint32_t seed)
{
    memset(f, 0, sizeof(*f));
    f->cfg.seed = seed;
    f->cfg.panel_w = 64;
    f->cfg.panel_h = 32;
    if (!ml_canvas_init(&f->cv, f->cfg.panel_w, f->cfg.panel_h, NULL)) return false;
    ml_view_compute(&f->view, ml_game_maze.pref_w, ml_game_maze.pref_h,
                    ml_game_maze.fit, f->cfg.panel_w, f->cfg.panel_h);
    fx_rng_state = seed;
    ml_game_maze.init(&f->st, &f->cfg, NULL);
    ml_game_maze.reset(&f->st, NULL);
    return true;
}

static void fx_close(fixture *f)
{
    ml_canvas_free(&f->cv);
}

static void fx_step(fixture *f, int ticks)
{
    for (int t = 0; t < ticks; t++) ml_game_maze.update(&f->st, NULL);
}

static void fx_axis(fixture *f, uint16_t code, int value)
{
    ml_input_event e;
    memset(&e, 0, sizeof(e));
    e.player_id = 1;
    e.code = code;
    e.value = (int16_t)value;
    e.type = ML_INPUT_AXIS;
    ml_game_maze.input(&f->st, &e, NULL);
}

static void fx_button(fixture *f, uint16_t code, int value)
{
    ml_input_event e;
    memset(&e, 0, sizeof(e));
    e.player_id = 1;
    e.code = code;
    e.value = (int16_t)value;
    e.type = ML_INPUT_BUTTON;
    ml_game_maze.input(&f->st, &e, NULL);
}

/* Whether two cells are the same square. */
static int fx_near(int ax, int ay, int bx, int by)
{
    return ax == bx && ay == by;
}

/* ---- field helpers ------------------------------------------------------ */

static int fx_open_count(const maze_state *s)
{
    int n = 0;
    for (int y = 0; y < MAZE_ROWS; y++)
        for (int x = 0; x < MAZE_COLS; x++)
            if (maze_open(s, x, y)) n++;
    return n;
}

/* Flood the open cells from the start; returns how many were reached. */
static int fx_reach(const maze_state *s, uint8_t seen[MAZE_ROWS][MAZE_COLS])
{
    static const int DX[4] = { 0, 1, 0, -1 };
    static const int DY[4] = { -1, 0, 1, 0 };
    int qx[MAZE_ROWS * MAZE_COLS], qy[MAZE_ROWS * MAZE_COLS];
    int head = 0, tail = 0, count = 0;

    memset(seen, 0, sizeof(uint8_t) * MAZE_ROWS * MAZE_COLS);
    if (!maze_open(s, MAZE_START_X, MAZE_START_Y)) return 0;

    qx[tail] = MAZE_START_X; qy[tail] = MAZE_START_Y; tail++;
    seen[MAZE_START_Y][MAZE_START_X] = 1; count = 1;

    while (head < tail) {
        const int x = qx[head], y = qy[head];
        head++;
        for (int d = 0; d < 4; d++) {
            const int nx = x + DX[d], ny = y + DY[d];
            if (nx < 0 || nx >= MAZE_COLS || ny < 0 || ny >= MAZE_ROWS) continue;
            if (!maze_open(s, nx, ny) || seen[ny][nx]) continue;
            seen[ny][nx] = 1;
            qx[tail] = nx; qy[tail] = ny; tail++;
            count++;
        }
    }
    return count;
}

/* The predecessor of the exit on the maze's one path from the start, or -1. */
static int fx_exit_approach(const maze_state *s, int *ax, int *ay)
{
    static const int DX[4] = { 0, 1, 0, -1 };
    static const int DY[4] = { -1, 0, 1, 0 };
    int px[MAZE_ROWS][MAZE_COLS], py[MAZE_ROWS][MAZE_COLS];
    int qx[MAZE_ROWS * MAZE_COLS], qy[MAZE_ROWS * MAZE_COLS];
    uint8_t seen[MAZE_ROWS][MAZE_COLS];
    int head = 0, tail = 0;

    memset(seen, 0, sizeof(seen));
    if (!maze_open(s, MAZE_START_X, MAZE_START_Y)) return -1;
    qx[tail] = MAZE_START_X; qy[tail] = MAZE_START_Y;
    px[MAZE_START_Y][MAZE_START_X] = -1; py[MAZE_START_Y][MAZE_START_X] = -1;
    seen[MAZE_START_Y][MAZE_START_X] = 1; tail++;

    while (head < tail) {
        const int x = qx[head], y = qy[head];
        head++;
        if (x == MAZE_EXIT_X && y == MAZE_EXIT_Y) {
            *ax = px[y][x];
            *ay = py[y][x];
            return 0;
        }
        for (int d = 0; d < 4; d++) {
            const int nx = x + DX[d], ny = y + DY[d];
            if (nx < 0 || nx >= MAZE_COLS || ny < 0 || ny >= MAZE_ROWS) continue;
            if (!maze_open(s, nx, ny) || seen[ny][nx]) continue;
            seen[ny][nx] = 1;
            px[ny][nx] = x; py[ny][nx] = y;
            qx[tail] = nx; qy[tail] = ny; tail++;
        }
    }
    return -1;
}

/* A blank field the cases can lay a corridor into, with nothing but the exit
 * and the clock live. */
static void fx_blank(fixture *f)
{
    for (int y = 0; y < MAZE_ROWS; y++) f->st.maze[y] = MAZE_ALL_WALLS;
    f->st.status = MAZE_PLAYING;
    f->st.timer = MAZE_ROUND_TICKS;
    f->st.score = 0;
    f->st.round = 1;
    f->st.move_ctr = 0;
    f->st.keys_left = 0;
    f->st.tilt_x = f->st.tilt_y = ML_AXIS_IDLE;
    f->st.held_up = f->st.held_down = f->st.held_left = f->st.held_right = 0;
    /* Keys parked off the corridors so a stray pickup cannot colour a
     * movement case. */
    f->st.key_x[0] = 1; f->st.key_y[0] = 9;
    f->st.key_x[1] = 3; f->st.key_y[1] = 9;
    f->st.key_x[2] = 5; f->st.key_y[2] = 9;
}

static void fx_carve_h(fixture *f, int y, int x0, int x1)
{
    for (int x = x0; x <= x1; x++) maze_carve(&f->st, x, y);
}

static void fx_carve_v(fixture *f, int x, int y0, int y1)
{
    for (int y = y0; y <= y1; y++) maze_carve(&f->st, x, y);
}

static void fx_place(fixture *f, int x, int y)
{
    f->st.player_x = (uint8_t)x;
    f->st.player_y = (uint8_t)y;
    f->st.move_ctr = 0;
}

/* ---- a perfect maze on every seed --------------------------------------- */

static void test_mazes_are_perfect_and_reachable(void)
{
    printf("maze: each seed deals a perfect maze whose keys and exit are reachable\n");
    int bad_count = 0, bad_connect = 0, bad_targets = 0;

    for (uint32_t seed = 1; seed <= 32; seed++) {
        fixture f;
        if (!fx_open(&f, seed)) { check(0, "a seed's fixture opens"); return; }

        uint8_t seen[MAZE_ROWS][MAZE_COLS];
        const int open = fx_open_count(&f.st);
        const int reach = fx_reach(&f.st, seen);

        if (open != 149) bad_count++;
        if (reach != open) bad_connect++;

        int ok = 1;
        for (int k = 0; k < MAZE_KEY_COUNT; k++) {
            if (!maze_open(&f.st, f.st.key_x[k], f.st.key_y[k])) ok = 0;
            if (!seen[f.st.key_y[k]][f.st.key_x[k]]) ok = 0;
            if (fx_near(f.st.key_x[k], f.st.key_y[k], MAZE_START_X, MAZE_START_Y)) ok = 0;
            if (fx_near(f.st.key_x[k], f.st.key_y[k], MAZE_EXIT_X, MAZE_EXIT_Y)) ok = 0;
        }
        /* three keys, three distinct rooms */
        if (fx_near(f.st.key_x[0], f.st.key_y[0], f.st.key_x[1], f.st.key_y[1]) ||
            fx_near(f.st.key_x[0], f.st.key_y[0], f.st.key_x[2], f.st.key_y[2]) ||
            fx_near(f.st.key_x[1], f.st.key_y[1], f.st.key_x[2], f.st.key_y[2])) ok = 0;
        if (!seen[MAZE_EXIT_Y][MAZE_EXIT_X]) ok = 0;
        if (!ok) bad_targets++;

        fx_close(&f);
    }

    check(bad_count == 0,
          "every seed's field is 75 rooms joined by 74 corridors (149 open cells)");
    check(bad_connect == 0,
          "and is connected: the start reaches every open cell");
    check(bad_targets == 0,
          "and three distinct keys plus the exit are all reachable and off the start/exit");
}

/* ---- deliberate control ------------------------------------------------- */

static void test_neutral_stops(void)
{
    printf("maze: a resting tilt walks nowhere, and the clock still runs\n");
    fixture f;
    if (!fx_open(&f, 2)) { check(0, "fixture opens"); return; }
    fx_blank(&f);
    fx_carve_h(&f, 1, 1, 10);
    fx_carve_v(&f, 5, 1, 6);
    fx_place(&f, 5, 1);

    fx_step(&f, 12);
    check(fx_near(f.st.player_x, f.st.player_y, 5, 1),
          "twelve ticks of idle tilt and no buttons leave the player put");
    check(f.st.timer == MAZE_ROUND_TICKS - 12, "and the round clock ticks down");
    fx_close(&f);
}

static void test_tilt_is_deliberate(void)
{
    printf("maze: tilt moves only past the deliberate angle, on the dominant axis\n");
    fixture f;
    if (!fx_open(&f, 2)) { check(0, "fixture opens"); return; }
    fx_blank(&f);
    fx_carve_h(&f, 1, 1, 20);
    fx_carve_v(&f, 5, 1, 6);

    /* Just under half travel asks for nothing; at half travel it moves. */
    fx_place(&f, 5, 1);
    fx_axis(&f, 4, 16382);
    fx_step(&f, 1);
    check(fx_near(f.st.player_x, f.st.player_y, 5, 1),
          "16382 units of tilt is not yet a request");

    fx_place(&f, 5, 1);
    fx_axis(&f, 4, 16383);
    fx_step(&f, 1);
    check(fx_near(f.st.player_x, f.st.player_y, 6, 1),
          "16383 units does move, one cell to the right");

    /* The larger component picks the axis; a tie goes to Y. */
    fx_place(&f, 5, 1);
    fx_axis(&f, 4, 32767); fx_axis(&f, 5, 30000);
    fx_step(&f, 1);
    check(fx_near(f.st.player_x, f.st.player_y, 6, 1),
          "the larger X component moves right");

    fx_place(&f, 5, 1);
    fx_axis(&f, 4, 30000); fx_axis(&f, 5, 32767);
    fx_step(&f, 1);
    check(fx_near(f.st.player_x, f.st.player_y, 5, 2),
          "the larger Y component moves down");

    fx_place(&f, 5, 1);
    fx_axis(&f, 4, 32767); fx_axis(&f, 5, 32767);
    fx_step(&f, 1);
    check(fx_near(f.st.player_x, f.st.player_y, 5, 2),
          "an equal tilt goes to Y");

    /* An idle component counts as zero: a driven X still moves right. */
    fx_place(&f, 5, 1);
    fx_axis(&f, 4, 32767); fx_axis(&f, 5, ML_AXIS_IDLE);
    fx_step(&f, 1);
    check(fx_near(f.st.player_x, f.st.player_y, 6, 1),
          "an idle Y does not fight a driven X");

    /* A held tilt must not drift: the same angle holds the same cell. */
    fx_place(&f, 5, 1);
    fx_step(&f, 1);
    check(fx_near(f.st.player_x, f.st.player_y, 6, 1), "a held tilt reaches a cell once");
    fx_step(&f, 32);
    check(fx_near(f.st.player_x, f.st.player_y, 14, 1),
          "and keeps walking one cell per four ticks while held");
    fx_close(&f);
}

static void test_buttons_steer_when_idle(void)
{
    printf("maze: with the tilt idle the buttons steer, and pairs cancel\n");
    fixture f;
    if (!fx_open(&f, 2)) { check(0, "fixture opens"); return; }
    fx_blank(&f);
    fx_carve_h(&f, 1, 1, 10);
    fx_carve_v(&f, 5, 1, 6);
    fx_carve_h(&f, 2, 5, 5);
    fx_carve_v(&f, 6, 1, 2);

    fx_place(&f, 5, 1);
    fx_button(&f, 3, 1);                 /* Right */
    fx_step(&f, 1);
    check(fx_near(f.st.player_x, f.st.player_y, 6, 1), "Right moves right");
    fx_button(&f, 3, 0);

    fx_place(&f, 5, 1);
    fx_button(&f, 1, 1);                 /* Down */
    fx_step(&f, 1);
    check(fx_near(f.st.player_x, f.st.player_y, 5, 2), "Down moves down");
    fx_button(&f, 1, 0);

    fx_place(&f, 5, 1);
    fx_button(&f, 2, 1);                 /* Left */
    fx_step(&f, 1);
    check(fx_near(f.st.player_x, f.st.player_y, 4, 1), "Left moves left");
    fx_button(&f, 2, 0);

    /* Up is a wall here: the attempt leaves the player standing. */
    fx_place(&f, 5, 1);
    fx_button(&f, 0, 1);
    fx_step(&f, 1);
    check(fx_near(f.st.player_x, f.st.player_y, 5, 1), "Up into a wall does not move");
    fx_button(&f, 0, 0);

    fx_place(&f, 5, 1);
    fx_button(&f, 0, 1); fx_button(&f, 1, 1);   /* Up + Down */
    fx_step(&f, 1);
    check(fx_near(f.st.player_x, f.st.player_y, 5, 1), "Up and Down cancel");
    fx_button(&f, 0, 0); fx_button(&f, 1, 0);

    fx_place(&f, 5, 1);
    fx_button(&f, 2, 1); fx_button(&f, 3, 1);   /* Left + Right */
    fx_step(&f, 1);
    check(fx_near(f.st.player_x, f.st.player_y, 5, 1), "Left and Right cancel");
    fx_button(&f, 2, 0); fx_button(&f, 3, 0);

    /* Vertical wins the tie: Up is blocked, so a horizontal-wins rule would
     * wrongly step right here. */
    fx_place(&f, 5, 1);
    fx_button(&f, 0, 1); fx_button(&f, 3, 1);   /* Up + Right */
    fx_step(&f, 1);
    check(fx_near(f.st.player_x, f.st.player_y, 5, 1),
          "a vertical and a horizontal button resolve to the vertical");
    fx_button(&f, 0, 0); fx_button(&f, 3, 0);

    fx_close(&f);
}

static void test_step_cadence(void)
{
    printf("maze: a directed step lands one cell every four ticks\n");
    fixture f;
    if (!fx_open(&f, 2)) { check(0, "fixture opens"); return; }
    fx_blank(&f);
    fx_carve_h(&f, 1, 1, 10);
    fx_place(&f, 5, 1);
    fx_axis(&f, 4, 32767);

    fx_step(&f, 1);
    check(fx_near(f.st.player_x, f.st.player_y, 6, 1), "the first tick steps one cell");
    fx_step(&f, 3);
    check(fx_near(f.st.player_x, f.st.player_y, 6, 1), "the next three wait");
    fx_step(&f, 1);
    check(fx_near(f.st.player_x, f.st.player_y, 7, 1), "the fourth steps again");

    /* A wall still consumes the step: the clock over four blocked ticks leaves
     * the player standing but the counter reloaded. */
    fx_place(&f, 10, 1);
    fx_step(&f, 1);                       /* step into the wall at x=11 */
    check(fx_near(f.st.player_x, f.st.player_y, 10, 1), "a wall blocks the step");
    fx_step(&f, 4);
    check(fx_near(f.st.player_x, f.st.player_y, 10, 1), "and keeps blocking each step");
    fx_close(&f);
}

/* ---- keys, exit and rounds --------------------------------------------- */

static void test_key_pickup_scores_once(void)
{
    printf("maze: a key scores its once, and only its once\n");
    fixture f;
    if (!fx_open(&f, 2)) { check(0, "fixture opens"); return; }
    fx_blank(&f);
    fx_carve_h(&f, 1, 1, 6);
    fx_place(&f, 1, 1);
    f.st.keys_left = 7;
    f.st.key_x[0] = 3; f.st.key_y[0] = 1;   /* straight ahead on the corridor */
    fx_button(&f, 3, 1);                     /* Right */

    fx_step(&f, 4);
    check(fx_near(f.st.player_x, f.st.player_y, 2, 1), "the player reaches the cell before the key");
    check(f.st.score == 0 && f.st.keys_left == 7, "and nothing is scored yet");

    fx_step(&f, 4);
    check(fx_near(f.st.player_x, f.st.player_y, 3, 1), "then the key's cell");
    check(f.st.score == 100, "which scores a hundred");
    check(f.st.keys_left == 6, "and marks that key home");

    fx_step(&f, 4);
    check(fx_near(f.st.player_x, f.st.player_y, 4, 1), "the player walks on");

    fx_button(&f, 3, 0);
    fx_button(&f, 2, 1);                     /* Left, back over the key */
    fx_step(&f, 4);
    check(fx_near(f.st.player_x, f.st.player_y, 3, 1), "and comes back over the key's cell");
    check(f.st.score == 100 && f.st.keys_left == 6, "which does not score a second time");
    fx_close(&f);
}

static void test_exit_locked_until_keys(void)
{
    printf("maze: the exit opens only once every key is home\n");
    fixture f;
    if (!fx_open(&f, 2)) { check(0, "fixture opens"); return; }
    fx_blank(&f);
    fx_carve_h(&f, 9, 28, 29);
    fx_place(&f, 28, 9);
    f.st.keys_left = 7;
    fx_button(&f, 3, 1);                     /* Right, onto the exit */

    fx_step(&f, 1);
    check(fx_near(f.st.player_x, f.st.player_y, MAZE_EXIT_X, MAZE_EXIT_Y),
          "the player can stand on the locked exit");
    check(f.st.round == 1 && f.st.status == MAZE_PLAYING,
          "and the locked exit does not end the round");

    /* With the keys home, the same standing cell opens the round: the step is
     * spent against the wall past the exit, then the exit resolves. */
    f.st.keys_left = 0;
    f.st.timer = 200;
    f.st.move_ctr = 0;
    fx_step(&f, 1);
    check(f.st.round == 2 && f.st.status == MAZE_PLAYING, "the unlocked exit completes the round");
    check(f.st.score == 5, "banking the five whole seconds left on the clock");
    check(f.st.timer == MAZE_ROUND_TICKS, "and dealing the next round a full timer");
    check(fx_near(f.st.player_x, f.st.player_y, MAZE_START_X, MAZE_START_Y),
          "with the player back at the start");
    check(fx_open_count(&f.st) == 149, "and a fresh perfect field");
    fx_close(&f);
}

static void test_last_tick_exit_beats_timeout(void)
{
    printf("maze: an exit on the final tick beats the timeout\n");
    fixture f;
    if (!fx_open(&f, 1)) { check(0, "fixture opens"); return; }

    int ax = 0, ay = 0;
    check(fx_exit_approach(&f.st, &ax, &ay) == 0, "the seed-1 exit has an approach");

    f.st.keys_left = 0;
    f.st.timer = 1;
    fx_place(&f, ax, ay);
    /* Drive the one cell toward the exit on the axis that leads there. */
    if (ax == MAZE_EXIT_X)      fx_axis(&f, 5, MAZE_EXIT_Y > ay ? 32767 : -32767);
    else                        fx_axis(&f, 4, MAZE_EXIT_X > ax ? 32767 : -32767);

    fx_step(&f, 1);
    /* The completion below is itself the proof the step landed on the exit:
     * the exit only resolves while the player stands on it. */
    check(f.st.round == 2 && f.st.status == MAZE_PLAYING,
          "the final tick steps onto the exit and completes instead of timing out");
    check(f.st.score == 1, "banking the one whole second that was left");
    check(f.st.timer == MAZE_ROUND_TICKS, "with the new round's timer untouched");
    check(fx_near(f.st.player_x, f.st.player_y, MAZE_START_X, MAZE_START_Y),
          "and the player dealt back to the start of the fresh field");
    check(!ml_game_maze.is_over(&f.st), "the game is not over");
    fx_close(&f);
}

static void test_timeout_loses(void)
{
    printf("maze: running out of time is the loss\n");
    fixture f;
    if (!fx_open(&f, 7)) { check(0, "fixture opens"); return; }
    f.st.keys_left = 7;
    f.st.timer = 1;
    f.st.move_ctr = 3;                       /* this tick is not a step tick */

    fx_step(&f, 1);
    check(f.st.timer == 0, "the clock reaches zero");
    check(f.st.status == MAZE_LOST, "and the round is lost");
    check(ml_game_maze.is_over(&f.st), "which is terminal");
    fx_close(&f);
}

static void test_three_rounds_win(void)
{
    printf("maze: three completed rounds are the win, each banking its time\n");
    fixture f;
    if (!fx_open(&f, 3)) { check(0, "fixture opens"); return; }
    fx_blank(&f);
    fx_carve_h(&f, 9, 28, 29);

    int expect_score = 0;
    for (int round = 1; round <= MAZE_ROUNDS; round++) {
        f.st.keys_left = 0;
        f.st.timer = 400;                    /* ten seconds banked, rounded up */
        fx_place(&f, MAZE_EXIT_X, MAZE_EXIT_Y);
        fx_step(&f, 1);
        expect_score += 10;

        check(f.st.score == expect_score, "the round's remaining seconds are banked");
        if (round < MAZE_ROUNDS) {
            check(f.st.round == round + 1 && f.st.status == MAZE_PLAYING,
                  "and the next round begins");
            check(f.st.timer == MAZE_ROUND_TICKS,
                  "with its full timer, not one tick short");
            check(fx_open_count(&f.st) == 149, "on a fresh perfect field");
        } else {
            check(f.st.status == MAZE_WON, "the third completion wins");
            check(ml_game_maze.is_over(&f.st), "and the game is over");
        }
    }
    fx_close(&f);
}

/* ---- snapshots ---------------------------------------------------------- */

static void test_snapshot_roundtrip(void)
{
    printf("maze: a snapshot restores the whole round, exactly\n");
    fixture a;
    if (!fx_open(&a, 5)) { check(0, "fixture opens"); return; }
    fx_blank(&a);
    fx_carve_h(&a, 1, 1, 10);
    a.st.keys_left = 5;
    fx_place(&a, 2, 1);
    fx_axis(&a, 4, 32767);
    fx_step(&a, 5);

    uint8_t buf[ML_SNAPSHOT_MAX];
    size_t len = 0;
    check(ml_game_maze.snapshot(&a.st, buf, sizeof(buf), &len), "the state snapshots");
    check(len == sizeof(maze_state), "in exactly its own size");

    size_t small = 0;
    check(!ml_game_maze.snapshot(&a.st, buf, sizeof(maze_state) - 1, &small),
          "a short buffer is refused");

    fixture b;
    if (!fx_open(&b, 5)) { check(0, "fixture opens"); return; }
    ml_game_maze.restore(&b.st, buf, len);
    check(memcmp(&a.st, &b.st, sizeof(a.st)) == 0, "and restores the state whole");

    /* Same inputs, same future: the maze, keys, clock and input latches all
     * travelled in the snapshot. */
    fx_step(&a, 20);
    fx_step(&b, 20);
    check(memcmp(&a.st, &b.st, sizeof(a.st)) == 0, "a restored round continues identically");

    maze_state before = b.st;
    ml_game_maze.restore(&b.st, buf, len - 1);
    check(memcmp(&before, &b.st, sizeof(before)) == 0,
          "a partial-length snapshot leaves the state untouched");

    fx_close(&a);
    fx_close(&b);
}

/* ---- drawing ------------------------------------------------------------ */

static void test_draw(void)
{
    printf("maze: the field draws walls and the player, and the terminal board clears\n");
    fixture f;
    if (!fx_open(&f, 1)) { check(0, "fixture opens"); return; }

    ml_game_maze.draw(&f.st, &f.view, &f.cv, NULL);
    ml_rgb wall = ml_canvas_get(&f.cv, MAZE_CELL_X0, MAZE_CELL_Y0);
    check(wall.r == 0 && wall.g == 80 && wall.b == 255, "the outer wall is drawn blue");
    ml_rgb player = ml_canvas_get(&f.cv, MAZE_CELL_X0 + 2 * MAZE_START_X,
                                        MAZE_CELL_Y0 + 2 * MAZE_START_Y);
    check(player.r == 0 && player.g == 255 && player.b == 255,
          "the player is drawn cyan at the start cell");

    int hud = 0;
    for (int y = 0; y < MAZE_CELL_Y0; y++)
        for (int x = 0; x < f.cv.w; x++) {
            ml_rgb p = ml_canvas_get(&f.cv, x, y);
            if (p.r || p.g || p.b) hud++;
        }
    check(hud > 0, "the HUD shows the clock above the field");

    f.st.status = MAZE_LOST;
    f.st.score = 1234;
    ml_game_maze.draw(&f.st, &f.view, &f.cv, NULL);
    int score_ink = 0;
    for (int x = 0; x < f.cv.w; x++) {
        ml_rgb p = ml_canvas_get(&f.cv, x, 0);
        if (p.r || p.g || p.b) score_ink++;
    }
    check(score_ink > 0, "the final score is drawn at the top");
    int over_ink = 0;
    for (int y = 17; y < f.cv.h; y++)
        for (int x = 0; x < f.cv.w; x++) {
            ml_rgb p = ml_canvas_get(&f.cv, x, y);
            if (p.r || p.g || p.b) over_ink++;
        }
    check(over_ink > 0, "and OVER is drawn below");
    ml_rgb cleared = ml_canvas_get(&f.cv, MAZE_CELL_X0, MAZE_CELL_Y0);
    check(cleared.r == 0 && cleared.g == 0 && cleared.b == 0,
          "on a cleared board, not the live field");

    f.st.status = MAZE_WON;
    ml_game_maze.draw(&f.st, &f.view, &f.cv, NULL);
    int win_ink = 0;
    for (int y = 17; y < f.cv.h; y++)
        for (int x = 0; x < f.cv.w; x++) {
            ml_rgb p = ml_canvas_get(&f.cv, x, y);
            if (p.g > 150 && p.r < 80) win_ink++;
        }
    check(win_ink > 0, "and a win draws the result in green");

    fx_close(&f);
}

int main(void)
{
    test_mazes_are_perfect_and_reachable();
    test_neutral_stops();
    test_tilt_is_deliberate();
    test_buttons_steer_when_idle();
    test_step_cadence();
    test_key_pickup_scores_once();
    test_exit_locked_until_keys();
    test_last_tick_exit_beats_timeout();
    test_timeout_loses();
    test_three_rounds_win();
    test_snapshot_roundtrip();
    test_draw();

    printf("\n%d checks, %d failures\n", g_checks, g_failures);
    if (g_failures) { printf("FAIL\n"); return 1; }
    printf("PASS\n");
    return 0;
}
