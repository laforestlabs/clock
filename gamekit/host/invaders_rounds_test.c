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
 * Two behaviours came after that and are the other half of what this pins:
 *
 * - the pace is the round's, not the wall's. It used to be divided by the
 *   survivors, so the last few aliens marched many times as often as the full
 *   wall and a round's speed depended on how much of it was left. A round now
 *   marches at one pace from its first alien to its last, and a faster pace is
 *   what the next round is.
 * - the wall's edges and its invasion are the live aliens' own. It used to use
 *   the 8x4 grid's box, so a wall with a cleared bottom row invaded from a row
 *   that held nothing, and a cleared column turned it around early.
 *
 * The cannon fires one bullet per press and never waits for the last one: these
 * cases press, tick and press again, count the bullets in the air, and read
 * them off the drawn panel, where the cannon's bullets are the only pure white
 * pixels.
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

static int fx_pshots_on(const fixture *f)
{
    int n = 0;
    for (int i = 0; i < INV_PSHOTS_MAX; i++) if (f->st.pshots[i].on) n++;
    return n;
}

/* One Shoot input event, at the level a pad, a key or the firmware sends it. */
static void fx_shoot(fixture *f, int value)
{
    ml_input_event e;
    memset(&e, 0, sizeof(e));
    e.player_id = 1;
    e.code = 2;
    e.value = (int16_t)value;
    e.type = ML_INPUT_BUTTON;
    ml_game_invaders.input(&f->st, &e, NULL);
}

/* A whole press and release with no tick between them: what a tap delivers. */
static void fx_tap(fixture *f)
{
    fx_shoot(f, 1);
    fx_shoot(f, 0);
}

/* Make the next update a formation step. */
static void fx_due_march(fixture *f)
{
    f->st.step_ctr = (uint8_t)(march_interval(&f->st) - 1);
    fx_step(f, 1);
}

/* The wall as the case needs it: [aliens] alive, the grid where the case puts
 * it, marching [dir]. Armour is dropped: the cases that care about it wear it
 * from the round's own refill. */
static void fx_wall(fixture *f, uint32_t aliens, int alive, int ax, int ay, int dir)
{
    f->st.aliens = aliens;
    f->st.n_alive = (uint8_t)alive;
    f->st.armor = 0;
    f->st.ax = (int16_t)ax;
    f->st.ay = (int16_t)ay;
    f->st.dir = (uint8_t)dir;
}

/* The cannon's bullets are the only pure white pixels on the panel. */
static int fx_white_at(const fixture *f, int x, int y)
{
    const ml_rgb p = fx_px(f, x, y);
    return p.r == 255 && p.g == 255 && p.b == 255;
}

/* Whether two fixtures' canvases are the same frame, pixel for pixel. */
static int fx_same_canvas(const fixture *a, const fixture *b)
{
    if (a->cv.w != b->cv.w || a->cv.h != b->cv.h) return 0;
    for (int y = 0; y < a->cv.h; y++)
        for (int x = 0; x < a->cv.w; x++)
            if (!fx_same(fx_px(a, x, y), fx_px(b, x, y))) return 0;
    return 1;
}

/* March [ticks] ticks with [aliens] left alive and report how many pixels the
 * formation moved. Alien fire is held off for the window: this measures the
 * march, and a bullet in the air is not part of it. */
static int fx_march_px(fixture *f, uint32_t aliens, int alive, int ticks)
{
    f->st.aliens = aliens;
    f->st.n_alive = (uint8_t)alive;
    f->st.armor = 0;
    f->st.shot_interval = 255;
    for (int i = 0; i < INV_ASHOTS_MAX; i++) f->st.ashots[i].on = 0;
    const int before = f->st.ax;
    fx_step(f, ticks);
    return f->st.ax - before;
}

/* The ticks the whole wall needs for its second step: one pace per round, so
 * this is twice the round's interval. -1 when it never gets there. */
static int fx_ticks_to_two_steps(fixture *f)
{
    f->st.aliens = 0xFFFFFFFFu;
    f->st.n_alive = INV_COLS * INV_ROWS;
    f->st.armor = 0;
    f->st.shot_interval = 255;
    for (int i = 0; i < INV_ASHOTS_MAX; i++) f->st.ashots[i].on = 0;
    const int before = f->st.ax;
    for (int t = 1; t <= 200; t++) {
        fx_step(f, 1);
        if (f->st.ax - before >= 2) return t;
    }
    return -1;
}

/* ---- one pace per round ------------------------------------------------- */

/* Every round marches a little sooner than the one before — measured by
 * driving the game, not by reading the table. A round's own pace is the same
 * on its first alien as on its last, so a thinning wall never changes it. */
static void test_round_pace(void)
{
    printf("invaders: a round marches at one pace, and every round is a faster one\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }

    /* Round 1 steps every 12 ticks. Twenty-four of them is exactly two steps. */
    check(fx_march_px(&f, 0xFFFFFFFFu, 32, 24) == 2,
          "the full wall marches two pixels in 24 ticks (round 1: every 12)");
    check(f.st.ay == 3, "and does not drop a row doing it");

    /* The same window with eight aliens and then with one: the same two
     * pixels. The pace a round set does not depend on how much of it is
     * left. */
    check(fx_march_px(&f, 0xFFu, 8, 24) == 2,
          "eight aliens march those same two pixels");
    check(f.st.ay == 3, "and do not drop a row either");
    check(fx_march_px(&f, 1u, 1, 24) == 2,
          "and the last alien left marches them too");

    fx_close(&f);
    if (!fx_open(&f)) { check(0, "fixture reopens"); return; }

    /* Round 2 steps every 11 ticks: the same 22 ticks buy it two steps where
     * round 1 got one. That difference is where "harder" comes from. */
    f.st.round = 2;
    refill_wave(&f.st, 2);
    check(fx_march_px(&f, 0xFFFFFFFFu, 32, 22) == 2,
          "round 2 marches two pixels in 22 ticks");
    f.st.round = 1;
    refill_wave(&f.st, 1);
    check(fx_march_px(&f, 0xFFFFFFFFu, 32, 22) == 1,
          "where round 1 marches one");

    /* Killing an alien inside the interval neither resets the clock nor
     * shortens the pace: the step still lands when the round said it would,
     * and the ones after it stay a whole pace apart. */
    fixture k;
    if (!fx_open(&k)) { check(0, "fixture opens"); return; }
    k.st.shot_interval = 255;
    fx_step(&k, 11);                 /* the tick before round 1's step */
    alien_kill(&k.st, 0, 0);
    const int before = k.st.ax;
    fx_step(&k, 1);
    check(k.st.ax == before + 1, "the step the round set still lands on time");
    fx_step(&k, 23);
    check(k.st.ax - before == 2, "and the next one is a whole pace later");
    fx_close(&k);
    fx_close(&f);
    if (!fx_open(&f)) { check(0, "fixture reopens"); return; }

    /* Round by round, the wall marches sooner: how long it takes to take its
     * second step only ever goes down. */
    int sooner = 1;
    int prev = 0;
    for (int round = 1; round <= 8; round++) {
        f.st.round = (uint8_t)round;
        refill_wave(&f.st, (uint8_t)round);
        const int ticks = fx_ticks_to_two_steps(&f);
        if (ticks < 0) { check(0, "the wall takes its second step"); break; }
        if (prev != 0 && ticks >= prev) sooner = 0;
        prev = ticks;
    }
    check(sooner, "every round marches sooner than the round before");

    /* And far past the table it stops rather than running away with itself. */
    f.st.round = 200;
    refill_wave(&f.st, 200);
    check(fx_ticks_to_two_steps(&f) == 6,
          "even two hundred rounds in, the pace is still bounded");

    fx_close(&f);
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
    f.st.pshots[0].x = (int16_t)(f.st.ax + 1);
    f.st.pshots[0].y = (int16_t)(f.st.ay + INV_SPRITE_H + 1);
    f.st.pshots[0].on = 1;
    fx_step(&f, 1);
    check(f.st.n_alive == INV_COLS * INV_ROWS, "the first hit kills nothing");
    check((f.st.armor & 1u) == 0, "it clears the armour off that alien");
    check(f.st.score == 10, "and pays a fifth of the kill");
    check(fx_pshots_on(&f) == 0, "and the bullet is spent");

    fx_draw_quiet(&f);
    check(!fx_same(fx_px(&f, ax0, ay0), inv_kind_color(INV_ANVIL)),
          "the cracked alien no longer fills its block");
    check(fx_same(fx_sprite_centre(&f, 0, 0), inv_kind_color(INV_ANVIL)),
          "but it is still the same kind in the same colour");

    /* The second hit on the same cell kills it, for its kind's full score. */
    f.st.pshots[0].x = (int16_t)(f.st.ax + 1);
    f.st.pshots[0].y = (int16_t)(f.st.ay + INV_SPRITE_H + 1);
    f.st.pshots[0].on = 1;
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

/* ---- the wall's edges are the live aliens' own -------------------------- */

static void test_invasion_bounds(void)
{
    printf("invaders: only the aliens still alive decide where the wall ends\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }

    /* One alien on the top row, three empty rows under it. The 8x4 grid's box
     * reaches the cannon row long before the alien does, and the old box test
     * ended the game there: the alien's own bottom is 17 against the box's 29. */
    fx_wall(&f, 1u, 1, 30, 15, 1);
    fx_due_march(&f);
    check(f.st.status == INV_PLAYING, "an alien at ay=15 is nowhere near the cannon");
    check(f.st.ax == 31 && f.st.ay == 15, "and it marches on three rows higher up");

    /* The same alien where its own sprite reaches the cannon's first drawn row
     * (panel_h - 2 = 30, the sprite's bottom at ay + 2). */
    fixture g;
    if (!fx_open(&g)) { check(0, "fixture opens"); return; }
    fx_wall(&g, 1u, 1, 30, 28, 1);
    fx_due_march(&g);
    check(g.st.status == INV_OVER, "an alien whose sprite reaches the cannon ends it");
    check(g.st.lives == 3, "and it is the invasion, not a lost life");

    /* One row short of that is still a live round. */
    fixture h;
    if (!fx_open(&h)) { check(0, "fixture opens"); return; }
    fx_wall(&h, 1u, 1, 30, 27, 1);
    fx_due_march(&h);
    check(h.st.status == INV_PLAYING && h.st.lives == 3,
          "a row above the cannon is not the cannon");

    /* Only column 0 alive, with the old grid's right edge already on the wall:
     * the live sprite is 35 pixels short of it and the wall keeps going. */
    fx_wall(&f, 1u, 1, 26, 3, 1);      /* the full grid's edge here was 26 + 37 */
    fx_due_march(&f);
    check(f.st.ax == 27 && f.st.ay == 3 && f.st.dir == 1,
          "a cleared right column does not turn the wall early");

    fx_wall(&f, 1u, 1, 60, 3, 1);      /* the live sprite's own right edge is 62 */
    fx_due_march(&f);
    check(f.st.ax == 61 && f.st.ay == 3 && f.st.dir == 1,
          "it marches on until the live sprite reaches the right edge");
    fx_due_march(&f);
    check(f.st.dir == 0 && f.st.ay == 6, "and then turns and drops a row");

    /* The same at the left, with only column 7 alive: the grid's origin can
     * sit anywhere, the live sprite is what turns the wall. */
    fx_wall(&f, 1u << 7, 1, 0, 3, 0);
    fx_due_march(&f);
    check(f.st.ax == -1 && f.st.ay == 3 && f.st.dir == 0,
          "a cleared left column does not turn the wall early");
    fx_wall(&f, 1u << 7, 1, -33, 3, 0);   /* the live sprite's own left is 2 */
    fx_due_march(&f);
    check(f.st.ax == -34 && f.st.ay == 3 && f.st.dir == 0,
          "it marches on until the live sprite reaches the left edge");
    fx_due_march(&f);
    check(f.st.dir == 1 && f.st.ay == 6, "and then turns and drops a row");

    fx_close(&f);
    fx_close(&g);
    fx_close(&h);
}

/* ---- the last kill ------------------------------------------------------ */

static void test_last_kill_precedence(void)
{
    printf("invaders: the tick that clears the wall ends there\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }

    /* The last alien, its sprite already on the right wall, a march due, one
     * life left, and a hostile bullet arriving at the cannon on this very
     * tick. The cannon's bullet kills the alien first: the round stays the
     * player's, and the hostile hit - and the march off the bottom - belong to
     * a wall that is no longer there. */
    fx_wall(&f, 1u, 1, 61, 25, 1);
    f.st.lives = 1;
    f.st.px = 30;
    f.st.pshots[0].x = 62;
    f.st.pshots[0].y = 29;
    f.st.pshots[0].on = 1;
    f.st.ashots[0].x = 30;
    f.st.ashots[0].y = 29;
    f.st.ashots[0].step = 1;
    f.st.ashots[0].on = 1;
    fx_due_march(&f);

    check(f.st.n_alive == 0, "the cannon's bullet kills the last alien");
    check(f.st.status == INV_PLAYING && f.st.lives == 1,
          "and the clear is not also the end of the round");
    check(f.st.ax == 61, "nor does a wall that is gone march off the board");
    check(fx_pshots_on(&f) == 0, "with the bullet that did it spent");

    fx_step(&f, 1);
    check(f.st.round == 2 && f.st.n_alive == INV_COLS * INV_ROWS,
          "the following tick brings the next round");
    check(fx_pshots_on(&f) == 0 && fx_shots_in_air(&f) == 0,
          "and it starts with nothing in the air");

    /* The control: a wall still standing, the same hostile hit, one life. That
     * end is the hostile bullet's, and it is still the end. */
    fixture g;
    if (!fx_open(&g)) { check(0, "fixture opens"); return; }
    fx_wall(&g, 0x3u, 2, 13, 3, 1);
    g.st.lives = 1;
    g.st.px = 30;
    g.st.ashots[0].x = 30;
    g.st.ashots[0].y = 29;
    g.st.ashots[0].step = 1;
    g.st.ashots[0].on = 1;
    fx_due_march(&g);
    check(g.st.status == INV_OVER && g.st.lives == 0,
          "a surviving wall still lets a hostile hit end the round");

    fx_close(&f);
    fx_close(&g);
}

/* ---- the cannon's bullets ----------------------------------------------- */

static void test_concurrent_shots(void)
{
    printf("invaders: the cannon fires per press, not per bullet in the air\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }

    /* Two taps a tick apart. The second must not wait for the first to leave
     * the panel, and the cannon sits at x=30, so both bullets are at x=31 with
     * one two pixels above the other. */
    check(f.st.px == 30, "the cannon starts centred");
    fx_tap(&f);
    fx_step(&f, 1);
    fx_tap(&f);
    fx_step(&f, 1);
    fx_draw_quiet(&f);
    check(fx_pshots_on(&f) == 2, "both presses are in the air at once");
    check(fx_white_at(&f, 31, 24) && fx_white_at(&f, 31, 26),
          "and both are drawn, two pixels apart");

    /* One press over the same two ticks: one bullet, so the second pixel above
     * is the second press and not the wall's own drawing. */
    fixture one;
    if (!fx_open(&one)) { check(0, "fixture opens"); return; }
    fx_tap(&one);
    fx_step(&one, 2);
    fx_draw_quiet(&one);
    check(fx_pshots_on(&one) == 1 && !fx_white_at(&one, 31, 26),
          "one press is one bullet");

    /* A held Shoot streams value=1 packets every frame: not one of them is a
     * new press, and only a release re-arms the next one. */
    fixture held;
    if (!fx_open(&held)) { check(0, "fixture opens"); return; }
    fx_shoot(&held, 1);
    for (int i = 0; i < 10; i++) fx_shoot(&held, 1);
    check(fx_pshots_on(&held) == 1, "a held level is one press, however long");
    fx_shoot(&held, 0);
    fx_tap(&held);
    check(fx_pshots_on(&held) == 2, "and the release re-arms the next one");

    /* Twenty whole taps inside one tick are twenty bullets: nothing about the
     * cadence is being assumed away by the tick. */
    fixture many;
    if (!fx_open(&many)) { check(0, "fixture opens"); return; }
    for (int i = 0; i < 20; i++) fx_tap(&many);
    check(fx_pshots_on(&many) == 20, "twenty taps in one tick are twenty bullets");
    fx_step(&many, 1);
    fx_draw_quiet(&many);
    check(fx_pshots_on(&many) == 20 && fx_white_at(&many, 31, 26),
          "and all of them are in the air on the next tick");

    /* Two bullets landing on the same armoured alien: the first cracks it and
     * is spent, the second kills it. Neither press was overwritten by the
     * other, and the wall is one alien lower for it. */
    fixture a;
    if (!fx_open(&a)) { check(0, "fixture opens"); return; }
    a.st.round = 4;
    refill_wave(&a.st, 4);            /* round 4's top row wears the armour */
    a.st.aliens = 1u;
    a.st.n_alive = 1;
    a.st.ax = 13;
    a.st.ay = 20;
    a.st.dir = 1;
    a.st.px = 12;                     /* the bullet is at x = 13: column 0 */
    check((a.st.armor & 1u) != 0, "the alien wears its armour");
    fx_tap(&a);
    fx_step(&a, 1);
    fx_tap(&a);
    fx_step(&a, 2);
    check(a.st.n_alive == 1 && a.st.score == 10 && fx_pshots_on(&a) == 1,
          "the first bullet cracks the armour and is spent");
    fx_step(&a, 1);
    check(a.st.n_alive == 0 && a.st.score == 50,
          "and the second kills it for the anvil's forty");

    fx_close(&f);
    fx_close(&one);
    fx_close(&held);
    fx_close(&many);
    fx_close(&a);
}

/* ---- spent bullets and the slots they free ------------------------------ */

static void test_shot_retirement(void)
{
    printf("invaders: a spent bullet frees only its own slot\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }

    /* Two bullets in the air: one over the only alien, one over empty space. */
    fx_wall(&f, 1u, 1, 13, 18, 1);
    f.st.px = 12;
    fx_tap(&f);                       /* (13, 28): the alien's own column */
    f.st.px = 40;
    fx_tap(&f);                       /* (41, 28): nothing under it */
    check(fx_pshots_on(&f) == 2, "both bullets are in the air");

    fx_step(&f, 4);                   /* the first reaches the alien's bottom row */
    check(f.st.n_alive == 0 && f.st.score == 10,
          "the one over the alien kills it");
    check(fx_pshots_on(&f) == 1, "and only that one is spent");
    fx_draw_quiet(&f);
    check(!fx_white_at(&f, 13, 20) && fx_white_at(&f, 41, 20),
          "the other is still flying and still drawn");

    /* The freed slot takes the next press; the live bullet keeps its own. */
    fx_tap(&f);
    check(fx_pshots_on(&f) == 2, "the cannon fires again into the slot it freed");
    fx_draw_quiet(&f);
    check(fx_white_at(&f, 41, 20) && fx_white_at(&f, 41, 28),
          "beside the bullet that is still in the air");

    /* A bullet that leaves the panel the same way: spent, and its slot is
     * reusable. */
    fixture g;
    if (!fx_open(&g)) { check(0, "fixture opens"); return; }
    fx_tap(&g);
    g.st.pshots[0].y = 1;
    fx_step(&g, 1);
    check(fx_pshots_on(&g) == 0, "a bullet above the panel is spent");
    fx_tap(&g);
    fx_step(&g, 1);
    check(fx_pshots_on(&g) == 1, "and the next press takes the free slot");

    /* A lost life spends every bullet, not just the one the hostile shot met. */
    fixture h;
    if (!fx_open(&h)) { check(0, "fixture opens"); return; }
    for (int i = 0; i < 3; i++) { fx_tap(&h); fx_step(&h, 1); }
    check(fx_pshots_on(&h) == 3, "three bullets are up");
    h.st.ashots[0].x = 30;
    h.st.ashots[0].y = 29;
    h.st.ashots[0].step = 1;
    h.st.ashots[0].on = 1;
    fx_step(&h, 1);
    check(h.st.lives == 2, "the hostile bullet hits the cannon");
    check(fx_pshots_on(&h) == 0, "and a lost life spends every bullet in the air");

    /* A round refill spends them too, and a reset clears them and the latch. */
    fixture k;
    if (!fx_open(&k)) { check(0, "fixture opens"); return; }
    fx_tap(&k);
    fx_tap(&k);
    k.st.aliens = 0;
    k.st.n_alive = 0;
    fx_step(&k, 1);
    check(k.st.round == 2 && fx_pshots_on(&k) == 0,
          "the round refill spends every bullet in the air");

    fx_tap(&k);
    fx_tap(&k);
    check(fx_pshots_on(&k) == 2, "two more bullets before the reset");
    ml_game_invaders.reset(&k.st, NULL);
    check(fx_pshots_on(&k) == 0 && k.st.held_s == 0,
          "and a reset clears them and the shoot latch with them");

    fx_close(&f);
    fx_close(&g);
    fx_close(&h);
    fx_close(&k);
}

/* ---- the bullets cross the wire ----------------------------------------- */

static void test_snapshot_shots(void)
{
    printf("invaders: the bullets and the shoot latch survive a snapshot\n");
    fixture a, b;
    if (!fx_open(&a) || !fx_open(&b)) { check(0, "fixtures open"); return; }

    /* Four bullets at four heights, the last one pressed and still held: the
     * latch is state like any other, and a restore that dropped it would fire
     * again on the next held packet. */
    fx_tap(&a); fx_step(&a, 3);
    fx_tap(&a); fx_step(&a, 3);
    fx_tap(&a); fx_step(&a, 3);
    fx_shoot(&a, 1);
    check(fx_pshots_on(&a) == 4, "four bullets, the last one held");

    /* The buffer the runtime can actually carry: the payload less the tick it
     * prefixes every snapshot with. */
    uint8_t buf[ML_SNAPSHOT_MAX - sizeof(uint32_t)];
    size_t len = 0;
    check(ml_game_invaders.snapshot(&a.st, buf, sizeof(buf), &len),
          "the whole state fits the payload the runtime can carry");
    check(len == sizeof(invaders_state), "and serializes as the state it is");

    ml_game_invaders.restore(&b.st, buf, len);
    fx_draw_quiet(&a);
    fx_draw_quiet(&b);
    check(fx_same_canvas(&a, &b), "the restored round draws the same board");

    /* And takes the same inputs the same way: the held latch does not fire
     * again on its own, and the release re-arms the next press. */
    fx_shoot(&a, 0); fx_shoot(&b, 0);
    fx_step(&a, 1); fx_step(&b, 1);
    fx_tap(&a); fx_tap(&b);
    fx_step(&a, 2); fx_step(&b, 2);
    fx_draw_quiet(&a);
    fx_draw_quiet(&b);
    check(fx_same_canvas(&a, &b), "and follows the same inputs the same way");

    fx_close(&a);
    fx_close(&b);
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
    f.st.pshots[0].on = 1;
    f.st.pshots[0].x = 30;
    f.st.pshots[0].y = 10;
    f.st.ashots[0].on = 1;
    f.st.ashots[0].x = 20;
    f.st.ashots[0].y = 10;
    fx_step(&f, 1);

    check(f.st.round == 2, "the round advances");
    check(f.st.n_alive == INV_COLS * INV_ROWS, "with the wall full again");
    check(f.st.score == 25 * 2, "and a bonus that grows with the round");
    check(f.st.intro == 40, "and the new number blinks");
    check(fx_pshots_on(&f) == 0 && fx_shots_in_air(&f) == 0,
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
    test_round_pace();
    test_round_walls();
    test_armour();
    test_kind_bullets();
    test_invasion_bounds();
    test_last_kill_precedence();
    test_concurrent_shots();
    test_shot_retirement();
    test_snapshot_shots();
    test_round_clears();

    printf("\n%d checks, %d failures\n", g_checks, g_failures);
    if (g_failures) { printf("FAIL\n"); return 1; }
    printf("PASS\n");
    return 0;
}
