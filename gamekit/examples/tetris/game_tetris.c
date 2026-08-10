/*
 * game_tetris.c - the third game: falling blocks on any panel.
 *
 * The puzzle game, and the first whose controls are semantic rather than
 * spatial: Up rotates, Down hard-drops, Left/Right move. Same input surface
 * as snake (four direction buttons), different meaning, which is exactly the
 * contract's point: the controls are declared by the game, and the controller
 * client renders them as labels.
 *
 * The field is capped at 32 wide by 64 tall, so a row is exactly one uint32
 * and the whole board is 256 bytes of state, well under the 1024-byte
 * snapshot cap. On panels larger than the field, the board sits centred with
 * a dim frame around it; on a 64x32 the field is the whole panel. Piece
 * order comes from the session PRNG in reset and on lock, never from a wall
 * clock, so a recorded input stream replays the exact same stack.
 */
#include <stdio.h>
#include <string.h>

#include "mirror/font.h"
#include "mirror/game.h"
#include "mirror/gamerun.h"

#define TETRIS_BW 32
#define TETRIS_BH 64

enum { TETRIS_PLAYING = 0, TETRIS_OVER = 1 };

typedef struct {
    int16_t  panel_w, panel_h;
    uint8_t  bw, bh;           /* actual field dims, <= the caps */
    uint8_t  ox, oy;           /* field origin on the panel */
    uint8_t  piece;            /* 0..6 */
    uint16_t mask;             /* current piece as a 4x4 bitmask, rotated */
    int16_t  px, py;           /* piece top-left in field coords */
    uint8_t  held_l, held_r;
    uint8_t  fall_ctr;
    uint8_t  level;
    uint8_t  status;
    uint8_t  next_piece;
    uint16_t score;
    uint16_t lines;
    uint8_t  pad[2];
    uint32_t board[TETRIS_BH]; /* 1 bit per cell, bw wide */
} tetris_state;

typedef char tetris_state_fits[(sizeof(tetris_state) <= ML_SNAPSHOT_MAX) ? 1 : -1];

/* base orientations, row 0 = top of the 4x4 box: I O T S Z J L */
static const uint16_t SHAPES[7] = {
    0x0F00u, 0x0660u, 0x0E40u, 0x06C0u,
    0x0C60u, 0x08E0u, 0x02E0u,
};

/* rotate a 4x4 mask 90 degrees clockwise, pure integer */
static uint16_t rot_cw(uint16_t m)
{
    uint16_t r = 0;
    for (int row = 0; row < 4; row++)
        for (int col = 0; col < 4; col++)
            if (m & (1u << (row * 4 + col)))
                r |= (uint16_t)(1u << (col * 4 + (3 - row)));
    return r;
}

static bool tetris_collide(const tetris_state *s, uint16_t mask, int px, int py)
{
    for (int row = 0; row < 4; row++) {
        for (int col = 0; col < 4; col++) {
            if (!(mask & (1u << (row * 4 + col)))) continue;
            int br = py + row, bc = px + col;
            if (bc < 0 || bc >= s->bw) return true;
            if (br < 0) continue;                 /* above the field: legal */
            if (br >= s->bh) return true;         /* below the floor */
            if (s->board[br] & (1u << bc)) return true;
        }
    }
    return false;
}

static void tetris_lock(tetris_state *s, ml_game_ctx *ctx)
{
    for (int row = 0; row < 4; row++) {
        for (int col = 0; col < 4; col++) {
            if (!(s->mask & (1u << (row * 4 + col)))) continue;
            int br = s->py + row, bc = s->px + col;
            if (br >= 0 && br < s->bh) s->board[br] |= (1u << bc);
        }
    }

    /* compact the stack past cleared rows */
    uint32_t full = (s->bw == 32) ? 0xFFFFFFFFu : ((1u << s->bw) - 1u);
    int dst = s->bh - 1;
    int cleared = 0;
    for (int r = s->bh - 1; r >= 0; r--) {
        if (s->board[r] == full) cleared++;
        else { if (dst != r) s->board[dst] = s->board[r]; dst--; }
    }
    for (int r = dst; r >= 0; r--) s->board[r] = 0;

    static const int LINE_SCORE[5] = { 0, 100, 300, 500, 800 };
    if (cleared > 4) cleared = 4;
    s->score += (uint16_t)(LINE_SCORE[cleared] * (s->level + 1));
    s->lines += (uint16_t)cleared;
    s->level = (uint8_t)(s->lines / 10);
    if (s->level > 15) s->level = 15;

    /* spawn the next piece; a collision at spawn is the top-out */
    s->piece = s->next_piece;
    s->next_piece = (uint8_t)(ml_ctx_rng(ctx) % 7);
    s->mask = SHAPES[s->piece];
    s->px = (int16_t)((s->bw - 4) / 2);
    s->py = 0;
    s->fall_ctr = 0;
    if (tetris_collide(s, s->mask, s->px, s->py)) s->status = TETRIS_OVER;
}

static void tetris_rotate(tetris_state *s)
{
    uint16_t nm = rot_cw(s->mask);
    /* wall kicks: try the rotation at a few horizontal offsets */
    const int kicks[5] = { 0, -1, 1, -2, 2 };
    for (int i = 0; i < 5; i++) {
        int kx = s->px + kicks[i];
        if (kx < -3 || kx >= s->bw) continue;
        if (!tetris_collide(s, nm, kx, s->py)) {
            s->mask = nm;
            s->px = (int16_t)kx;
            return;
        }
    }
}

static void tetris_drop(tetris_state *s, ml_game_ctx *ctx)
{
    while (!tetris_collide(s, s->mask, s->px, s->py + 1)) {
        s->py++;
        s->score += 2;
    }
    tetris_lock(s, ctx);
}

static void tetris_init(void *state, const ml_game_cfg *cfg, ml_game_ctx *ctx)
{
    (void)ctx;
    tetris_state *s = state;
    memset(s, 0, sizeof(*s));
    s->panel_w = (int16_t)cfg->panel_w;
    s->panel_h = (int16_t)cfg->panel_h;
    s->bw = (uint8_t)(cfg->panel_w < TETRIS_BW ? cfg->panel_w : TETRIS_BW);
    s->bh = (uint8_t)(cfg->panel_h < TETRIS_BH ? cfg->panel_h : TETRIS_BH);
    s->ox = (uint8_t)((cfg->panel_w - s->bw) / 2);
    s->oy = (uint8_t)((cfg->panel_h - s->bh) / 2);
}

static void tetris_reset(void *state, ml_game_ctx *ctx)
{
    tetris_state *s = state;
    memset(s->board, 0, sizeof(s->board));
    s->score = 0;
    s->lines = 0;
    s->level = 0;
    s->fall_ctr = 0;
    s->held_l = 0;
    s->held_r = 0;
    s->status = TETRIS_PLAYING;
    s->piece = (uint8_t)(ml_ctx_rng(ctx) % 7);
    s->next_piece = (uint8_t)(ml_ctx_rng(ctx) % 7);
    s->mask = SHAPES[s->piece];
    s->px = (int16_t)((s->bw - 4) / 2);
    s->py = 0;
}

static void tetris_input(void *state, const ml_input_event *e, ml_game_ctx *ctx)
{
    tetris_state *s = state;
    if (s->status != TETRIS_PLAYING) return;
    switch (e->code) {
    case 0:  /* Up: rotate */
        if (e->value) tetris_rotate(s);
        break;
    case 1:  /* Down: hard drop */
        if (e->value) tetris_drop(s, ctx);
        break;
    case 2:  /* Left */
        s->held_l = e->value ? 1 : 0;
        break;
    case 3:  /* Right */
        s->held_r = e->value ? 1 : 0;
        break;
    default:
        break;
    }
}

static void tetris_update(void *state, ml_game_ctx *ctx)
{
    tetris_state *s = state;
    if (s->status != TETRIS_PLAYING) return;

    /* held moves repeat every tick */
    if (s->held_l && !tetris_collide(s, s->mask, s->px - 1, s->py)) s->px--;
    if (s->held_r && !tetris_collide(s, s->mask, s->px + 1, s->py)) s->px++;

    /* gravity: 20 ticks per row at level 0, two fewer per level */
    int interval = 20 - s->level * 2;
    if (interval < 1) interval = 1;
    if (++s->fall_ctr >= interval) {
        s->fall_ctr = 0;
        if (!tetris_collide(s, s->mask, s->px, s->py + 1)) s->py++;
        else tetris_lock(s, ctx);
    }
}

static ml_rgb tetris_piece_color(int piece)
{
    switch (piece) {
    case 0: return ML_RGB(0, 229, 255);    /* I cyan */
    case 1: return ML_RGB(255, 220, 0);    /* O yellow */
    case 2: return ML_RGB(180, 0, 255);    /* T purple */
    case 3: return ML_RGB(0, 200, 80);     /* S green */
    case 4: return ML_RGB(255, 40, 40);    /* Z red */
    case 5: return ML_RGB(60, 90, 255);    /* J blue */
    default: return ML_RGB(255, 140, 0);   /* L orange */
    }
}

static void tetris_draw(const void *state, const ml_view *view, ml_canvas *c,
                        const ml_game_ctx *ctx)
{
    (void)view; (void)ctx;
    const tetris_state *s = state;
    ml_canvas_clear(c, ml_black);
    int W = c->w, H = c->h;

    /* dim frame when the field is smaller than the panel */
    if (s->ox > 1 || s->oy > 1) {
        ml_rgb frame = ML_RGB(40, 40, 40);
        int x0 = s->ox - 1, y0 = s->oy - 1;
        int x1 = s->ox + s->bw, y1 = s->oy + s->bh;
        for (int x = x0; x <= x1 && x < W; x++) {
            ml_canvas_set(c, x, y0, frame);
            ml_canvas_set(c, x, y1 < H ? y1 : H - 1, frame);
        }
        for (int y = y0; y <= y1 && y < H; y++) {
            ml_canvas_set(c, x0, y, frame);
            if (x1 < W) ml_canvas_set(c, x1, y, frame);
        }
    }

    /* locked stack: one settled colour, so the falling piece pops */
    ml_rgb settled = ML_RGB(90, 100, 120);
    for (int r = 0; r < s->bh; r++) {
        uint32_t row = s->board[r];
        if (!row) continue;
        for (int bc = 0; bc < s->bw; bc++)
            if (row & (1u << bc))
                ml_canvas_set(c, s->ox + bc, s->oy + r, settled);
    }

    /* falling piece in its own colour */
    ml_rgb pc = tetris_piece_color(s->piece);
    for (int row = 0; row < 4; row++) {
        for (int col = 0; col < 4; col++) {
            if (!(s->mask & (1u << (row * 4 + col)))) continue;
            int bx = s->ox + s->px + col;
            int by = s->oy + s->py + row;
            if (by < 0 || by >= H || bx < 0 || bx >= W) continue;
            ml_canvas_set(c, bx, by, pc);
        }
    }

    /* score, in the current piece's colour so a new piece resets it */
    char buf[8];
    const ml_font *f = ml_font_find("digits10");
    if (!f) f = ml_font_default();
    snprintf(buf, sizeof(buf), "%u", (unsigned)s->score);
    ml_text_draw(c, f, 1, 1, buf, pc, ML_SCALE_1X);
}

static bool tetris_snapshot(const void *state, uint8_t *buf, size_t cap, size_t *len)
{
    if (cap < sizeof(tetris_state)) return false;
    memcpy(buf, state, sizeof(tetris_state));
    *len = sizeof(tetris_state);
    return true;
}

static void tetris_restore(void *state, const uint8_t *buf, size_t len)
{
    size_t n = len < sizeof(tetris_state) ? len : sizeof(tetris_state);
    memcpy(state, buf, n);
}

static const ml_control_def tetris_controls[] = {
    { .label = "Up",    .code = 0, .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "Down",  .code = 1, .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "Left",  .code = 2, .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "Right", .code = 3, .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
};

const ml_game_vt ml_game_tetris = {
    .id            = "tetris",
    .pref_w        = 0, .pref_h = 0,
    .fit           = ML_FIT_ADAPTIVE,
    .tick_ms       = 25,
    .max_players   = 1,
    .state_size    = sizeof(tetris_state),
    .controls      = tetris_controls,
    .control_count = 4,
    .init          = tetris_init,
    .reset         = tetris_reset,
    .input         = tetris_input,
    .update        = tetris_update,
    .draw          = tetris_draw,
    .snapshot      = tetris_snapshot,
    .restore       = tetris_restore,
};
