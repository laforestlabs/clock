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
 * The field is a fixed 10x16 logical board drawn at TETRIS_CELL physical pixels
 * a cell and centred on the panel, so a field cell's pixel rectangle starts at
 * (ox + col*TETRIS_CELL, oy + row*TETRIS_CELL). On the 64x32 Mini panel that is
 * 20x32 pixels at (22,0) - the whole panel height - with the frame one pixel
 * outside it; larger panels keep the same field and blocks with bigger margins.
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

/* The four shipped panels, with the field origin each must produce: the field
 * is always 20x32 pixels, centred. The first entry is the Mini panel. */
typedef struct { int w, h, ox, oy; } panel_size;

static const panel_size PANELS[] = {
    { 64,  32,  22,  0 },
    { 64,  64,  22, 16 },
    { 128, 64,  54, 16 },
    { 128, 128, 54, 48 },
};
#define PANEL_COUNT ((int)(sizeof(PANELS) / sizeof(PANELS[0])))

typedef struct {
    tetris_state st;
    ml_game_cfg  cfg;
    ml_view      view;
    ml_canvas    cv;
} fixture;

static bool fx_open(fixture *f, int panel_w, int panel_h)
{
    memset(f, 0, sizeof(*f));
    f->cfg.seed = 1;
    f->cfg.panel_w = panel_w;
    f->cfg.panel_h = panel_h;
    if (!ml_canvas_init(&f->cv, panel_w, panel_h, NULL)) return false;
    ml_view_compute(&f->view, ml_game_tetris.pref_w, ml_game_tetris.pref_h,
                    ml_game_tetris.fit, panel_w, panel_h);
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

static int fx_same(ml_rgb a, ml_rgb b)
{
    return a.r == b.r && a.g == b.g && a.b == b.b;
}

/* Whether every pixel of the field cell at (col,row) holds color: a cell's
 * rectangle starts at (ox + col*TETRIS_CELL, oy + row*TETRIS_CELL). A renderer
 * that still painted one pixel per cell would pass a top-left-only sample, so
 * the checks read whole rectangles. */
static int fx_cell_solid(const fixture *f, int col, int row, ml_rgb color)
{
    for (int dy = 0; dy < TETRIS_CELL; dy++) {
        for (int dx = 0; dx < TETRIS_CELL; dx++) {
            const ml_rgb p = ml_canvas_get(&f->cv,
                                           f->st.ox + col * TETRIS_CELL + dx,
                                           f->st.oy + row * TETRIS_CELL + dy);
            if (!fx_same(p, color)) return 0;
        }
    }
    return 1;
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

static void test_empty_field(int pw, int ph)
{
    printf("tetris: the preview marks where the piece will land (%dx%d)\n", pw, ph);
    fixture f;
    if (!fx_open(&f, pw, ph)) { check(0, "fixture opens"); return; }

    const int gy = fx_landing(&f);
    const ml_rgb pc = tetris_piece_color(f.st.piece);
    const ml_rgb dim = fx_dim(&f);
    fx_draw(&f);

    check(gy > f.st.py + 3, "the dealt piece has room to fall and be seen falling");

    /* Every cell of every column the piece occupies is exactly one of three
     * things: the piece itself, the copy of it at its landing row, or empty.
     * That is what "the preview is only where the piece is going" means, and it
     * covers the column of a piece cell whose own landing cell sits under a
     * different row of the same piece. Each cell is read as a whole rectangle,
     * so a renderer still painting one pixel per cell cannot pass. */
    int preview_ok = 1, piece_ok = 1, clear_ok = 1, cells = 0, dims = 0;
    for (int col = 0; col < 4; col++) {
        int used = 0;
        for (int row = 0; row < 4; row++) if (fx_cell_lit(&f, col, row)) used = 1;
        if (!used) continue;
        for (int r = 0; r < f.st.bh; r++) {
            const int dr = r - f.st.py, gr = r - gy;
            const int is_piece = dr >= 0 && dr < 4 && fx_cell_lit(&f, col, dr);
            const int is_landing = gr >= 0 && gr < 4 && fx_cell_lit(&f, col, gr);
            if (is_piece) {
                cells++;
                if (!fx_cell_solid(&f, f.st.px + col, r, pc)) piece_ok = 0;
            } else if (is_landing) {
                dims++;
                if (!fx_cell_solid(&f, f.st.px + col, r, dim)) preview_ok = 0;
            } else if (!fx_cell_solid(&f, f.st.px + col, r, ml_black)) {
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

static void test_landed_piece(int pw, int ph)
{
    printf("tetris: a piece already on the floor shows no preview (%dx%d)\n", pw, ph);
    fixture f;
    if (!fx_open(&f, pw, ph)) { check(0, "fixture opens"); return; }

    /* Drop the piece onto the floor by hand: one row lower and it collides, so
     * the preview would sit exactly under it. */
    f.st.py = (int16_t)fx_landing(&f);
    check(tetris_collide(&f.st, f.st.mask, f.st.px, f.st.py + 1),
          "the piece cannot move down from here");

    const ml_rgb dim = fx_dim(&f);
    const ml_rgb pc = tetris_piece_color(f.st.piece);
    fx_draw(&f);

    /* Read the whole field rectangle, not one pixel a cell: no dim pixel
     * anywhere, and the piece in its full colour over every pixel of its cells. */
    int no_dim = 1;
    for (int y = f.st.oy; y < f.st.oy + f.st.bh * TETRIS_CELL; y++)
        for (int x = f.st.ox; x < f.st.ox + f.st.bw * TETRIS_CELL; x++)
            if (fx_same(ml_canvas_get(&f.cv, x, y), dim)) no_dim = 0;

    int piece_ok = 1;
    for (int row = 0; row < 4; row++) {
        for (int col = 0; col < 4; col++) {
            if (!fx_cell_lit(&f, col, row)) continue;
            if (!fx_cell_solid(&f, f.st.px + col, f.st.py + row, pc)) piece_ok = 0;
        }
    }
    check(no_dim, "the field holds no dim pixel at all");
    check(piece_ok, "and the piece is drawn in its full colour, not a dim one");

    fx_close(&f);
}

/* ---- the preview follows the stack -------------------------------------- */

static void test_follows_stack(int pw, int ph)
{
    printf("tetris: the preview lands on the stack, not on the floor (%dx%d)\n",
           pw, ph);
    fixture f;
    if (!fx_open(&f, pw, ph)) { check(0, "fixture opens"); return; }

    /* A settled cell under the piece's leftmost occupied column, high enough
     * that the piece cannot reach the floor: the piece must come to rest on it. */
    int bc = -1, br = -1;
    for (int col = 0; col < 4 && bc < 0; col++)
        for (int row = 3; row >= 0; row--)
            if (fx_cell_lit(&f, col, row)) { bc = col; br = row; break; }

    const int stack_row = f.st.bh / 2;
    const int bcol = f.st.px + bc;
    f.st.board[stack_row] |= 1u << bcol;
    const int gy = fx_landing(&f);

    check(gy + br == stack_row - 1, "the piece comes to rest on the settled cell");

    const ml_rgb dim = fx_dim(&f);
    const ml_rgb settled = ML_RGB(90, 100, 120);
    fx_draw(&f);
    check(fx_cell_solid(&f, bcol, stack_row - 1, dim),
          "the preview cell sits directly on the stack");
    check(fx_cell_solid(&f, bcol, stack_row, settled),
          "and the stack cell under it is drawn as settled");
    check(gy < f.st.bh - 4, "which is above the floor, not on it");

    fx_close(&f);
}

/* ---- the classic ten-cell line clear ------------------------------------ */

/* Six settled cells plus the four of a horizontal I complete the field's bottom
 * row edge to edge: the field is ten cells wide, so ten cells clear it. */
static void test_line_clear(int pw, int ph)
{
    printf("tetris: ten cells across the field clear the bottom row (%dx%d)\n", pw, ph);
    fixture f;
    if (!fx_open(&f, pw, ph)) { check(0, "fixture opens"); return; }

    const int row = f.st.bh - 1;
    f.st.board[row] = 0x3Fu;
    f.st.piece = 0;
    f.st.mask = SHAPES[0];
    f.st.px = 6;
    f.st.py = (int16_t)(row - 2);
    f.st.next_piece = 1;
    f.st.down_active = 1;

    ml_game_tetris.update(&f.st, NULL);

    check(f.st.lines == 1, "the row clears");
    check(f.st.score == 100, "and scores a single line");
    int empty = 1;
    for (int r = 0; r < f.st.bh; r++) if (f.st.board[r]) empty = 0;
    check(empty, "and leaves no settled cell behind");
    check(f.st.status == TETRIS_PLAYING && f.st.py == 0,
          "with the next piece falling from the top");

    /* The cleared row is gone from the frame too, not just from the board. */
    const ml_rgb settled = ML_RGB(90, 100, 120);
    fx_draw(&f);
    int cleared = 1;
    for (int col = 0; col < f.st.bw; col++)
        if (fx_cell_solid(&f, col, row, settled)) cleared = 0;
    check(cleared, "and no settled pixel survives in the bottom row of the frame");

    fx_close(&f);
}

/* ---- the floor is the field's last row ---------------------------------- */

static void test_floor(int pw, int ph)
{
    printf("tetris: the floor is the field's last row (%dx%d)\n", pw, ph);
    fixture f;
    if (!fx_open(&f, pw, ph)) { check(0, "fixture opens"); return; }

    f.st.piece = 0;
    f.st.mask = SHAPES[0];
    f.st.px = 6;
    f.st.py = (int16_t)(f.st.bh - 3);   /* the I's occupied row is the last one */
    check(fx_landing(&f) == f.st.py,
          "a horizontal I on the field's last row cannot fall further");
    check(f.st.py + 2 == f.st.bh - 1, "which is row 15, not a panel-sized floor");

    /* Rendered, both pixel rows of the last field row carry the piece, so the
     * clipped frame has not eaten into the playable area. */
    const ml_rgb pc = tetris_piece_color(f.st.piece);
    const int y0 = f.st.oy + (f.st.bh - 1) * TETRIS_CELL;
    fx_draw(&f);
    int solid = 1;
    for (int col = 6; col < 10; col++) {
        if (!fx_cell_solid(&f, col, f.st.bh - 1, pc)) solid = 0;
        for (int dy = 0; dy < TETRIS_CELL; dy++)
            if (!fx_same(ml_canvas_get(&f.cv, f.st.ox + col * TETRIS_CELL,
                                       y0 + dy), pc))
                solid = 0;
    }
    check(solid, "the bottom row of cells paints both of its pixel rows");
    check(y0 + TETRIS_CELL <= f.cv.h, "and the field's last pixel row is on the panel");
    if (ph == PANELS[0].h)  /* Mini: the field is the whole panel height */
        check(f.st.oy + f.st.bh * TETRIS_CELL == ph,
              "on Mini the frame's bottom edge falls off the panel, not over the "
              "last row");

    fx_close(&f);
}

/* ---- top-out at the field's own dimensions ------------------------------ */

static void test_topout(int pw, int ph)
{
    printf("tetris: a spawn onto the stack tops out (%dx%d)\n", pw, ph);
    fixture f;
    if (!fx_open(&f, pw, ph)) { check(0, "fixture opens"); return; }

    /* A settled cell at (4,1) while an I locks along the floor without clearing
     * a row: the next piece is the O, which spawns across columns 4 and 5 on row
     * 1 and collides with it at once. */
    f.st.board[1] = 1u << 4;
    f.st.piece = 0;
    f.st.mask = SHAPES[0];
    f.st.px = 6;
    f.st.py = (int16_t)(f.st.bh - 3);
    f.st.next_piece = 1;
    f.st.down_active = 1;

    ml_game_tetris.update(&f.st, NULL);

    check(f.st.lines == 0, "the I locks without clearing a row");
    check(ml_game_tetris.is_over(&f.st), "and the blocked spawn is a top-out");

    fx_close(&f);
}

/* ---- the fixed field geometry at every panel size ----------------------- */

/* The expected origin, size and cell scale come from the panel table, not from
 * the production geometry, so a board that silently grew or shrank with the
 * panel would fail here. */
static void test_geometry(const panel_size *p)
{
    printf("tetris: the fixed field is centred at 2x2 pixels (%dx%d)\n", p->w, p->h);
    fixture f;
    if (!fx_open(&f, p->w, p->h)) { check(0, "fixture opens"); return; }

    check(f.st.bw == TETRIS_BW && f.st.bh == TETRIS_BH,
          "the logical board is 10x16 cells");
    check(f.st.ox == p->ox && f.st.oy == p->oy,
          "and the 20x32-pixel field sits where the table says");

    /* A known piece on a known cell, so the pixel grid is read in the table's
     * coordinates rather than in whatever the seed dealt. */
    f.st.piece = 0;              /* I: cyan, its occupied row is row 2 of the box */
    f.st.mask = SHAPES[0];
    f.st.px = 2;
    f.st.py = 3;
    f.st.next_piece = 1;         /* O: yellow, a colour the piece never uses */
    const ml_rgb pc = tetris_piece_color(f.st.piece);
    const ml_rgb dim = fx_dim(&f);
    const ml_rgb npc = tetris_piece_color(f.st.next_piece);
    const int gy = fx_landing(&f);
    const int fw = f.st.bw * TETRIS_CELL, fh = f.st.bh * TETRIS_CELL;
    const int cell_px = TETRIS_CELL * TETRIS_CELL;
    fx_draw(&f);

    /* The piece and its preview are four cells each, each cell a whole 2x2
     * rectangle: exactly 16 pixels apiece inside the field and nothing stray. */
    int pc_px = 0, dim_px = 0;
    for (int y = f.st.oy; y < f.st.oy + fh; y++) {
        for (int x = f.st.ox; x < f.st.ox + fw; x++) {
            const ml_rgb c = ml_canvas_get(&f.cv, x, y);
            if (fx_same(c, pc)) pc_px++;
            else if (fx_same(c, dim)) dim_px++;
        }
    }
    check(pc_px == 4 * cell_px, "the piece paints exactly four 2x2 cell rectangles");
    check(dim_px == 4 * cell_px, "and its preview the same four at its landing row");
    check(fx_cell_solid(&f, f.st.px, f.st.py + 2, pc) &&
          fx_cell_solid(&f, f.st.px + 3, f.st.py + 2, pc) &&
          fx_cell_solid(&f, f.st.px, gy + 2, dim),
          "at the cells the table's origin and cell size predict");

    /* The frame is one pixel outside the field on every side and holds no
     * playable cell. */
    int frame_ok = 1;
    for (int y = f.st.oy - 1; y <= f.st.oy + fh; y++) {
        for (int k = 0; k < 2; k++) {
            const int x = k ? f.st.ox + fw : f.st.ox - 1;
            if (x < 0 || x >= f.cv.w || y < 0 || y >= f.cv.h) continue;
            const ml_rgb c = ml_canvas_get(&f.cv, x, y);
            if (fx_same(c, pc) || fx_same(c, dim) || fx_same(c, npc)) frame_ok = 0;
        }
    }
    check(frame_ok, "and the frame column stays outside the playable cells");

    /* The next-piece preview is a whole 8x8 box clear of the field, drawn from
     * the same 2x2 cells. */
    const int pvx = f.st.ox + fw + 2;
    const int pvy = f.st.oy + (fh - 4 * TETRIS_CELL) / 2;
    int npc_px = 0, npc_stray = 0;
    for (int y = 0; y < f.cv.h; y++) {
        for (int x = 0; x < f.cv.w; x++) {
            if (!fx_same(ml_canvas_get(&f.cv, x, y), npc)) continue;
            npc_px++;
            if (x < pvx || x >= pvx + 4 * TETRIS_CELL ||
                y < pvy || y >= pvy + 4 * TETRIS_CELL) npc_stray = 1;
        }
    }
    check(pvx > f.st.ox + fw, "the preview box starts clear of the field");
    check(npc_px == 4 * cell_px, "and is four 2x2 cells");
    check(!npc_stray, "all of them inside its own 8x8 box");

    fx_close(&f);
}

/* ---- a long score stays in its margin ----------------------------------- */

static void test_score_clip(const panel_size *p)
{
    printf("tetris: a five-digit score stays left of the field (%dx%d)\n", p->w, p->h);
    fixture f;
    if (!fx_open(&f, p->w, p->h)) { check(0, "fixture opens"); return; }

    ml_canvas plain;
    if (!ml_canvas_init(&plain, p->w, p->h, NULL)) { check(0, "canvas opens"); return; }

    f.st.score = 0;
    fx_draw(&f);
    memcpy(plain.px, f.cv.px, (size_t)p->w * p->h * sizeof(ml_rgb));

    f.st.score = 12345;
    fx_draw(&f);

    /* Everything at or right of the frame column is unchanged: the score was
     * bounded by its margin instead of painting over the board. */
    int intact = 1, drawn = 0;
    for (int y = 0; y < p->h; y++) {
        for (int x = 0; x < p->w; x++) {
            const int same = fx_same(ml_canvas_get(&f.cv, x, y),
                                     ml_canvas_get(&plain, x, y));
            if (x >= f.st.ox - 1) { if (!same) intact = 0; }
            else if (!same) drawn = 1;
        }
    }
    check(intact, "no score pixel reaches the field or its frame");
    check(drawn, "while the digits are drawn in the margin");

    ml_canvas_free(&plain);
    fx_close(&f);
}

/* ---- draw stays pure ---------------------------------------------------- */

static void test_draw_is_pure(int pw, int ph)
{
    printf("tetris: the preview adds no state to the frame (%dx%d)\n", pw, ph);
    fixture f;
    if (!fx_open(&f, pw, ph)) { check(0, "fixture opens"); return; }

    ml_canvas first;
    if (!ml_canvas_init(&first, pw, ph, NULL)) { check(0, "canvas opens"); return; }

    fx_draw(&f);
    memcpy(first.px, f.cv.px, (size_t)pw * ph * sizeof(ml_rgb));
    const tetris_state before = f.st;
    fx_draw(&f);

    int same = 1;
    for (int y = 0; y < ph && same; y++)
        for (int x = 0; x < pw; x++)
            if (!fx_same(ml_canvas_get(&f.cv, x, y), ml_canvas_get(&first, x, y))) { same = 0; break; }
    check(same, "two draws of one state are the same frame");
    check(memcmp(&before, &f.st, sizeof(before)) == 0, "and draw left the state alone");

    ml_canvas_free(&first);
    fx_close(&f);
}

int main(void)
{
    /* The ghost cases run with and without a vertical margin, since a board
     * centred above row 0 and one flush with the panel edge draw at different
     * origins. */
    test_empty_field(PANELS[0].w, PANELS[0].h);
    test_empty_field(PANELS[1].w, PANELS[1].h);
    test_landed_piece(PANELS[0].w, PANELS[0].h);
    test_landed_piece(PANELS[1].w, PANELS[1].h);
    test_follows_stack(PANELS[0].w, PANELS[0].h);

    for (int i = 0; i < PANEL_COUNT; i++) {
        test_geometry(&PANELS[i]);
        test_line_clear(PANELS[i].w, PANELS[i].h);
        test_floor(PANELS[i].w, PANELS[i].h);
        test_topout(PANELS[i].w, PANELS[i].h);
    }

    test_score_clip(&PANELS[1]);
    test_draw_is_pure(PANELS[0].w, PANELS[0].h);

    printf("\n%d checks, %d failures\n", g_checks, g_failures);
    if (g_failures) { printf("FAIL\n"); return 1; }
    printf("PASS\n");
    return 0;
}
