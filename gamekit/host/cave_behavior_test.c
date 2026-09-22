/*
 * cave_behavior_test.c - the cave's collision and the pause after a crash.
 *
 * The cases here are the ones a screenshot cannot settle: a tilt is an absolute
 * request, so a wrist can ask for a jump across the whole shaft in one tick, and
 * the ship must meet the rock on the way rather than arrive inside it; the
 * shaft's opening pinches as it is travelled, so a column that was fine a moment
 * ago can close around a ship that did not move; and a crash has to cost exactly
 * one life and leave the cave in a state the player can fly again.
 *
 * The fixture includes the game's own translation unit and provides the ctx
 * service it reaches for, so it drives the game's real static lifecycle without
 * a production test API. It links the view helper and the core, never the
 * runtime and never the game's own object: a service the game calls that is not
 * stubbed here is a link error, which is the point.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "../examples/cave/game_cave.c"

/* The game reaches the runtime's PRNG through ctx for the walk of the tunnel
 * centre. The fixture owns it instead of opening a session: the same xorshift
 * the runtime uses, so the rolls are as deterministic as the game expects. */
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
    cave_state  st;
    ml_game_cfg cfg;
    ml_view     view;
    ml_canvas   cv;
} fixture;

static bool fx_open(fixture *f)
{
    memset(f, 0, sizeof(*f));
    f->cfg.seed = 1;
    f->cfg.panel_w = CAVE_COLS;
    f->cfg.panel_h = CAVE_H;
    if (!ml_canvas_init(&f->cv, CAVE_COLS, CAVE_H, NULL)) return false;
    ml_view_compute(&f->view, ml_game_cave.pref_w, ml_game_cave.pref_h,
                    ml_game_cave.fit, CAVE_COLS, CAVE_H);
    fx_rng_state = 1u;
    ml_game_cave.init(&f->st, &f->cfg, NULL);
    ml_game_cave.reset(&f->st, NULL);
    return true;
}

static void fx_close(fixture *f)
{
    ml_canvas_free(&f->cv);
}

static void fx_step(fixture *f, int ticks)
{
    for (int t = 0; t < ticks; t++) ml_game_cave.update(&f->st, NULL);
}

static void fx_draw(fixture *f)
{
    ml_game_cave.draw(&f->st, &f->view, &f->cv, NULL);
}

/* One axis sample, at the level the phone or the app's touch pad sends it. */
static void fx_tilt(fixture *f, int value)
{
    ml_input_event e;
    memset(&e, 0, sizeof(e));
    e.player_id = 1;
    e.code = 2;
    e.value = (int16_t)value;
    e.type = ML_INPUT_AXIS;
    ml_game_cave.input(&f->st, &e, NULL);
}

/* One button edge, as a pad or the touch pad delivers it. */
static void fx_press(fixture *f, uint16_t code, int down)
{
    ml_input_event e;
    memset(&e, 0, sizeof(e));
    e.player_id = 1;
    e.code = code;
    e.value = (int16_t)(down ? 1 : 0);
    e.type = ML_INPUT_BUTTON;
    ml_game_cave.input(&f->st, &e, NULL);
}

/* The cave a case needs: every column at the same centre, at [distance], so the
 * opening and the pace are exactly the ones that distance implies. */
static void fx_straight(fixture *f, int centre, uint16_t distance)
{
    for (int i = 0; i < CAVE_COLS; i++) f->st.centre[i] = (uint8_t)centre;
    f->st.distance = distance;
}

/* Hold the cave still for a case that is about the ship: a counter this long
 * outlasts every case here, so no column arrives mid-assertion. */
static void fx_hold_scroll(fixture *f)
{
    f->st.scroll_ctr = 200;
}

/* A travelled cave with a shaft that has wandered, then one crash into its
 * rock. Used by the two cases that are about what a crash leaves behind. */
static void fx_travelled_crash(fixture *f)
{
    fx_straight(f, CAVE_CENTRE, 10);
    f->st.score = 10;
    f->st.centre[0] = CAVE_CENTRE_MAX;
    f->st.centre[30] = CAVE_CENTRE_MIN;
    f->st.ship_y = 12;             /* rock: the opening starts at row 14 */
    fx_step(f, 1);
}

static ml_rgb fx_px(const fixture *f, int x, int y)
{
    return ml_canvas_get(&f->cv, x, y);
}

static int fx_same(ml_rgb a, ml_rgb b)
{
    return a.r == b.r && a.g == b.g && a.b == b.b;
}

static int fx_is_wall(ml_rgb p)
{
    return fx_same(p, ML_RGB(0, 80, 255));
}

static int fx_is_black(ml_rgb p)
{
    return fx_same(p, ml_black);
}

/* ---- the cave scrolls at the pace it declares --------------------------- */

/* Drive the cave one tick at a time and record, for every column, how many
 * ticks passed between it and the one before — measured by flying, not by
 * reading the pace table. The ship is left at the middle of the shaft, where no
 * centre the walk can reach puts rock under it, so it never interrupts the run. */
static void test_scroll_cadence(void)
{
    printf("cave: the tunnel scrolls at its declared pace\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }

    static int gap_end[502];
    int prev = 0, last = 0;
    for (int tick = 1; f.st.distance < 501; tick++) {
        fx_step(&f, 1);
        if ((int)f.st.distance != prev) {
            gap_end[prev] = tick - last;
            last = tick;
            prev = (int)f.st.distance;
        }
    }

    check(gap_end[0] == 4, "the first column arrives four ticks in");
    check(gap_end[159] == 4, "and four ticks apart while the shaft is wide");
    check(gap_end[160] == 3, "the first pinch closes a tick off the pace");
    check(gap_end[319] == 3, "which holds until the second pinch");
    check(gap_end[320] == 2 && gap_end[500] == 2, "and then never quicker");
    check(f.st.score == f.st.distance, "one point a column");
    check(f.st.lives == CAVE_LIVES && f.st.status == CAVE_PLAYING,
          "and a ship left in the middle of the shaft never meets rock");

    int walk_ok = 1;
    for (int i = 0; i < CAVE_COLS; i++) {
        if (f.st.centre[i] < CAVE_CENTRE_MIN || f.st.centre[i] > CAVE_CENTRE_MAX)
            walk_ok = 0;
        if (i + 1 < CAVE_COLS) {
            int d = (int)f.st.centre[i + 1] - (int)f.st.centre[i];
            if (d < -1 || d > 1) walk_ok = 0;
        }
    }
    check(walk_ok, "and the rock never steps more than a row between columns");

    fx_close(&f);
}

/* ---- the opening pinches as the cave is travelled ----------------------- */

/* Read off the panel: the rock is the only blue in the band, and the opening is
 * what is left black after the ship has been drawn over it. */
static void test_tunnel_narrows(void)
{
    printf("cave: the opening pinches as the cave is travelled\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }

    fx_straight(&f, CAVE_CENTRE, 0);
    fx_draw(&f);
    check(fx_is_wall(fx_px(&f, 30, 13)) && !fx_is_wall(fx_px(&f, 30, 14)),
          "at the start the opening reaches from row 14");
    check(!fx_is_wall(fx_px(&f, 30, 26)) && fx_is_wall(fx_px(&f, 30, 27)),
          "to row 26");

    fx_straight(&f, CAVE_CENTRE, 320);
    fx_draw(&f);
    check(fx_is_wall(fx_px(&f, 30, 15)) && !fx_is_wall(fx_px(&f, 30, 16)),
          "after two pinches the ceiling has closed onto row 16");
    check(!fx_is_wall(fx_px(&f, 30, 24)) && fx_is_wall(fx_px(&f, 30, 25)),
          "and the floor onto row 24");
    check(fx_same(fx_px(&f, 11, 19), ML_RGB(0, 255, 255)) &&
          fx_same(fx_px(&f, 11, 20), ML_RGB(0, 255, 255)),
          "with the two-row ship still drawn where it flies");

    fx_close(&f);
}

/* ---- a thrown tilt meets the rock --------------------------------------- */

/* The ship's legal band in a still cave is one interval, so a sweep can never
 * disagree with a destination test there; what the sweep pins down is that a
 * tilt asking for a row the shaft does not have is a crash at the rock, not a
 * teleport into it, and that a tilt the shaft can hold is flown to and held. */
static void test_thrown_tilt(void)
{
    printf("cave: a thrown tilt cannot skip over rock\n");
    fixture f;

    if (!fx_open(&f)) { check(0, "fixture opens"); return; }
    fx_tilt(&f, 32767);            /* the far end of the travel: row 29, rock */
    fx_step(&f, 1);
    check(f.st.lives == CAVE_LIVES - 1, "full tilt into the roof is a crash");
    check(f.st.ship_y == CAVE_SHIP_START_Y,
          "and leaves the ship mid-shaft, not inside the rock");
    fx_close(&f);

    if (!fx_open(&f)) { check(0, "fixture opens"); return; }
    fx_tilt(&f, -32767);           /* the other end: row 10, rock */
    fx_step(&f, 1);
    check(f.st.lives == CAVE_LIVES - 1, "full tilt into the floor is a crash");
    check(f.st.ship_y == CAVE_SHIP_START_Y, "and is not tunnelled through");
    fx_close(&f);

    if (!fx_open(&f)) { check(0, "fixture opens"); return; }
    fx_tilt(&f, 19661);            /* maps to row 25, the lowest open top */
    fx_step(&f, 1);
    check(f.st.lives == CAVE_LIVES && f.st.ship_y == 25,
          "a tilt the shaft can hold flies the ship to that row");
    fx_step(&f, 2);
    check(f.st.ship_y == 25, "and holding the angle holds the ship still");

    fx_tilt(&f, 0);                /* level: the middle of the travel */
    fx_step(&f, 1);
    check(f.st.ship_y == CAVE_SHIP_START_Y, "a level phone puts it back mid-shaft");
    fx_close(&f);
}

/* ---- the pad steps the ship a row a tick -------------------------------- */

static void test_button_step(void)
{
    printf("cave: the pad steps the ship a row a tick\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }

    fx_straight(&f, CAVE_CENTRE, 0);
    fx_hold_scroll(&f);

    fx_press(&f, 0, 1);            /* Up */
    fx_step(&f, 1);
    check(f.st.ship_y == CAVE_SHIP_START_Y - 1, "one press is one row");

    fx_press(&f, 0, 0);
    fx_press(&f, 1, 1);            /* Down */
    fx_step(&f, 1);
    check(f.st.ship_y == CAVE_SHIP_START_Y, "and the opposite button steps back");

    fx_press(&f, 1, 0);
    fx_press(&f, 0, 1);            /* Up again */
    fx_step(&f, 1);
    check(f.st.ship_y == CAVE_SHIP_START_Y - 1, "Up alone climbs again");

    fx_press(&f, 1, 1);            /* both held */
    fx_step(&f, 1);
    check(f.st.ship_y == CAVE_SHIP_START_Y - 1 && f.st.lives == CAVE_LIVES,
          "and a held pair cancels instead of diving");
    fx_close(&f);
}

/* ---- every column and row under the ship is rock-tested ----------------- */

/* A pinch one column wide, under one ship column at a time: each is enough on
 * its own to close row 21, which a straight shaft leaves open. */
static void test_footprint_columns(void)
{
    printf("cave: every column under the ship is rock-tested\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }
    fx_straight(&f, CAVE_CENTRE, 320);
    fx_hold_scroll(&f);
    f.st.ship_y = 21;
    fx_step(&f, 1);
    check(f.st.lives == CAVE_LIVES, "row 21 is open while the shaft is straight");
    fx_close(&f);

    for (int x = CAVE_SHIP_X; x < CAVE_SHIP_X + CAVE_SHIP_W; x++) {
        fixture g;
        if (!fx_open(&g)) { check(0, "fixture opens"); return; }
        fx_straight(&g, CAVE_CENTRE, 320);
        fx_hold_scroll(&g);
        g.st.centre[x] = CAVE_CENTRE_MIN;   /* a bulge under that one column */
        g.st.ship_y = 21;
        fx_step(&g, 1);
        check(g.st.lives == CAVE_LIVES - 1,
              "a bulge under any ship column is a crash");
        check(g.st.ship_y == CAVE_SHIP_START_Y, "and the ship is put back mid-shaft");
        fx_close(&g);
    }
}

/* The ship is two rows tall: the second row is rock-tested like the first, so a
 * top row the opening would take is still a crash when the tail does not fit. */
static void test_footprint_height(void)
{
    printf("cave: the ship is two rows tall\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }

    fx_straight(&f, CAVE_CENTRE, 320);   /* the opening is rows 16 to 24 */
    fx_hold_scroll(&f);

    f.st.ship_y = 23;
    fx_step(&f, 1);
    check(f.st.lives == CAVE_LIVES, "the ship fits with its tail in the opening");

    f.st.ship_y = 24;
    fx_step(&f, 1);
    check(f.st.lives == CAVE_LIVES - 1,
          "but row 24 is open and row 25 is rock, so its tail cannot be there");
    fx_close(&f);
}

/* ---- a collision costs one life ----------------------------------------- */

static void test_one_life_per_crash(void)
{
    printf("cave: a collision costs exactly one life\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }

    fx_straight(&f, CAVE_CENTRE, 0);
    f.st.ship_y = 12;              /* rock: the opening starts at row 14 */
    fx_step(&f, 1);
    check(f.st.lives == CAVE_LIVES - 1, "the crash takes a life");
    check(f.st.score == 0 && f.st.distance == 0, "and costs no ground");

    fx_step(&f, 5);
    check(f.st.lives == CAVE_LIVES - 1 && f.st.status == CAVE_PLAYING,
          "and the ship, put back mid-shaft, costs no second life");
    fx_close(&f);
}

/* ---- a crash leaves a cave to fly again --------------------------------- */

static void test_crash_resets_cave(void)
{
    printf("cave: a crash opens the cave straight again\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }

    fx_straight(&f, CAVE_CENTRE, 10);
    f.st.score = 10;
    f.st.centre[30] = CAVE_CENTRE_MIN;   /* the shaft has wandered off centre */
    fx_draw(&f);
    check(fx_is_wall(fx_px(&f, 30, 25)),
          "the travelled cave has rock at row 25 of that column");

    f.st.ship_y = 12;
    fx_step(&f, 1);
    check(f.st.lives == CAVE_LIVES - 1, "one life is gone");
    check(f.st.ship_y == CAVE_SHIP_START_Y, "the ship is back mid-shaft");
    check(f.st.score == 10 && f.st.distance == 10,
          "and the ground already covered is kept");

    fx_draw(&f);
    check(!fx_is_wall(fx_px(&f, 30, 25)),
          "and the shaft has opened straight again at that column");
    fx_close(&f);
}

/* The pause is the crash's, not the scroll's: the counter is not wound down
 * while it runs, so the cave resumes its cadence instead of snapping a column
 * through on the first tick back. */
static void test_recovery_holds_the_cave(void)
{
    printf("cave: the world waits out the crash pause\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }

    fx_travelled_crash(&f);
    check(f.st.lives == CAVE_LIVES - 1 &&
          f.st.centre[30] == CAVE_CENTRE,
          "the crash is the one the reset case describes");

    fx_step(&f, 80);
    check(f.st.distance == 10, "nothing scrolls while the pause runs");

    fx_step(&f, 3);
    check(f.st.distance == 10, "nor in the ticks just after it");

    fx_step(&f, 1);
    check(f.st.distance == 11 && f.st.score == 11,
          "and the next column arrives a whole interval after the pause");

    check(f.st.lives == CAVE_LIVES - 1 && f.st.status == CAVE_PLAYING,
          "with the recovered ship flying on untouched");
    fx_close(&f);
}

/* ---- the last crash ends the run ---------------------------------------- */

static void test_last_life_ends_run(void)
{
    printf("cave: the last crash ends the run\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }

    fx_straight(&f, CAVE_CENTRE, 0);
    f.st.score = 137;
    f.st.lives = 1;
    f.st.ship_y = 12;
    fx_step(&f, 1);

    check(f.st.lives == 0 && ml_game_cave.is_over(&f.st), "the run is over");

    fx_step(&f, 10);
    check(ml_game_cave.is_over(&f.st) && f.st.score == 137,
          "and a finished run neither moves nor scores");

    fx_draw(&f);

    int board_clear = 1;
    for (int y = CAVE_ROW_TOP; y <= 16; y++)
        for (int x = 0; x < CAVE_COLS; x++)
            if (!fx_is_black(fx_px(&f, x, y))) board_clear = 0;
    check(board_clear && fx_is_black(fx_px(&f, 30, 10)) &&
          fx_is_black(fx_px(&f, 11, 19)),
          "the board is cleared, rock and ship alike");

    int score_ink = 0;
    for (int y = 0; y < CAVE_ROW_TOP; y++)
        for (int x = 0; x < CAVE_COLS; x++)
            if (!fx_is_black(fx_px(&f, x, y))) score_ink = 1;
    check(score_ink, "the final score is drawn in the HUD band");

    int over_ink = 0, min_x = CAVE_COLS, max_x = -1;
    for (int y = 17; y <= 26; y++)
        for (int x = 0; x < CAVE_COLS; x++)
            if (!fx_is_black(fx_px(&f, x, y))) {
                over_ink = 1;
                if (x < min_x) min_x = x;
                if (x > max_x) max_x = x;
            }
    check(over_ink, "and a word is drawn over the middle of the panel");
    check(over_ink && min_x >= 8 && max_x <= CAVE_COLS - 9,
          "centred, not pinned to the left like the score");
    fx_close(&f);
}

int main(void)
{
    test_scroll_cadence();
    test_tunnel_narrows();
    test_thrown_tilt();
    test_button_step();
    test_footprint_columns();
    test_footprint_height();
    test_one_life_per_crash();
    test_crash_resets_cave();
    test_recovery_holds_the_cave();
    test_last_life_ends_run();

    printf("\n%d checks, %d failures\n", g_checks, g_failures);
    if (g_failures) { printf("FAIL\n"); return 1; }
    printf("PASS\n");
    return 0;
}
