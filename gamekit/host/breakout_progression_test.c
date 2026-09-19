/*
 * breakout_progression_test.c - regression test for the brick wall's bounds.
 *
 * Two bugs this pins down:
 *
 *  1. Clearing the wall never advanced a level on a 64-wide panel.
 *     refill_bricks set all 128 storage bits of every active row, while only
 *     the panel's columns are drawn, so bricks_left() stayed true after the
 *     visible wall was gone and the level-clear branch was unreachable.
 *
 *  2. brick_at/brick_clear bounded x by the panel width instead of the 128-bit
 *     storage bound. On a panel wider than the storage a ball in the empty
 *     right-hand arena indexed a mask word belonging to another row, "hit" a
 *     brick that was not there, bounced off it and cleared a brick out of the
 *     left-hand wall.
 *
 * Observable: real init/reset/update/draw on the game's own state, then the
 * drawn canvas. A live brick is the colour breakout_row_color picked for its
 * row and black means no brick, so every assertion reads pixels, not masks.
 * The fixture includes the breakout translation unit so it can drive the
 * game's own static lifecycle and state without adding a production test API;
 * the Makefile links this test without game_breakout.o for the same reason.
 *
 * Script 1 (64 and 65 columns, 32 rows): reset leaves a full wall, every brick
 * the panel draws is cleared except (10,1), and the ball is placed at (10,2)
 * heading up one cell per tick. One tick clears that last visible brick, which
 * must run the level increment, the +100 bonus, the refill and the serve, so
 * row 0 is red again edge to edge. Before the fix the wall was never refilled
 * and the far edge stayed black.
 *
 * Script 2 (256 columns, 32 rows): the wall keeps its 128 live columns and the
 * ball is placed at (200,2) in the empty arena beyond them, heading up. The
 * wall band must remain pixel-identical to a fresh reset wall after one
 * update, while the ball passes upward through the empty right-hand space.
 * Before the fix this indexed the following row's masks and cleared (72,2).
 *
 * It also pins what a cleared wall comes back as: not the same solid wall but
 * the next level's own pattern (levels cycle solid, brickwork, pyramid,
 * checkerboard) and with the next level's paddle, one pixel narrower. The
 * level-2 frame is compared against one drawn from a fixture the test moved to
 * level 2 itself, so a refill that ignored the level would fail on the walls
 * alone.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "../examples/breakout/game_breakout.c"

#define PANEL_H 32

/* ---- fixture ------------------------------------------------------------ */

typedef struct {
    breakout_state st;
    ml_game_cfg    cfg;
    ml_view        view;
    ml_canvas      cv;
} fixture;

/* The game's lifecycle never reads ctx (no tick, no PRNG), so the fixture
 * drives it with NULL and keeps ml_game_ctx out of the harness. */
static bool fx_open(fixture *f, int w, int h)
{
    memset(f, 0, sizeof(*f));
    f->cfg.seed = 1;
    f->cfg.panel_w = w;
    f->cfg.panel_h = h;
    if (!ml_canvas_init(&f->cv, w, h, NULL)) return false;
    ml_view_compute(&f->view, ml_game_breakout.pref_w, ml_game_breakout.pref_h,
                    ml_game_breakout.fit, w, h);
    ml_game_breakout.init(&f->st, &f->cfg, NULL);
    ml_game_breakout.reset(&f->st, NULL);
    return true;
}

static void fx_close(fixture *f)
{
    ml_canvas_free(&f->cv);
}

/* Draw the current state exactly as the runtime does, then read pixels. */
static void fx_draw(fixture *f)
{
    ml_game_breakout.draw(&f->st, &f->view, &f->cv, NULL);
}

static ml_rgb fx_px(const fixture *f, int x, int y)
{
    return ml_canvas_get(&f->cv, x, y);
}

static int fx_same(ml_rgb a, ml_rgb b)
{
    return a.r == b.r && a.g == b.g && a.b == b.b;
}

static void fx_step(fixture *f, int ticks)
{
    for (int t = 0; t < ticks; t++) ml_game_breakout.update(&f->st, NULL);
}

/* Clear every brick the panel draws except one, through the game's own
 * accessor. Hidden storage bits are deliberately left alone: a level clear has
 * to depend on what the player can see. */
static void fx_clear_visible_except(fixture *f, int keep_x, int keep_y)
{
    for (int y = 0; y < f->st.brick_rows; y++)
        for (int x = 0; x < f->cfg.panel_w; x++)
            if (x != keep_x || y != keep_y) brick_clear(&f->st, x, y);
}

static void fx_place_ball(fixture *f, int x, int y, int32_t vx, int32_t vy)
{
    f->st.bx = (int32_t)x << FX;
    f->st.by = (int32_t)y << FX;
    f->st.bvx = vx;
    f->st.bvy = vy;
}


/* The ball is the only pure white pixel on the panel. */
static int fx_ball(const fixture *f, int *bx, int *by)
{
    for (int y = 0; y < f->cv.h; y++)
        for (int x = 0; x < f->cv.w; x++)
            if (fx_same(ml_canvas_get(&f->cv, x, y), ML_RGB(255, 255, 255))) {
                *bx = x;
                *by = y;
                return 1;
            }
    return 0;
}

/* Compare the drawn brick band - the rows the wall occupies, score text
 * included - against another frame. Both frames must be drawn. */
static int fx_band_same(const fixture *f, const fixture *ref)
{
    for (int y = 0; y < f->st.brick_rows; y++)
        for (int x = 0; x < BRICK_COLS_MAX; x++)
            if (!fx_same(ml_canvas_get(&f->cv, x, y),
                         ml_canvas_get(&ref->cv, x, y)))
                return 0;
    return 1;
}

/* ---- scripts ------------------------------------------------------------ */

/* Clearing the last visible brick must reach the level-cleared path on any
 * panel up to the storage bound, and the wall that comes back must be the next
 * level's own pattern, drawn by a fixture that took the same level, score and
 * intro (the band includes the HUD rows, so the two frames may differ only in
 * the wall). */
static int case_progression(int w)
{
    fixture f;
    if (!fx_open(&f, w, PANEL_H)) {
        fprintf(stderr, "canvas init failed at width %d\n", w);
        return 0;
    }

    /* Everything the panel draws but one brick, then send the ball into it:
     * one tick moves it from (10,2) to (10,1) and clears the wall. */
    fx_clear_visible_except(&f, 10, 1);
    fx_place_ball(&f, 10, 2, 0, -FX_ONE);
    fx_step(&f, 1);
    fx_draw(&f);

    int scored = f.st.level == 2 && f.st.score == 110;
    int served = f.st.bx == ((w / 2) << FX);
    int paddle = f.st.paddle_w == level_paddle_w(w, 2);

    /* The level-2 wall as the game itself builds it, drawn from a fresh
     * fixture moved to the same level. */
    fixture ref;
    int wall = 0;
    if (fx_open(&ref, w, PANEL_H)) {
        ref.st.level = f.st.level;
        ref.st.score = f.st.score;
        ref.st.intro = f.st.intro;
        ref.st.paddle_w = f.st.paddle_w;
        refill_bricks(&ref.st);
        fx_draw(&ref);
        wall = fx_band_same(&f, &ref);
        fx_close(&ref);
    }
    int ok = scored && served && paddle && wall;

    printf("width %3d: level=%u score=%u served=%d paddle_w=%d wall=%d: %s\n",
           w, (unsigned)f.st.level, (unsigned)f.st.score, served,
           (int)f.st.paddle_w, wall, ok ? "ok" : "FAIL");

    fx_close(&f);
    return ok;
}

/* A panel wider than the brick storage keeps its wall left-aligned, and the
 * space beyond it stays empty for the ball to play in. */
static int case_wide_panel(void)
{
    const int w = 256;
    fixture f, ref;
    if (!fx_open(&f, w, PANEL_H)) {
        fprintf(stderr, "canvas init failed at width %d\n", w);
        return 0;
    }
    if (!fx_open(&ref, w, PANEL_H)) {
        fprintf(stderr, "canvas init failed at width %d\n", w);
        fx_close(&f);
        return 0;
    }

    /* One update must pass through empty arena, not alias a later mask row. */
    fx_place_ball(&f, 200, 2, 0, -FX_ONE);
    fx_step(&f, 1);
    fx_draw(&f);

    /* The untouched wall as drawn, with the ball parked clear of its rows.
     * Same blink phase as the frame under test: the HUD occupies the wall
     * band's top rows while a level's intro is running. */
    ref.st.intro = f.st.intro;
    fx_place_ball(&ref, 200, 20, 0, 0);
    fx_draw(&ref);

    int bx = -1, by = -1;
    int ball = fx_ball(&f, &bx, &by);
    int wall = fx_band_same(&f, &ref)
            && fx_same(fx_px(&f, 72, 2), breakout_row_color(2));
    int passed = ball && bx == 200 && by == 1;
    int ok = wall && passed;

    printf("width %3d: wall=%d ball=(%d,%d) passed=%d: %s\n",
           w, wall, bx, by, passed, ok ? "ok" : "FAIL");

    fx_close(&ref);
    fx_close(&f);
    return ok;
}

int main(void)
{
    int ok = 1;
    if (!case_progression(64)) ok = 0;
    if (!case_progression(65)) ok = 0;
    if (!case_wide_panel()) ok = 0;

    if (!ok) {
        printf("FAIL\n");
        return 1;
    }
    printf("PASS\n");
    return 0;
}
