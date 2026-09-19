/*
 * snake_pace_test.c - regression test for the snake's pace.
 *
 * The bug: the pace was fixed for the whole round. snake_update stepped when the
 * absolute tick divided by w/16, so a snake that had eaten twenty foods moved
 * exactly as fast as one that had eaten none, and the only thing that ever made
 * a run harder was the snake's own length. The pace now starts at one cell per
 * w/16 ticks and gains a tick's worth of speed for every four foods, down to two
 * ticks a cell.
 *
 * Observable: how often the head moves, and the head's painted cell. The fixture
 * includes the snake translation unit and provides the two ctx services the game
 * calls (ml_ctx_rng, ml_ctx_emit_event) itself, so a test can drive the game tick
 * by tick and place the food where it wants; the Makefile links it with neither
 * the runtime (whose ml_ctx_* this file replaces) nor the game's own object.
 *
 * Every counting run starts from a fresh reset and parks the food out of the
 * head's way, so the number of steps is a function of the score alone and not of
 * where the PRNG happened to drop the food.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "../examples/snake/game_snake.c"

/* The game reaches the runtime through ctx for its PRNG and its eat/death
 * events. The fixture owns both instead of opening a session: same xorshift the
 * runtime uses, so the rolls are as deterministic as the game expects. A ctx
 * service the game calls without a stub here is a link error, which is the point.
 */
static uint32_t fx_rng_state = 1u;
uint32_t ml_ctx_rng(ml_game_ctx *ctx)
{
    (void)ctx;
    uint32_t x = fx_rng_state;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return (fx_rng_state = x);
}

void ml_ctx_emit_event(ml_game_ctx *ctx, uint16_t code, int32_t value)
{
    (void)ctx; (void)code; (void)value;
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

typedef struct {
    snake_state st;
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
    ml_view_compute(&f->view, ml_game_snake.pref_w, ml_game_snake.pref_h,
                    ml_game_snake.fit, PANEL_W, PANEL_H);
    fx_rng_state = 1u;
    ml_game_snake.init(&f->st, &f->cfg, NULL);
    ml_game_snake.reset(&f->st, NULL);
    return true;
}

static void fx_close(fixture *f)
{
    ml_canvas_free(&f->cv);
}

static void fx_step(fixture *f, int ticks)
{
    for (int t = 0; t < ticks; t++) ml_game_snake.update(&f->st, NULL);
}

static void fx_draw(fixture *f)
{
    ml_game_snake.draw(&f->st, &f->view, &f->cv, NULL);
}

/* Park the food somewhere the head's path never reaches. */
static void fx_park_food(fixture *f)
{
    f->st.food_x = 0;
    f->st.food_y = 0;
}

/* Walk the game one update at a time and record the update index of every step,
 * read as the head's ring index changing. Returns how many steps happened. */
static int fx_moves(fixture *f, int updates, int *at)
{
    int n = 0;
    uint16_t head = f->st.head;
    for (int t = 0; t < updates; t++) {
        fx_step(f, 1);
        if (f->st.head != head) {
            head = f->st.head;
            if (at) at[n] = t;
            n++;
        }
    }
    return n;
}

/* The gap between the steps, or -1 when they are not evenly spaced. */
static int fx_gap(const int *at, int n)
{
    if (n < 2) return -1;
    for (int i = 1; i < n; i++)
        if (at[i] - at[i - 1] != at[1] - at[0]) return -1;
    return at[1] - at[0];
}

/* The cell the head is painted in: the one bright green nothing else uses (the
 * body is a third as bright and the food is red). */
static int fx_head_cell(const fixture *f, int *hx, int *hy)
{
    const ml_rgb head = ML_RGB(130, 255, 150);
    for (int y = 0; y < f->cv.h; y++) {
        for (int x = 0; x < f->cv.w; x++) {
            const ml_rgb p = ml_canvas_get(&f->cv, x, y);
            if (p.r == head.r && p.g == head.g && p.b == head.b) {
                *hx = x; *hy = y;
                return 1;
            }
        }
    }
    return 0;
}

/* ---- the pace at each score --------------------------------------------- */

/* One run of 40 updates from a fresh reset at a given score. */
static int fx_steps_at(int score, int *gap)
{
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return -1; }
    fx_park_food(&f);
    f.st.score = (uint16_t)score;
    int at[64];
    const int n = fx_moves(&f, 40, at);
    *gap = fx_gap(at, n);
    fx_close(&f);
    return n;
}

static void test_pace(void)
{
    printf("snake: the pace starts at one cell per four ticks\n");
    int gap = 0;
    check(fx_steps_at(0, &gap) == 10, "a fresh snake takes 10 steps in 40 ticks");
    check(gap == 4, "and the ticks between them are 4, not a burst");
}

/* The old pace never changed: this is the round that used to be indistinguishable
 * from the first one. */
static void test_pace_climbs(void)
{
    printf("snake: eating makes it quicker\n");
    int gap = 0;

    check(fx_steps_at(1, &gap) == 10 && gap == 4,
          "one food in, the pace has not moved (the ramp starts at four)");
    check(fx_steps_at(4, &gap) == 14, "four foods in, 14 steps in 40 ticks");
    check(gap == 3, "and the ticks between them are 3");
    check(fx_steps_at(8, &gap) == 20, "eight foods in, 20 steps in 40 ticks");
    check(gap == 2, "and the ticks between them are 2");
}

static void test_floor(void)
{
    printf("snake: the pace floors at two ticks a cell\n");
    int gap = 0;
    check(fx_steps_at(200, &gap) == 20 && gap == 2,
          "two hundred foods in, it is still every 2 ticks: a long snake stays playable");
}

/* ---- the food is what starts the ramp ----------------------------------- */

static void test_eating(void)
{
    printf("snake: eating in front of the head scores and grows it\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }

    /* Put the food in the head's own path: the snake starts centre-right, so the
     * cell it is about to move into is one to the right of the head. */
    const int hx = f.st.sx[f.st.head], hy = f.st.sy[f.st.head];
    f.st.food_x = (uint8_t)(hx + 1);
    f.st.food_y = (uint8_t)hy;

    fx_draw(&f);
    int dx = -1, dy = -1;
    check(fx_head_cell(&f, &dx, &dy) && dx == hx && dy == hy,
          "the head is where the state says it is");

    fx_step(&f, 1);
    check(f.st.score == 1, "the next step eats the food");
    check(f.st.len == 3, "and the growth it owes has not landed yet");

    fx_draw(&f);
    check(fx_head_cell(&f, &dx, &dy) && dx == hx + 1 && dy == hy,
          "the head is painted a cell further along");
    const ml_rgb tail = ml_canvas_get(&f.cv, hx - 2, hy);
    check(!(tail.r || tail.g || tail.b),
          "and the cell the tail left is no longer drawn");

    /* The pace is four ticks, so the step that lands the growth is the fourth
     * update after the eat, not the eat's own tick. */
    fx_step(&f, 3);
    check(f.st.len == 3, "the growth waits out the rest of the interval");
    fx_step(&f, 1);
    check(f.st.len == 4, "and lands on the next step, four ticks after the eat");

    /* And one food is not yet enough to move the pace. */
    fx_park_food(&f);
    int at[64];
    const int n = fx_moves(&f, 40, at);
    check(n == 10 && fx_gap(at, n) == 4, "one food in, the pace is still every 4");

    fx_close(&f);
}

int main(void)
{
    test_pace();
    test_pace_climbs();
    test_floor();
    test_eating();

    printf("\n%d checks, %d failures\n", g_checks, g_failures);
    if (g_failures) { printf("FAIL\n"); return 1; }
    printf("PASS\n");
    return 0;
}
