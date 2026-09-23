/*
 * game_jumpman.c - Jumpman: a hand-authored level, run right and jump the gaps.
 *
 * The Mario-shaped game of the set. A 4x6 character runs a 256-column level
 * authored for a 64x32 window that follows it, and the level is const data in
 * this translation unit: the ground runs, the pits between them, the pipes, the
 * blocks, the coins, the enemies, the checkpoint and the flag. Nothing here is
 * rolled from the session PRNG, so a peer that rebuilds after a death plays the
 * one level that was designed rather than another soup of it.
 *
 * What the player meets, in order: a mushroom block and a "?" row in the
 * opening, a goomba, a brick row to jump for, a second goomba, a pipe with a
 * piranha plant in it, a koopa whose shell can be stomped and kicked, a pit
 * with a coin over it, a checkpoint flag, a four-wide "?" row, a wide chasm
 * with a high coin, and a stone staircase up to the flagpole.
 *
 * The rules that make that readable at this size:
 *
 * - an enemy sleeps until the player is within a dozen columns, so each beat
 *   arrives when the player does and can be taken in from the ground.
 * - a stomp squashes a goomba, turns a koopa into a shell, and stops a sliding
 *   shell; touching a still shell kicks it away, and a kicked shell kills what
 *   it runs into and cannot be outrun, so it has to be stopped.
 * - a "?" block pays for the column the head hit, one coin per column bumped,
 *   which is why a four-wide row is worth four jumps rather than one.
 * - a mushroom grows the player: one hit shrinks them with a moment of
 *   invulnerability, the next one costs a life. A death reloads the authored
 *   level and restarts at the checkpoint once the player has passed it, so no
 *   death is a replay of ground already cleared.
 *
 * The phone's tilt is a direction here rather than a position, the same reading
 * Snake and Maze take from theirs: a deliberate angle runs that way, a level
 * phone stands still, and an idle axis hands the run back to the buttons. A
 * held angle cannot express a jump, so Jump is a button and the level is
 * playable on the pad alone. Every animation is driven by a state counter and
 * never by the tick, so a peer's frame for the same state is the same frame.
 */
#include <stdio.h>
#include <string.h>

#include "mirror/font.h"
#include "mirror/game.h"
#include "mirror/gamerun.h"

/* The logical panel the game is authored for: 64 columns of level in a window,
 * letterboxed by the runtime, so the physics below is always in these
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
#define JM_NONE         0xFF   /* no ground in this column */

/* The player: 4 wide, six rows small and nine rows super, standing on the
 * ground row with their feet placed so a size change never moves them. */
#define PLAYER_W       4
#define PLAYER_H_SMALL 6
#define PLAYER_H_SUPER 9
#define PLAYER_START_X 3

/*
 * Q8.8 physics. Gravity is 56/256 of a pixel per tick squared and the jump
 * leaves the ground at 504/256, so a full hold rises a little under eight rows
 * and is back down 18 ticks later - a jump a player can aim. Gravity is applied
 * before the move, and a body resting on the ground is not accelerated at all:
 * a standing player neither sinks a pixel and snaps back nor jitters.
 */
#define JM_GRAVITY      56
#define JM_JUMP         504
#define JM_JUMP_CUT     336   /* an early release clamps the rise to this */
#define JM_MAX_FALL     512   /* 2 px/tick: the fall is brisk, never a blur */
#define JM_RUN          288   /* 1.125 px/tick, about 45 px/s */
#define JM_STOMP_BOUNCE 256

/* Blocks: one packed byte per column, four rows thick, so a block reads square
 * against the four-wide player. The row is what the block is for: row 6 hangs
 * below head height so a jump puts the head into its underside, and a raised
 * block (row 11, 13 or 15) is a platform to land on and a wall from the side. */
#define BLOCK_H   4
#define JM_NOBLK  0xFF
#define BM_BRICK  1
#define BM_COIN   2
#define BM_MUSH   3
#define BM_STONE  4
#define BM_USED   5
#define BM_BROKEN 6

/* Pipes: three columns wide, their surface a raised ground row, one of them
 * with a piranha plant that rises and sinks on its own cycle. */
#define PIPE_W     3
#define PIPE_SLOTS 6
#define PM_NONE    0xFF
#define PLANT_ROWS 5
#define PLANT_CYCLE 104

/* Coins float 2x2 in the air; a bumped block pays with a popped coin that rises
 * six rows and vanishes, which is the only thing that tells the player a block
 * paid at all. */
#define COIN_SLOTS 24
#define CM_NONE    0
#define CM_LIVE    1
#define CM_TAKEN   2
#define POP_SLOTS  3
#define POP_TICKS  24

/* Enemies: a goomba, a koopa and the shell a koopa leaves. A walking enemy
 * wakes when the player is twelve columns away and walks at a third of the
 * player's run; a kicked shell slides faster than the player can run. */
#define ENEMY_SLOTS  12
#define ENEMY_W      4
#define GOOMBA_H     3
#define KOOPA_H      6
#define SHELL_H      3
#define ENEMY_WALK   96    /* 0.375 px/tick */
#define SHELL_SLIDE  320   /* 1.25 px/tick: the player cannot outrun it */
#define ENEMY_WAKE   12    /* columns in front of the player an enemy wakes at */
#define SQUASH_TICKS 18
#define EK_NONE      0xFF  /* the kind of an empty enemy slot */

/* The mushroom: four rows square, rises out of the block that paid it, then
 * walks. It falls off a ledge rather than turning at one, but it does turn at a
 * pit, so the player can never lose one to geometry. */
#define ITEM_SLOTS 2
#define ITEM_W     4
#define ITEM_H     4
#define ITEM_WALK  128     /* 0.5 px/tick */
#define ITEM_FALL  256     /* 1 px/tick: items fall at a fixed step */
#define IS_NONE    0xFF    /* the state of an empty item slot */

/* The player's timers. */
#define INVULN_TICKS 80    /* 2 s of flashing after a hit while super */
#define DIE_TICKS    55    /* the world is frozen for this long */
#define BUMP_TICKS   6     /* how long a bumped block is jerked up for */

/* Score and the coin count, both capped so the HUD never runs out of digits. */
#define SCORE_COIN    200
#define SCORE_GOOMBA  100
#define SCORE_KOOPA   100
#define SCORE_SHELL   200
#define SCORE_BRICK   50
#define SCORE_POWERUP 1000
#define SCORE_FLAG    1000
#define SCORE_STOMP   100
#define SCORE_MAX     9999
#define COIN_MAX      99

/* The level: 256 columns, one run of ground per entry, the checkpoint flag and
 * the goal flagpole. */
#define JUMP_COLS    256
#define CHECKPOINT_X 116
#define FLAG_X       (JUMP_COLS - 4)

/* A deliberate tilt, not a resting hand: a quarter of the travel, about 11
 * degrees off neutral. */
#define JM_TILT_TURN (32767 / 4)

enum { JM_PLAYING = 0, JM_DYING, JM_WON, JM_OVER };
enum { JM_IN_LEFT = 0, JM_IN_RIGHT = 1, JM_IN_JUMP = 2, JM_IN_TILT = 3 };
enum { EK_GOOMBA = 0, EK_KOOPA = 1, EK_SHELL = 2 };
enum { ES_WALK = 0, ES_SHELL, ES_SLIDE, ES_SQUASH };
enum { IS_EMERGE = 0, IS_WALK };
enum {
    JM_EVENT_COIN = 1, JM_EVENT_STOMP, JM_EVENT_DEATH, JM_EVENT_FLAG,
    JM_EVENT_HURT, JM_EVENT_BUMP, JM_EVENT_BREAK, JM_EVENT_KICK,
    JM_EVENT_CHECKPOINT, JM_EVENT_POWERUP
};

/* ---- the level, authored ------------------------------------------------ */

/* One entry per run of columns. Together the runs cover 0..JUMP_COLS-1 exactly,
 * so a gap between them is a pit and nothing else. */
#define JML_PIT 0xFF
typedef struct { uint8_t x, w, surf; } jm_ground_def;     /* surf = JML_PIT for a pit */
typedef struct { uint8_t x, w, row, kind; } jm_block_def; /* w 1-column blocks in a row */
typedef struct { uint8_t x, h, plant; } jm_pipe_def;      /* h = rows above the ground */
typedef struct { uint8_t x, y; } jm_coin_def;             /* top-left, world pixels */
typedef struct { uint8_t x, row; int8_t dir; uint8_t kind; } jm_enemy_def; /* row = the surface its feet rest on */

static const jm_ground_def jm_level_ground[] = {
    {   0, 105, 19 }, { 105,   3, JML_PIT }, { 108,  66, 19 }, { 174,   5, JML_PIT },
    { 179,  38, 19 }, { 217,   8, JML_PIT }, { 225,  31, 19 },
};

static const jm_pipe_def jm_level_pipes[] = {
    {  66, 5, 1 },
};

static const jm_block_def jm_level_blocks[] = {
    {   2, 1,  6, BM_MUSH  }, {   7, 4,  6, BM_COIN }, {  35, 4,  6, BM_BRICK },
    { 146, 4,  6, BM_COIN  },
    { 244, 1, 15, BM_STONE }, { 245, 1, 15, BM_STONE }, { 245, 1, 11, BM_STONE },
    { 246, 1, 15, BM_STONE }, { 246, 1, 11, BM_STONE }, { 247, 1, 15, BM_STONE },
};

static const jm_coin_def jm_level_coins[] = {
    {  27, 11 }, {  55, 11 }, {  68, 11 }, {  97, 11 }, { 106, 13 }, { 138, 11 },
    { 166, 11 }, { 176, 13 }, { 209, 11 }, { 220,  8 }, { 240, 11 },
};

static const jm_enemy_def jm_level_enemies[] = {
    {  23, 19, -1, EK_GOOMBA }, {  51, 19, -1, EK_GOOMBA },
    {  93, 19, -1, EK_KOOPA  }, { 134, 19, -1, EK_GOOMBA },
    { 162, 19, -1, EK_KOOPA  }, { 205, 19, -1, EK_GOOMBA },
};

/* The columns of block the authored table places. One block per column, so a
 * second entry for a column is superseded by the later one; the staircase's
 * stacked stones therefore read as the column's top block. */
#define JM_LEVEL_BLOCK_COLS 19

typedef char jm_level_pipes_fit[
    (sizeof jm_level_pipes / sizeof jm_level_pipes[0] <= PIPE_SLOTS) ? 1 : -1];
typedef char jm_level_coins_fit[
    (sizeof jm_level_coins / sizeof jm_level_coins[0] <= COIN_SLOTS) ? 1 : -1];
typedef char jm_level_enemies_fit[
    (sizeof jm_level_enemies / sizeof jm_level_enemies[0] <= ENEMY_SLOTS) ? 1 : -1];
typedef char jm_level_block_cols_fit[(JM_LEVEL_BLOCK_COLS <= JUMP_COLS) ? 1 : -1];

/* ---- state -------------------------------------------------------------- */

typedef struct {
    uint8_t x;      /* left column */
    uint8_t top;    /* world row of the pipe's surface */
    uint8_t plant;  /* whether a piranha plant lives in it */
    uint8_t phase;  /* 0..PLANT_CYCLE-1, the plant's rise and sink */
} jumpman_pipe;

typedef struct {
    int32_t x, y;   /* top-left, Q8.8 */
    int16_t vx, vy;
    int8_t  dir;    /* 0 when it is a shell at rest */
    uint8_t kind, state, anim, awake;
} jm_enemy;

typedef struct {
    uint8_t x, y;   /* top-left, world pixels */
    uint8_t state;  /* CM_* */
} jumpman_coin;

typedef struct {
    uint8_t x, y;   /* top-left, world pixels */
    uint8_t anim;   /* ticks left; 0 is an empty slot */
} jm_pop;

typedef struct {
    int32_t x, y;   /* top-left, Q8.8 */
    int8_t  dir;    /* -1 left, +1 right */
    uint8_t state, anim;
} jm_item;

typedef struct {
    int32_t  px, py;        /* the player's top-left, Q8.8 */
    int32_t  vx, vy;
    uint8_t  surf[JUMP_COLS];   /* ground surface row, JM_NONE for a pit */
    uint8_t  block[JUMP_COLS];  /* packed kind and row, JM_NOBLK for none */
    jumpman_pipe pipes[PIPE_SLOTS];
    jm_enemy enemies[ENEMY_SLOTS];
    jumpman_coin coins[COIN_SLOTS];
    jm_pop   pop[POP_SLOTS];
    jm_item  items[ITEM_SLOTS];
    int16_t  cam;           /* the column drawn at the left edge */
    int16_t  tilt_x;        /* ML_AXIS_IDLE until a controller drives it */
    uint16_t score;
    uint16_t coin_count;
    uint8_t  lives;
    uint8_t  status;        /* JM_* */
    uint8_t  facing;        /* 1 right, 0 left */
    uint8_t  jump_queued;   /* a press waiting for the ground */
    uint8_t  jump_held;
    uint8_t  held_left, held_right;
    uint8_t  super;         /* 1 when grown */
    uint8_t  invuln;        /* ticks of flashing left */
    uint8_t  dying;         /* ticks of the death pause left */
    uint8_t  checkpoint;    /* the checkpoint flag has been passed */
    uint8_t  bump_x;        /* the column of the block being jerked */
    uint8_t  bump_anim;     /* ticks of jerk left */
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

/* ---- blocks: one packed byte per column --------------------------------- */

/* kind in the top three bits, row in the low five. Rows are <= 16, kinds <= 6,
 * which is what lets 256 columns of block live in 256 bytes. */
static uint8_t jm_blk_make(uint8_t kind, uint8_t row)
{
    return (uint8_t)((kind << 5) | row);
}
static uint8_t jm_blk_kind(uint8_t v) { return (uint8_t)(v >> 5); }
static uint8_t jm_blk_row(uint8_t v)  { return (uint8_t)(v & 31); }

/* ---- world queries ------------------------------------------------------ */

/* A world pixel is solid when it is at or under its column's surface, or inside
 * a block that still stands. Off either end of the level is solid, so nothing
 * walks out of the world, and below the field is open air, because that is how
 * a pit ends a life. */
static bool jm_solid(const jumpman_state *s, int x, int y)
{
    if (x < 0 || x >= JUMP_COLS) return true;
    if (y < 0 || y >= JUMP_ROWS) return false;
    if (s->surf[x] != JM_NONE && y >= (int)s->surf[x]) return true;
    if (s->block[x] != JM_NOBLK) {
        const uint8_t k = jm_blk_kind(s->block[x]), r = jm_blk_row(s->block[x]);
        if (k != BM_BROKEN && y >= (int)r && y < (int)r + BLOCK_H) return true;
    }
    return false;
}

/* Whether any row of a column run is solid: the two tests a swept move needs,
 * one per axis. */
static bool jm_col_solid(const jumpman_state *s, int x, int y0, int y1)
{
    for (int y = y0; y <= y1; y++) if (jm_solid(s, x, y)) return true;
    return false;
}

/* The column of a body a row is first solid in, or -1: the one a head bump
 * belongs to. */
static int jm_row_first(const jumpman_state *s, int l, int r, int row)
{
    for (int x = l; x <= r; x++) if (jm_solid(s, x, row)) return x;
    return -1;
}

/* Whether a body whose left column is l and width w has ground under the two
 * middle columns of its feet. That is what "standing on something" means here:
 * a body falls once its centre leaves the ground, so a pit drops whatever walks
 * into it however narrow the pit is, and a body on a ledge stands until it has
 * actually stepped off. */
static bool jm_floor_solid(const jumpman_state *s, int l, int w, int row)
{
    const int a = l + (w - 1) / 2, b = l + w / 2;
    return jm_solid(s, a, row) || jm_solid(s, b, row);
}

/* Whether a walker is at rest on the ground: exactly on a surface, with its
 * middle columns over it. Only then is gravity withheld, so a body that is
 * airborne - or fractionally below a ledge it has just left - keeps falling
 * instead of hovering a pixel inside the ground. */
static bool jm_resting(const jumpman_state *s, int32_t x, int32_t y, int w, int h)
{
    if ((y & 0xFF) != 0) return false;
    return jm_floor_solid(s, x >> 8, w, (y >> 8) + h);
}

/* The vertical velocity of a walker: one at rest on the ground is not
 * accelerated at all, so it holds its row instead of sinking a pixel and
 * snapping back; one in the air falls under gravity to the terminal velocity. */
static int32_t jm_fall(int32_t vy, bool resting)
{
    if (resting && vy >= 0) return 0;
    vy += JM_GRAVITY;
    return vy > JM_MAX_FALL ? (int32_t)JM_MAX_FALL : vy;
}

/* The player's height, and the box that follows from it. The top-left is the
 * body's own, so the feet stay where they are when the size changes. */
static int play_h(const jumpman_state *s) { return s->super ? PLAYER_H_SUPER : PLAYER_H_SMALL; }
static int jm_left(const jumpman_state *s)   { return s->px >> 8; }
static int jm_right(const jumpman_state *s)  { return (s->px >> 8) + PLAYER_W - 1; }
static int jm_top(const jumpman_state *s)    { return s->py >> 8; }
static int jm_bottom(const jumpman_state *s) { return (s->py >> 8) + play_h(s) - 1; }

/* Whether the player is standing on something. A resting body is exactly one
 * pixel above the surface, so the row the feet are in is the surface's, and it
 * is the body's middle columns that decide - the same rule every walker uses. */
static bool jm_on_ground(const jumpman_state *s)
{
    return jm_resting(s, s->px, s->py, PLAYER_W, play_h(s));
}

/* Whether every pixel of a rectangle is free: the test a grown player has to
 * pass before the mushroom is consumed. */
static bool jm_body_clear(const jumpman_state *s, int x, int y, int w, int h)
{
    for (int yy = y; yy < y + h; yy++)
        for (int xx = x; xx < x + w; xx++)
            if (jm_solid(s, xx, yy)) return false;
    return true;
}

/* ---- one moved body ----------------------------------------------------- */

typedef struct { int32_t x, y; int w, h; } jm_body;   /* Q8.8 top-left */

#define JMHIT_FLOOR 1u
#define JMHIT_CEIL  2u
#define JMHIT_WALL  4u

/*
 * Move b by (vx, vy), resolving against the terrain the way the two hand-written
 * passes used to: the horizontal pass pushes it out of the first wall it enters,
 * and the vertical pass tests every row the body crossed rather than just the
 * destination, because a fall moves two pixels and a jump nearly two. A rising
 * body reports the column of its first ceiling hit in *ceil_x, which is the
 * column whose block gets bumped.
 */
static uint8_t jm_move(const jumpman_state *s, jm_body *b, int32_t vx, int32_t vy,
                       int *ceil_x)
{
    uint8_t hit = 0;
    if (ceil_x) *ceil_x = -1;

    if (vx != 0) {
        b->x += vx;
        const int top = b->y >> 8, bot = (b->y >> 8) + b->h - 1;
        if (vx > 0) {
            const int col = (b->x >> 8) + b->w - 1;
            if (jm_col_solid(s, col, top, bot)) {
                b->x = (int32_t)(col - b->w) << 8;
                hit |= JMHIT_WALL;
            }
        } else {
            const int col = b->x >> 8;
            if (jm_col_solid(s, col, top, bot)) {
                b->x = (int32_t)(col + 1) << 8;
                hit |= JMHIT_WALL;
            }
        }
    }

    if (vy != 0) {
        const int l = b->x >> 8, r = l + b->w - 1;
        const int from = vy > 0 ? (b->y >> 8) + b->h - 1 : b->y >> 8;
        b->y += vy;
        const int to = vy > 0 ? (b->y >> 8) + b->h - 1 : b->y >> 8;
        if (vy > 0) {
            for (int row = from; row <= to; row++) {
                if (!jm_floor_solid(s, l, b->w, row)) continue;
                b->y = (int32_t)(row - b->h) << 8;
                hit |= JMHIT_FLOOR;
                break;
            }
        } else {
            for (int row = from; row >= to; row--) {
                const int col = jm_row_first(s, l, r, row);
                if (col < 0) continue;
                b->y = (int32_t)(row + 1) << 8;
                hit |= JMHIT_CEIL;
                if (ceil_x) *ceil_x = col;
                break;
            }
        }
    }
    return hit;
}

/* ---- enemies: shared queries ------------------------------------------- */

static int jm_enemy_h(uint8_t kind)
{
    if (kind == EK_KOOPA) return KOOPA_H;
    if (kind == EK_GOOMBA) return GOOMBA_H;
    return SHELL_H;
}

/* How far in front of an enemy the player is: the awake test. */
static int jm_enemy_gap(const jumpman_state *s, const jm_enemy *e)
{
    const int d = (e->x >> 8) - (s->px >> 8);
    return d < 0 ? -d : d;
}

/* ---- loading the authored level ---------------------------------------- */

static int jm_pipe_slot(const jumpman_state *s)
{
    for (int i = 0; i < PIPE_SLOTS; i++) if (s->pipes[i].x == PM_NONE) return i;
    return -1;
}

static int jm_coin_slot(const jumpman_state *s)
{
    for (int i = 0; i < COIN_SLOTS; i++) if (s->coins[i].state == CM_NONE) return i;
    return -1;
}

static int jm_enemy_slot(const jumpman_state *s)
{
    for (int i = 0; i < ENEMY_SLOTS; i++) if (s->enemies[i].kind == EK_NONE) return i;
    return -1;
}

/*
 * Build the level from the authored tables and put the player at its start.
 * This is the whole of (re)starting: reset calls it once, and the death path
 * calls it again, so the level a death reloads is the authored one - a bumped
 * block is live again, a taken coin is back, and every enemy is at its spawn.
 * The score, the coin count, the lives and the checkpoint are the only things a
 * death carries, and this function deliberately does not touch them.
 */
static void jm_load_level(jumpman_state *s)
{
    memset(s->surf, JM_NONE, sizeof s->surf);
    memset(s->block, JM_NOBLK, sizeof s->block);

    for (int i = 0; i < PIPE_SLOTS; i++) {
        s->pipes[i].x = PM_NONE;
        s->pipes[i].top = 0;
        s->pipes[i].plant = 0;
        s->pipes[i].phase = 0;
    }
    for (int i = 0; i < ENEMY_SLOTS; i++) {
        memset(&s->enemies[i], 0, sizeof s->enemies[i]);
        s->enemies[i].kind = EK_NONE;
    }
    for (int i = 0; i < COIN_SLOTS; i++) {
        s->coins[i].x = 0;
        s->coins[i].y = 0;
        s->coins[i].state = CM_NONE;
    }
    for (int i = 0; i < POP_SLOTS; i++) {
        s->pop[i].x = 0;
        s->pop[i].y = 0;
        s->pop[i].anim = 0;
    }
    for (int i = 0; i < ITEM_SLOTS; i++) {
        memset(&s->items[i], 0, sizeof s->items[i]);
        s->items[i].state = IS_NONE;
    }

    for (unsigned i = 0; i < sizeof jm_level_ground / sizeof jm_level_ground[0]; i++) {
        const jm_ground_def *g = &jm_level_ground[i];
        if (g->surf == JML_PIT) continue;
        for (int x = g->x; x < (int)g->x + (int)g->w; x++) s->surf[x] = g->surf;
    }

    for (unsigned i = 0; i < sizeof jm_level_pipes / sizeof jm_level_pipes[0]; i++) {
        const jm_pipe_def *p = &jm_level_pipes[i];
        const int slot = jm_pipe_slot(s);
        if (slot < 0) break;
        const int top = JUMP_GROUND_ROW - (int)p->h;
        for (int x = p->x; x < (int)p->x + PIPE_W; x++) s->surf[x] = (uint8_t)top;
        s->pipes[slot].x = p->x;
        s->pipes[slot].top = (uint8_t)top;
        s->pipes[slot].plant = p->plant;
        s->pipes[slot].phase = 0;
    }

    for (unsigned i = 0; i < sizeof jm_level_blocks / sizeof jm_level_blocks[0]; i++) {
        const jm_block_def *b = &jm_level_blocks[i];
        for (int k = 0; k < (int)b->w; k++)
            s->block[b->x + k] = jm_blk_make(b->kind, b->row);
    }

    for (unsigned i = 0; i < sizeof jm_level_coins / sizeof jm_level_coins[0]; i++) {
        const jm_coin_def *c = &jm_level_coins[i];
        const int slot = jm_coin_slot(s);
        if (slot < 0) break;
        s->coins[slot].x = c->x;
        s->coins[slot].y = c->y;
        s->coins[slot].state = CM_LIVE;
    }

    for (unsigned i = 0; i < sizeof jm_level_enemies / sizeof jm_level_enemies[0]; i++) {
        const jm_enemy_def *d = &jm_level_enemies[i];
        const int slot = jm_enemy_slot(s);
        if (slot < 0) break;
        jm_enemy *e = &s->enemies[slot];
        e->x = (int32_t)d->x << 8;
        e->y = (int32_t)((int)d->row - jm_enemy_h(d->kind)) << 8;
        e->vx = 0;
        e->vy = 0;
        e->kind = d->kind;
        e->state = ES_WALK;
        e->dir = d->dir;
        e->anim = 0;
        e->awake = 0;
    }

    s->px = (int32_t)(s->checkpoint ? CHECKPOINT_X : PLAYER_START_X) << 8;
    s->py = (int32_t)(JUMP_GROUND_ROW - PLAYER_H_SMALL) << 8;
    s->vx = 0;
    s->vy = 0;
    s->super = 0;
    s->invuln = 0;
    s->dying = 0;
    s->status = JM_PLAYING;
    s->cam = 0;
    s->facing = 1;
    s->jump_queued = 0;
    s->jump_held = 0;
    s->bump_x = 0xFF;
    s->bump_anim = 0;
}

/* ---- score, payouts and spawns ----------------------------------------- */

static void jm_award(jumpman_state *s, int points, int coins)
{
    const int total = (int)s->score + points;
    s->score = (uint16_t)(total > SCORE_MAX ? SCORE_MAX : total);
    if (coins) {
        int c = (int)s->coin_count + coins;
        if (c > COIN_MAX) c = COIN_MAX;
        s->coin_count = (uint16_t)c;
    }
}

/* A popped coin: the block's payout rising six rows over its life. */
static void jm_spawn_pop(jumpman_state *s, int x, int row)
{
    for (int i = 0; i < POP_SLOTS; i++) {
        if (s->pop[i].anim != 0) continue;
        s->pop[i].x = (uint8_t)x;
        s->pop[i].y = (uint8_t)row;
        s->pop[i].anim = POP_TICKS;
        return;
    }
}

/* A mushroom, starting inside the block that paid it. */
static void jm_spawn_item(jumpman_state *s, int x, int row)
{
    for (int i = 0; i < ITEM_SLOTS; i++) {
        jm_item *it = &s->items[i];
        if (it->state != IS_NONE) continue;
        it->x = (int32_t)x << 8;
        it->y = (int32_t)row << 8;
        it->dir = 1;
        it->state = IS_EMERGE;
        it->anim = 0;
        return;
    }
}

/*
 * A block met from below. The column the head hit is what pays, not the whole
 * run: a four-wide "?" row is four jumps for four coins. A rise of nearly two
 * pixels a tick can put the head a row inside the block rather than on its
 * underside, so any block ahead of the body counts as the bump. Any bump also
 * shakes off whatever is standing on the block.
 */
static void jm_bump(jumpman_state *s, int x, ml_game_ctx *ctx)
{
    if (x < 0 || x >= JUMP_COLS) return;
    const uint8_t v = s->block[x];
    if (v == JM_NOBLK) return;

    const uint8_t kind = jm_blk_kind(v), row = jm_blk_row(v);
    s->bump_x = (uint8_t)x;
    s->bump_anim = BUMP_TICKS;
    ml_ctx_emit_event(ctx, JM_EVENT_BUMP, 0);

    if (kind == BM_COIN) {
        s->block[x] = jm_blk_make(BM_USED, row);
        jm_award(s, SCORE_COIN, 1);
        jm_spawn_pop(s, x, row);
        ml_ctx_emit_event(ctx, JM_EVENT_COIN, 0);
    } else if (kind == BM_MUSH) {
        s->block[x] = jm_blk_make(BM_USED, row);
        jm_spawn_item(s, x, row);
        ml_ctx_emit_event(ctx, JM_EVENT_POWERUP, 0);
    } else if (kind == BM_BRICK && s->super) {
        s->block[x] = jm_blk_make(BM_BROKEN, row);
        jm_award(s, SCORE_BRICK, 0);
        ml_ctx_emit_event(ctx, JM_EVENT_BREAK, 0);
    }

    for (int i = 0; i < ENEMY_SLOTS; i++) {
        jm_enemy *e = &s->enemies[i];
        if (e->kind == EK_NONE || e->state == ES_SQUASH || !e->awake) continue;
        const int ex = e->x >> 8;
        if (ex > x || ex + ENEMY_W - 1 < x) continue;
        if ((e->y >> 8) + jm_enemy_h(e->kind) != (int)row) continue;
        e->state = ES_SQUASH;
        e->anim = 0;
        jm_award(s, SCORE_STOMP, 0);
    }
}

/* ---- piranha plants ----------------------------------------------------- */

/* How many rows of itself a plant has out of its pipe, from its phase: hidden
 * for 40 ticks, up over 20, held for 24, down over 20. */
static int jm_plant_rows(uint8_t phase)
{
    if (phase < 40) return 0;
    if (phase < 60) return 1 + (int)(phase - 40) / 4;
    if (phase < 84) return PLANT_ROWS;
    return PLANT_ROWS - 1 - (int)(phase - 84) / 4;
}

/* Whether the player's body covers any of a pipe's columns: what stops a plant
 * rising under them, and what makes standing on a pipe the way past one. */
static bool jm_player_over_pipe(const jumpman_state *s, const jumpman_pipe *p)
{
    return !(jm_right(s) < (int)p->x || jm_left(s) > (int)p->x + PIPE_W - 1);
}

static void jm_update_plants(jumpman_state *s)
{
    for (int i = 0; i < PIPE_SLOTS; i++) {
        jumpman_pipe *p = &s->pipes[i];
        if (p->x == PM_NONE || !p->plant) continue;
        /* About to rise under the player: hold, so a pipe is a place to wait. */
        if (p->phase == 39 && jm_player_over_pipe(s, p)) continue;
        p->phase = (uint8_t)((p->phase + 1) % PLANT_CYCLE);
    }
}

/* The plant's risen body: the pipe's three columns, from its top up. */
static bool jm_plant_touch(const jumpman_state *s)
{
    const int l = jm_left(s), r = jm_right(s), top = jm_top(s), bot = jm_bottom(s);
    for (int i = 0; i < PIPE_SLOTS; i++) {
        const jumpman_pipe *p = &s->pipes[i];
        if (p->x == PM_NONE || !p->plant) continue;
        const int rows = jm_plant_rows(p->phase);
        if (rows == 0) continue;
        if (r < (int)p->x || l > (int)p->x + PIPE_W - 1) continue;
        if (bot < (int)p->top - rows || top > (int)p->top - 1) continue;
        return true;
    }
    return false;
}

/* ---- enemies: movement, stomps, shells --------------------------------- */

/*
 * One enemy's tick. A walking enemy turns where the column its leading edge
 * would enter is solid, or where that column has no ground at any row from its
 * feet down: that is a pit, and an enemy that walked into one would be an enemy
 * the player never has to deal with. A step down is not a turn - gravity takes
 * it down, which is how a goomba comes off a staircase. A kicked shell checks
 * the wall only, so it can slide into a pit and be gone.
 */
static void jm_enemy_walk(const jumpman_state *s, jm_enemy *e)
{
    const int h = jm_enemy_h(e->kind);
    const int dir = e->dir < 0 ? -1 : 1;
    const int lead = dir > 0 ? (e->x >> 8) + ENEMY_W : (e->x >> 8) - 1;
    const int top = e->y >> 8, bot = (e->y >> 8) + h - 1;

    bool turn = jm_col_solid(s, lead, top, bot);
    if (!turn && e->state != ES_SLIDE) {
        bool ground = false;
        for (int y = bot + 1; y < JUMP_ROWS; y++)
            if (jm_solid(s, lead, y)) { ground = true; break; }
        if (!ground) turn = true;
    }
    if (turn) {
        e->dir = (int8_t)-e->dir;
        e->anim++;
        return;
    }

    e->vy = (int16_t)jm_fall(e->vy, jm_resting(s, e->x, e->y, ENEMY_W, h));
    jm_body b = { e->x, e->y, ENEMY_W, h };
    const uint8_t hit = jm_move(s, &b, (int32_t)dir * (e->state == ES_SLIDE ? SHELL_SLIDE : ENEMY_WALK),
                                e->vy, NULL);
    e->x = b.x;
    e->y = b.y;
    if (hit & (JMHIT_FLOOR | JMHIT_CEIL)) e->vy = 0;
    if (hit & JMHIT_WALL) e->dir = (int8_t)-e->dir;
    e->anim++;
}

/* A sliding shell runs down whatever it meets and keeps going; two sliding
 * shells that meet reverse and neither dies. A still shell is ignored by the
 * walking enemies, so this is the only way enemies interact at all. */
static void jm_shell_hits(jumpman_state *s, ml_game_ctx *ctx)
{
    for (int i = 0; i < ENEMY_SLOTS; i++) {
        jm_enemy *a = &s->enemies[i];
        if (a->kind != EK_SHELL || a->state != ES_SLIDE) continue;
        for (int j = i + 1; j < ENEMY_SLOTS; j++) {
            jm_enemy *b = &s->enemies[j];
            if (b->kind == EK_NONE || b->state == ES_SQUASH) continue;
            const int ha = SHELL_H, hb = jm_enemy_h(b->kind);
            const int ax = a->x >> 8, bx = b->x >> 8;
            if (ax > bx + ENEMY_W - 1 || bx > ax + ENEMY_W - 1) continue;
            if ((a->y >> 8) > (b->y >> 8) + hb - 1) continue;
            if ((b->y >> 8) > (a->y >> 8) + ha - 1) continue;
            if (b->kind == EK_SHELL && b->state == ES_SLIDE) {
                a->dir = (int8_t)-a->dir;
                b->dir = (int8_t)-b->dir;
            } else {
                b->state = ES_SQUASH;
                b->anim = 0;
                jm_award(s, SCORE_SHELL, 0);
                ml_ctx_emit_event(ctx, JM_EVENT_KICK, 0);
            }
        }
    }
}

static void jm_update_enemies(jumpman_state *s, ml_game_ctx *ctx)
{
    for (int i = 0; i < ENEMY_SLOTS; i++) {
        jm_enemy *e = &s->enemies[i];
        if (e->kind == EK_NONE) continue;
        if (e->state == ES_SQUASH) {
            if (++e->anim >= SQUASH_TICKS) e->kind = EK_NONE;
            continue;
        }
        if (!e->awake) {
            if (jm_enemy_gap(s, e) >= ENEMY_WAKE) continue;
            e->awake = 1;
        }
        jm_enemy_walk(s, e);
        if ((e->y >> 8) > JUMP_ROWS + 2) { e->kind = EK_NONE; continue; }
    }
    jm_shell_hits(s, ctx);
}

/* The player's bounce off an enemy, and what that enemy becomes: a squashed
 * goomba, a koopa's still shell, or a sliding shell stopped. */
static void jm_stomp(jumpman_state *s, jm_enemy *e, ml_game_ctx *ctx)
{
    if (e->kind == EK_GOOMBA) {
        e->state = ES_SQUASH;
        e->anim = 0;
        jm_award(s, SCORE_GOOMBA, 0);
    } else if (e->state == ES_WALK) {
        /* A walking koopa loses its legs: the shell is three rows where the
         * koopa was six, with its feet where they were. */
        e->kind = EK_SHELL;
        e->state = ES_SHELL;
        e->y += (int32_t)(KOOPA_H - SHELL_H) << 8;
        e->dir = 0;
        e->anim = 0;
        jm_award(s, SCORE_KOOPA, 0);
    } else {
        /* A still shell stays put; a sliding one stops. */
        e->state = ES_SHELL;
        e->dir = 0;
    }
    s->vy = -JM_STOMP_BOUNCE;
    ml_ctx_emit_event(ctx, JM_EVENT_STOMP, 0);
}

/*
 * Overlap between the player and an enemy. A descending player whose feet are
 * at the enemy's head stomps; touching a still shell from anywhere but above
 * kicks it away from the player; anything else is a hit. The feet have to be
 * above the head rather than beside it, which is what stops a player standing
 * next to a goomba from scoring a stomp.
 */
static bool jm_enemy_touch(jumpman_state *s, ml_game_ctx *ctx)
{
    const int l = jm_left(s), r = jm_right(s), top = jm_top(s), bot = jm_bottom(s);
    bool hurt = false;
    for (int i = 0; i < ENEMY_SLOTS; i++) {
        jm_enemy *e = &s->enemies[i];
        if (e->kind == EK_NONE || e->state == ES_SQUASH) continue;
        const int h = jm_enemy_h(e->kind);
        const int ex = e->x >> 8, ey = e->y >> 8;
        if (r < ex || l > ex + ENEMY_W - 1) continue;
        if (bot < ey || top > ey + h - 1) continue;

        if (s->vy > 0 && bot <= ey + 1) {
            jm_stomp(s, e, ctx);
        } else if (e->kind == EK_SHELL && e->state == ES_SHELL) {
            e->state = ES_SLIDE;
            e->dir = (int8_t)(l >= ex ? -1 : 1);
            ml_ctx_emit_event(ctx, JM_EVENT_KICK, 0);
        } else {
            hurt = true;
        }
    }
    return hurt;
}

/* ---- items and coins --------------------------------------------------- */

static void jm_update_items(jumpman_state *s)
{
    for (int i = 0; i < ITEM_SLOTS; i++) {
        jm_item *it = &s->items[i];
        if (it->state == IS_NONE) continue;
        if ((it->y >> 8) > JUMP_ROWS + 2) { it->state = IS_NONE; continue; }

        if (it->state == IS_EMERGE) {
            it->anim++;
            if ((it->anim & 3) == 0) it->y -= 1 << 8;
            if (it->anim >= ITEM_H * 4) { it->state = IS_WALK; it->anim = 0; }
            continue;
        }

        const int dir = it->dir < 0 ? -1 : 1;
        const int lead = dir > 0 ? (it->x >> 8) + ITEM_W : (it->x >> 8) - 1;
        const int top = it->y >> 8, bot = top + ITEM_H - 1;
        bool turn = jm_col_solid(s, lead, top, bot);
        if (!turn) {
            bool ground = false;
            for (int y = bot + 1; y < JUMP_ROWS; y++)
                if (jm_solid(s, lead, y)) { ground = true; break; }
            if (!ground) turn = true;
        }
        if (turn) { it->dir = (int8_t)-it->dir; continue; }

        const bool resting = jm_resting(s, it->x, it->y, ITEM_W, ITEM_H);
        jm_body b = { it->x, it->y, ITEM_W, ITEM_H };
        jm_move(s, &b, (int32_t)dir * ITEM_WALK, resting ? 0 : ITEM_FALL, NULL);
        it->x = b.x;
        it->y = b.y;
    }
}

/* Collecting a mushroom: the grown body has to fit where the small one stood,
 * or the mushroom keeps walking and the player tries again. */
static void jm_take_items(jumpman_state *s, ml_game_ctx *ctx)
{
    const int l = jm_left(s), r = jm_right(s), top = jm_top(s), bot = jm_bottom(s);
    for (int i = 0; i < ITEM_SLOTS; i++) {
        jm_item *it = &s->items[i];
        if (it->state == IS_NONE) continue;
        const int ix = it->x >> 8, iy = it->y >> 8;
        if (r < ix || l > ix + ITEM_W - 1) continue;
        if (bot < iy || top > iy + ITEM_H - 1) continue;
        if (!s->super) {
            const int ny = (s->py >> 8) - (PLAYER_H_SUPER - PLAYER_H_SMALL);
            if (!jm_body_clear(s, l, ny, PLAYER_W, PLAYER_H_SUPER)) continue;
            s->py -= (int32_t)(PLAYER_H_SUPER - PLAYER_H_SMALL) << 8;
            s->super = 1;
        }
        it->state = IS_NONE;
        jm_award(s, SCORE_POWERUP, 0);
        ml_ctx_emit_event(ctx, JM_EVENT_POWERUP, 0);
    }
}

static void jm_update_pops(jumpman_state *s)
{
    for (int i = 0; i < POP_SLOTS; i++) {
        jm_pop *p = &s->pop[i];
        if (p->anim == 0) continue;
        if ((p->anim & 3) == 0 && p->y > 0) p->y--;
        p->anim--;
    }
}

static void jm_take_coins(jumpman_state *s, ml_game_ctx *ctx)
{
    const int l = jm_left(s), r = jm_right(s), top = jm_top(s), bot = jm_bottom(s);
    for (int i = 0; i < COIN_SLOTS; i++) {
        jumpman_coin *c = &s->coins[i];
        if (c->state != CM_LIVE) continue;
        if (r < (int)c->x || l > (int)c->x + 1) continue;
        if (bot < (int)c->y || top > (int)c->y + 1) continue;
        c->state = CM_TAKEN;
        jm_award(s, SCORE_COIN, 1);
        ml_ctx_emit_event(ctx, JM_EVENT_COIN, 0);
    }
}

/* ---- lifecycle --------------------------------------------------------- */

/* The camera keeps the player a little left of centre and never leaves the
 * level, so the right edge is the last thing it shows. */
static void jm_follow(jumpman_state *s)
{
    int cam = (s->px >> 8) + PLAYER_W / 2 - JUMP_W / 2;
    if (cam < 0) cam = 0;
    if (cam > JUMP_COLS - JUMP_W) cam = JUMP_COLS - JUMP_W;
    s->cam = (int16_t)cam;
}

/* A hit. While super it shrinks and flashes instead of costing a life, and the
 * window it opens ignores every touch, so the player is never killed by the
 * thing that just hurt them. */
static void jm_hurt(jumpman_state *s, ml_game_ctx *ctx)
{
    if (s->invuln > 0 || s->status != JM_PLAYING) return;
    if (s->super) {
        s->super = 0;
        s->py += (int32_t)(PLAYER_H_SUPER - PLAYER_H_SMALL) << 8;
        s->invuln = INVULN_TICKS;
        ml_ctx_emit_event(ctx, JM_EVENT_HURT, 0);
        return;
    }
    s->status = JM_DYING;
    s->dying = DIE_TICKS;
    s->vx = 0;
    s->vy = -256;      /* a last hop, then the fall through the floor */
    ml_ctx_emit_event(ctx, JM_EVENT_DEATH, 0);
}

/* The end of the death pause: a life, then either the end of the run or the
 * authored level rebuilt and the player back on it. */
static void jm_end_death(jumpman_state *s)
{
    if (s->lives > 0) s->lives--;
    if (s->lives == 0) { s->status = JM_OVER; return; }
    jm_load_level(s);
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
    (void)ctx;
    jumpman_state *s = state;
    s->score = 0;
    s->coin_count = 0;
    s->lives = 3;
    s->checkpoint = 0;
    s->status = JM_PLAYING;
    s->held_left = 0;
    s->held_right = 0;
    s->tilt_x = ML_AXIS_IDLE;
    jm_load_level(s);
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

    /* A death is a pause, not a game: the world is frozen and only the body
     * falls, through whatever it was standing on, until the pause is over. */
    if (s->status == JM_DYING) {
        s->vy += JM_GRAVITY;
        if (s->vy > JM_MAX_FALL) s->vy = JM_MAX_FALL;
        s->py += s->vy;
        if (s->dying > 0) s->dying--;
        if (s->dying == 0) jm_end_death(s);
        return;
    }
    if (s->status != JM_PLAYING) return;

    if (s->invuln > 0) s->invuln--;
    if (s->bump_anim > 0) s->bump_anim--;

    /* Run. An engaged axis makes the phone's angle the direction - a held tilt
     * keeps running, a level phone stands still - and otherwise the buttons
     * are the only thing steering, with opposite buttons cancelling. */
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
    s->vy = jm_fall(s->vy, jm_on_ground(s));

    jm_update_plants(s);
    jm_update_enemies(s, ctx);
    jm_update_items(s);
    jm_update_pops(s);

    {
        jm_body b = { s->px, s->py, PLAYER_W, play_h(s) };
        int ceil_x = -1;
        const uint8_t hit = jm_move(s, &b, s->vx, s->vy, &ceil_x);
        s->px = b.x;
        s->py = b.y;
        if (hit & JMHIT_FLOOR) s->vy = 0;
        if (hit & JMHIT_CEIL) {
            s->vy = 0;
            jm_bump(s, ceil_x, ctx);
        }
    }

    /* Falling out of the level is a death, and it outranks everything else the
     * tick might have found. */
    if ((s->py >> 8) > JUMP_ROWS) { jm_hurt(s, ctx); return; }

    if (s->invuln == 0) {
        if (jm_enemy_touch(s, ctx)) jm_hurt(s, ctx);
        if (s->status == JM_PLAYING && jm_plant_touch(s)) jm_hurt(s, ctx);
    }
    if (s->status != JM_PLAYING) return;

    jm_take_items(s, ctx);
    jm_take_coins(s, ctx);

    if (!s->checkpoint && jm_right(s) >= CHECKPOINT_X) {
        s->checkpoint = 1;
        ml_ctx_emit_event(ctx, JM_EVENT_CHECKPOINT, 0);
    }
    if (jm_right(s) >= FLAG_X) {
        jm_award(s, SCORE_FLAG, 0);
        s->status = JM_WON;
        ml_ctx_emit_event(ctx, JM_EVENT_FLAG, 0);
        return;
    }
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

/* One palette for every sprite in the game, so a creature is a picture in the
 * source and nothing else. Letters follow the file's module comment; 'a' and
 * 'n' are the goomba's own two browns, kept from the blob it grew out of. */
static ml_rgb jm_sprite_col(char ch)
{
    switch (ch) {
    case 'r': return ML_RGB(224, 56, 48);   /* red: cap, plant head */
    case 's': return ML_RGB(252, 200, 152); /* skin */
    case 'd': return ML_RGB(56, 96, 208);   /* denim */
    case 'b': return ML_RGB(112, 68, 36);   /* boot brown */
    case 'k': return ML_RGB(24, 24, 24);    /* dark: the player's eye */
    case 'w': return ML_RGB(255, 248, 240); /* white */
    case 'g': return ML_RGB(56, 200, 88);   /* green: koopa and shell */
    case 'h': return ML_RGB(24, 128, 56);   /* dark green */
    case 'y': return ML_RGB(248, 208, 64);  /* yellow: the koopa's head */
    case 'p': return ML_RGB(252, 200, 152); /* cream: the mushroom's stem */
    case 'a': return ML_RGB(64, 40, 26);    /* the goomba's cap */
    case 'n': return ML_RGB(104, 64, 44);   /* the goomba's body */
    default:  return ML_RGB(0, 0, 0);       /* unreachable: sprite data only */
    }
}

static void jm_sprite(ml_canvas *c, int cam, int x, int y,
                      const char *const *rows, int w, int h)
{
    for (int dy = 0; dy < h; dy++) {
        for (int dx = 0; dx < w; dx++) {
            const char ch = rows[dy][dx];
            if (ch == '.') continue;
            jm_put(c, cam, x + dx, y + dy, jm_sprite_col(ch));
        }
    }
}

static const char *const jm_spr_goomba[GOOMBA_H] = { "aaaa", "wnnw", "nnnn" };
static const char *const jm_spr_koopa[KOOPA_H]   = { "..yy", "ggyy", "gggg",
                                                     "ghgg", "gggg", "b..b" };
static const char *const jm_spr_plant[3]         = { "rrr", "rwr", "www" };
static const char *const jm_spr_mushroom[ITEM_H] = { ".rr.", "rwrw", "rrrr", ".pp." };

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

/* The plant, only while it has rows out: its three-row head on top of the rise
 * and its stem down the pipe's middle to the rim. */
static void jm_draw_plants(ml_canvas *c, const jumpman_state *s)
{
    const ml_rgb stem = ML_RGB(24, 120, 48);
    const int cam = s->cam;

    for (int i = 0; i < PIPE_SLOTS; i++) {
        const jumpman_pipe *p = &s->pipes[i];
        if (p->x == PM_NONE || !p->plant) continue;
        const int rows = jm_plant_rows(p->phase);
        if (rows == 0) continue;
        if ((int)p->x + PIPE_W <= cam || (int)p->x >= cam + JUMP_W) continue;
        for (int y = (int)p->top - rows; y <= (int)p->top - 1; y++) {
            const int hr = y - ((int)p->top - rows);
            if (hr < 3) jm_sprite(c, cam, p->x, y, &jm_spr_plant[hr], 3, 1);
            else jm_put(c, cam, (int)p->x + 1, y, stem);
        }
    }
}

/*
 * Blocks, one column at a time with the run's mark drawn once. A block is four
 * rows thick: the base colour by kind, a lighter top row and a darker bottom
 * one. A "?" or a mushroom block also carries a two-pixel dark mark centred on
 * its run - a hook for the "?" and a dome for the mushroom - because one column
 * is one pixel wide and a single pixel cannot tell two blocks apart.
 */
static void jm_draw_blocks(ml_canvas *c, const jumpman_state *s)
{
    const ml_rgb brick = ML_RGB(196, 108, 48);
    const ml_rgb lit   = ML_RGB(236, 160, 88);
    const ml_rgb stone = ML_RGB(152, 152, 160);
    const ml_rgb stone_lit = ML_RGB(200, 200, 208);
    const ml_rgb gold  = ML_RGB(248, 208, 64);
    const ml_rgb gold_lit = ML_RGB(255, 240, 160);
    const ml_rgb used  = ML_RGB(96, 88, 80);
    const ml_rgb used_lit = ML_RGB(128, 120, 112);
    const ml_rgb mark  = ML_RGB(120, 84, 8);
    const int cam = s->cam;

    for (int x = cam; x < cam + JUMP_W; ) {
        if (x < 0 || x >= JUMP_COLS) { x++; continue; }
        const uint8_t v = s->block[x];
        if (v == JM_NOBLK || jm_blk_kind(v) == BM_BROKEN) { x++; continue; }

        const uint8_t kind = jm_blk_kind(v);
        int x0 = x;
        while (x0 > 0 && s->block[x0 - 1] == v) x0--;
        int x1 = x;
        while (x1 + 1 < JUMP_COLS && s->block[x1 + 1] == v) x1++;

        ml_rgb base = brick, top = lit;
        if (kind == BM_COIN || kind == BM_MUSH) { base = gold; top = gold_lit; }
        else if (kind == BM_STONE) { base = stone; top = stone_lit; }
        else if (kind == BM_USED)  { base = used;  top = used_lit; }

        for (int cx = x; cx <= x1; cx++) {
            if (cx < cam || cx >= cam + JUMP_W) continue;
            const int row = jm_blk_row(v) - (s->bump_x == cx && (s->bump_anim & 1) ? 1 : 0);
            jm_fill(c, cam, cx, row, 1, BLOCK_H, base);
            jm_put(c, cam, cx, row, top);
            jm_put(c, cam, cx, row + BLOCK_H - 1, used);
        }

        if (kind == BM_COIN || kind == BM_MUSH) {
            const int row = jm_blk_row(v);
            const int m = x0 + (x1 - x0) / 2;
            const int m2 = m + 1 <= x1 ? m + 1 : x1;
            jm_put(c, cam, m, row + 1, mark);
            jm_put(c, cam, m2, row + 1, mark);
            if (kind == BM_COIN) jm_put(c, cam, m, row + 2, mark);
        }
        x = x1 + 1;
    }
}

static void jm_draw_pops(ml_canvas *c, const jumpman_state *s)
{
    const ml_rgb gold = ML_RGB(255, 216, 64);
    const ml_rgb glint = ML_RGB(255, 248, 200);
    for (int i = 0; i < POP_SLOTS; i++) {
        const jm_pop *p = &s->pop[i];
        if (p->anim == 0) continue;
        jm_fill(c, s->cam, p->x, p->y, 2, 2, gold);
        jm_put(c, s->cam, p->x, p->y, glint);
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

static void jm_draw_items(ml_canvas *c, const jumpman_state *s)
{
    const int cam = s->cam;
    for (int i = 0; i < ITEM_SLOTS; i++) {
        const jm_item *it = &s->items[i];
        if (it->state == IS_NONE) continue;
        const int x = it->x >> 8, y = it->y >> 8;
        if (x + ITEM_W <= cam || x >= cam + JUMP_W) continue;
        jm_sprite(c, cam, x, y, jm_spr_mushroom, ITEM_W, ITEM_H);
    }
}

/* The shell: a green oval with two dark rim pixels that walk round it while it
 * slides, which is the whole of its spin at four pixels across. */
static void jm_draw_shell(ml_canvas *c, const jumpman_state *s, const jm_enemy *e)
{
    const ml_rgb rim  = ML_RGB(56, 200, 88);
    const ml_rgb dark = ML_RGB(24, 128, 56);
    const int x = e->x >> 8, y = e->y >> 8;
    const int spin = e->state == ES_SLIDE ? (e->anim >> 2) & 3 : 1;
    jm_fill(c, s->cam, x, y, ENEMY_W, 1, rim);
    jm_fill(c, s->cam, x, y + 1, ENEMY_W, 1, rim);
    jm_fill(c, s->cam, x, y + 2, ENEMY_W, 1, rim);
    jm_put(c, s->cam, x + spin, y + 1, dark);
    jm_put(c, s->cam, x + ((spin + 1) & 3), y + 1, dark);
}

static void jm_draw_enemies(ml_canvas *c, const jumpman_state *s)
{
    const int cam = s->cam;
    for (int i = 0; i < ENEMY_SLOTS; i++) {
        const jm_enemy *e = &s->enemies[i];
        if (e->kind == EK_NONE) continue;
        const int h = jm_enemy_h(e->kind);
        const int x = e->x >> 8, y = e->y >> 8;
        if (x + ENEMY_W <= cam || x >= cam + JUMP_W) continue;
        if (e->state == ES_SQUASH) {
            jm_fill(c, cam, x, y + h - 1, ENEMY_W, 1, jm_sprite_col(e->kind == EK_KOOPA ? 'g' : 'a'));
        } else if (e->kind == EK_GOOMBA) {
            jm_sprite(c, cam, x, y, jm_spr_goomba, ENEMY_W, GOOMBA_H);
        } else if (e->kind == EK_KOOPA) {
            jm_sprite(c, cam, x, y, jm_spr_koopa, ENEMY_W, KOOPA_H);
        } else {
            jm_draw_shell(c, s, e);
        }
    }
}

/* The checkpoint: a short pole and pennant, grey until the player passes it and
 * gold from then on. */
static void jm_draw_checkpoint(ml_canvas *c, const jumpman_state *s)
{
    const int top = 12;
    const ml_rgb grey = ML_RGB(176, 176, 184);
    const ml_rgb gold = ML_RGB(248, 208, 64);
    const ml_rgb col = s->checkpoint ? gold : grey;
    jm_fill(c, s->cam, CHECKPOINT_X, top, 1, JUMP_GROUND_ROW - top, col);
    jm_fill(c, s->cam, CHECKPOINT_X + 1, top, 2, 2, col);
}

/* The goal: a pole at the last column of the level and a pennant off its top.
 * Touching the pole is what ends the run. */
static void jm_draw_flag(ml_canvas *c, const jumpman_state *s)
{
    const ml_rgb pole  = ML_RGB(216, 216, 224);
    const ml_rgb cloth = ML_RGB(240, 72, 64);
    const int top = JUMP_GROUND_ROW - 9;
    jm_fill(c, s->cam, FLAG_X, top, 1, JUMP_GROUND_ROW - top, pole);
    for (int i = 0; i < 3; i++)
        jm_put(c, s->cam, FLAG_X + 1, top + i, cloth);
    jm_fill(c, s->cam, FLAG_X + 1, top, 2, 1, cloth);
    jm_put(c, s->cam, FLAG_X + 2, top + 1, cloth);
}

/* The player: cap, face, overalls, boots, six rows small and nine super with
 * the same three parts grown. The eye follows the facing, which is the whole of
 * what tells the player they are running left, and an invulnerable player is
 * skipped on every other four-tick block. */
static void jm_draw_player(ml_canvas *c, const jumpman_state *s)
{
    const ml_rgb cap   = ML_RGB(224, 56, 48);
    const ml_rgb skin  = ML_RGB(252, 200, 152);
    const ml_rgb denim = ML_RGB(56, 96, 208);
    const ml_rgb boots = ML_RGB(112, 68, 36);
    const ml_rgb eye   = ML_RGB(24, 24, 24);
    const int x = s->px >> 8;
    const int y = s->py >> 8;
    const int cam = s->cam;
    const int h = play_h(s);
    const int face = h == PLAYER_H_SUPER ? 3 : 2;
    const int legs = h == PLAYER_H_SUPER ? 3 : 2;
    const int feet = h - 1 - face - legs;

    if (s->invuln > 0 && ((s->invuln >> 2) & 1)) return;

    jm_fill(c, cam, x, y, PLAYER_W, 1, cap);
    jm_fill(c, cam, x, y + 1, PLAYER_W, face, skin);
    jm_fill(c, cam, x, y + 1 + face, PLAYER_W, legs, denim);
    jm_fill(c, cam, x, y + 1 + face + legs, PLAYER_W, feet, boots);
    jm_put(c, cam, x + (s->facing ? 2 : 1), y + (h == PLAYER_H_SUPER ? 2 : 1), eye);
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
     * can be read as a level still being played. A death still draws the world,
     * with the body falling through it. */
    if (s->status == JM_WON || s->status == JM_OVER) {
        jm_draw_terminal(s, c);
        return;
    }

    jm_draw_ground(c, s);
    jm_draw_pipes(c, s);
    jm_draw_plants(c, s);
    jm_draw_blocks(c, s);
    jm_draw_pops(c, s);
    jm_draw_coins(c, s);
    jm_draw_items(c, s);
    jm_draw_enemies(c, s);
    jm_draw_checkpoint(c, s);
    jm_draw_flag(c, s);
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
