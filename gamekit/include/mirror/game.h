/*
 * game.h - the contract every game signs.
 *
 * A game is one C translation unit exporting a single const ml_game_vt. It never
 * links against the runtime; the runtime links against it. That inversion keeps
 * the firmware free to ship only the games it fits, and the host free to test
 * whatever it wants, with neither knowing the other's set.
 *
 * The framework inherits the render core's one rule, once removed: a frame is a
 * pure function of game state and a view, and state advances as a pure function
 * of the previous state, the inputs, and a tick counter. Nothing in this header
 * reads a wall clock, floats the host way, allocates in the loop, or depends on
 * the machine it runs on. See docs/games.md for the reasoning.
 */
#ifndef MIRROR_GAME_H
#define MIRROR_GAME_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "mirror/canvas.h"
#include "mirror/color.h"
#include "mirror/model.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---- size policy: how a game's logical space meets the physical panel ---- */

typedef enum {
    /*
     * The game reads the panel size and lays itself out. pref_w/pref_h are 0.
     * Default, and the one panel-shaped games (clocks, full-field play) reach
     * for, since branching on width beats scaling bitmap art.
     */
    ML_FIT_ADAPTIVE = 0,
    /*
     * The game renders at pref, the runtime integer-upscales to the largest
     * multiple that fits and centres it, painting margins with the background.
     * Keeps authoring at one canonical size cheap and the art crisp.
     */
    ML_FIT_LETTERBOX,
    /* As letterbox but non-integer, blurring pixels. Present so a game can opt
     * in; nothing selects it by default, on a LED matrix it is usually wrong. */
    ML_FIT_STRETCH,
    /* Render pref in the top-left and clip the spill. For designed overflow. */
    ML_FIT_CLIP
} ml_fit_mode;

typedef struct {
    int     pref_w, pref_h;    /* the size the game authored (0,0 when adaptive) */
    int     sx, sy;           /* per-axis integer upscale, 1 when adaptive/clip */
    int     ox, oy;           /* pixel offset of the logical rect in the panel */
    ml_rect active;           /* sub-rect of the physical canvas the game owns */
} ml_view;

/*
 * Compute the view a game occupies on a (pw,ph) panel, given its authored
 * preferred size and fit mode. Pure arithmetic; used by the runtime before
 * draw and available to tests. For adaptive (pref 0) the logical size is the
 * panel size and sx,sy are 1.
 */
void ml_view_compute(ml_view *v, int pref_w, int pref_h, ml_fit_mode fit,
                     int pw, int ph);

/* ---- input ---- */

typedef enum {
    ML_INPUT_BUTTON = 0,      /* value: 0 released, 1 pressed */
    ML_INPUT_AXIS,            /* value: -32768..32767 */
    ML_INPUT_TOUCH            /* value: a touch point the controller UI packs */
} ml_input_type;

/* What a controller can provide. The host refuses a join the game can't play,
 * and swaps players into roles they can actually reach. */
typedef enum {
    ML_CAP_BUTTON = 1u << 0,
    ML_CAP_DPAD   = 1u << 1,
    ML_CAP_JOY    = 1u << 2,
    ML_CAP_SLIDER = 1u << 3,
    ML_CAP_TOUCH  = 1u << 4,
    ML_CAP_ACCEL  = 1u << 5
} ml_cap_bits;

#define ML_INPUT_CODE_COUNT 16
#define ML_INPUT_MAX_CODE  (ML_INPUT_CODE_COUNT - 1)

typedef struct {
    uint16_t player_id;        /* assigned by the host at join */
    uint16_t seq;              /* per-player sequence: rejects replayed/stale */
    uint16_t code;             /* game-defined control code (index into controls) */
    int16_t  value;            /* press 0/1, axis -32768..32767, touch packed */
    uint32_t tick;             /* host tick this applies to; host stamps, not peer */
    uint8_t  type;             /* ml_input_type */
    uint8_t  _pad[3];
} ml_input_event;

/* A control the phone controller renders. The game declares its surface; the
 * client draws exactly these and nothing else, so a one-button clock game and a
 * steering-joystick mirror game share one client. */
typedef struct {
    char     label[16];
    uint16_t code;            /* delivered in events */
    uint16_t caps;            /* caps a controller needs to drive it */
    uint8_t  type;            /* ml_input_type */
    uint8_t  _pad[3];
} ml_control_def;

/* ---- players / roles ---- */

typedef enum {
    ML_ROLE_CONTROLLER = 0,    /* sends input, renders its own surface only */
    ML_ROLE_DISPLAY,           /* renders snapshots, never simulates */
    ML_ROLE_DUAL               /* both: phone showing a scoreboard while playing */
} ml_role;

#define ML_PLAYER_NAME_LEN 16

typedef struct {
    uint16_t id;
    char     name[ML_PLAYER_NAME_LEN];
    uint8_t  role;            /* ml_role */
    uint8_t  caps;            /* OR of ml_cap_bits */
} ml_player_caps;

/* ---- config handed to init ---- */

typedef struct {
    uint32_t seed;            /* session seed; the PRNG is seeded from this */
    int      panel_w, panel_h;
} ml_game_cfg;

/* upper bound on a serialized state so a game can never wedge a peer */
#define ML_SNAPSHOT_MAX 1024

/*
 * Forward-declared; the runtime owns the real struct (see gamerun.h). Through it
 * a game reaches the tick counter, the PRNG, the read-only model, and the emit
 * hooks for sound and discrete events. It is deliberately read-mostly: the only
 * state it exposes that can change a frame is the tick (fixed) and the PRNG
 * (deterministic), so a game cannot, through ctx, touch the network, the
 * filesystem, or another peer.
 */
typedef struct ml_game_ctx ml_game_ctx;

/* ---- the vtable: one static const per game ---- */

typedef struct ml_game_vt {
    const char          *id;             /* stable string id, e.g. "rally" */
    int                  pref_w, pref_h; /* 0,0 when adaptive */
    ml_fit_mode         fit;
    uint32_t            tick_ms;        /* fixed simulation timestep */
    int                 max_players;
    size_t              state_size;     /* bytes the runtime reserves for state */

    const ml_control_def *controls;     /* NULL when the game takes none */
    int                 control_count;

    /* Lifecycle. init runs once at load; reset on (re)start re-using the ctx
     * seed. join/leave fire on net arrivals, before any update that depends on
     * them. All deterministic given the seed. */
    void (*init)(void *state, const ml_game_cfg *cfg, ml_game_ctx *ctx);
    void (*reset)(void *state, ml_game_ctx *ctx);
    void (*join)(void *state, const ml_player_caps *p, ml_game_ctx *ctx);
    void (*leave)(void *state, uint16_t player_id, ml_game_ctx *ctx);

    /* input arrives one event at a time, in tick order, before the matching
     * update. update advances state by exactly one tick. Both deterministic. */
    void (*input)(void *state, const ml_input_event *e, ml_game_ctx *ctx);
    void (*update)(void *state, ml_game_ctx *ctx);

    /* draw is pure: it may read state, the view, the canvas and ctx's read-only
     * services (tick, model), and write pixels. Nothing else. Called on every
     * peer, so it must never mutate state or touch the net. */
    void (*draw)(const void *state, const ml_view *view, ml_canvas *c,
                 const ml_game_ctx *ctx);

    /* host serializes canonical state into buf; *len set, capped by cap. Returns
     * false when the state did not fit (caller then retries, asking for a delta).
     * restore is its inverse, run by every peer on each snapshot. */
    bool (*snapshot)(const void *state, uint8_t *buf, size_t cap, size_t *len);
    void (*restore)(void *state, const uint8_t *buf, size_t len);

    /* Optional: whether the game has reached its terminal state (game over,
     * or the win state where a game has one). NULL when the game never ends
     * (rally). A pure read of state; the host polls it after each update,
     * and the firmware uses it to tell the controller the game ended. */
    bool (*is_over)(const void *state);
} ml_game_vt;

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_GAME_H */