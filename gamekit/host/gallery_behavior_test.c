/*
 * gallery_behavior_test.c - regression test for Target Gallery's uncertain edges.
 *
 * Four behaviours this pins, each one a place the game could quietly be wrong:
 *
 * - overlapping targets consume one slot, not the whole stack. A shot takes the
 *   lowest-index live target under the crosshair, so three targets stacked on one
 *   cell need three shots and pay three times; a shot that cleared everything it
 *   overlapped would turn a lucky spawn into a jackpot.
 * - the held trigger's cooldown. A press fires at once, then once every eight
 *   ticks for as long as Shoot is held, and letting go burns the cooldown so the
 *   next press fires at once again. A level event repeated every tick must not
 *   re-arm the cooldown, or holding Shoot would fire every tick.
 * - the streak. A hit pays 10 per point of the streak, capped at five; a miss
 *   zeroes the streak; a target that simply times out must not.
 * - the final tick. The round's last tick resolves its shot before the clock ends
 *   the game, so a press on tick 2400 scores and then the board reads OVER.
 *
 * Observable: the state the game's own update left, and the drawn frame. The
 * fixture includes the gallery translation unit - which reaches the runtime only
 * through ml_ctx_rng - and provides that one service itself, the same xorshift the
 * runtime uses, so a test can drive the game tick by tick and still place the
 * targets it wants. The Makefile links this fixture with neither the runtime
 * (whose ml_ctx_rng this file replaces) nor the game's own object.
 *
 * Every case starts from a reset with the board cleared and the spawn clock
 * parked, so a spawn or a leftover target never colours the result.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "../examples/gallery/game_gallery.c"

/* The game reaches the runtime's PRNG through ctx. The fixture owns it instead of
 * opening a session, so a test can drive the game tick by tick: same xorshift the
 * runtime uses, so the rolls are as deterministic as the game expects. A ctx
 * service the game calls without a stub here is a link error, which is the point. */
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

typedef struct {
    gallery_state st;
    ml_game_cfg   cfg;
    ml_view       view;
    ml_canvas     cv;
} fixture;

static bool fx_open(fixture *f)
{
    memset(f, 0, sizeof(*f));
    f->cfg.seed = 1;
    f->cfg.panel_w = PANEL_W;
    f->cfg.panel_h = PANEL_H;
    if (!ml_canvas_init(&f->cv, PANEL_W, PANEL_H, NULL)) return false;
    ml_view_compute(&f->view, ml_game_gallery.pref_w, ml_game_gallery.pref_h,
                    ml_game_gallery.fit, f->cfg.panel_w, f->cfg.panel_h);
    fx_rng_state = 1u;
    ml_game_gallery.init(&f->st, &f->cfg, NULL);
    ml_game_gallery.reset(&f->st, NULL);
    return true;
}

static void fx_close(fixture *f)
{
    ml_canvas_free(&f->cv);
}

static void fx_step(fixture *f, int ticks)
{
    for (int t = 0; t < ticks; t++) ml_game_gallery.update(&f->st, NULL);
}

static void fx_draw(fixture *f)
{
    ml_game_gallery.draw(&f->st, &f->view, &f->cv, NULL);
}

static ml_rgb fx_px(const fixture *f, int x, int y)
{
    return ml_canvas_get(&f->cv, x, y);
}

static int fx_same(ml_rgb a, ml_rgb b)
{
    return a.r == b.r && a.g == b.g && a.b == b.b;
}

/* One control event, at the level a pad, a key or the firmware sends it. */
static void fx_btn(fixture *f, uint16_t code, int value)
{
    ml_input_event e;
    memset(&e, 0, sizeof(e));
    e.player_id = 1;
    e.code = code;
    e.type = ML_INPUT_BUTTON;
    e.value = (int16_t)(value ? 1 : 0);
    ml_game_gallery.input(&f->st, &e, NULL);
}

/* A button press, which is what a fresh press is: the game fires on the press. */
static void fx_press(fixture *f, uint16_t code)   { fx_btn(f, code, 1); }
static void fx_release(fixture *f, uint16_t code) { fx_btn(f, code, 0); }

/* The board the case wants: empty, the spawn clock parked past the case's length,
 * the crosshair at its neutral centre, and no held controls. */
static void fx_arm(fixture *f)
{
    gallery_state *s = &f->st;
    for (int i = 0; i < TARGETS; i++) s->targets[i].on = 0;
    s->spawn_ctr = 200;             /* the case runs far short of the next spawn */
    s->held_up = s->held_down = s->held_left = s->held_right = s->held_shoot = 0;
    s->shoot_cd = 0;
    s->flash = 0;
    s->streak = 0;
    s->score = 0;
    s->status = GALLERY_PLAYING;
    s->ticks_left = ROUND_TICKS;
    s->tilt_x = s->tilt_y = ML_AXIS_IDLE;
    s->cx = 31;
    s->cy = 20;
}

/* Park a live target in one slot, exactly where the case wants it. dir 0 keeps
 * it still, so the only thing that can remove it is a shot or its lifetime. */
static void fx_place(fixture *f, int slot, int x, int y, int dir, int age)
{
    gallery_target *t = &f->st.targets[slot];
    t->x = (int8_t)x;
    t->y = (int8_t)y;
    t->dir = (int8_t)dir;
    t->age = (uint8_t)age;
    t->on = 1;
}

/* ---- overlapping targets consume one slot ------------------------------- */

static void test_overlap_one_slot(void)
{
    printf("gallery: a shot takes one of a stack\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }
    fx_arm(&f);

    /* Two targets sharing every pixel, both under the crosshair. */
    fx_place(&f, 0, 30, 19, 0, 0);
    fx_place(&f, 1, 30, 19, 0, 0);
    fx_press(&f, GALLERY_SHOOT);
    fx_step(&f, 1);

    check(!f.st.targets[0].on, "the shot consumes the lowest-index target");
    check(f.st.targets[1].on, "and leaves the other overlapping target standing");
    check(f.st.score == 10, "for the streak's first ten points");

    /* The second shot of the pair needs its own trigger, and takes the survivor. */
    fx_release(&f, GALLERY_SHOOT);
    fx_press(&f, GALLERY_SHOOT);
    fx_step(&f, 1);
    check(!f.st.targets[1].on, "a second shot takes the survivor");
    check(f.st.score == 30, "and pays the second streak step");

    fx_close(&f);
}

/* ---- the held trigger's cadence ----------------------------------------- */

static void test_held_shoot_cooldown(void)
{
    printf("gallery: holding Shoot fires once every eight ticks\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }
    fx_arm(&f);

    fx_place(&f, 0, 30, 19, 0, 0);
    fx_press(&f, GALLERY_SHOOT);
    fx_step(&f, 1);
    check(!f.st.targets[0].on && f.st.score == 10, "the press fires at once");
    check(f.st.flash == 2, "and flashes the crosshair");

    /* Put the target back: the next shot, if it comes early, will hit it and the
     * score will show it. Seven ticks is one short of the cooldown. */
    fx_place(&f, 0, 30, 19, 0, 0);
    fx_step(&f, 7);
    check(f.st.targets[0].on, "the held trigger waits out the cooldown");
    check(f.st.score == 10, "so the seventh tick scores nothing");

    fx_step(&f, 1);
    check(!f.st.targets[0].on, "the eighth tick after the shot fires again");
    check(f.st.score == 30, "and pays the extended streak");

    fx_close(&f);
}

/* ---- the streak --------------------------------------------------------- */

static void test_streak_scoring(void)
{
    printf("gallery: the streak pays up to five, and a miss resets it\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }
    fx_arm(&f);

    /* Six consecutive hits: 10+20+30+40+50, then a sixth capped at 50. */
    static const int EXPECT[6] = { 10, 30, 60, 100, 150, 200 };
    for (int i = 0; i < 6; i++) {
        fx_place(&f, 0, 30, 19, 0, 0);
        fx_release(&f, GALLERY_SHOOT);   /* a fresh press fires at once */
        fx_press(&f, GALLERY_SHOOT);
        fx_step(&f, 1);
        char what[64];
        snprintf(what, sizeof(what), "hit %d scores the streak's total", i + 1);
        check(f.st.score == EXPECT[i], what);
    }
    check(f.st.streak == 6, "six hits make a six-long streak");

    /* A shot into empty space drops the streak without scoring. */
    fx_release(&f, GALLERY_SHOOT);
    fx_press(&f, GALLERY_SHOOT);
    fx_step(&f, 1);
    check(f.st.streak == 0, "a miss zeroes the streak");
    check(f.st.score == 200, "and scores nothing");

    /* The next hit starts the streak over. */
    fx_place(&f, 0, 30, 19, 0, 0);
    fx_release(&f, GALLERY_SHOOT);
    fx_press(&f, GALLERY_SHOOT);
    fx_step(&f, 1);
    check(f.st.score == 210, "the run after a miss starts again at ten");

    fx_close(&f);
}

/* ---- a target that times out is not a miss ------------------------------ */

static void test_expiry_keeps_streak(void)
{
    printf("gallery: an expiring target does not reset the streak\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }
    fx_arm(&f);

    fx_place(&f, 0, 30, 19, 0, 0);
    fx_press(&f, GALLERY_SHOOT);
    fx_step(&f, 1);
    check(f.st.score == 10 && f.st.streak == 1, "a first hit starts the streak");

    /* A target one tick short of its life, parked away from the crosshair. */
    fx_place(&f, 1, 0, 12, 0, TARGET_LIFE - 1);
    fx_release(&f, GALLERY_SHOOT);
    fx_step(&f, 1);
    check(!f.st.targets[1].on, "a target retires at its lifetime");
    check(f.st.streak == 1, "and its expiry leaves the streak alone");

    fx_place(&f, 0, 30, 19, 0, 0);
    fx_press(&f, GALLERY_SHOOT);
    fx_step(&f, 1);
    check(f.st.score == 30, "so the next hit still pays the second streak step");

    fx_close(&f);
}

/* ---- the final tick ----------------------------------------------------- */

static void test_final_tick_shot(void)
{
    printf("gallery: the last tick's shot resolves before OVER\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }
    fx_arm(&f);

    fx_place(&f, 0, 30, 19, 0, 0);
    f.st.ticks_left = 1;             /* this next update is the round's last */
    fx_press(&f, GALLERY_SHOOT);
    fx_step(&f, 1);

    check(!f.st.targets[0].on && f.st.score == 10,
          "the final tick still resolves its shot");
    check(ml_game_gallery.is_over(&f.st), "and then the round is over");

    /* Nothing after the clock runs: another press cannot score on a dead round. */
    fx_release(&f, GALLERY_SHOOT);
    fx_place(&f, 0, 30, 19, 0, 0);
    fx_press(&f, GALLERY_SHOOT);
    fx_step(&f, 1);
    check(f.st.score == 10, "the terminal round takes no more shots");

    fx_close(&f);
}

/* ---- what the frame shows ----------------------------------------------- */

static void test_rendered_frame(void)
{
    printf("gallery: the crosshair, the targets and the terminal board\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }
    fx_arm(&f);

    const ml_rgb cyan  = ML_RGB(0, 255, 255);
    const ml_rgb gold  = ML_RGB(255, 200, 0);
    const ml_rgb blank = ML_RGB(0, 0, 0);

    fx_place(&f, 0, 30, 19, 0, 0);
    f.st.cx = 31; f.st.cy = 20;
    fx_draw(&f);
    check(fx_same(fx_px(&f, 31, 20), cyan), "the crosshair centre is cyan");
    check(fx_same(fx_px(&f, 31, 19), cyan) && fx_same(fx_px(&f, 30, 20), cyan),
          "and its arms are too");
    check(fx_same(fx_px(&f, 30, 19), gold) && fx_same(fx_px(&f, 32, 21), gold),
          "a live target is gold");
    check(fx_same(fx_px(&f, 0, 31), ML_RGB(255, 255, 255)),
          "the time bar starts full on the last row");

    /* A shot turns the crosshair white for its two ticks and clears the target. */
    fx_press(&f, GALLERY_SHOOT);
    fx_step(&f, 1);
    fx_draw(&f);
    check(fx_same(fx_px(&f, 31, 20), ML_RGB(255, 255, 255)),
          "a shot flashes the crosshair white");
    check(fx_same(fx_px(&f, 30, 19), blank), "and the struck target is gone");

    fx_step(&f, 2);
    fx_draw(&f);
    check(fx_same(fx_px(&f, 31, 20), cyan), "the flash clears after two ticks");

    /* The terminal board is cleared: no crosshair, no target, no time bar. */
    f.st.status = GALLERY_OVER;
    f.st.cx = 5; f.st.cy = 29;
    fx_place(&f, 0, 60, 24, 0, 0);
    fx_draw(&f);
    check(fx_same(fx_px(&f, 5, 29), blank), "the terminal board drops the crosshair");
    check(fx_same(fx_px(&f, 60, 24), blank), "and the targets");
    check(fx_same(fx_px(&f, 0, 31), blank), "and the time bar");

    fx_close(&f);
}

int main(void)
{
    test_overlap_one_slot();
    test_held_shoot_cooldown();
    test_streak_scoring();
    test_expiry_keeps_streak();
    test_final_tick_shot();
    test_rendered_frame();

    printf("\n%d checks, %d failures\n", g_checks, g_failures);
    if (g_failures) { printf("FAIL\n"); return 1; }
    printf("PASS\n");
    return 0;
}
