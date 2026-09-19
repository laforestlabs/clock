/*
 * tetris_preview_test.c - regression test for the landing preview.
 *
 * What it pins down: the player could not see where the falling piece was going
 * to settle, so on a board with any stack at all the piece's destination was
 * guesswork. draw now paints the cells the piece would occupy if nothing moved
 * it, a third of the piece's own colour so the falling piece still reads first.
 *
 * Observable: the drawn field. The fixture includes the tetris translation unit
 * and provides the one ctx service the game calls (ml_ctx_rng) itself, so a test
 * can deal a known piece and then place the piece, the stack and the floor where
 * it needs them; the Makefile links it with neither the runtime (whose
 * ml_ctx_rng this file replaces) nor the game's own object.
 *
 * The field is the middle 32 columns of the 64x32 panel (ox = 16, oy = 0,
 * bw = 32, bh = 32), so a field cell's panel coordinate is (ox + col, row). The
 * frame the game paints around the field is at columns 15 and 48, outside it.
 * The landing row the test expects is computed here from tetris_collide,
 * independently of the game's own helper: the two agreeing on where the piece
 * lands is the whole point.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "../examples/tetris/game_tetris.c"

/* The game reaches the runtime's PRNG through ctx for the piece order. The
 * fixture owns it instead of opening a session, so the dealt piece is fixed. */
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
    tetris_state st;
    ml_game_cfg  cfg;
    ml_view      view;
    ml_canvas    cv;
} fixture;

static bool fx_open(fixture *f)
{
    memset(f, 0, sizeof(*f));
    f->cfg.seed = 1;
    f->cfg.panel_w = PANEL_W;
    f->cfg.panel_h = PANEL_H;
    if (!ml_canvas_init(&f->cv, PANEL_W, PANEL_H, NULL)) return false;
    ml_view_compute(&f->view, ml_game_tetris.pref_w, ml_game_tetris.pref_h,
                    ml_game_tetris.fit, PANEL_W, PANEL_H);
    fx_rng_state = 1u;
    ml_game_tetris.init(&f->st, &f->cfg, NULL);
    ml_game_tetris.reset(&f->st, NULL);
    return true;
}

static void fx_close(fixture *f)
{
    ml_canvas_free(&f->cv);
}

static void fx_draw(fixture *f)
{
    ml_game_tetris.draw(&f->st, &f->view, &f->cv, NULL);
}

static ml_rgb fx_cell(const fixture *f, int col, int row)
{
    return ml_canvas_get(&f->cv, f->st.ox + col, f->st.oy + row);
}

static int fx_same(ml_rgb a, ml_rgb b)
{
    return a.r == b.r && a.g == b.g && a.b == b.b;
}

static ml_rgb fx_dim(const fixture *f)
{
    const ml_rgb pc = tetris_piece_color(f->st.piece);
    return ML_RGB(pc.r / 3, pc.g / 3, pc.b / 3);
}

/* Where the test says the piece lands, worked out from the collision rule alone. */
static int fx_landing(const fixture *f)
{
    int gy = f->st.py;
    while (!tetris_collide(&f->st, f->st.mask, f->st.px, gy + 1)) gy++;
    return gy;
}

static bool fx_cell_lit(const fixture *f, int col, int row)
{
    return (f->st.mask & (1u << (row * 4 + col))) != 0;
}

/* ---- the preview on an empty field -------------------------------------- */

static void test_empty_field(void)
{
    printf("tetris: the preview marks where the piece will land\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }

    const int gy = fx_landing(&f);
    const ml_rgb pc = tetris_piece_color(f.st.piece);
    const ml_rgb dim = fx_dim(&f);
    fx_draw(&f);

    check(gy > f.st.py + 3, "the dealt piece has room to fall and be seen falling");

    /* Every cell of every column the piece occupies is exactly one of three
     * things: the piece itself, the copy of it at its landing row, or empty.
     * That is what "the preview is only where the piece is going" means, and it
     * covers the column of a piece cell whose own landing cell sits under a
     * different row of the same piece. */
    int preview_ok = 1, piece_ok = 1, clear_ok = 1, cells = 0, dims = 0;
    for (int col = 0; col < 4; col++) {
        int used = 0;
        for (int row = 0; row < 4; row++) if (fx_cell_lit(&f, col, row)) used = 1;
        if (!used) continue;
        for (int r = 0; r < f.st.bh; r++) {
            const int dr = r - f.st.py, gr = r - gy;
            const int is_piece = dr >= 0 && dr < 4 && fx_cell_lit(&f, col, dr);
            const int is_landing = gr >= 0 && gr < 4 && fx_cell_lit(&f, col, gr);
            const ml_rgb p = fx_cell(&f, f.st.px + col, r);
            if (is_piece) {
                cells++;
                if (!fx_same(p, pc)) piece_ok = 0;
            } else if (is_landing) {
                dims++;
                if (!fx_same(p, dim)) preview_ok = 0;
            } else if (p.r || p.g || p.b) {
                clear_ok = 0;
            }
        }
    }
    check(cells == 4, "the dealt piece is four cells");
    check(dims == 4, "and the preview is the same four cells at its landing row");
    check(piece_ok, "the falling piece is drawn in its full colour");
    check(preview_ok, "and each preview cell is a third of that colour");
    check(clear_ok, "with nothing drawn anywhere else in those columns");

    fx_close(&f);
}

/* ---- a landed piece has no preview -------------------------------------- */

static void test_landed_piece(void)
{
    printf("tetris: a piece already on the floor shows no preview\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }

    /* Drop the piece onto the floor by hand: one row lower and it collides, so
     * the preview would sit exactly under it. */
    f.st.py = (int16_t)fx_landing(&f);
    check(tetris_collide(&f.st, f.st.mask, f.st.px, f.st.py + 1),
          "the piece cannot move down from here");

    const ml_rgb dim = fx_dim(&f);
    const ml_rgb pc = tetris_piece_color(f.st.piece);
    fx_draw(&f);

    int no_dim = 1, piece_ok = 1;
    for (int row = 0; row < f.st.bh; row++) {
        for (int col = 0; col < f.st.bw; col++) {
            if (fx_same(fx_cell(&f, col, row), dim)) no_dim = 0;
        }
    }
    for (int row = 0; row < 4; row++) {
        for (int col = 0; col < 4; col++) {
            if (!fx_cell_lit(&f, col, row)) continue;
            if (!fx_same(fx_cell(&f, f.st.px + col, f.st.py + row), pc)) piece_ok = 0;
        }
    }
    check(no_dim, "the field holds no dim pixel at all");
    check(piece_ok, "and the piece is drawn in its full colour, not a dim one");

    fx_close(&f);
}

/* ---- the preview follows the stack -------------------------------------- */

static void test_follows_stack(void)
{
    printf("tetris: the preview lands on the stack, not on the floor\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }

    /* A settled cell under the piece's leftmost occupied column, high enough
     * that the piece cannot reach the floor: the piece must come to rest on it. */
    int bc = -1, br = -1;
    for (int col = 0; col < 4 && bc < 0; col++)
        for (int row = 3; row >= 0; row--)
            if (fx_cell_lit(&f, col, row)) { bc = col; br = row; break; }

    const int stack_row = 20;
    const int bcol = f.st.px + bc;
    f.st.board[stack_row] |= 1u << bcol;
    const int gy = fx_landing(&f);

    check(gy + br == stack_row - 1, "the piece comes to rest on the settled cell");

    const ml_rgb dim = fx_dim(&f);
    const ml_rgb settled = ML_RGB(90, 100, 120);
    fx_draw(&f);
    check(fx_same(fx_cell(&f, bcol, stack_row - 1), dim),
          "the preview cell sits directly on the stack");
    check(fx_same(fx_cell(&f, bcol, stack_row), settled),
          "and the stack cell under it is drawn as settled");
    check(gy < f.st.bh - 4, "which is above the floor, not on it");

    fx_close(&f);
}

/* ---- draw stays pure ---------------------------------------------------- */

static void test_draw_is_pure(void)
{
    printf("tetris: the preview adds no state to the frame\n");
    fixture f;
    if (!fx_open(&f)) { check(0, "fixture opens"); return; }

    ml_canvas first;
    if (!ml_canvas_init(&first, PANEL_W, PANEL_H, NULL)) { check(0, "canvas opens"); return; }

    fx_draw(&f);
    memcpy(first.px, f.cv.px, (size_t)PANEL_W * PANEL_H * sizeof(ml_rgb));
    const tetris_state before = f.st;
    fx_draw(&f);

    int same = 1;
    for (int y = 0; y < PANEL_H && same; y++)
        for (int x = 0; x < PANEL_W; x++)
            if (!fx_same(ml_canvas_get(&f.cv, x, y), ml_canvas_get(&first, x, y))) { same = 0; break; }
    check(same, "two draws of one state are the same frame");
    check(memcmp(&before, &f.st, sizeof(before)) == 0, "and draw left the state alone");

    ml_canvas_free(&first);
    fx_close(&f);
}

int main(void)
{
    test_empty_field();
    test_landed_piece();
    test_follows_stack();
    test_draw_is_pure();

    printf("\n%d checks, %d failures\n", g_checks, g_failures);
    if (g_failures) { printf("FAIL\n"); return 1; }
    printf("PASS\n");
    return 0;
}
