/*
 * game_jumpman.c - Jumpman: run right, jump the gaps, stomp the blobs.
 *
 * The Mario-shaped game of the set. A 4x6 character runs along a 160-column
 * course authored for a 64x32 window that follows it, and the course is made of
 * the four things that make that genre work at this size:
 *
 * - ground with pits in it. A pit is a column whose surface is gone, so the
 *   character is in the air over nothing and falls out of the level; two to
 *   four columns of it, all of them inside a jump that clears about eight rows
 *   and thirty pixels of travel.
 * - pipes, which are just ground that stands taller: three columns at a raised
 *   surface, walkable on top and solid from the side.
 * - blocks. One row of brick pixels four rows thick, which is 3 or 4 columns
 *   wide, so a block is square to the eye. A block is stood on, bumped from
 *   below, and one of them is a coin block that pays out and turns used.
 * - blobs, which walk the flat ground and turn at anything that is not flat.
 *   Landing on one squashes it and bounces the player; meeting one side-on
 *   costs a life, which is the whole reason the jump button has a variable
 *   height.
 *
 * Three lives, three courses, and touching the flag ends the one in play. A
 * death puts the player back at the start of the course it happened on - the
 * course itself, and every block already bumped and coin already taken, is the
 * one that was being played.
 *
 * The phone's tilt is a direction here rather than a position, the same reading
 * Snake and Maze take from theirs: a deliberate angle runs that way, a level
 * phone stands still, and an idle axis hands the run back to the buttons. A
 * held angle cannot express a jump, so Jump is a button and every course is
 * playable on the pad alone.
 */
#include <stdio.h>
#include <string.h>

#include "mirror/font.h"
#include "mirror/game.h"
#include "mirror/gamerun.h"

/* The logical panel the game is authored for: 64 columns of course in a
 * window, letterboxed by the runtime, so the physics below is always in these
 * coordinates whatever the physical panel is. */
#define JUMP_W 64
#define JUMP_H 32

/* Rows 0-9 are the HUD (score, coins, lives), 10-31 are the field. World rows
 * are field rows: world row 0 is panel row 10, and a world pixel is one panel
 * pixel. */
#define JUMP_HUD_H 10
#define JUMP_ROWS  22

/* Ground: a grass surface over dirt, to the bottom of the field. */
#define JUMP_GROUND_ROW 19
#define JM_NONE         0xFF   /* no ground in this column / no block in it */

/* The player: 4x6, standing on the ground row with six rows of headroom. */
#define PLAYER_W 4
#define PLAYER_H 6
#define PLAYER_START_X 3
#define PLAYER_START_Y (JUMP_GROUND_ROW - PLAYER_H)

/*
 * Q8.8 physics. Gravity is 24/256 of a pixel per tick squared and the jump
 * leaves the ground at 316/256, so a jump from the ground peaks about eight
 * rows up and comes back down 26 ticks later - a little over half a second at
 * the 25ms tick, which is a jump a player can aim.
 */
#define JM_GRAVITY    24
#define JM_JUMP       316
#define JM_JUMP_CUT   144   /* an early release clamps the rise to this */
#define JM_MAX_FALL   512   /* 2 px/tick: the fall is brisk, never a blur */
#define JM_RUN        288   /* 1.125 px/tick, about 45 px/s */

/* Blobs: 4x3 on the ground, slower than the player at every difficulty. */
#define BLOB_W 4
#define BLOB_H 3
#define BLOB_SLOTS 12
#define BLOB_SPEED_BASE 56  /* 0.22 px/tick */
#define BLOB_SPEED_STEP 16  /* one step faster per course */
#define JM_STOMP_BOUNCE 256

/*
 * Blocks: 3 or 4 columns wide and always 4 rows thick, so they read square, at
 * one of two heights. A six-row player is taller than the gap a single height
 * could serve, so the height is what the block is for:
 *
 * - a low block's surface is 12 or 13, which is a platform the player lands on
 *   and a wall from the side, with a coin over it as the reward for the climb.
 *   Its underside is never reached: the player's head is already past it.
 * - a coin block hangs at 9, one row above the standing player's head, so the
 *   player walks under it and a jump puts their head into its underside. That
 *   bump is the only way a coin is paid out, and the only block height where
 *   the bump is even possible.
 */
#define BRICK_H        4
#define BRICK_ROW_LOW  13
#define BRICK_ROW_MID  12
#define BRICK_ROW_HIGH 9
#define BM_NONE 0
#define BM_BRICK 1
#define BM_COIN  2
#define BM_USED  3

/* Pipes: three columns wide and 3 to 5 rows above the ground, so a pipe is
 * nearly as wide as the player and unmistakable from the side. */
#define PIPE_W     3
#define PIPE_SLOTS 8
#define PM_NONE 0xFF

/* Coins float or sit above a block. 2x2, so one is a target worth aiming a
 * jump at rather than something the player walks through. */
#define COIN_SLOTS 16
#define CM_NONE  0
#define CM_LIVE  1
#define CM_TAKEN 2

/* The course: a run-in that is always flat, a tail that always holds the flag,
 * and 160 columns of generated middle. */
#define JUMP_COLS   160
#define JUMP_RUN_IN 10
/* The opening stretch of a course: blocks and coins may be here, but nothing
 * that can end a life. A player who holds Right from the first tick meets the
 * first pit, pipe or blob with about half a second in hand, which is what makes
 * the first jump of a course something the player chose to make. */
#define JUMP_SAFE_START 28
#define JUMP_TAIL   8
#define JUMP_FLAG   (JUMP_COLS - 5)

#define JUMP_LEVELS 3

#define SCORE_COIN  100
#define SCORE_STOMP 200
#define SCORE_FLAG  500
#define SCORE_MAX   9999

/* A deliberate tilt, not a resting hand: a quarter of the travel, about 11
 * degrees off neutral. */
#define JM_TILT_TURN (32767 / 4)

enum { JM_PLAYING = 0, JM_WON = 1, JM_OVER = 2 };
enum { JM_IN_LEFT = 0, JM_IN_RIGHT = 1, JM_IN_JUMP = 2, JM_IN_TILT = 3 };
enum { JM_EVENT_COIN = 1, JM_EVENT_STOMP = 2, JM_EVENT_DEATH = 3, JM_EVENT_FLAG = 4 };

typedef struct {
    uint8_t x;      /* left column */
    uint8_t top;    /* world row of the pipe's surface */
} jumpman_pipe;

typedef struct {
    int32_t x;      /* left edge, Q8.8 */
    int16_t sx;     /* the column it was placed at, for a respawn */
    int8_t  dir;    /* -1 left, +1 right */
    uint8_t alive;
} jumpman_blob;

typedef struct {
    uint8_t x, y;   /* top-left, world pixels */
    uint8_t state;  /* CM_* */
} jumpman_coin;

typedef struct {
    int32_t  px, py;        /* the player's top-left, Q8.8 */
    int32_t  vx, vy;
    uint8_t  surf[JUMP_COLS];   /* ground surface row, JM_NONE for a pit */
    uint8_t  brick[JUMP_COLS];  /* block row, JM_NONE for none */
    uint8_t  bkind[JUMP_COLS];  /* BM_* */
    jumpman_pipe pipes[PIPE_SLOTS];
    jumpman_blob blobs[BLOB_SLOTS];
    jumpman_coin coins[COIN_SLOTS];
    int16_t  cam;           /* the column drawn at the left edge */
    uint16_t score;
    uint16_t coin_count;
    uint8_t  level;
    uint8_t  lives;
    uint8_t  status;        /* JM_* */
    uint8_t  facing;        /* 1 right, 0 left */
    uint8_t  jump_queued;   /* a press waiting for the ground */
    uint8_t  jump_held;
    uint8_t  held_left, held_right;
    int16_t  tilt_x;        /* ML_AXIS_IDLE until a controller drives it */
} jumpman_state;

/* The runtime reserves four bytes of the snapshot header, so the usable budget
 * is four under the nominal maximum. A later edit that grows the state past it
 * fails to compile rather than wedging a peer. */
typedef char jumpman_state_fits[
    (sizeof(jumpman_state) <= ML_SNAPSHOT_MAX - 4) ? 1 : -1];

static const ml_control_def jumpman_controls[] = {
    { .label = "Left",  .code = JM_IN_LEFT,  .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "Right", .code = JM_IN_RIGHT, .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "Jump",  .code = JM_IN_JUMP,  .caps = ML_CAP_BUTTON, .type = ML_INPUT_BUTTON },
    { .label = "TiltX", .code = JM_IN_TILT,  .caps = ML_CAP_ACCEL,  .type = ML_INPUT_AXIS },
};

/* ---- world queries ------------------------------------------------------ */

/* A world pixel is solid when it is at or under its column's surface, or inside
 * a block. Off either end of the course is solid, so nothing walks out of the
 * world, and below the field is open air, because that is how a pit ends a
 * life. */
static bool jm_solid(const jumpman_state *s, int x, int y)
{
    if (x < 0 || x >= JUMP_COLS) return true;
    if (y < 0 || y >= JUMP_ROWS) return false;
    if (s->surf[x] != JM_NONE && y >= (int)s->surf[x]) return true;
    if (s->brick[x] != JM_NONE && y >= (int)s->brick[x] &&
        y < (int)s->brick[x] + BRICK_H) return true;
    return false;
}

/* Whether any row of a column run is solid: the two tests a swept move needs,
 * one per axis. */
static bool jm_col_solid(const jumpman_state *s, int x, int y0, int y1)
{
    for (int y = y0; y <= y1; y++) if (jm_solid(s, x, y)) return true;
    return false;
}

/* Whether any column of a body is solid on one row. */
static bool jm_row_solid(const jumpman_state *s, int l, int r, int row)
{
    for (int x = l; x <= r; x++) if (jm_solid(s, x, row)) return true;
    return false;
}

/* The column of a body a row is first solid in, or -1: the one a head bump
 * belongs to. */
static int jm_row_first(const jumpman_state *s, int l, int r, int row)
{
    for (int x = l; x <= r; x++) if (jm_solid(s, x, row)) return x;
    return -1;
}

static int jm_left(const jumpman_state *s)   { return s->px >> 8; }
static int jm_right(const jumpman_state *s)  { return (s->px >> 8) + PLAYER_W - 1; }
static int jm_top(const jumpman_state *s)    { return s->py >> 8; }
static int jm_bottom(const jumpman_state *s) { return (s->py >> 8) + PLAYER_H - 1; }

/* Whether the player is standing on something. The resting position is exactly
 * one pixel above the surface, so the row the feet are in is the surface's. */
static bool jm_on_ground(const jumpman_state *s)
{
    const int row = (s->py >> 8) + PLAYER_H;
    return jm_col_solid(s, jm_left(s), row, row) ||
           jm_col_solid(s, jm_right(s), row, row);
}

static int jm_blob_speed(const jumpman_state *s)
{
    return BLOB_SPEED_BASE + BLOB_SPEED_STEP * (int)s->level;
}

/* Where a blob at x would step into: off the course, over a pit, onto ground
 * that stands taller, or into a block it is tall enough to meet. Any of those
 * is a turn. A pit is the one case the solid test cannot see, because to the
 * player it is air to fall through, so the surface is asked about separately. */
static bool jm_blob_blocked(const jumpman_state *s, int x)
{
    if (x < 0 || x >= JUMP_COLS) return true;
    if (s->surf[x] != JUMP_GROUND_ROW) return true;
    return jm_col_solid(s, x, JUMP_GROUND_ROW - BLOB_H, JUMP_GROUND_ROW - 1);
}

/* ---- level construction ------------------------------------------------- */

static uint32_t jm_roll(ml_game_ctx *ctx, int span)
{
    return ml_ctx_rng(ctx) % (uint32_t)span;
}

/* The flat course every generation starts from: ground the whole way, no
 * blocks, no pipes, no coins, no blobs. */
static void jm_flatten(jumpman_state *s)
{
    for (int x = 0; x < JUMP_COLS; x++) {
        s->surf[x] = JUMP_GROUND_ROW;
        s->brick[x] = JM_NONE;
        s->bkind[x] = BM_NONE;
    }
    for (int i = 0; i < PIPE_SLOTS; i++) s->pipes[i].x = PM_NONE;
    for (int i = 0; i < BLOB_SLOTS; i++) { s->blobs[i].alive = 0; s->blobs[i].sx = -1; }
    for (int i = 0; i < COIN_SLOTS; i++) s->coins[i].state = CM_NONE;
}

static int jm_pipe_slot(const jumpman_state *s)
{
    for (int i = 0; i < PIPE_SLOTS; i++) if (s->pipes[i].x == PM_NONE) return i;
    return -1;
}

static int jm_blob_slot(const jumpman_state *s)
{
    for (int i = 0; i < BLOB_SLOTS; i++) if (!s->blobs[i].alive && s->blobs[i].sx < 0)
        return i;
    return -1;
}

static void jm_place_coin(jumpman_state *s, int x, int y)
{
    if (x < 1 || x > JUMP_COLS - 2 || y < 0 || y > JUMP_ROWS - 2) return;
    for (int i = 0; i < COIN_SLOTS; i++) {
        if (s->coins[i].state != CM_NONE) continue;
        s->coins[i].x = (uint8_t)x;
        s->coins[i].y = (uint8_t)y;
        s->coins[i].state = CM_LIVE;
        return;
    }
}

/* A blob is only placed where it can walk: its own column and the four either
 * side flat, so it never starts inside a pipe or turns on its own first tick.
 * It is also kept clear of the flag, because a blob standing on the flag is a
 * death and a win arriving on the same column. */
static void jm_place_blob(jumpman_state *s, int x, int dir)
{
    if (x > JUMP_FLAG - 6) return;
    for (int i = x - 2; i <= x + 2; i++) {
        if (i < 0 || i >= JUMP_COLS) return;
        if (jm_blob_blocked(s, i)) return;
    }
    const int slot = jm_blob_slot(s);
    if (slot < 0) return;
    s->blobs[slot].x = (int32_t)x << 8;
    s->blobs[slot].sx = (int16_t)x;
    s->blobs[slot].dir = (int8_t)dir;
    s->blobs[slot].alive = 1;
}

static void jm_place_pipe(jumpman_state *s, int x, int height)
{
    const int slot = jm_pipe_slot(s);
    if (slot < 0) return;
    const int top = JUMP_GROUND_ROW - height;
    for (int i = 0; i < PIPE_W; i++) s->surf[x + i] = (uint8_t)top;
    s->pipes[slot].x = (uint8_t)x;
    s->pipes[slot].top = (uint8_t)top;
}

/* One block: a run of columns at one row, all of one kind. */
static void jm_place_block(jumpman_state *s, int x, int w, int row, int kind)
{
    for (int i = 0; i < w; i++) {
        s->brick[x + i] = (uint8_t)row;
        s->bkind[x + i] = (uint8_t)kind;
    }
}

static bool jm_flat_span(const jumpman_state *s, int x, int w)
{
    for (int i = 0; i < w; i++) {
        if (s->surf[x + i] != JUMP_GROUND_ROW) return false;
        if (s->brick[x + i] != JM_NONE) return false;
    }
    return true;
}

/*
 * Generate the middle of a course left to right, one pattern per step, so the
 * RNG is consumed in a fixed order and the same seed and course index always
 * build the same course. Difficulty is the course index: wider pits, faster
 * blobs, more of them at once.
 *
 * A pit is followed by three flat columns, which is what keeps two pits from
 * running together into a gap no jump clears. Every other pattern advances the
 * cursor past what it placed, so the same protection covers a pipe or a block
 * landing hard against a pit's far edge.
 */
static void jm_build_course(jumpman_state *s, ml_game_ctx *ctx)
{
    const int diff = (int)s->level;
    const int limit = JUMP_COLS - JUMP_TAIL;
    int x = JUMP_RUN_IN;
    int flat_run = 0;

    while (x < limit) {
        if (flat_run > 0) { flat_run--; x++; continue; }

        int roll = (int)jm_roll(ctx, 100);
        /* Nothing fatal in the opening: a coin to jump for instead. */
        if (x < JUMP_SAFE_START && (roll < 40 || (roll >= 66 && roll < 88)))
            roll = 95;

        if (roll < 22) {
            /* A pit: 2 columns at the first course, 4 at the last. */
            int max_w = 2 + diff;
            if (max_w > 4) max_w = 4;
            int w = 2 + (int)jm_roll(ctx, (uint32_t)(max_w - 1));
            if (x + w + 3 > limit) w = 0;
            if (w > 0) {
                for (int i = 0; i < w; i++) s->surf[x + i] = JM_NONE;
                x += w;
                flat_run = 3;
            } else {
                x++;
            }
        } else if (roll < 40) {
            /* A pipe, 3 to 5 rows high. */
            const int height = 3 + (int)jm_roll(ctx, 3);
            if (x + PIPE_W + 1 < limit && jm_flat_span(s, x, PIPE_W)) {
                jm_place_pipe(s, x, height);
                x += PIPE_W + 1;
            } else {
                x++;
            }
        } else if (roll < 66) {
            /* A coin block on its own, or one or two low blocks in a row with a
             * coin floating over each. */
            const int w = 3 + (int)jm_roll(ctx, 2);
            if (jm_roll(ctx, 4) == 0) {
                if (x + w + 2 < limit && jm_flat_span(s, x, w)) {
                    jm_place_block(s, x, w, BRICK_ROW_HIGH, BM_COIN);
                    x += w + 1;
                } else {
                    x++;
                }
            } else {
                const int row = jm_roll(ctx, 2) ? BRICK_ROW_MID : BRICK_ROW_LOW;
                const int n = 1 + (int)jm_roll(ctx, 2);
                const int span = w * n;
                if (x + span + 2 < limit && jm_flat_span(s, x, span)) {
                    for (int b = 0; b < n; b++) {
                        jm_place_block(s, x + b * w, w, row, BM_BRICK);
                        jm_place_coin(s, x + b * w + w / 2, row - 2);
                    }
                    x += span + 1;
                } else {
                    x++;
                }
            }
        } else if (roll < 88) {
            /* A walking group, 1 to 3 of them by course. */
            const int n = 1 + (int)jm_roll(ctx, (uint32_t)(1 + diff));
            int placed = 0;
            for (int i = 0; i < n; i++) {
                const int bx = x + 2 + i * 3;
                const int before = jm_blob_slot(s);
                jm_place_blob(s, bx, -1);
                if (jm_blob_slot(s) != before) placed++;
            }
            if (placed) x += 2 + n * 3;
            else        x += 2;
        } else {
            /* Flat ground with a coin to jump for. */
            jm_place_coin(s, x + 1, JUMP_GROUND_ROW - 8 + (int)jm_roll(ctx, 2));
            x += 3 + (int)jm_roll(ctx, 4);
        }
    }
}

/* Start the player and the camera at the left edge of a course. Called on a
 * fresh course and again after a death, so a death replays the course from the
 * top with every block and coin as the player left them. */
static void jm_rewind(jumpman_state *s)
{
    for (int i = 0; i < BLOB_SLOTS; i++) {
        if (s->blobs[i].sx < 0) continue;
        s->blobs[i].x = (int32_t)s->blobs[i].sx << 8;
        s->blobs[i].dir = -1;
        s->blobs[i].alive = 1;
    }
    s->px = PLAYER_START_X << 8;
    s->py = PLAYER_START_Y << 8;
    s->vx = 0;
    s->vy = 0;
    s->cam = 0;
    s->facing = 1;
    s->jump_queued = 0;
    s->jump_held = 0;
}

static void jm_load_course(jumpman_state *s, ml_game_ctx *ctx)
{
    jm_flatten(s);
    jm_build_course(s, ctx);
    jm_rewind(s);
}

/* ---- moving ------------------------------------------------------------- */

/* Score and coins, both capped so the HUD never runs out of digits. */
static void jm_award(jumpman_state *s, int points, int coins)
{
    const int total = (int)s->score + points;
    s->score = (uint16_t)(total > SCORE_MAX ? SCORE_MAX : total);
    if (coins) s->coin_count = (uint16_t)(s->coin_count + coins);
}

/* A block met from below. Only a coin block pays out, and the whole block turns
 * used rather than the single column the head happened to catch. A rise of more
 * than a pixel a tick can put the head a row inside the block rather than on its
 * underside, so any block header counts as the bump. */
static void jm_bump(jumpman_state *s, int x, ml_game_ctx *ctx)
{
    if (s->brick[x] == JM_NONE) return;
    if (s->bkind[x] != BM_COIN) return;
    const int block_row = (int)s->brick[x];
    for (int i = x; i >= 0 && s->brick[i] == block_row && s->bkind[i] == BM_COIN; i--)
        s->bkind[i] = BM_USED;
    for (int i = x + 1; i < JUMP_COLS && s->brick[i] == block_row &&
                    s->bkind[i] == BM_COIN; i++)
        s->bkind[i] = BM_USED;
    jm_award(s, SCORE_COIN, 1);
    ml_ctx_emit_event(ctx, JM_EVENT_COIN, 0);
}

/* Horizontal move, then flush out of whatever wall it ended in. A tick moves
 * the player about a pixel, so the sweep is one column deep on either side and
 * nothing can be stepped over. */
static void jm_move_x(jumpman_state *s)
{
    if (s->vx == 0) return;
    s->px += s->vx;
    const int top = jm_top(s), bot = jm_bottom(s);
    if (s->vx > 0) {
        const int col = jm_right(s);
        if (jm_col_solid(s, col, top, bot)) s->px = (col - PLAYER_W) << 8;
    } else {
        const int col = jm_left(s);
        if (jm_col_solid(s, col, top, bot)) s->px = (col + 1) << 8;
    }
}

/*
 * Vertical move, then resolve against every row the body crossed, not just the
 * one it ended on. A fall moves up to two pixels and a jump over one, so
 * testing the destination row alone lets the feet step past a surface and then
 * resolve onto the row under it, which buries the sprite a pixel in the ground
 * for a tick. The search starts at the row the body was on, which is free by
 * construction, and takes the first solid row it meets: the feet land on that
 * one, or the head stops under that one.
 */
static void jm_move_y(jumpman_state *s, ml_game_ctx *ctx)
{
    if (s->vy == 0) return;
    const int l = jm_left(s), r = jm_right(s);
    const int from = s->vy > 0 ? jm_bottom(s) : jm_top(s);
    s->py += s->vy;
    const int to = s->vy > 0 ? jm_bottom(s) : jm_top(s);

    if (s->vy > 0) {
        for (int row = from; row <= to; row++) {
            if (!jm_row_solid(s, l, r, row)) continue;
            s->py = (row - PLAYER_H) << 8;
            s->vy = 0;
            return;
        }
    } else {
        for (int row = from; row >= to; row--) {
            const int x = jm_row_first(s, l, r, row);
            if (x < 0) continue;
            s->py = (row + 1) << 8;
            s->vy = 0;
            jm_bump(s, x, ctx);
            return;
        }
    }
}

/* Blobs walk the flat ground and turn at whatever is not flat. They do not fall
 * off a ledge: the turn happens on the column before it, because a blob that
 * walked into a pit would be a blob the player never has to deal with. */
static void jm_move_blobs(jumpman_state *s)
{
    const int speed = jm_blob_speed(s);
    for (int i = 0; i < BLOB_SLOTS; i++) {
        jumpman_blob *b = &s->blobs[i];
        if (!b->alive) continue;
        const int32_t next = b->x + (int32_t)b->dir * speed;
        /* The edge that is walking, in columns: the body is four columns wide,
         * so a rightward blob tests three columns to the right of where it is. */
        const int lead = b->dir > 0 ? (int)(next >> 8) + BLOB_W - 1 : (int)(next >> 8);
        if (jm_blob_blocked(s, lead)) {
            b->dir = (int8_t)-b->dir;
            continue;
        }
        b->x = next;
    }
}

/* Overlap with a walking blob: a descending player whose feet are at the blob's
 * head squashes it and bounces, and anything else is the player's death. The
 * feet have to have been above the head, not beside it, which is what stops a
 * player standing next to a blob from scoring a stomp. */
static bool jm_blob_touch(jumpman_state *s, ml_game_ctx *ctx)
{
    const int l = jm_left(s), r = jm_right(s), top = jm_top(s), bot = jm_bottom(s);
    const int head = JUMP_GROUND_ROW - BLOB_H;
    for (int i = 0; i < BLOB_SLOTS; i++) {
        jumpman_blob *b = &s->blobs[i];
        if (!b->alive) continue;
        const int bx = (int)(b->x >> 8);
        if (r < bx || l > bx + BLOB_W - 1) continue;
        if (bot < head || top > head + BLOB_H - 1) continue;
        if (s->vy > 0 && bot <= head + 1) {
            b->alive = 0;
            s->vy = -JM_STOMP_BOUNCE;
            jm_award(s, SCORE_STOMP, 0);
            ml_ctx_emit_event(ctx, JM_EVENT_STOMP, 0);
            continue;
        }
        return true;
    }
    return false;
}

static void jm_take_coins(jumpman_state *s)
{
    const int l = jm_left(s), r = jm_right(s), top = jm_top(s), bot = jm_bottom(s);
    for (int i = 0; i < COIN_SLOTS; i++) {
        jumpman_coin *c = &s->coins[i];
        if (c->state != CM_LIVE) continue;
        if (r < (int)c->x || l > (int)c->x + 1) continue;
        if (bot < (int)c->y || top > (int)c->y + 1) continue;
        c->state = CM_TAKEN;
        jm_award(s, SCORE_COIN, 1);
    }
}

/* The camera keeps the player a little left of centre and never leaves the
 * course, so the right edge of the level is the last thing it shows. */
static void jm_follow(jumpman_state *s)
{
    int cam = (s->px >> 8) + PLAYER_W / 2 - JUMP_W / 2;
    if (cam < 0) cam = 0;
    if (cam > JUMP_COLS - JUMP_W) cam = JUMP_COLS - JUMP_W;
    s->cam = (int16_t)cam;
}

/* ---- lifecycle ---------------------------------------------------------- */

static void jm_die(jumpman_state *s, ml_game_ctx *ctx)
{
    ml_ctx_emit_event(ctx, JM_EVENT_DEATH, 0);
    if (s->lives > 0) s->lives--;
    if (s->lives == 0) {
        s->status = JM_OVER;
        return;
    }
    jm_rewind(s);
}

/* The flag ends the course: a bonus, then the next one, or the win on the last
 * course. Score, coins and lives carry across, so the run is one run. */
static void jm_finish_course(jumpman_state *s, ml_game_ctx *ctx)
{
    ml_ctx_emit_event(ctx, JM_EVENT_FLAG, 0);
    jm_award(s, SCORE_FLAG, 0);
    if ((int)s->level + 1 >= JUMP_LEVELS) {
        s->status = JM_WON;
        return;
    }
    s->level++;
    jm_load_course(s, ctx);
}

static void jm_init(void *state, const ml_game_cfg *cfg, ml_game_ctx *ctx)
{
    (void)cfg; (void)ctx;
    jumpman_state *s = state;
    memset(s, 0, sizeof(*s));
    s->tilt_x = ML_AXIS_IDLE;
}

static void jm_reset(void *state, ml_game_ctx *ctx)
{
    jumpman_state *s = state;
    s->score = 0;
    s->coin_count = 0;
    s->level = 0;
    s->lives = 3;
    s->status = JM_PLAYING;
    s->held_left = 0;
    s->held_right = 0;
    s->tilt_x = ML_AXIS_IDLE;
    jm_load_course(s, ctx);
}

static void jm_input(void *state, const ml_input_event *e, ml_game_ctx *ctx)
{
    (void)ctx;
    jumpman_state *s = state;
    switch (e->code) {
    case JM_IN_LEFT:
        if (e->type == ML_INPUT_BUTTON) s->held_left = (uint8_t)(e->value ? 1 : 0);
        break;
    case JM_IN_RIGHT:
        if (e->type == ML_INPUT_BUTTON) s->held_right = (uint8_t)(e->value ? 1 : 0);
        break;
    case JM_IN_JUMP:
        if (e->type == ML_INPUT_BUTTON) {
            /* The press is what jumps, so a held button does not bounce the
             * player off the ground on every tick it is down for. */
            if (e->value && !s->jump_held) s->jump_queued = 1;
            s->jump_held = (uint8_t)(e->value ? 1 : 0);
        }
        break;
    case JM_IN_TILT:
        /* An axis is a position, not a press: it is latched whenever it
         * arrives, including while the phone is level. */
        if (e->type == ML_INPUT_AXIS) s->tilt_x = e->value;
        break;
    default:
        break;
    }
}

static void jm_update(void *state, ml_game_ctx *ctx)
{
    jumpman_state *s = state;
    if (s->status != JM_PLAYING) return;

    /* Run. An engaged axis makes the phone's angle the direction - a held tilt
     * keeps running, a level phone stands still - and otherwise the buttons
     * are the only thing steering. */
    int dir = 0;
    if (ml_axis_engaged(s->tilt_x)) {
        if (s->tilt_x > JM_TILT_TURN)       dir = 1;
        else if (s->tilt_x < -JM_TILT_TURN) dir = -1;
    } else if (s->held_right != s->held_left) {
        dir = s->held_right ? 1 : -1;
    }
    if (dir != 0) s->facing = (uint8_t)(dir > 0 ? 1 : 0);
    s->vx = dir * JM_RUN;

    /* Jump, and let go of the button early to cut it short: the rise is capped
     * while it is still rising, which is what makes the height the player's. */
    if (s->jump_queued && jm_on_ground(s)) s->vy = -JM_JUMP;
    s->jump_queued = 0;
    if (s->vy < 0 && !s->jump_held && s->vy < -JM_JUMP_CUT) s->vy = -JM_JUMP_CUT;

    s->vy += JM_GRAVITY;
    if (s->vy > JM_MAX_FALL) s->vy = JM_MAX_FALL;

    jm_move_blobs(s);
    jm_move_x(s);
    jm_move_y(s, ctx);

    /* Death outranks the flag, so a blob that catches the player on the last
     * column of the course is a death and not a win. */
    if (jm_blob_touch(s, ctx)) { jm_die(s, ctx); return; }
    if (s->py > (JUMP_ROWS << 8)) { jm_die(s, ctx); return; }
    jm_take_coins(s);
    if (jm_right(s) >= JUMP_FLAG) { jm_finish_course(s, ctx); return; }
    jm_follow(s);
}

/* ---- drawing ------------------------------------------------------------ */

static void jm_put(ml_canvas *c, int cam, int x, int y, ml_rgb col)
{
    ml_canvas_set(c, x - cam, y + JUMP_HUD_H, col);
}

static void jm_fill(ml_canvas *c, int cam, int x, int y, int w, int h, ml_rgb col)
{
    for (int dy = 0; dy < h; dy++)
        for (int dx = 0; dx < w; dx++)
            jm_put(c, cam, x + dx, y + dy, col);
}

static void jm_draw_ground(ml_canvas *c, const jumpman_state *s)
{
    const ml_rgb grass = ML_RGB(72, 176, 80);
    const ml_rgb dirt  = ML_RGB(120, 72, 40);
    const ml_rgb dark  = ML_RGB(84, 48, 26);
    const int cam = s->cam;

    for (int x = cam; x < cam + JUMP_W; x++) {
        if (x < 0 || x >= JUMP_COLS) continue;
        const int surf = s->surf[x];
        if (surf == JM_NONE) continue;
        jm_put(c, cam, x, surf, grass);
        for (int y = surf + 1; y < JUMP_ROWS; y++)
            jm_put(c, cam, x, y, (y == surf + 1 && (x & 1)) ? dark : dirt);
    }
}

/* Pipes are ground that stands taller, so the terrain above already filled them
 * with dirt; this is the green that makes them read as pipes: a bright rim
 * across the top and a highlight down the left edge. */
static void jm_draw_pipes(ml_canvas *c, const jumpman_state *s)
{
    const ml_rgb body  = ML_RGB(40, 184, 72);
    const ml_rgb rim   = ML_RGB(120, 240, 144);
    const ml_rgb shade = ML_RGB(24, 120, 48);
    const int cam = s->cam;

    for (int i = 0; i < PIPE_SLOTS; i++) {
        if (s->pipes[i].x == PM_NONE) continue;
        const int x = s->pipes[i].x;
        const int top = s->pipes[i].top;
        if (x + PIPE_W <= cam || x >= cam + JUMP_W) continue;
        jm_fill(c, cam, x, top + 1, PIPE_W, JUMP_GROUND_ROW - top - 1, body);
        jm_fill(c, cam, x, top, PIPE_W, 1, rim);
        for (int y = top + 1; y < JUMP_GROUND_ROW; y++) jm_put(c, cam, x, y, rim);
        for (int y = top + 2; y < JUMP_GROUND_ROW; y++)
            jm_put(c, cam, x + PIPE_W - 1, y, shade);
    }
}

static void jm_draw_blocks(ml_canvas *c, const jumpman_state *s)
{
    const ml_rgb brick = ML_RGB(196, 108, 48);
    const ml_rgb lit   = ML_RGB(236, 160, 88);
    const ml_rgb coin  = ML_RGB(248, 208, 64);
    const ml_rgb used  = ML_RGB(96, 88, 80);
    const int cam = s->cam;

    for (int x = cam; x < cam + JUMP_W; x++) {
        if (x < 0 || x >= JUMP_COLS) continue;
        if (s->brick[x] == JM_NONE) continue;
        const int row = s->brick[x];
        ml_rgb base = brick, top = lit;
        if (s->bkind[x] == BM_COIN)       { base = coin;  top = ML_RGB(255, 240, 160); }
        else if (s->bkind[x] == BM_USED)  { base = used;  top = ML_RGB(128, 120, 112); }
        jm_fill(c, cam, x, row, 1, BRICK_H, base);
        jm_put(c, cam, x, row, top);
        jm_put(c, cam, x, row + BRICK_H - 1, used);
        /* A coin block carries a dark mark in its middle row, which is the one
         * pixel of a 1-wide column that can hold a signal at all. */
        if (s->bkind[x] == BM_COIN) jm_put(c, cam, x, row + 2, ML_RGB(120, 84, 8));
    }
}

static void jm_draw_coins(ml_canvas *c, const jumpman_state *s)
{
    const ml_rgb gold = ML_RGB(255, 216, 64);
    const ml_rgb glint = ML_RGB(255, 248, 200);
    const int cam = s->cam;
    for (int i = 0; i < COIN_SLOTS; i++) {
        const jumpman_coin *cn = &s->coins[i];
        if (cn->state != CM_LIVE) continue;
        if (cn->x + 2 <= cam || cn->x >= cam + JUMP_W) continue;
        jm_fill(c, cam, cn->x, cn->y, 2, 2, gold);
        jm_put(c, cam, cn->x, cn->y, glint);
    }
}

/* The flag: a pole at the last column of the course and a pennant off its top.
 * Touching the pole is what ends the course. */
static void jm_draw_flag(ml_canvas *c, const jumpman_state *s)
{
    const ml_rgb pole  = ML_RGB(216, 216, 224);
    const ml_rgb cloth = ML_RGB(240, 72, 64);
    const int top = JUMP_GROUND_ROW - 9;
    jm_fill(c, s->cam, JUMP_FLAG, top, 1, JUMP_GROUND_ROW - top, pole);
    for (int i = 0; i < 3; i++)
        jm_put(c, s->cam, JUMP_FLAG + 1, top + i, cloth);
    jm_fill(c, s->cam, JUMP_FLAG + 1, top, 2, 1, cloth);
    jm_put(c, s->cam, JUMP_FLAG + 2, top + 1, cloth);
}

/* A blob is dark where a block is bright: the two are the same kind of shape at
 * the same size on this panel, and a colour apart is all that tells the player
 * which one is about to cost a life. The eyes are the lightest thing on the
 * board, which is what makes it read as a creature rather than a block. */
static void jm_draw_blobs(ml_canvas *c, const jumpman_state *s)
{
    const ml_rgb shell = ML_RGB(104, 64, 44);
    const ml_rgb cap   = ML_RGB(64, 40, 26);
    const ml_rgb eye   = ML_RGB(255, 248, 240);
    const int head = JUMP_GROUND_ROW - BLOB_H;
    for (int i = 0; i < BLOB_SLOTS; i++) {
        const jumpman_blob *b = &s->blobs[i];
        if (!b->alive) continue;
        const int x = (int)(b->x >> 8);
        if (x + BLOB_W <= s->cam || x >= s->cam + JUMP_W) continue;
        jm_fill(c, s->cam, x, head + 1, BLOB_W, BLOB_H - 1, shell);
        jm_fill(c, s->cam, x, head, BLOB_W, 1, cap);
        /* Wide-set eyes: at four columns across, the two middle columns of a row
         * run together into a stripe, and a stripe is not a face. */
        jm_put(c, s->cam, x, head + 1, eye);
        jm_put(c, s->cam, x + BLOB_W - 1, head + 1, eye);
    }
}

/* The player: cap, face, overalls, boots. The eye follows the facing, which is
 * the whole of what tells the player they are running left. */
static void jm_draw_player(ml_canvas *c, const jumpman_state *s)
{
    const ml_rgb cap    = ML_RGB(224, 56, 48);
    const ml_rgb skin   = ML_RGB(252, 200, 152);
    const ml_rgb denim  = ML_RGB(56, 96, 208);
    const ml_rgb boots  = ML_RGB(112, 68, 36);
    const ml_rgb eye    = ML_RGB(24, 24, 24);
    const int x = s->px >> 8;
    const int y = s->py >> 8;
    const int cam = s->cam;

    jm_fill(c, cam, x, y, PLAYER_W, 1, cap);
    jm_fill(c, cam, x, y + 1, PLAYER_W, 2, skin);
    jm_fill(c, cam, x, y + 3, PLAYER_W, 2, denim);
    jm_fill(c, cam, x, y + 5, PLAYER_W, 1, boots);
    jm_put(c, cam, x + (s->facing ? 2 : 1), y + 1, eye);
}

static void jm_draw_hud(ml_canvas *c, const jumpman_state *s)
{
    const ml_font *f = ml_font_find("digits10");
    if (!f) f = ml_font_default();
    const ml_rgb hud = ML_RGB(255, 255, 255);
    const ml_rgb gold = ML_RGB(255, 216, 64);
    char buf[8];

    snprintf(buf, sizeof(buf), "%u", (unsigned)s->score);
    ml_text_draw(c, f, 1, 0, buf, hud, ML_SCALE_1X);

    /* The coin count wears a coin, so the two digits beside it need no label. */
    ml_canvas_fill_rect(c, ML_RECT(33, 4, 2, 2), gold);
    snprintf(buf, sizeof(buf), "%u", (unsigned)s->coin_count);
    ml_text_draw(c, f, 37, 0, buf, hud, ML_SCALE_1X);

    snprintf(buf, sizeof(buf), "%u", (unsigned)s->lives);
    ml_text_draw(c, f, 58, 0, buf, hud, ML_SCALE_1X);
}

static void jm_draw_terminal(const jumpman_state *s, ml_canvas *c)
{
    char buf[8];
    const ml_font *df = ml_font_find("digits10");
    if (!df) df = ml_font_default();
    snprintf(buf, sizeof(buf), "%u", (unsigned)s->score);
    ml_text_draw(c, df, 1, 0, buf, ML_RGB(255, 255, 255), ML_SCALE_1X);

    const char *word = s->status == JM_WON ? "WIN" : "OVER";
    const ml_font *of = ml_font_find("sans10");
    if (!of) of = ml_font_default();
    const int w = ml_text_width(of, word, ML_SCALE_1X);
    ml_text_draw(c, of, (JUMP_W - w) / 2, 17, word,
                 s->status == JM_WON ? ML_RGB(120, 255, 140) : ML_RGB(255, 60, 60),
                 ML_SCALE_1X);
}

static void jm_draw(const void *state, const ml_view *view, ml_canvas *c,
                    const ml_game_ctx *ctx)
{
    (void)view; (void)ctx;
    const jumpman_state *s = state;
    ml_canvas_clear(c, ml_black);

    /* A finished run clears the board: the score stands alone, so nothing on it
     * can be read as a course still being played. */
    if (s->status != JM_PLAYING) {
        jm_draw_terminal(s, c);
        return;
    }

    jm_draw_ground(c, s);
    jm_draw_pipes(c, s);
    jm_draw_blocks(c, s);
    jm_draw_flag(c, s);
    jm_draw_coins(c, s);
    jm_draw_blobs(c, s);
    jm_draw_player(c, s);
    jm_draw_hud(c, s);
}

static bool jm_snapshot(const void *state, uint8_t *buf, size_t cap, size_t *len)
{
    if (cap < sizeof(jumpman_state)) return false;
    memcpy(buf, state, sizeof(jumpman_state));
    *len = sizeof(jumpman_state);
    return true;
}

static void jm_restore(void *state, const uint8_t *buf, size_t len)
{
    /* Only a snapshot of exactly this game's state is a state at all: anything
     * else is a different game's or a truncated frame, and overwriting with it
     * would corrupt a run in progress. */
    if (len != sizeof(jumpman_state)) return;
    memcpy(state, buf, sizeof(jumpman_state));
}

static bool jm_is_over(const void *state)
{
    const jumpman_state *s = state;
    return s->status == JM_WON || s->status == JM_OVER;
}

const ml_game_vt ml_game_jumpman = {
    .id            = "jumpman",
    .pref_w        = JUMP_W, .pref_h = JUMP_H,
    .fit           = ML_FIT_LETTERBOX,
    .tick_ms       = 25,
    .max_players   = 1,
    .state_size    = sizeof(jumpman_state),
    .controls      = jumpman_controls,
    .control_count = 4,
    .init          = jm_init,
    .reset         = jm_reset,
    .input         = jm_input,
    .update        = jm_update,
    .draw          = jm_draw,
    .snapshot      = jm_snapshot,
    .restore       = jm_restore,
    .is_over       = jm_is_over,
};
