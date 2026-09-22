/*
 * racer_behavior_test.c - regression test for Tilt Racer's edge cases.
 *
 * What it pins down, all of it read off the game's own update and the drawn
 * panel:
 *
 * - the player's move is swept column by column. The tilt axis is an absolute
 *   position, so a full tilt swings the car from one side of the road to the
 *   other in a single tick; the sweep is what stops that from jumping straight
 *   through a car parked between the two positions. A car outside the swept
 *   columns, and one that is merely side by side with the car, must not
 *   register as a hit.
 * - the traffic's move is swept row by row, and a car only collides once its
 *   four-row body actually meets the player's, so a car one column over drives
 *   the whole road without touching it.
 * - the first collision of a tick costs exactly one life, not one per car, and
 *   it clears the road and keeps the player's column, score and difficulty.
 *   Four lives' worth of collisions drain three lives and the third is the
 *   end of the game.
 * - cars that get past score and count, the score stops at 9999, and the
 *   difficulty a pass count buys is visible as the traffic's speed and as the
 *   spawn cadence.
 * - the terminal frame clears the board (no cyan left) and draws the score
 *   band and the ending; is_over agrees.
 * - a snapshot is all-or-nothing: too small a buffer is refused, a buffer of
 *   the exact size round-trips the state, and restoring a short buffer leaves
 *   the state alone.
 *
 * The fixture includes the racer translation unit - which reaches the runtime
 * only through ml_ctx_rng - and provides that one service itself, the same
 * xorshift the runtime uses, so a test can drive the game tick by tick and
 * place traffic exactly where the case needs it. The Makefile links this
 * fixture with neither the runtime (whose ml_ctx_rng this file replaces) nor
 * the game's own object (which it includes).
 *
 * Observable: the state the game's own update left, plus the panel it drew. The
 * fixtures place cars through the state the game itself owns rather than any
 * test-only seam.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "../examples/racer/game_racer.c"

/* The game reaches the runtime's PRNG through ctx. The fixture owns it instead
 * of opening a session: same xorshift the runtime uses, so the rolls are as
 * deterministic as the game expects. Any other ctx service the game called
 * would be a link error, which is the point. */
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

#define PANEL_W 64
#define PANEL_H 32

#define CODE_LEFT  0
#define CODE_RIGHT 1
#define CODE_TILT  2

typedef struct {
    racer_state st;
    ml_game_cfg cfg;
    ml_view     view;
    ml_canvas   cv;
} fixture;

static bool fx_open(fixture *f)
{
    memset(f, 0, sizeof(*f));
    f->cfg.seed = 1;
    f->cfg.panel_w = PANEL_W;
    f->cfg.panel_h = PANEL_H;
    if (!ml_canvas_init(&f->cv, PANEL_W, PANEL_H, NULL)) return false;
    ml_view_compute(&f->view, ml_game_racer.pref_w, ml_game_racer.pref_h,
                    ml_game_racer.fit, PANEL_W, PANEL_H);
    fx_rng_state = 1u;
    ml_game_racer.init(&f->st, &f->cfg, NULL);
    ml_game_racer.reset(&f->st, NULL);
    return true;
}

static void fx_close(fixture *f)
{
    ml_canvas_free(&f->cv);
}

static void fx_step(fixture *f, int ticks)
{
    for (int t = 0; t < ticks; t++) ml_game_racer.update(&f->st, NULL);
}

static void fx_draw(fixture *f)
{
    ml_game_racer.draw(&f->st, &f->view, &f->cv, NULL);
}

static void fx_button(fixture *f, uint16_t code, int value)
{
    ml_input_event e;
    memset(&e, 0, sizeof(e));
    e.player_id = 1;
    e.code = code;
    e.value = (int16_t)value;
    e.type = ML_INPUT_BUTTON;
    ml_game_racer.input(&f->st, &e, NULL);
}

static void fx_axis(fixture *f, int value)
{
    ml_input_event e;
    memset(&e, 0, sizeof(e));
    e.player_id = 1;
    e.code = CODE_TILT;
    e.value = (int16_t)value;
    e.type = ML_INPUT_AXIS;
    ml_game_racer.input(&f->st, &e, NULL);
}

/* Park one traffic car in a slot at a stated column and top row. */
static void fx_car(fixture *f, int slot, int x, int row)
{
    f->st.cars[slot].on = 1;
    f->st.cars[slot].x = (int16_t)x;
    f->st.cars[slot].y = (int32_t)row << 8;
}

static void fx_no_cars(fixture *f)
{
    for (int i = 0; i < RACER_SLOTS; i++) f->st.cars[i].on = 0;
}

static int fx_cars_on(const fixture *f)
{
    int n = 0;
    for (int i = 0; i < RACER_SLOTS; i++) if (f->st.cars[i].on) n++;
    return n;
}

static ml_rgb fx_px(const fixture *f, int x, int y)
{
    return ml_canvas_get(&f->cv, x, y);
}

static int fx_is(ml_rgb p, int r, int g, int b)
{
    return p.r == (uint8_t)r && p.g == (uint8_t)g && p.b == (uint8_t)b;
}

static int fx_black_at(const fixture *f, int x, int y)
{
    return fx_is(fx_px(f, x, y), 0, 0, 0);
}

/* Lit pixels inside a rectangle of the frame. */
static int fx_lit_in(const fixture *f, int x0, int y0, int x1, int y1)
{
    int n = 0;
    for (int y = y0; y <= y1; y++)
        for (int x = x0; x <= x1; x++) {
            ml_rgb p = fx_px(f, x, y);
            if (p.r || p.g || p.b) n++;
        }
    return n;
}

/* Ticks until a car next appears on an empty road, or -1 inside the window. */
static int fx_ticks_to_spawn(fixture *f, int window)
{
    for (int t = 1; t <= window; t++) {
        fx_step(f, 1);
        if (fx_cars_on(f)) return t;
    }
    return -1;
}

/* The ticks between one car appearing on an empty road and the next one
 * appearing after that car has driven off: the spawn cadence, which is what
 * difficulty shortens. -1 if the window runs out first. */
static int fx_spawn_gap(fixture *f, int window)
{
    int t = 0;
    while (t < window && fx_cars_on(f) == 0) { fx_step(f, 1); t++; }
    if (fx_cars_on(f) == 0) return -1;
    const int first = t;
    while (t < window && fx_cars_on(f) > 0) { fx_step(f, 1); t++; }
    while (t < window && fx_cars_on(f) == 0) { fx_step(f, 1); t++; }
    if (fx_cars_on(f) == 0) return -1;
    return t - first;
}

/* ---- the declared contract ---------------------------------------------- */

static void test_declared_contract(void)
{
    printf("racer: the surface the app and the host agree on\n");
    check(strcmp(ml_game_racer.id, "racer") == 0, "the id is racer");
    check(ml_game_racer.pref_w == 64 && ml_game_racer.pref_h == 32,
          "it authors the 64x32 panel");
    check(ml_game_racer.fit == ML_FIT_LETTERBOX, "letterboxed, never stretched");
    check(ml_game_racer.tick_ms == 25, "a 25ms tick");
    check(ml_game_racer.max_players == 1, "single player");
    check(ml_game_racer.state_size <= ML_SNAPSHOT_MAX - 4,
          "the state fits the 1020 bytes a broadcast leaves");

    check(ml_game_racer.control_count == 3, "three controls");
    check(ml_game_racer.controls[CODE_LEFT].code == CODE_LEFT &&
          strcmp(ml_game_racer.controls[CODE_LEFT].label, "Left") == 0 &&
          ml_game_racer.controls[CODE_LEFT].type == ML_INPUT_BUTTON,
          "code 0 is the Left button");
    check(ml_game_racer.controls[CODE_RIGHT].code == CODE_RIGHT &&
          strcmp(ml_game_racer.controls[CODE_RIGHT].label, "Right") == 0 &&
          ml_game_racer.controls[CODE_RIGHT].type == ML_INPUT_BUTTON,
          "code 1 is the Right button");
    check(ml_game_racer.controls[CODE_TILT].code == CODE_TILT &&
          strcmp(ml_game_racer.controls[CODE_TILT].label, "TiltX") == 0 &&
          ml_game_racer.controls[CODE_TILT].type == ML_INPUT_AXIS &&
          ml_game_racer.controls[CODE_TILT].caps == ML_CAP_ACCEL,
          "code 2 is the TiltX axis");
}

/* ---- the movement model the sweep sits on ------------------------------- */

static void test_movement(void)
{
    printf("racer: buttons step from here, a held axis holds, idle never recentres\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }

    check(f.st.px == 30, "the car starts centred");
    check(f.st.lives == 3, "with three lives");

    /* Buttons: one column per tick, held. */
    fx_button(&f, CODE_RIGHT, 1);
    fx_step(&f, 3);
    check(f.st.px == 33, "Right moves one column per tick");
    fx_button(&f, CODE_RIGHT, 0);
    fx_step(&f, 2);
    check(f.st.px == 33, "releasing stops dead, with no drift");
    fx_button(&f, CODE_LEFT, 1);
    fx_step(&f, 5);
    check(f.st.px == 28, "Left moves back the same way");

    /* Opposite buttons cancel rather than picking a winner. */
    fx_button(&f, CODE_RIGHT, 1);
    fx_step(&f, 4);
    check(f.st.px == 28, "both buttons held cancel out");
    fx_button(&f, CODE_LEFT, 0);
    fx_button(&f, CODE_RIGHT, 0);

    /* The axis is a position, not a velocity: the ends of the travel land
     * exactly on the ends of the road, and a level phone centres the car. */
    fx_axis(&f, 32767);
    fx_step(&f, 1);
    check(f.st.px == 51, "+full tilt puts the car at the right end");
    fx_axis(&f, -32767);
    fx_step(&f, 1);
    check(f.st.px == 10, "-full tilt puts it at the left end");
    fx_axis(&f, 0);
    fx_step(&f, 1);
    check(f.st.px == 30, "a level phone puts it back at the centre");

    /* A held angle holds the column; the buttons own the road again only when
     * the axis goes idle, and they move from wherever the car is. */
    fx_axis(&f, 16384);
    fx_step(&f, 1);
    const int held = f.st.px;
    fx_step(&f, 5);
    check(f.st.px == held, "a held angle holds the same column");
    fx_axis(&f, ML_AXIS_IDLE);
    fx_step(&f, 3);
    check(f.st.px == held, "an idle axis leaves the column alone");

    /* Buttons still move it from there, and stop at the road's end. */
    fx_button(&f, CODE_RIGHT, 1);
    fx_step(&f, 60);
    check(f.st.px == 51, "buttons move from the held column to the right end");
    fx_button(&f, CODE_RIGHT, 0);
    fx_button(&f, CODE_LEFT, 1);
    fx_step(&f, 60);
    check(f.st.px == 10, "and stop at the left end too, never off the road");
    fx_button(&f, CODE_LEFT, 0);

    fx_close(&f);
}

/* ---- the swept player move ---------------------------------------------- */

static void test_player_sweep(void)
{
    printf("racer: a full-tilt move is swept, column by column\n");
    fixture f;

    /* The control: with the road clear, one full-tilt tick really does carry
     * the car the whole way across, so the blocked case below is the sweep
     * catching something and not the move failing to happen. */
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }
    fx_no_cars(&f);
    fx_axis(&f, 32767);
    fx_step(&f, 1);
    check(f.st.px == 51 && f.st.lives == 3,
          "with the road clear, full tilt crosses in one tick");
    fx_close(&f);

    /* A car parked between the start and the destination: the jump must not
     * pass through it. Side by side is not a hit: touching edges do not
     * overlap. */
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }
    fx_no_cars(&f);
    fx_car(&f, 0, 40, PLAYER_TOP);
    fx_axis(&f, 32767);
    fx_step(&f, 1);
    check(f.st.lives == 2, "a car in the swept path still stops the car");
    check(f.st.px == 30, "and the car stays where it was, not at the target");
    check(fx_cars_on(&f) == 0, "a crash clears the road");
    check(f.st.status == RACER_PLAYING && !racer_is_over(&f.st),
          "one crash is not the end");
    fx_close(&f);

    /* A car to the left of a car that jumps right is not in the path. */
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }
    fx_no_cars(&f);
    fx_car(&f, 0, 13, PLAYER_TOP);
    fx_axis(&f, 32767);
    fx_step(&f, 1);
    check(f.st.px == 51 && f.st.lives == 3,
          "a car outside the swept columns is passed by");
    fx_close(&f);

    /* And the same move to the left. */
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }
    fx_no_cars(&f);
    fx_car(&f, 0, 13, PLAYER_TOP);
    fx_axis(&f, -32767);
    fx_step(&f, 1);
    check(f.st.lives == 2 && f.st.px == 30,
          "a car in the leftward path stops that move too");
    fx_close(&f);
}

/* ---- the swept traffic move --------------------------------------------- */

static void test_traffic_sweep(void)
{
    printf("racer: traffic collides only where its body and the car meet\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }
    fx_no_cars(&f);

    /* One column over is clear, four rows away is clear, and the tick the
     * four-row body reaches the car's top row is the hit. */
    fx_car(&f, 0, 33, 20);
    fx_step(&f, 1);
    check(f.st.lives == 3, "a car one column over does not touch the player");
    fx_no_cars(&f);

    fx_car(&f, 0, 30, 22);
    fx_step(&f, 1);
    check(f.st.lives == 3 && fx_cars_on(&f) == 1,
          "a car still below the car's nose is not a hit yet");
    fx_step(&f, 1);
    check(f.st.lives == 2, "the tick its body reaches the player is the hit");
    check(fx_cars_on(&f) == 0, "and the road clears");

    /* A car that gets past scores, and never touches a player it shared a
     * column with on the way by. */
    fx_no_cars(&f);
    f.st.lives = 3;
    f.st.score = 0;
    f.st.passed = 0;
    fx_car(&f, 0, 30, 20);
    f.st.cars[0].x = 33;               /* one column over for the whole run */
    fx_step(&f, 25);
    check(f.st.lives == 3, "it drove the whole road without a hit");
    check(fx_cars_on(&f) == 0, "and it is gone once its top row passes row 30");
    check(f.st.score == 10 && f.st.passed == 1, "and it scored and counted");

    fx_close(&f);
}

/* ---- one collision, one life -------------------------------------------- */

static void test_one_collision_one_life(void)
{
    printf("racer: the first collision of a tick costs exactly one life\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }
    fx_no_cars(&f);
    f.st.score = 120;
    f.st.passed = 30;

    /* Two cars in the path of one full-tilt move. */
    fx_car(&f, 0, 20, PLAYER_TOP);
    fx_car(&f, 1, 40, PLAYER_TOP);
    fx_axis(&f, 32767);
    fx_step(&f, 1);
    check(f.st.lives == 2, "two cars hit in one tick still cost one life");
    check(f.st.px == 30 && f.st.score == 120 && f.st.passed == 30,
          "the crash keeps the column, the score and the difficulty");
    check(f.st.spawn_timer == 48 - 4 * 3, "and restarts the spawn countdown");

    /* Two more collisions, one tick apart, drain the lives one at a time. */
    fx_car(&f, 0, 20, PLAYER_TOP);
    fx_car(&f, 1, 40, PLAYER_TOP);
    fx_step(&f, 1);
    check(f.st.lives == 1, "the next crash costs the second life");
    fx_car(&f, 0, 20, PLAYER_TOP);
    fx_car(&f, 1, 40, PLAYER_TOP);
    fx_step(&f, 1);
    check(f.st.lives == 0, "and the third costs the last");
    check(f.st.status == RACER_OVER && racer_is_over(&f.st),
          "zero lives ends the game");

    /* Terminal is terminal: nothing moves after it. */
    const uint16_t score = f.st.score;
    const int px = f.st.px;
    fx_no_cars(&f);
    fx_car(&f, 0, 30, PLAYER_TOP);
    fx_step(&f, 20);
    check(f.st.lives == 0 && f.st.status == RACER_OVER,
          "later updates leave the ending alone");
    check(f.st.score == score && f.st.px == px,
          "and the final score stands");

    fx_close(&f);
}

/* ---- scoring and difficulty --------------------------------------------- */

static void test_scoring(void)
{
    printf("racer: passes score, the score caps, and difficulty shows in pace\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }
    fx_no_cars(&f);

    /* A car already at the last row is retired on the tick it leaves. */
    fx_car(&f, 0, 13, PASS_ROW);
    fx_step(&f, 1);
    check(fx_cars_on(&f) == 1 && f.st.score == 0,
          "a car still on row 30 has not got by");
    fx_step(&f, 1);
    check(fx_cars_on(&f) == 0 && f.st.score == 10 && f.st.passed == 1,
          "and the tick it passes scores ten");

    /* The score stops at its ceiling. */
    f.st.score = 9999;
    fx_car(&f, 0, 13, PASS_ROW);
    fx_step(&f, 2);
    check(f.st.score == 9999, "the score stops at 9999");
    check(f.st.passed == 2, "though the pass still counts");

    /* Difficulty is the pace: at four steps of difficulty a car crosses the
     * last row in one tick where difficulty zero needed two. */
    fx_close(&f);

    if (!fx_open(&f)) { check(0, "fixture opens"); return; }
    fx_no_cars(&f);
    f.st.passed = 40;                  /* difficulty 4: twice the speed */
    fx_car(&f, 0, 13, PASS_ROW);
    fx_step(&f, 1);
    check(fx_cars_on(&f) == 0 && f.st.score == 10,
          "at full difficulty a car on the last row passes in one tick");
    fx_close(&f);

    /* And difficulty is cadence: the first car is 48 ticks out either way,
     * and the gap after it is the interval the difficulty set. */
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }
    check(fx_ticks_to_spawn(&f, 120) == 48,
          "the first car appears after 48 ticks");
    check(fx_spawn_gap(&f, 200) == 48,
          "at difficulty 0 the next car is 48 ticks later");
    fx_close(&f);

    /* The first car is 48 ticks out whatever the difficulty: it is the reload
     * the difficulty shortens, not the opening wait. */
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }
    f.st.passed = 40;                  /* difficulty 4 */
    check(fx_ticks_to_spawn(&f, 120) == 48,
          "the first car is still 48 ticks out at full difficulty");
    fx_close(&f);

    if (!fx_open(&f)) { check(0, "fixture opens"); return; }
    f.st.passed = 40;                  /* difficulty 4 */
    check(fx_spawn_gap(&f, 200) == 48 - 4 * 4,
          "at difficulty 4 the next car is 32 ticks later");
    fx_close(&f);
}

/* ---- the end of the game ------------------------------------------------ */

static void test_terminal_frame(void)
{
    printf("racer: the ending clears the board and writes the score\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }
    fx_no_cars(&f);
    f.st.score = 30;

    fx_draw(&f);
    check(fx_is(fx_px(&f, 30, PLAYER_TOP), 0, 255, 255),
          "in play the panel is the board: a cyan car at its column");
    check(fx_is(fx_px(&f, 1, 31), 255, 255, 255),
          "with a life pixel on the bottom row");

    /* One life, one car in the way: the run ends. */
    f.st.lives = 1;
    fx_car(&f, 0, 30, 22);
    fx_step(&f, 2);
    check(f.st.lives == 0 && racer_is_over(&f.st), "the run is over");

    fx_draw(&f);
    int cyan = 0;
    for (int y = 0; y < PANEL_H; y++)
        for (int x = 0; x < PANEL_W; x++)
            if (fx_is(fx_px(&f, x, y), 0, 255, 255)) cyan++;
    check(cyan == 0, "the terminal frame has no board left on it");
    check(fx_lit_in(&f, 0, 0, PANEL_W - 1, 9) > 0,
          "the final score is drawn in the HUD band");
    check(fx_lit_in(&f, 12, 15, PANEL_W - 13, 27) > 0,
          "and the ending is drawn centred at y=17");
    check(fx_black_at(&f, 1, 31), "the life pixels are gone with the board");

    fx_close(&f);
}

/* ---- snapshot ------------------------------------------------------------ */

static void test_snapshot(void)
{
    printf("racer: a snapshot is all or nothing\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }
    fx_no_cars(&f);
    fx_axis(&f, 8000);
    fx_car(&f, 2, 35, 14);
    fx_step(&f, 3);

    uint8_t buf[256];
    size_t len = 0;
    check(!ml_game_racer.snapshot(&f.st, buf, sizeof(racer_state) - 1, &len),
          "a buffer one byte short is refused");
    check(ml_game_racer.snapshot(&f.st, buf, sizeof(buf), &len) &&
          len == sizeof(racer_state),
          "an exact-size buffer takes the whole state");

    const racer_state saved = f.st;

    /* A state that has moved on is put back by the snapshot. */
    f.st.lives = 1;
    f.st.score = 77;
    f.st.px = 11;
    fx_no_cars(&f);
    ml_game_racer.restore(&f.st, buf, len);
    check(memcmp(&f.st, &saved, sizeof(saved)) == 0,
          "restoring the exact snapshot puts the whole state back");

    /* A buffer of the wrong size is not a state at all. */
    f.st.lives = 1;
    ml_game_racer.restore(&f.st, buf, len - 1);
    check(f.st.lives == 1, "a short buffer leaves the state untouched");

    /* And a restored state keeps playing the same way as the one it came
     * from: same traffic, same column, same score after ten more ticks. Both
     * copies take the snapshot's own countdown, but pushed out so no spawn -
     * and so no PRNG roll, which is the session's and not the state's - falls
     * inside the window. */
    fixture a, b;
    memset(&a, 0, sizeof(a));
    memset(&b, 0, sizeof(b));
    a.st = saved;
    a.st.spawn_timer = 1000;
    ml_game_racer.restore(&b.st, buf, len);
    b.st.spawn_timer = 1000;
    fx_step(&a, 10);
    for (int t = 0; t < 10; t++) ml_game_racer.update(&b.st, NULL);
    check(memcmp(&a.st, &b.st, sizeof(racer_state)) == 0,
          "a restored state continues identically");

    fx_close(&f);
}

int main(void)
{
    test_declared_contract();
    test_movement();
    test_player_sweep();
    test_traffic_sweep();
    test_one_collision_one_life();
    test_scoring();
    test_terminal_frame();
    test_snapshot();

    printf("\n%d checks, %d failures\n", g_checks, g_failures);
    if (g_failures) { printf("FAIL\n"); return 1; }
    printf("PASS\n");
    return 0;
}
