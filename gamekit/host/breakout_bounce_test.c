/*
 * breakout_bounce_test.c - regression test for the ball's angle off the paddle.
 *
 * The bug: the paddle's aim did not reach the ball. breakout_update added the
 * hit offset to the incoming bvx and then clamped both axes to one cell per
 * tick, and both wall bounces *set* bvx/bvy to exactly one cell per tick. After
 * any edge hit or any side-wall bounce |bvx| == |bvy|, so the ball travelled at
 * exactly 45 degrees most of the time and a hit one pixel from the paddle's end
 * looked like a hit in its middle.
 *
 * Observable: the ball's outgoing direction and the drawn panel. The fixture
 * includes the breakout translation unit so it can park the ball on the
 * paddle's own row and read the state the bounce left, which a session over the
 * FFI cannot do; the Makefile links this test without game_breakout.o for the
 * same reason. The game's lifecycle never reads ctx, so the fixture drives it
 * with NULL.
 *
 * Cases:
 *   - the hit column picks the direction: the paddle's left end sends the ball
 *     left, its right end right, and the two are exact mirrors;
 *   - the ends are not 45-degree exits (what the old code made of every hit),
 *     and a hit beside the centre is a much shallower one than either end;
 *   - every direction is about one pixel per tick and no axis is over one cell,
 *     the bound the single brick check per tick relies on;
 *   - no direction leaves with zero horizontal speed, which would trap the ball
 *     between two bricks;
 *   - the walls mirror one axis and leave the other alone, so the angle the ball
 *     arrived with is the angle it leaves with;
 *   - a brick still clears, scores and flips only its dominant axis.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../examples/breakout/game_breakout.c"

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
    breakout_state st;
    ml_game_cfg    cfg;
    ml_view        view;
    ml_canvas      cv;
} fixture;

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

static void fx_place(fixture *f, int x, int y, int32_t vx, int32_t vy)
{
    f->st.bx = (int32_t)x << FX;
    f->st.by = (int32_t)y << FX;
    f->st.bvx = vx;
    f->st.bvy = vy;
}

/* Take the wall out of the way. These cases are about the panel's edges; a
 * cleared wall is never refilled and no brick is left to clear. */
static void fx_no_bricks(fixture *f)
{
    memset(f->st.bricks, 0, sizeof(f->st.bricks));
}

/* Bounce the ball off the paddle's column `col`: the paddle is parked at a
 * known px, and the ball is put one row above its top row heading straight
 * down at one cell per tick, so a single tick lands it in the paddle's own
 * band and the paddle's answer is what is left in the state. */
static void fx_hit_paddle(fixture *f, int col, int px, int paddle_w)
{
    f->st.px = (int16_t)px;
    f->st.paddle_w = (int16_t)paddle_w;
    fx_place(f, col, f->st.panel_h - 4, 0, FX_ONE);
    fx_step(f, 1);
}

/* ---- the table's mapping ------------------------------------------------ */

/* The hit column's zone, over the whole span of the paddle a level is played
 * with. Mid-paddle columns may share a zone (a 10 px paddle has two for each of
 * two zones) but the ends are always the table's ends, and the sequence never
 * goes backwards: a column further right never sends the ball less rightwards. */
static void test_zone_mapping(void)
{
    printf("breakout: the hit column picks the zone\n");
    fixture f;
    if (!fx_open(&f, 64, 32)) { check(0, "fixture opens"); return; }

    /* 256 / 10, the shipped panel's first level. */
    static const int want6[6] = { 0, 1, 3, 4, 6, 7 };
    f.st.paddle_w = 6;
    f.st.px = 20;
    int ok6 = 1, rising = 1, last = -1;
    for (int i = 0; i < 6; i++) {
        const int z = bounce_zone(&f.st, 20 + i);
        if (z != want6[i]) ok6 = 0;
        if (z < last) rising = 0;
        last = z;
    }
    check(ok6, "a 6 px paddle maps its columns to zones 0,1,3,4,6,7");
    check(rising, "and never maps a righter column further left");

    /* 3 px: the narrowest paddle any level ships. The two extremes still land
     * on the table's ends, so even the hardest paddle can aim. */
    static const int want3[3] = { 0, 4, 7 };
    f.st.paddle_w = 3;
    int ok3 = 1;
    for (int i = 0; i < 3; i++)
        if (bounce_zone(&f.st, 20 + i) != want3[i]) ok3 = 0;
    check(ok3, "a 3 px paddle maps its columns to zones 0,4,7");

    /* Every zone the table holds is reachable by some column of the widest
     * paddle, so no direction is dead weight. */
    f.st.paddle_w = 10;
    int seen[BOUNCE_DIRS] = { 0 };
    for (int i = 0; i < 10; i++) {
        const int z = bounce_zone(&f.st, 20 + i);
        if (z >= 0 && z < BOUNCE_DIRS) seen[z] = 1;
    }
    int all = 1;
    for (int z = 0; z < BOUNCE_DIRS; z++) if (!seen[z]) all = 0;
    check(all, "a 10 px paddle can reach every direction in the table");

    fx_close(&f);
}

/* ---- the ends mirror, and are not 45 degrees ---------------------------- */

static void test_ends_mirror(void)
{
    printf("breakout: the paddle's ends send the ball left and right\n");
    fixture f;
    if (!fx_open(&f, 64, 32)) { check(0, "fixture opens"); return; }
    check(f.st.paddle_w == 6, "the first level's paddle is 6 px wide");

    fx_hit_paddle(&f, 20, 20, 6);          /* the paddle's left end */
    const int32_t lvx = f.st.bvx, lvy = f.st.bvy;
    fx_hit_paddle(&f, 25, 20, 6);          /* its right end */
    const int32_t rvx = f.st.bvx, rvy = f.st.bvy;

    check(lvx < 0, "the left end sends the ball left");
    check(rvx > 0, "the right end sends it right");
    check(lvy < 0 && rvy < 0, "both ends send it up the panel");
    check(lvx == -rvx && lvy == rvy, "and the two are exact mirrors");

    /* The old code clamped both axes to one cell per tick, so every hit left
     * at 45 degrees: |vx| == |vy|. The ends are the table's steepest sideways
     * directions, and no column of the paddle exits at 45 degrees. */
    check(abs((int)lvx) != abs((int)lvy), "the left end is not a 45-degree exit");
    check(abs((int)rvx) != abs((int)rvy), "nor is the right end");
    check(abs((int)lvx) > abs((int)lvy), "an end hit leaves mostly sideways");

    /* One column in from the middle: a hit beside the centre is a much more
     * vertical ball than either end, which is the aim the player feels. */
    fx_hit_paddle(&f, 22, 20, 6);
    check(abs((int)f.st.bvx) < abs((int)f.st.bvy),
          "a hit beside the centre leaves mostly downwards");
    check(abs((int)f.st.bvx) < abs((int)lvx),
          "and less sideways than the paddle's end");

    fx_close(&f);
}

/* ---- speed, and the bound the brick test needs --------------------------- */

static void test_speed(void)
{
    printf("breakout: every direction is one cell per tick at most\n");
    fixture f;
    if (!fx_open(&f, 64, 32)) { check(0, "fixture opens"); return; }
    fx_no_bricks(&f);

    /* A 10 px paddle walks the whole table, so every direction is checked. */
    int bounded = 1, steady = 1, sideways = 1;
    for (int col = 20; col < 30; col++) {
        fx_hit_paddle(&f, col, 20, 10);
        const int vx = (int)f.st.bvx, vy = (int)f.st.bvy;
        if (vx > FX_ONE || vx < -FX_ONE || vy > FX_ONE || vy < -FX_ONE) bounded = 0;
        const int mag2 = vx * vx + vy * vy;
        if (mag2 > FX_ONE * FX_ONE + 512 || mag2 < FX_ONE * FX_ONE - 512) steady = 0;
        if (vx == 0) sideways = 0;
    }
    check(bounded, "no axis is over one cell per tick");
    check(steady, "and the speed stays at one cell per tick");
    check(sideways, "and no direction leaves with zero horizontal speed");

    fx_close(&f);
}

/* ---- the walls keep the angle ------------------------------------------- */

static void test_walls(void)
{
    printf("breakout: a wall mirrors one axis and keeps the angle\n");
    fixture f;
    if (!fx_open(&f, 64, 32)) { check(0, "fixture opens"); return; }
    fx_no_bricks(&f);

    /* Arriving at the left wall at the table's steepest angle: the old wall
     * code set bvx to exactly one cell per tick (the 45-degree bug on the
     * other axis) and snapped the ball onto the wall's own column. */
    fx_place(&f, 0, 16, -BOUNCE_VX[7], -FX_ONE);
    fx_step(&f, 1);
    check(f.st.bvx == BOUNCE_VX[7], "the left wall mirrors the horizontal speed");
    check(f.st.bvy == -FX_ONE, "and leaves the vertical speed alone");

    /* The ceiling is the same wall on the other axis, at the shallowest
     * direction the table has. */
    fx_place(&f, 32, 0, BOUNCE_VX[4], BOUNCE_VY[4]);
    fx_step(&f, 1);
    check(f.st.bvy == -BOUNCE_VY[4], "the ceiling mirrors the vertical speed");
    check(f.st.bvx == BOUNCE_VX[4], "and leaves the horizontal speed alone");

    fx_close(&f);
}

/* ---- a brick is untouched by any of this -------------------------------- */

static void test_brick(void)
{
    printf("breakout: a brick still clears, scores and flips one axis\n");
    fixture f;
    if (!fx_open(&f, 64, 32)) { check(0, "fixture opens"); return; }

    /* A 15-degree ball moving down and right, one tick from the middle of a
     * live brick: it enters that cell, so the single check per tick must see
     * it. Placed clear of the HUD, which covers the wall's left end. */
    fx_draw(&f);
    check(fx_same(fx_px(&f, 40, 1), breakout_row_color(1)),
          "the brick is there before the hit");

    fx_place(&f, 40, 1, BOUNCE_VX[4], -BOUNCE_VY[4]);
    fx_step(&f, 1);
    check(f.st.score == 10, "the brick scored");
    check(f.st.bvx == BOUNCE_VX[4] && f.st.bvy == BOUNCE_VY[4],
          "the dominant axis flipped and the other is unchanged");

    /* The ball is left sitting in the cell it cleared, so the cell reads as the
     * ball; the brick beside it is the control that the wall still stands. */
    fx_draw(&f);
    check(!fx_same(fx_px(&f, 40, 1), breakout_row_color(1)),
          "and the brick the ball was in is no longer drawn");
    check(fx_same(fx_px(&f, 41, 1), breakout_row_color(1)),
          "while the brick beside it still is");

    fx_close(&f);
}

/* The wall above is a level-1 wall: the case reads a real brick, so it fails
 * with the rest if the level patterns ever stop filling row 1. */
int main(void)
{
    test_zone_mapping();
    test_ends_mirror();
    test_speed();
    test_walls();
    test_brick();

    printf("\n%d checks, %d failures\n", g_checks, g_failures);
    if (g_failures) { printf("FAIL\n"); return 1; }
    printf("PASS\n");
    return 0;
}
