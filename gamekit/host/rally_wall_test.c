/*
 * rally_wall_test.c - regression test for the ball against the top and bottom
 * walls.
 *
 * The bug: a ball whose vertical speed is smaller than one pixel per tick gets
 * stuck on the top edge instead of bouncing off. The walls were done by
 * snapping the ball to the wall row and flipping its vertical speed, and the
 * test was "is the ball at or past this row?" with no idea which way it was
 * going. A ball sitting in the wall's own row therefore flipped every tick and
 * never left: at 32 (an eighth of a pixel per tick, see below) it is pinned to
 * row 0 for as long as the round lasts, and the player sees a ball frozen on
 * the ceiling while the rally goes nowhere.
 *
 * Where such a ball comes from: paddle_bounce() adds (rel * FX_ONE) / ph, so a
 * hit one row off the centre of a still paddle gives 32 - an eighth of a pixel
 * per tick, which crawls rather than moves. Any of those balls that reaches a
 * wall used to freeze there.
 *
 * Observable: the state is driven by the game's own init/reset/update/draw and
 * the ball is read off the drawn panel, where it is the only pure white pixel.
 * The fixture includes the rally translation unit so it can place the ball in
 * the state the bug needs, which a session over the FFI cannot do; the Makefile
 * links this test without game_rally.o for the same reason. Both sides are
 * marked present, so update() never reaches for the AI and needs no ctx.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "../examples/rally/game_rally.c"

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
    rally_state st;
    ml_game_cfg cfg;
    ml_view     view;
    ml_canvas   cv;
} fixture;

static bool fx_open(fixture *f)
{
    memset(f, 0, sizeof(*f));
    f->cfg.seed = 1;
    f->cfg.panel_w = RALLY_W;
    f->cfg.panel_h = RALLY_H;
    if (!ml_canvas_init(&f->cv, RALLY_W, RALLY_H, NULL)) return false;
    ml_view_compute(&f->view, ml_game_rally.pref_w, ml_game_rally.pref_h,
                    ml_game_rally.fit, RALLY_W, RALLY_H);
    ml_game_rally.init(&f->st, &f->cfg, NULL);
    ml_game_rally.reset(&f->st, NULL);
    /* Both sides present: the AI would need a ctx tick and is not under test. */
    f->st.present = 3u;
    return true;
}

static void fx_close(fixture *f)
{
    ml_canvas_free(&f->cv);
}

/* Is any part of the paddle where the ball wants to be? Not under test. */
static void fx_park_paddles(fixture *f)
{
    f->st.paddle_y[0] = 0;
    f->st.paddle_y[1] = 0;
    f->st.paddle_v[0] = 0;
    f->st.paddle_v[1] = 0;
}

static void fx_place(fixture *f, int x, int y, int32_t vx, int32_t vy)
{
    f->st.bx = (int32_t)x << FX;
    f->st.by = (int32_t)y << FX;
    f->st.bvx = vx;
    f->st.bvy = vy;
}

static void fx_step(fixture *f)
{
    ml_game_rally.update(&f->st, NULL);
}

/* The ball is the only pure white pixel on the panel. A ball that is off the
 * panel is reported as not drawn, which is how the test tells "left the field"
 * from "sitting on a wall". */
static int fx_ball(fixture *f, int *bx, int *by)
{
    ml_game_rally.draw(&f->st, &f->view, &f->cv, NULL);
    for (int y = 0; y < f->cv.h; y++) {
        for (int x = 0; x < f->cv.w; x++) {
            const ml_rgb p = ml_canvas_get(&f->cv, x, y);
            if (p.r == 220 && p.g == 220 && p.b == 220) {
                *bx = x;
                *by = y;
                return 1;
            }
        }
    }
    return 0;
}

/* ---- the wall contract -------------------------------------------------- */

/* A shallow upward ball on the ceiling must come off it, not sit there. */
static void test_ceiling(void)
{
    printf("rally: a shallow ball comes off the ceiling\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }
    fx_park_paddles(&f);

    /* Row 0, moving up at an eighth of a pixel per tick: what a hit one row
     * off the centre of a still paddle produces. */
    fx_place(&f, 32, 0, FX_ONE * 3 / 4, -32);

    int bx = -1, by = -1;
    check(fx_ball(&f, &bx, &by) && by == 0, "the ball starts on the ceiling");

    int rows[20];
    for (int t = 0; t < 20; t++) {
        fx_step(&f);
        check(fx_ball(&f, &bx, &by) && by >= 0, "the ball stays on the panel");
        rows[t] = by;
    }
    check(f.st.bvy > 0, "the bounce sends it downwards");
    check(rows[19] >= 2, "and it leaves the top rows behind it");

    int moved = 0;
    for (int t = 1; t < 20; t++) {
        if (rows[t] != rows[0]) moved = 1;
    }
    check(moved, "the ball is never frozen in a wall row");

    fx_close(&f);
}

/* The floor is the same wall, mirrored. */
static void test_floor(void)
{
    printf("rally: a shallow ball comes off the floor\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }
    fx_park_paddles(&f);
    fx_place(&f, 32, RALLY_H - 1, FX_ONE * 3 / 4, 32);

    int bx = -1, by = -1;
    fx_ball(&f, &bx, &by);
    check(by == RALLY_H - 1, "the ball starts on the floor");

    int rows[20];
    for (int t = 0; t < 20; t++) {
        fx_step(&f);
        check(fx_ball(&f, &bx, &by) && by < RALLY_H, "the ball stays on the panel");
        rows[t] = by;
    }
    check(f.st.bvy < 0, "the bounce sends it upwards");
    check(rows[19] <= RALLY_H - 3, "and it leaves the bottom rows behind it");

    int moved = 0;
    for (int t = 1; t < 20; t++) {
        if (rows[t] != rows[0]) moved = 1;
    }
    check(moved, "the ball is never frozen in a wall row");

    fx_close(&f);
}

/* A ball on the last row that is on its way up is leaving: it must not be
 * turned around by the row it is already in. */
static void test_leaving_the_floor(void)
{
    printf("rally: a ball leaving the last row is not sent back into it\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }
    fx_park_paddles(&f);
    fx_place(&f, 32, RALLY_H - 1, FX_ONE * 3 / 4, -32);

    int bx = -1, by = -1;
    fx_ball(&f, &bx, &by);
    check(by == RALLY_H - 1, "the ball starts on the last row");
    fx_step(&f);
    fx_ball(&f, &bx, &by);
    check(f.st.bvy < 0, "it is still on its way up");
    check(by < RALLY_H - 1, "and it has left the row behind");

    fx_close(&f);
}

/* A fast ball still bounces the old way: it must not pass through the wall. */
static void test_fast_ball(void)
{
    printf("rally: a fast ball is reflected, not let through\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }
    fx_park_paddles(&f);
    fx_place(&f, 32, 0, FX_ONE * 3 / 4, -2 * FX_ONE);

    int bx = -1, by = -1;
    for (int t = 0; t < 12; t++) {
        fx_step(&f);
        if (!fx_ball(&f, &bx, &by)) { check(0, "the ball stays on the panel"); return; }
    }
    check(by > 0, "it comes back into the field");
    check(f.st.bvy > 0, "and it is on its way down");
    fx_close(&f);
}

/* The state the report came from: a still paddle's one-row-off deflection is
 * shallow, and that shallow ball still leaves the wall it reaches. */
static void test_shallow_deflection(void)
{
    printf("rally: the shallow ball a still paddle makes still comes off the wall\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }

    /* Ball arriving at the right paddle one row below its centre, both paddles
     * still: the deflection is (1 * FX_ONE) / 8 = 32, an eighth of a pixel per
     * tick, and it is aimed at the floor. */
    const int paddle_centre = f.st.paddle_y[1] + f.st.paddle_h / 2;
    fx_place(&f, f.st.face[1] - 1, paddle_centre + 1, FX_ONE * 3 / 4, 0);

    for (int t = 0; t < 4 && f.st.bvx > 0; t++) fx_step(&f);
    check(f.st.bvx < 0, "the paddle sends the ball back");
    check(f.st.bvy == 32, "a still paddle's one-row offset is an eighth of a pixel");

    /* Now that ball against the wall it is heading for: it must come away. */
    f.st.bx = 32 << FX;
    f.st.by = (int32_t)(RALLY_H - 1) << FX;
    f.st.bvy = 32;
    f.st.bvx = FX_ONE * 3 / 4;

    int bx = -1, by = -1;
    int rows[20];
    for (int t = 0; t < 20; t++) {
        fx_step(&f);
        if (!fx_ball(&f, &bx, &by)) { check(0, "the ball stays on the panel"); return; }
        rows[t] = by;
    }
    check(rows[19] <= RALLY_H - 3, "the shallow ball climbs away from the floor");

    int moved = 0;
    for (int t = 1; t < 20; t++) {
        if (rows[t] != rows[0]) moved = 1;
    }
    check(moved, "and it is never frozen there");

    fx_close(&f);
}

int main(void)
{
    test_ceiling();
    test_floor();
    test_leaving_the_floor();
    test_fast_ball();
    test_shallow_deflection();

    printf("\n%d checks, %d failures\n", g_checks, g_failures);
    if (g_failures) { printf("FAIL\n"); return 1; }
    printf("PASS\n");
    return 0;
}
