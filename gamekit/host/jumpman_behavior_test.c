/*
 * jumpman_behavior_test.c - regression test for Jumpman's edge cases.
 *
 * What it pins down, all of it read off the game's own update and the drawn
 * panel:
 *
 * - the course a seed and a course index build is the course rebuilt: the
 *   terrain, the blocks, the coins and where the blobs start are the same
 *   every time, the run-in and the flag's flat are clear of everything, and no
 *   pit is wide enough to be a jump the player cannot make.
 * - the jump is the one the physics promises: a ground jump puts the feet about
 *   eight rows up, and a player who jumps before a low block lands on top of
 *   it, while one who walks into it is stopped by it.
 * - a coin block pays out once, from below, and the whole block turns used;
 *   walking under one does nothing, and a used block never pays again.
 * - a blob is stomped when the player comes down on its head - the blob dies,
 *   the score pays and the player bounces - and kills the player when they meet
 *   it anywhere else, including standing beside it.
 * - a pit is fatal: the player falls out of the field, and the life is gone.
 * - three lives, and the third death is the end of the game; a death puts the
 *   player back at the start of the course and puts the blobs back where they
 *   started, while the course itself - blocks already bumped, coins already
 *   taken - is the one that was being played.
 * - the flag ends the course for a bonus and starts the next one; the third
 *   flag is the win, and is_over agrees on both endings.
 * - a tilt is a direction: a deliberate angle runs, a level phone stands still,
 *   an idle axis hands the run back to the buttons, and a held tilt keeps
 *   running.
 * - the terminal frame clears the board of the course and draws the score band
 *   and the ending.
 * - a snapshot is all-or-nothing: too small a buffer is refused, a buffer of
 *   the exact size round-trips the state, and restoring a short buffer leaves
 *   the state alone.
 *
 * The fixture includes the jumpman translation unit - which reaches the runtime
 * through ml_ctx_rng and ml_ctx_emit_event - and provides those two services
 * itself, the same xorshift the runtime uses, so a test can drive the game tick
 * by tick and place a block, a coin or a blob exactly where the case needs it.
 * The Makefile links this fixture with neither the runtime (whose ctx services
 * this file replaces) nor the game's own object (which it includes).
 *
 * Observable: the state the game's own update left, plus the panel it drew. The
 * fixtures place course pieces through the state the game itself owns rather
 * than any test-only seam.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "../examples/jumpman/game_jumpman.c"

/* The game reaches the runtime's services through ctx. The fixture owns them
 * instead of opening a session: the same xorshift the runtime uses, so the
 * rolls are as deterministic as the game expects. Any other ctx service the
 * game called would be a link error, which is the point. */
static uint32_t fx_rng_state = 1u;
static int      fx_events;

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
    fx_events++;
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
#define CODE_JUMP  2
#define CODE_TILT  3

typedef struct {
    jumpman_state st;
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
    ml_view_compute(&f->view, ml_game_jumpman.pref_w, ml_game_jumpman.pref_h,
                    ml_game_jumpman.fit, PANEL_W, PANEL_H);
    fx_rng_state = 1u;
    fx_events = 0;
    ml_game_jumpman.init(&f->st, &f->cfg, NULL);
    ml_game_jumpman.reset(&f->st, NULL);
    return true;
}

static void fx_close(fixture *f)
{
    ml_canvas_free(&f->cv);
}

static void fx_step(fixture *f, int ticks)
{
    for (int t = 0; t < ticks; t++) ml_game_jumpman.update(&f->st, NULL);
}

static void fx_draw(fixture *f)
{
    ml_game_jumpman.draw(&f->st, &f->view, &f->cv, NULL);
}

static void fx_button(fixture *f, uint16_t code, int value)
{
    ml_input_event e;
    memset(&e, 0, sizeof(e));
    e.player_id = 1;
    e.code = code;
    e.value = (int16_t)value;
    e.type = ML_INPUT_BUTTON;
    ml_game_jumpman.input(&f->st, &e, NULL);
}

static void fx_axis(fixture *f, int value)
{
    ml_input_event e;
    memset(&e, 0, sizeof(e));
    e.player_id = 1;
    e.code = CODE_TILT;
    e.value = (int16_t)value;
    e.type = ML_INPUT_AXIS;
    ml_game_jumpman.input(&f->st, &e, NULL);
}

/* Press Jump for one tick, which is what a press is: the queue is consumed by
 * the tick the update runs. */
static void fx_jump(fixture *f)
{
    fx_button(f, CODE_JUMP, 1);
    fx_step(f, 1);
}

/* ---- placing course pieces ---------------------------------------------- */

/* An empty flat course in a fresh run: ground the whole way, nothing in it, and
 * no input left latched from the case before. Used for the cases that are about
 * one mechanic, so a generated block or pit cannot reach the case under test. */
static void fx_flat(fixture *f)
{
    jumpman_state *s = &f->st;
    jm_flatten(s);
    s->score = 0;
    s->coin_count = 0;
    s->level = 0;
    s->lives = 3;
    s->status = JM_PLAYING;
    s->held_left = 0;
    s->held_right = 0;
    s->jump_held = 0;
    s->jump_queued = 0;
    s->tilt_x = ML_AXIS_IDLE;
    s->px = PLAYER_START_X << 8;
    s->py = PLAYER_START_Y << 8;
    s->vx = 0;
    s->vy = 0;
    s->cam = 0;
}

static void fx_place_player(fixture *f, int col, int row)
{
    f->st.px = col << 8;
    f->st.py = row << 8;
    f->st.vx = 0;
    f->st.vy = 0;
}

static int fx_blob_slot_at(fixture *f, int col, int dir)
{
    f->st.blobs[0].x = (int32_t)col << 8;
    f->st.blobs[0].sx = (int16_t)col;
    f->st.blobs[0].dir = (int8_t)dir;
    f->st.blobs[0].alive = 1;
    return 0;
}

static void fx_no_blobs(fixture *f)
{
    for (int i = 0; i < BLOB_SLOTS; i++) { f->st.blobs[i].alive = 0; f->st.blobs[i].sx = -1; }
}

static int fx_alive_blobs(const fixture *f)
{
    int n = 0;
    for (int i = 0; i < BLOB_SLOTS; i++) if (f->st.blobs[i].alive) n++;
    return n;
}

/* Where a blob's left edge is on the panel after the last update. */
static int fx_blob_col(const fixture *f, int slot)
{
    return (int)(f->st.blobs[slot].x >> 8);
}

/* ---- reading the panel --------------------------------------------------- */

/* The palette the game draws with, mirrored here so the assertions can name a
 * pixel. Anything not listed is background. */
static int fx_is(ml_rgb p, int r, int g, int b)
{
    return p.r == (uint8_t)r && p.g == (uint8_t)g && p.b == (uint8_t)b;
}

static int fx_is_cap(ml_rgb p)    { return fx_is(p, 224, 56, 48); }
static int fx_is_blob(ml_rgb p)   { return fx_is(p, 104, 64, 44) || fx_is(p, 64, 40, 26); }

/* The panel is the authored size here, so a world row is its panel row plus the
 * HUD band, and the ending is drawn in panel rows because it is not part of the
 * field. Both readers exist so a check never has to guess which it is in. */
static ml_rgb fx_world_px(const fixture *f, int x, int y)
{
    return ml_canvas_get(&f->cv, x, y + JUMP_HUD_H);
}

static int fx_lit_panel(const fixture *f, int x0, int y0, int x1, int y1)
{
    int n = 0;
    for (int y = y0; y <= y1; y++)
        for (int x = x0; x <= x1; x++) {
            ml_rgb p = ml_canvas_get(&f->cv, x, y);
            if (p.r || p.g || p.b) n++;
        }
    return n;
}

/* Whether the player's cap is drawn at this world position: the one pixel of
 * the player that no course piece shares a colour with. */
static int fx_player_at(const fixture *f, int x, int y)
{
    return fx_is_cap(fx_world_px(f, x, y));
}

static int fx_blob_at(const fixture *f, int x, int y)
{
    return fx_is_blob(fx_world_px(f, x, y));
}

/* ---- the declared contract ---------------------------------------------- */

static void test_declared_contract(void)
{
    printf("jumpman: the surface the app and the host agree on\n");
    check(strcmp(ml_game_jumpman.id, "jumpman") == 0, "the id is jumpman");
    check(ml_game_jumpman.pref_w == 64 && ml_game_jumpman.pref_h == 32,
          "it authors the 64x32 panel");
    check(ml_game_jumpman.fit == ML_FIT_LETTERBOX, "letterboxed, never stretched");
    check(ml_game_jumpman.tick_ms == 25, "a 25ms tick");
    check(ml_game_jumpman.max_players == 1, "single player");
    check(ml_game_jumpman.state_size <= ML_SNAPSHOT_MAX - 4,
          "the state fits the 1020 bytes a broadcast leaves");

    check(ml_game_jumpman.control_count == 4, "four controls");
    check(ml_game_jumpman.controls[CODE_LEFT].code == CODE_LEFT &&
          strcmp(ml_game_jumpman.controls[CODE_LEFT].label, "Left") == 0 &&
          ml_game_jumpman.controls[CODE_LEFT].type == ML_INPUT_BUTTON,
          "code 0 is the Left button");
    check(ml_game_jumpman.controls[CODE_RIGHT].code == CODE_RIGHT &&
          strcmp(ml_game_jumpman.controls[CODE_RIGHT].label, "Right") == 0 &&
          ml_game_jumpman.controls[CODE_RIGHT].type == ML_INPUT_BUTTON,
          "code 1 is the Right button");
    check(ml_game_jumpman.controls[CODE_JUMP].code == CODE_JUMP &&
          strcmp(ml_game_jumpman.controls[CODE_JUMP].label, "Jump") == 0 &&
          ml_game_jumpman.controls[CODE_JUMP].type == ML_INPUT_BUTTON,
          "code 2 is the Jump button");
    check(ml_game_jumpman.controls[CODE_TILT].code == CODE_TILT &&
          strcmp(ml_game_jumpman.controls[CODE_TILT].label, "TiltX") == 0 &&
          ml_game_jumpman.controls[CODE_TILT].type == ML_INPUT_AXIS &&
          ml_game_jumpman.controls[CODE_TILT].caps == ML_CAP_ACCEL,
          "code 3 is the TiltX axis");
}

/* ---- the course --------------------------------------------------------- */

/* A course rebuilt from scratch: the same seed and the same index have to give
 * the same course, or a peer that rebuilds after a death plays another one. */
static void test_course_is_deterministic(void)
{
    printf("jumpman: the course a seed builds is the course rebuilt\n");
    fixture a, b;
    if (!fx_open(&a) || !fx_open(&b)) { check(0, "the fixtures open"); return; }

    check(memcmp(a.st.surf, b.st.surf, sizeof(a.st.surf)) == 0 &&
          memcmp(a.st.brick, b.st.brick, sizeof(a.st.brick)) == 0 &&
          memcmp(a.st.bkind, b.st.bkind, sizeof(a.st.bkind)) == 0 &&
          memcmp(a.st.blobs, b.st.blobs, sizeof(a.st.blobs)) == 0 &&
          memcmp(a.st.coins, b.st.coins, sizeof(a.st.coins)) == 0,
          "two runs of the same seed build the same course");

    /* It is a course, not a field of flat: a seed that generated nothing would
     * pass the check above. */
    int pits = 0, blocks = 0, coins = 0, pipes = 0;
    for (int x = 0; x < JUMP_COLS; x++) {
        if (a.st.surf[x] == JM_NONE) pits++;
        if (a.st.brick[x] != JM_NONE) blocks++;
    }
    for (int i = 0; i < COIN_SLOTS; i++) if (a.st.coins[i].state == CM_LIVE) coins++;
    for (int i = 0; i < PIPE_SLOTS; i++) if (a.st.pipes[i].x != PM_NONE) pipes++;
    check(pits > 0 && blocks > 0 && coins > 0 && pipes > 0 && fx_alive_blobs(&a) > 0,
          "and it holds pits, blocks, coins, pipes and blobs");
    check(pits < JUMP_COLS / 4, "the course is ground with gaps, not gaps with ground");
    check(a.st.status == JM_PLAYING && a.st.lives == 3 && a.st.level == 0,
          "the game starts playing, on the first course, with three lives");

    /* The cheap end of the course: a flat run-in to start from and a flat tail
     * for the flag, so the player never starts in a pit or lands the flag in
     * one. */
    int run_in_clear = 1, tail_clear = 1;
    for (int x = 0; x < JUMP_RUN_IN; x++) {
        if (a.st.surf[x] != JUMP_GROUND_ROW || a.st.brick[x] != JM_NONE) run_in_clear = 0;
        for (int i = 0; i < BLOB_SLOTS; i++)
            if (a.st.blobs[i].alive && (int)a.st.blobs[i].sx < JUMP_RUN_IN) run_in_clear = 0;
    }
    for (int x = JUMP_FLAG - 1; x < JUMP_COLS; x++)
        if (a.st.surf[x] != JUMP_GROUND_ROW || a.st.brick[x] != JM_NONE) tail_clear = 0;
    check(run_in_clear, "the run-in is flat ground with nothing on it");
    check(tail_clear, "the flag stands on flat ground with nothing in the way");

    /* Every pit is inside what a jump clears: a jump travels about 32 columns,
     * so a pit of four is the widest the generator may make. */
    int widest = 0, run = 0;
    for (int x = 0; x < JUMP_COLS; x++) {
        run = a.st.surf[x] == JM_NONE ? run + 1 : 0;
        if (run > widest) widest = run;
    }
    check(widest >= 2 && widest <= 4, "every pit is 2 to 4 columns wide");

    /* A blob starts on ground it can walk: its own column flat. */
    int grounded = 1;
    for (int i = 0; i < BLOB_SLOTS; i++) {
        if (!a.st.blobs[i].alive) continue;
        if (a.st.surf[a.st.blobs[i].sx] != JUMP_GROUND_ROW) grounded = 0;
    }
    check(grounded, "every blob starts on flat ground");

    /* The later courses are harder, which is what the index buys: wider pits,
     * faster blobs. */
    fixture c;
    if (!fx_open(&c)) { check(0, "the third fixture opens"); return; }
    c.st.level = 2;
    jm_load_course(&c.st, NULL);
    int widest_c = 0, run_c = 0;
    for (int x = 0; x < JUMP_COLS; x++) {
        run_c = c.st.surf[x] == JM_NONE ? run_c + 1 : 0;
        if (run_c > widest_c) widest_c = run_c;
    }
    check(jm_blob_speed(&c.st) > jm_blob_speed(&a.st),
          "a later course walks its blobs faster");
    check(widest_c >= 2 && widest_c <= 4, "and its pits are still what a jump clears");

    /* The same protections hold on every course: a flat tail for the flag, and
     * no blob parked on it. */
    int tail_ok_c = 1, flag_clear_c = 1;
    for (int x = JUMP_FLAG - 1; x < JUMP_COLS; x++)
        if (c.st.surf[x] != JUMP_GROUND_ROW || c.st.brick[x] != JM_NONE) tail_ok_c = 0;
    for (int i = 0; i < BLOB_SLOTS; i++)
        if (c.st.blobs[i].alive && (int)c.st.blobs[i].sx > JUMP_FLAG - 6) flag_clear_c = 0;
    check(tail_ok_c, "and a flat tail for the flag");
    check(flag_clear_c, "and no blob standing on the flag");

    fx_close(&a); fx_close(&b); fx_close(&c);
}

/* ---- running and jumping ------------------------------------------------- */

static void test_run_and_the_jump(void)
{
    printf("jumpman: buttons run, a jump clears eight rows, a held tilt keeps running\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "the fixture opens"); return; }
    fx_flat(&f);

    check(f.st.px == PLAYER_START_X << 8 && f.st.py == PLAYER_START_Y << 8,
          "the player starts on the ground at the run-in");
    check(f.st.py >> 8 == JUMP_GROUND_ROW - PLAYER_H, "with its feet on the surface");

    fx_button(&f, CODE_RIGHT, 1);
    fx_step(&f, 8);
    check((f.st.px >> 8) > PLAYER_START_X && (f.st.px >> 8) <= PLAYER_START_X + 10,
          "Right runs a little over a pixel a tick");
    check(f.st.py >> 8 == JUMP_GROUND_ROW - PLAYER_H, "running does not leave the ground");
    fx_button(&f, CODE_RIGHT, 0);
    fx_step(&f, 2);
    const int32_t stopped = f.st.px;
    fx_step(&f, 3);
    check(f.st.px == stopped, "releasing stops dead, with no drift");

    fx_button(&f, CODE_LEFT, 1);
    fx_step(&f, 4);
    check((f.st.px >> 8) < (stopped >> 8), "Left runs back the other way");
    check(f.st.facing == 0, "and the player faces the way it runs");
    fx_button(&f, CODE_LEFT, 0);

    /* Opposite buttons cancel rather than picking a winner. */
    const int32_t before = f.st.px;
    fx_button(&f, CODE_LEFT, 1);
    fx_button(&f, CODE_RIGHT, 1);
    fx_step(&f, 4);
    check(f.st.px == before, "both buttons held cancel out");
    fx_button(&f, CODE_LEFT, 0);
    fx_button(&f, CODE_RIGHT, 0);

    /* The jump, measured from the ground it leaves: full height held, then cut
     * short by letting go. */
    fx_place_player(&f, 4, JUMP_GROUND_ROW - PLAYER_H);
    const int ground = f.st.py >> 8;
    fx_button(&f, CODE_JUMP, 1);
    fx_step(&f, 1);
    int highest = f.st.py >> 8;
    for (int t = 0; t < 30; t++) {
        fx_step(&f, 1);
        if ((f.st.py >> 8) < highest) highest = f.st.py >> 8;
    }
    check(highest <= ground - 7 && highest >= ground - 9,
          "a held jump clears about eight rows");
    check(f.st.py >> 8 == ground, "and the player lands back on it");

    /* Letting go on the way up is a shorter jump. */
    fx_button(&f, CODE_JUMP, 0);
    (void)fx_events;
    fx_button(&f, CODE_JUMP, 1);
    fx_step(&f, 4);
    fx_button(&f, CODE_JUMP, 0);
    int cut_highest = f.st.py >> 8;
    for (int t = 0; t < 30; t++) {
        fx_step(&f, 1);
        if ((f.st.py >> 8) < cut_highest) cut_highest = f.st.py >> 8;
    }
    check(cut_highest > highest, "releasing early is a lower jump");
    check(f.st.py >> 8 == ground, "and the player lands back on the ground");

    /* A held button does not re-launch the player off the ground. */
    fx_step(&f, 6);
    fx_button(&f, CODE_JUMP, 1);
    fx_step(&f, 1);
    const int rising = f.st.py;
    fx_step(&f, 3);
    check(f.st.py != rising, "holding Jump is not a second jump");
    fx_button(&f, CODE_JUMP, 0);

    /* Tilt is a direction: deliberate angles run, level stands still, and an
     * idle axis hands the run back to the buttons. */
    fx_place_player(&f, 10, JUMP_GROUND_ROW - PLAYER_H);
    fx_axis(&f, 32767);
    fx_step(&f, 4);
    check((f.st.px >> 8) > 10, "+full tilt runs right");
    const int32_t held = f.st.px;
    fx_step(&f, 4);
    check((f.st.px >> 8) > (held >> 8), "and a held angle keeps running");
    fx_axis(&f, 0);
    const int32_t level = f.st.px;
    fx_step(&f, 4);
    check(f.st.px == level, "a level phone stands still");
    fx_axis(&f, -32767);
    fx_step(&f, 4);
    check((f.st.px >> 8) < (level >> 8), "-full tilt runs left");
    fx_axis(&f, ML_AXIS_IDLE);
    const int32_t parked = f.st.px;
    fx_step(&f, 3);
    check(f.st.px == parked, "an idle axis leaves the player alone");
    fx_button(&f, CODE_RIGHT, 1);
    fx_step(&f, 4);
    check((f.st.px >> 8) > (parked >> 8), "and the buttons run from where the tilt left it");
    fx_button(&f, CODE_RIGHT, 0);

    /* Between the halves of the travel is deliberately dead: a resting hand
     * cannot shiver the player into a run. */
    fx_axis(&f, JM_TILT_TURN);
    const int32_t near = f.st.px;
    fx_step(&f, 4);
    check(f.st.px == near, "a tilt inside the dead zone does not run");

    fx_close(&f);
}

/* ---- blocks, coins, pipes ------------------------------------------------ */

static void test_blocks(void)
{
    printf("jumpman: a block is a wall, a platform, and a coin block is a payout\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "the fixture opens"); return; }
    fx_flat(&f);

    /* A low block is a wall from the side: the player is stopped against it. */
    jm_place_block(&f.st, 20, 3, BRICK_ROW_LOW, BM_BRICK);
    fx_place_player(&f, 10, JUMP_GROUND_ROW - PLAYER_H);
    fx_button(&f, CODE_RIGHT, 1);
    fx_step(&f, 12);
    check((f.st.px >> 8) + PLAYER_W == 20,
          "running into a low block stops the player against its left edge");
    check(f.st.brick[20] == BRICK_ROW_LOW && f.st.bkind[20] == BM_BRICK,
          "and a plain block pays nothing when it is met");

    /* It is a platform: coming down over it lands the player on its top row,
     * which the panel then shows. */
    fx_button(&f, CODE_RIGHT, 0);
    fx_place_player(&f, 20, BRICK_ROW_LOW - PLAYER_H - 2);
    f.st.vy = 128;
    for (int t = 0; t < 20 && f.st.vy != 0; t++) fx_step(&f, 1);
    check(f.st.py >> 8 == BRICK_ROW_LOW - PLAYER_H,
          "falling over a low block lands the player on its top row");
    fx_draw(&f);
    check(fx_player_at(&f, 20, BRICK_ROW_LOW - PLAYER_H), "and the panel shows it standing there");

    /* And a jump from beside it clears its top, so a block is a step the player
     * jumps rather than a wall that ends the course. */
    fx_place_player(&f, 16, JUMP_GROUND_ROW - PLAYER_H);
    fx_button(&f, CODE_JUMP, 1);
    fx_step(&f, 1);
    int apex = f.st.py >> 8;
    for (int t = 0; t < 20; t++) {
        fx_step(&f, 1);
        if ((f.st.py >> 8) < apex) apex = f.st.py >> 8;
    }
    check(apex <= BRICK_ROW_LOW - PLAYER_H, "a jump from beside a low block clears its top");
    fx_button(&f, CODE_JUMP, 0);

    /* A running jump carries over all of it: three columns of block cleared at
     * a run, with the player landing on the ground past the far side. */
    fx_place_player(&f, 16, JUMP_GROUND_ROW - PLAYER_H);
    fx_button(&f, CODE_RIGHT, 1);
    fx_button(&f, CODE_JUMP, 1);
    fx_step(&f, 30);
    check(f.st.py >> 8 == JUMP_GROUND_ROW - PLAYER_H && (f.st.px >> 8) > 22,
          "a running jump clears a low block and lands beyond it");
    fx_button(&f, CODE_RIGHT, 0);
    fx_button(&f, CODE_JUMP, 0);

    /* A coin block hangs above the player's head, so a jump bumps it: the score
     * and the coin count pay, the whole block turns used, and a second bump
     * does not pay again. */
    fx_flat(&f);
    jm_place_block(&f.st, 20, 4, BRICK_ROW_HIGH, BM_COIN);
    check(f.st.surf[20] == JUMP_GROUND_ROW, "the ground under a coin block is level");
    check(BRICK_ROW_HIGH + BRICK_H <= JUMP_GROUND_ROW - PLAYER_H,
          "the block hangs clear of the player's head");
    fx_place_player(&f, 20, JUMP_GROUND_ROW - PLAYER_H);
    fx_button(&f, CODE_JUMP, 1);
    int bumped = 0;
    for (int t = 0; t < 10 && !bumped; t++) {
        fx_step(&f, 1);
        bumped = f.st.bkind[20] == BM_USED;
    }
    check(bumped, "a jump into a coin block bumps it");
    check(f.st.score == SCORE_COIN && f.st.coin_count == 1, "and the bump pays a coin");
    check(f.st.bkind[20] == BM_USED && f.st.bkind[21] == BM_USED &&
          f.st.bkind[22] == BM_USED && f.st.bkind[23] == BM_USED,
          "the whole block turns used, not just the column the head caught");
    check((f.st.py >> 8) == BRICK_ROW_HIGH + BRICK_H,
          "the head stops under the block it bumped");
    fx_button(&f, CODE_JUMP, 0);
    fx_step(&f, 20);
    check(f.st.surf[20] == JUMP_GROUND_ROW && (f.st.py >> 8) == JUMP_GROUND_ROW - PLAYER_H,
          "and the player lands back on the ground under it");
    check(f.st.score == SCORE_COIN, "walking under a used block pays nothing");
    fx_place_player(&f, 20, JUMP_GROUND_ROW - PLAYER_H);
    fx_jump(&f);
    fx_step(&f, 8);
    check(f.st.score == SCORE_COIN && f.st.coin_count == 1,
          "a used block never pays a second time");
    fx_button(&f, CODE_JUMP, 0);

    /* The score stops at 9999 rather than wrapping. */
    f.st.score = SCORE_MAX;
    f.st.bkind[20] = BM_COIN;
    fx_place_player(&f, 20, JUMP_GROUND_ROW - PLAYER_H);
    fx_jump(&f);
    fx_step(&f, 8);
    check(f.st.score == SCORE_MAX, "the score caps at 9999");

    /* A pipe is ground that stands taller: solid from the side, walked on the
     * top of. */
    fx_flat(&f);
    jm_place_pipe(&f.st, 24, 4);
    check(f.st.surf[24] == JUMP_GROUND_ROW - 4 && f.st.surf[25] == JUMP_GROUND_ROW - 4 &&
          f.st.surf[26] == JUMP_GROUND_ROW - 4,
          "a pipe raises the ground under all three of its columns");
    fx_place_player(&f, 12, JUMP_GROUND_ROW - PLAYER_H);
    fx_button(&f, CODE_RIGHT, 1);
    fx_step(&f, 20);
    check((f.st.px >> 8) + PLAYER_W == 24, "a pipe stops the player from the side");
    fx_button(&f, CODE_RIGHT, 0);
    fx_place_player(&f, 24, JUMP_GROUND_ROW - 4 - PLAYER_H - 2);
    f.st.vy = 64;
    for (int t = 0; t < 20 && f.st.vy != 0; t++) fx_step(&f, 1);
    check((f.st.py >> 8) == JUMP_GROUND_ROW - 4 - PLAYER_H, "and the top is walked on");

    /* A coin in the air is collected by jumping into it. */
    fx_flat(&f);
    jm_place_coin(&f.st, 20, JUMP_GROUND_ROW - 8);
    fx_place_player(&f, 20, JUMP_GROUND_ROW - PLAYER_H);
    check(f.st.coins[0].state == CM_LIVE, "a placed coin is live");
    fx_button(&f, CODE_JUMP, 1);
    int taken = 0;
    for (int t = 0; t < 30 && !taken; t++) {
        fx_step(&f, 1);
        taken = f.st.score == SCORE_COIN;
    }
    check(taken && f.st.coins[0].state == CM_TAKEN && f.st.coin_count == 1,
          "a jump collects a floating coin");
    fx_button(&f, CODE_JUMP, 0);

    fx_close(&f);
}

/* ---- blobs --------------------------------------------------------------- */

static void test_blobs(void)
{
    printf("jumpman: a blob is stomped on the head and fatal anywhere else\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "the fixture opens"); return; }
    fx_flat(&f);
    fx_no_blobs(&f);
    fx_blob_slot_at(&f, 20, -1);

    /* Walking into it is a death: one life, and the player is back at the start
     * of the course. */
    check(f.st.lives == 3, "three lives");
    fx_place_player(&f, 16, JUMP_GROUND_ROW - PLAYER_H);
    fx_button(&f, CODE_RIGHT, 1);
    for (int t = 0; t < 40 && f.st.lives == 3; t++) fx_step(&f, 1);
    check(f.st.lives == 2, "walking into a blob costs a life");
    check(f.st.px >> 8 == PLAYER_START_X, "and the player is back at the start of the course");
    check(fx_alive_blobs(&f) == 1, "while the blob that did it is still there");
    check(fx_blob_col(&f, 0) == 20, "back where it started");
    fx_button(&f, CODE_RIGHT, 0);

    /* Standing beside it and letting it walk in is the same death. */
    fx_flat(&f);
    fx_no_blobs(&f);
    fx_blob_slot_at(&f, 24, -1);
    fx_place_player(&f, 20, JUMP_GROUND_ROW - PLAYER_H);
    for (int t = 0; t < 60 && f.st.lives == 3; t++) fx_step(&f, 1);
    check(f.st.lives == 2, "a blob that walks into the player is fatal too");

    /* Coming down on its head: the blob dies, the score pays, the player
     * bounces and keeps the life. */
    fx_flat(&f);
    fx_no_blobs(&f);
    fx_blob_slot_at(&f, 20, -1);
    f.st.blobs[0].dir = 0;  /* parked, so the case is the stomp and nothing else */
    fx_place_player(&f, 20, JUMP_GROUND_ROW - BLOB_H - 9);
    f.st.vy = 64;
    int bounced = 0;
    for (int t = 0; t < 30; t++) {
        fx_step(&f, 1);
        if (f.st.vy < 0) bounced = 1;
    }
    check(f.st.lives == 3, "a stomp costs no life");
    check(f.st.score == SCORE_STOMP, "a stomp pays");
    check(fx_alive_blobs(&f) == 0, "and the blob that was stood on is gone");
    check(bounced, "the player bounces off it");
    check(f.st.py >> 8 == JUMP_GROUND_ROW - PLAYER_H,
          "and lands on the ground again");

    /* A blob turns at what is not flat ground - a pit's edge and a pipe's
     * side - rather than walking off or through it. */
    fx_flat(&f);
    fx_no_blobs(&f);
    for (int x = 30; x < 34; x++) f.st.surf[x] = JM_NONE;
    fx_blob_slot_at(&f, 20, 1);
    fx_place_player(&f, 3, JUMP_GROUND_ROW - PLAYER_H);
    int over_pit = 0;
    for (int t = 0; t < 200; t++) {
        fx_step(&f, 1);
        const int bx = fx_blob_col(&f, 0);
        for (int i = 0; i < BLOB_W; i++)
            if (bx + i < 0 || bx + i >= JUMP_COLS || f.st.surf[bx + i] == JM_NONE) over_pit = 1;
    }
    check(!over_pit, "a blob never stands over a pit");
    check(fx_blob_col(&f, 0) + BLOB_W - 1 < 30, "and it turns at the pit's edge");

    fx_flat(&f);
    fx_no_blobs(&f);
    jm_place_pipe(&f.st, 40, 4);
    fx_blob_slot_at(&f, 30, 1);
    fx_place_player(&f, 3, JUMP_GROUND_ROW - PLAYER_H);
    for (int t = 0; t < 200; t++) fx_step(&f, 1);
    check(fx_blob_col(&f, 0) + BLOB_W - 1 < 40,
          "and a pipe is a wall it turns at as well");

    /* The blobs of a course are drawn: a step that leaves one at the camera
     * puts brown pixels on the panel where it stands. */
    fx_flat(&f);
    fx_no_blobs(&f);
    fx_blob_slot_at(&f, 10, -1);
    fx_place_player(&f, 2, JUMP_GROUND_ROW - PLAYER_H);
    fx_draw(&f);
    check(fx_blob_at(&f, 10, JUMP_GROUND_ROW - BLOB_H) &&
          fx_blob_at(&f, 10, JUMP_GROUND_ROW - 1),
          "a blob draws its 4x3 body where it stands");

    fx_close(&f);
}

/* ---- pits, lives, endings ------------------------------------------------ */

static void test_pits_and_lives(void)
{
    printf("jumpman: a pit is fatal, three deaths end the run\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "the fixture opens"); return; }
    fx_flat(&f);
    fx_no_blobs(&f);

    /* A pit the player cannot clear is three deaths: the game ends, and the
     * panel says so. */
    for (int x = 30; x < 40; x++) f.st.surf[x] = JM_NONE;
    fx_place_player(&f, 28, JUMP_GROUND_ROW - PLAYER_H);
    fx_button(&f, CODE_RIGHT, 1);
    fx_step(&f, 60);
    check(f.st.lives < 3, "falling into a pit costs a life");
    fx_step(&f, 600);
    check(f.st.status == JM_OVER && f.st.lives == 0, "and three of them end the game");
    check(ml_game_jumpman.is_over(&f.st), "is_over agrees the run is over");
    fx_button(&f, CODE_RIGHT, 0);

    /* The terminal board clears the course away: the score band and the ending
     * are all that is left of it. */
    f.st.score = 1234;
    fx_draw(&f);
    check(fx_lit_panel(&f, 0, 10, 17, 31) == 0 && fx_lit_panel(&f, 47, 10, 63, 31) == 0 &&
          fx_lit_panel(&f, 0, 28, 63, 31) == 0,
          "a finished run draws no course behind the ending");
    check(fx_lit_panel(&f, 18, 17, 46, 26) > 0, "the ending is drawn");
    check(fx_lit_panel(&f, 1, 0, 30, 9) > 0, "and the score band is still drawn");

    /* A death keeps the course: a block already bumped stays used and a coin
     * already taken stays taken. */
    fx_flat(&f);
    fx_no_blobs(&f);
    jm_place_block(&f.st, 20, 4, BRICK_ROW_HIGH, BM_COIN);
    jm_place_coin(&f.st, 30, JUMP_GROUND_ROW - 8);
    fx_place_player(&f, 20, JUMP_GROUND_ROW - PLAYER_H);
    fx_jump(&f);
    fx_step(&f, 8);
    fx_button(&f, CODE_JUMP, 0);
    check(f.st.bkind[20] == BM_USED, "a bumped block is used");
    f.st.coins[0].state = CM_TAKEN;
    const uint16_t score = f.st.score;
    f.st.lives = 2;
    jm_die(&f.st, NULL);
    check(f.st.bkind[20] == BM_USED, "a death leaves the block used");
    check(f.st.coins[0].state == CM_TAKEN, "and the coin taken");
    check(f.st.score == score, "and the score as it was");

    /* The flag ends the course: a bonus, the next course, and the player back
     * at the start of it. The third flag is the win. */
    fx_flat(&f);
    fx_no_blobs(&f);
    f.st.level = 0;
    f.st.score = 0;
    f.st.lives = 3;
    fx_place_player(&f, JUMP_FLAG - 6, JUMP_GROUND_ROW - PLAYER_H);
    fx_button(&f, CODE_RIGHT, 1);
    for (int t = 0; t < 40 && f.st.level == 0; t++) fx_step(&f, 1);
    check(f.st.level == 1 && f.st.score == SCORE_FLAG,
          "touching the flag pays and starts the next course");
    check(f.st.px >> 8 == PLAYER_START_X, "on the next course the player starts at the run-in");
    check(f.st.lives == 3, "with the lives it had");

    fx_no_blobs(&f);
    f.st.level = JUMP_LEVELS - 1;
    f.st.score = 0;
    fx_place_player(&f, JUMP_FLAG - 6, JUMP_GROUND_ROW - PLAYER_H);
    fx_step(&f, 12);
    check(f.st.status == JM_WON && ml_game_jumpman.is_over(&f.st),
          "the last course's flag is the win");
    check(f.st.score == SCORE_FLAG, "and it pays like the others");

    fx_draw(&f);
    check(fx_lit_panel(&f, 1, 0, 30, 9) > 0, "the win draws the score band");
    check(fx_lit_panel(&f, 18, 17, 46, 26) > 0, "and says WIN");

    fx_button(&f, CODE_RIGHT, 0);
    fx_close(&f);
}

/* ---- the wire ------------------------------------------------------------ */

static void test_snapshot(void)
{
    printf("jumpman: a snapshot is all or nothing\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "the fixture opens"); return; }

    fx_place_player(&f, 40, JUMP_GROUND_ROW - PLAYER_H - 4);
    fx_step(&f, 5);
    jumpman_state copy;
    memcpy(&copy, &f.st, sizeof(copy));

    uint8_t buf[ML_SNAPSHOT_MAX];
    size_t len = 0;
    check(!ml_game_jumpman.snapshot(&f.st, buf, sizeof(f.st) - 1, &len),
          "a buffer one byte short is refused");
    check(ml_game_jumpman.snapshot(&f.st, buf, sizeof(f.st), &len) &&
          len == sizeof(f.st),
          "a buffer of the exact size takes the state");

    fx_step(&f, 9);
    check(memcmp(&f.st, &copy, sizeof(copy)) != 0, "the state moves on");
    ml_game_jumpman.restore(&f.st, buf, len);
    check(memcmp(&f.st, &copy, sizeof(copy)) == 0, "and restoring puts it back");

    fx_step(&f, 3);
    memcpy(&copy, &f.st, sizeof(copy));
    ml_game_jumpman.restore(&f.st, buf, len - 1);
    check(memcmp(&f.st, &copy, sizeof(copy)) == 0,
          "a truncated snapshot leaves the state alone");

    fx_close(&f);
}

int main(void)
{
    test_declared_contract();
    test_course_is_deterministic();
    test_run_and_the_jump();
    test_blocks();
    test_blobs();
    test_pits_and_lives();
    test_snapshot();

    printf("jumpman: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
