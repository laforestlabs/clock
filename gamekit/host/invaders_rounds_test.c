/*
 * invaders_rounds_test.c - regression test for the aliens' rounds.
 *
 * What it pins down: every round of the game used to be the same 8x4 wall of
 * identical crabs, with only the march interval two ticks shorter than the
 * round before, so "a new round" looked and played like the last one. Now the
 * round's plan decides which of the four kinds sits on each row, what a kill is
 * worth, whether a shot takes one hit or two, what the bullet does, how often
 * and how many of them fire at once, and how many may be in the air.
 *
 * Observable: the state the game's own update left, and the drawn panel. The
 * fixture includes the invaders translation unit — which reaches the runtime
 * only through ml_ctx_rng — and provides that one service itself, the same
 * xorshift the runtime uses, so a test can drive the game tick by tick and
 * still choose the wall it starts from. The Makefile links this fixture with
 * neither the runtime (whose ml_ctx_rng this file replaces) nor the game's own
 * object (which it includes).
 *
 * The wall's left end sits under the HUD line, which is drawn after it, so the
 * cases that read individual sprite pixels park the blink at a hidden phase
 * (intro 39 of its 40) first. That is what a player sees on half of the intro's
 * ticks anyway; the blink itself is not what these cases are about.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "../examples/invaders/game_invaders.c"

/* The game reaches the runtime's PRNG through ctx. The fixture owns it instead of
 * opening a session, so a test can drive the game tick by tick and still choose
 * the wall it starts from: same xorshift the runtime uses, so the rolls are as
 * deterministic as the game expects. Every other ctx service the game calls needs
 * the same treatment; a missing one is a link error, which is the point. */
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
    invaders_state st;
    ml_game_cfg    cfg;
    ml_view        view;
    ml_canvas      cv;
} fixture;

static bool fx_open(fixture *f)
{
    memset(f, 0, sizeof(*f));
    f->cfg.seed = 1;
    f->cfg.panel_w = 64;
    f->cfg.panel_h = 32;
    if (!ml_canvas_init(&f->cv, f->cfg.panel_w, f->cfg.panel_h, NULL)) return false;
    ml_view_compute(&f->view, ml_game_invaders.pref_w, ml_game_invaders.pref_h,
                    ml_game_invaders.fit, f->cfg.panel_w, f->cfg.panel_h);
    fx_rng_state = 1u;
    ml_game_invaders.init(&f->st, &f->cfg, NULL);
    ml_game_invaders.reset(&f->st, NULL);
    return true;
}

static void fx_close(fixture *f)
{
    ml_canvas_free(&f->cv);
}

static void fx_step(fixture *f, int ticks)
{
    for (int t = 0; t < ticks; t++) ml_game_invaders.update(&f->st, NULL);
}

/* Draw with the HUD blink at a phase where the line is not drawn, so the wall's
 * left sprites are readable as the wall drew them. */
static void fx_draw_quiet(fixture *f)
{
    f->st.intro = 39;
    ml_game_invaders.draw(&f->st, &f->view, &f->cv, NULL);
}

static ml_rgb fx_px(const fixture *f, int x, int y)
{
    return ml_canvas_get(&f->cv, x, y);
}

static int fx_same(ml_rgb a, ml_rgb b)
{
    return a.r == b.r && a.g == b.g && a.b == b.b;
}

/* The centre pixel of the sprite at (row, col) on the current origin: every
 * shape lights it, so it reads as the row's kind colour when the alien is there
 * and black when it is not. */
static ml_rgb fx_sprite_centre(const fixture *f, int row, int col)
{
    return fx_px(f, f->st.ax + col * INV_GAP_X + 1, f->st.ay + row * INV_GAP_Y + 1);
}

static int fx_shots_in_air(const fixture *f)
{
    int n = 0;
    for (int i = 0; i < INV_ASHOTS_MAX; i++) if (f->st.ashots[i].on) n++;
    return n;
}

/* ---- the plans ---------------------------------------------------------- */

static void test_plans(void)
{
    printf("invaders: each round's plan is harder than the last\n");
    int step_ok = 1, shot_ok = 1, volley_ok = 1, capped = 1, kinds_ok = 1;
    int prev_step = 0, prev_shot = 0, prev_fire = 0;
    for (int round = 1; round <= 8; round++) {
        inv_round_plan p;
        inv_plan_for((uint8_t)round, &p);
        if (round == 1) { prev_step = p.step_interval; prev_shot = p.shot_min; prev_fire = p.fire_count; }
        else {
            if (p.step_interval > prev_step) step_ok = 0;
            if (p.shot_min > prev_shot) shot_ok = 0;
            if (p.fire_count < prev_fire) volley_ok = 0;
            prev_step = p.step_interval;
            prev_shot = p.shot_min;
            prev_fire = p.fire_count;
        }
        if (p.max_shots > INV_ASHOTS_MAX) capped = 0;
        for (int row = 0; row < INV_ROWS; row++)
            if (p.kind[row] >= INV_KIND_COUNT) kinds_ok = 0;
    }
    check(step_ok, "the wall marches sooner every round");
    check(shot_ok, "and fires sooner every round");
    check(volley_ok, "and fires more shots per volley");
    check(capped, "never more bullets in the air than the array holds");
    check(kinds_ok, "and every row names a real kind");

    /* Past the table the last plan repeats harder rather than flattening out. */
    inv_round_plan r6, r7;
    inv_plan_for(6, &r6);
    inv_plan_for(7, &r7);
    check(r7.step_interval < r6.step_interval && r7.shot_min < r6.shot_min,
          "the seventh round is still a step harder than the sixth");

    /* And far past it nothing runs away: the bounds hold as the rounds go on. */
    inv_round_plan far;
    inv_plan_for(200, &far);
    check(far.step_interval >= 3 && far.shot_span >= 12 && far.fire_count <= 5 &&
          far.max_shots <= INV_ASHOTS_MAX,
          "even two hundred rounds in, the plan stays within its bounds");
}

/* ---- each round draws its own wall -------------------------------------- */

static void test_round_walls(void)
{
    printf("invaders: each round's wall is drawn as its plan says\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }

    int armour_ok = 1, colour_ok = 1, alive_ok = 1;
    int zipper_in_r2 = 0, zipper_in_r1 = 0;
    for (int round = 1; round <= INV_ROUNDS; round++) {
        inv_round_plan p;
        inv_plan_for((uint8_t)round, &p);
        f.st.round = (uint8_t)round;   /* the round and its wall go together */
        refill_wave(&f.st, (uint8_t)round);
        fx_draw_quiet(&f);

        if (f.st.n_alive != INV_COLS * INV_ROWS) alive_ok = 0;

        uint32_t want_armor = 0;
        for (int row = 0; row < INV_ROWS; row++)
            if (inv_kind_armored(p.kind[row]))
                for (int col = 0; col < INV_COLS; col++)
                    want_armor |= 1u << (row * INV_COLS + col);
        if (f.st.armor != want_armor) armour_ok = 0;

        for (int row = 0; row < INV_ROWS; row++) {
            ml_rgb want = inv_kind_color(p.kind[row]);
            for (int col = 0; col < INV_COLS; col++) {
                if (!fx_same(fx_sprite_centre(&f, row, col), want)) colour_ok = 0;
                if (p.kind[row] == INV_ZIPPER && fx_same(fx_sprite_centre(&f, row, col), want)) {
                    if (round == 1) zipper_in_r1 = 1;
                    if (round == 2) zipper_in_r2 = 1;
                }
            }
        }
    }
    check(alive_ok, "every round starts with the full wall");
    check(armour_ok, "and wears armour on exactly the rows whose kind does");
    check(colour_ok, "and every sprite is drawn in its row's kind colour");
    check(zipper_in_r2 && !zipper_in_r1,
          "round 2's wall holds zippers and round 1's holds none");

    fx_close(&f);
}

/* ---- armour ------------------------------------------------------------- */

static void test_armour(void)
{
    printf("invaders: an anvil takes two hits\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }

    /* Round 4's top row is anvils; nothing else on that wall wears armour. */
    f.st.round = 4;
    refill_wave(&f.st, 4);
    fx_draw_quiet(&f);
    const int ax0 = f.st.ax, ay0 = f.st.ay;
    check((f.st.armor & 1u) != 0, "the top-row alien wears armour");
    check(fx_same(fx_px(&f, ax0, ay0), inv_kind_color(INV_ANVIL)),
          "and is drawn as a solid block of steel before the hit");

    /* The cannon's bullet starts just below the wall's top row and moves two
     * pixels up into it, which is what a real shot does. */
    f.st.pshot.x = (int16_t)(f.st.ax + 1);
    f.st.pshot.y = (int16_t)(f.st.ay + INV_SPRITE_H + 1);
    f.st.pshot.on = 1;
    fx_step(&f, 1);
    check(f.st.n_alive == INV_COLS * INV_ROWS, "the first hit kills nothing");
    check((f.st.armor & 1u) == 0, "it clears the armour off that alien");
    check(f.st.score == 10, "and pays a fifth of the kill");
    check(f.st.pshot.on == 0, "and the bullet is spent");

    fx_draw_quiet(&f);
    check(!fx_same(fx_px(&f, ax0, ay0), inv_kind_color(INV_ANVIL)),
          "the cracked alien no longer fills its block");
    check(fx_same(fx_sprite_centre(&f, 0, 0), inv_kind_color(INV_ANVIL)),
          "but it is still the same kind in the same colour");

    /* The second hit on the same cell kills it, for its kind's full score. */
    f.st.pshot.x = (int16_t)(f.st.ax + 1);
    f.st.pshot.y = (int16_t)(f.st.ay + INV_SPRITE_H + 1);
    f.st.pshot.on = 1;
    fx_step(&f, 1);
    check(f.st.n_alive == INV_COLS * INV_ROWS - 1, "the second hit kills it");
    check(f.st.score == 50, "and pays the anvil's 40 on top of the crack's 10");

    fx_close(&f);
}

/* ---- what each kind's bullet does --------------------------------------- */

static void test_kind_bullets(void)
{
    printf("invaders: the kind decides the bullet\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }

    /* One alien left, so the column it fires down is forced and the test reads
     * the kind's bullet rather than the PRNG's choice of column. */
    const int col = 0;

    /* Round 2's bottom row is zippers: their bullet falls twice as fast. */
    f.st.round = 2;
    refill_wave(&f.st, 2);
    f.st.aliens = 1u << (3 * INV_COLS + col);
    f.st.n_alive = 1;
    f.st.armor = 0;
    f.st.shot_interval = 1;
    f.st.shot_ctr = 0;
    fx_step(&f, 1);
    check(fx_shots_in_air(&f) == 1, "a lone alien fires exactly one bullet");
    check(f.st.ashots[0].step == 2 && f.st.ashots[0].x == f.st.ax + 1,
          "a zipper's bullet falls two pixels a tick down its own column");

    /* Round 3's top row is snipers: their bullet comes down the cannon's own
     * column, not the alien's. */
    fx_close(&f);
    if (!fx_open(&f)) { check(0, "fixture reopens"); return; }
    f.st.round = 3;
    refill_wave(&f.st, 3);
    f.st.aliens = 1u << (0 * INV_COLS + col);
    f.st.n_alive = 1;
    f.st.armor = 0;
    f.st.px = 5;
    f.st.shot_interval = 1;
    f.st.shot_ctr = 0;
    fx_step(&f, 1);
    check(fx_shots_in_air(&f) == 1, "the sniper fires one bullet");
    check(f.st.ashots[0].step == 1, "a sniper's bullet falls one pixel a tick");
    check(f.st.ashots[0].x == 5 + INV_SPRITE_W / 2,
          "and it aims at the cannon's column, not the alien's");

    /* Round 1 is grunts: the plain slow bullet down the alien's own column. */
    fx_close(&f);
    if (!fx_open(&f)) { check(0, "fixture reopens"); return; }
    f.st.round = 1;
    refill_wave(&f.st, 1);
    f.st.aliens = 1u << (2 * INV_COLS + 3);
    f.st.n_alive = 1;
    f.st.armor = 0;
    f.st.shot_interval = 1;
    f.st.shot_ctr = 0;
    fx_step(&f, 1);
    check(f.st.ashots[0].step == 1 && f.st.ashots[0].x == f.st.ax + 3 * INV_GAP_X + 1,
          "a grunt's bullet falls slowly down the alien's own column");

    fx_close(&f);
}

/* ---- the march speeds up as the wall thins ------------------------------ */

static void test_thinning_pace(void)
{
    printf("invaders: a thinner wall marches faster\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }

    const int full_ax = f.st.ax;
    fx_step(&f, 24);
    check(f.st.ax == full_ax + 2,
          "the whole wall marches twice in 24 ticks (round 1: every 12)");
    check(f.st.ay == 3, "and does not drop a row doing it");

    fx_close(&f);
    if (!fx_open(&f)) { check(0, "fixture reopens"); return; }
    f.st.aliens = 0xFFu;              /* eight alive, all in the top row */
    f.st.n_alive = 8;
    const int thin_ax = f.st.ax;
    fx_step(&f, 24);
    check(f.st.ax == thin_ax + 8,
          "eight aliens march eight times in the same 24 ticks (every 3)");
    check(f.st.ay == 3, "and do not drop a row either");

    fx_close(&f);
}

/* ---- a cleared round ---------------------------------------------------- */

static void test_round_clears(void)
{
    printf("invaders: a cleared round brings the next one's enemies\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }

    f.st.aliens = 0;
    f.st.n_alive = 0;
    f.st.score = 0;
    f.st.round = 1;
    f.st.pshot.on = 1;
    f.st.pshot.y = 10;
    f.st.ashots[0].on = 1;
    f.st.ashots[0].x = 20;
    f.st.ashots[0].y = 10;
    fx_step(&f, 1);

    check(f.st.round == 2, "the round advances");
    check(f.st.n_alive == INV_COLS * INV_ROWS, "with the wall full again");
    check(f.st.score == 25 * 2, "and a bonus that grows with the round");
    check(f.st.intro == 40, "and the new number blinks");
    check(f.st.pshot.on == 0 && fx_shots_in_air(&f) == 0,
          "and nothing is left in the air");

    /* The new wall is round 2's: zippers on the bottom two rows, grunts on top.
     * Read at a column past the HUD line, which is drawn over the wall's left. */
    ml_game_invaders.draw(&f.st, &f.view, &f.cv, NULL);
    check(fx_same(fx_sprite_centre(&f, 0, 5), inv_kind_color(INV_GRUNT)) &&
          fx_same(fx_sprite_centre(&f, 3, 5), inv_kind_color(INV_ZIPPER)),
          "and it is drawn with the next round's enemies");

    fx_close(&f);
}

int main(void)
{
    test_plans();
    test_round_walls();
    test_armour();
    test_kind_bullets();
    test_thinning_pace();
    test_round_clears();

    printf("\n%d checks, %d failures\n", g_checks, g_failures);
    if (g_failures) { printf("FAIL\n"); return 1; }
    printf("PASS\n");
    return 0;
}
