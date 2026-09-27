/*
 * game_ffi.h - the binding surface for the Flutter game simulation.
 *
 * Same principle as mirror_ffi.h: keep the boundary narrow. A game id and a
 * panel size go in, pixels come out. The game vtable, the runtime, the
 * loopback bus, and the fixed-point physics are all encapsulated behind one
 * opaque handle. Dart never touches a C struct.
 *
 * The session owns a host, a canvas, and (for the first player) a controller
 * on the loopback bus. Stepping the simulation advances the game by a fixed
 * number of ticks; rendering produces RGBA8888 the same way ml_sim_render_rgba
 * does, so the same Flutter paint path draws both.
 */
#ifndef MIRROR_GAME_FFI_H
#define MIRROR_GAME_FFI_H

#include <stdint.h>

#include "mirror/game.h"

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#  define ML_GAME_EXPORT __declspec(dllexport)
#else
#  define ML_GAME_EXPORT __attribute__((visibility("default")))
#endif

typedef struct ml_game_session ml_game_session;

/* ------------------------------------------------------------- catalogue */

/* Number of games compiled into this build. */
ML_GAME_EXPORT int         ml_game_count(void);

/* Stable id of the game at index, e.g. "rally". */
ML_GAME_EXPORT const char *ml_game_id(int index);

/* Human-readable name, e.g. "Rally". */
ML_GAME_EXPORT const char *ml_game_name(int index);

/* Max players the game supports. */
ML_GAME_EXPORT int         ml_game_max_players(int index);

/* Number of controls the game declares (its controller surface). */
ML_GAME_EXPORT int         ml_game_control_count(int index);

/* Label for control ci of game at index gi. */
ML_GAME_EXPORT const char *ml_game_control_label(int gi, int ci);

/*
 * Type of control ci of game at index gi, as an ml_input_type value:
 * 0 button, 1 axis, 2 touch. -1 for an out-of-range index.
 */
ML_GAME_EXPORT int         ml_game_control_type(int gi, int ci);

/* ------------------------------------------------------------ lifecycle */

/*
 * Open a session. The game is selected by id; panel_w and panel_h set the
 * canvas size; seed drives the deterministic PRNG; players is how many
 * controllers to attach locally (capped by the game's max_players). Returns
 * NULL on a bad game id or allocation failure.
 */
ML_GAME_EXPORT ml_game_session *ml_game_open(const char *game_id,
                                              int panel_w, int panel_h,
                                              uint32_t seed, int players);

ML_GAME_EXPORT void ml_game_close(ml_game_session *s);

/* Configure a fresh (tick zero) Jumpman campaign. Courses are one-based;
 * unlocked comes from trusted persistent storage, not a player's selection.
 * Invalid/locked courses and non-Jumpman sessions return 0 without mutation.
 * This explicitly selects built-in courses rather than an editor override. */
ML_GAME_EXPORT int ml_game_start_course(ml_game_session *s, int course, int unlocked);

/* Current course and highest unlocked course; 0 for non-campaign sessions.
 * Poll unlocked after stepping and persist increases even before game over. */
ML_GAME_EXPORT int ml_game_course(const ml_game_session *s);
ML_GAME_EXPORT int ml_game_unlocked(const ml_game_session *s);

/* ------------------------------------------------------------- geometry */

ML_GAME_EXPORT int ml_game_width(const ml_game_session *s);
ML_GAME_EXPORT int ml_game_height(const ml_game_session *s);
ML_GAME_EXPORT int ml_game_tick(const ml_game_session *s);

/* ------------------------------------------------------------ simulation */

/*
 * Feed one control of the round's full state. player_id selects which
 * controller (1-based). value is 1/0 for a button and -32768..32767 for an
 * axis; the control's declared type decides which, resolved from the game's
 * own control table rather than trusted from the caller - the same rule the
 * firmware applies to the Bluetooth frame, so a local round and a mirror round
 * read one frame the same way.
 */
ML_GAME_EXPORT void ml_game_input(ml_game_session *s,
                                   uint16_t player_id, uint16_t code,
                                   int16_t value);

/* Advance the simulation by wall_ms of real time (fixed-timestep internally). */
ML_GAME_EXPORT void ml_game_step(ml_game_session *s, uint32_t ms);

/* Whether the game has reached its terminal state (game over, or the win
 * state where a game has one). Read after ml_game_step. */
ML_GAME_EXPORT int ml_game_is_over(const ml_game_session *s);

/* ------------------------------------------------------------- rendering */

/*
 * Render and return width*height*4 bytes of RGBA8888, gamma-corrected exactly
 * as the panel would show it. The buffer is owned by the session and stays
 * valid until the next render or close. Returns NULL if the session is bad.
 */
ML_GAME_EXPORT const uint8_t *ml_game_render_rgba(ml_game_session *s);

ML_GAME_EXPORT int ml_game_rgba_size(const ml_game_session *s);

/* ------------------------------------------------------- authored levels */

/*
 * Both of these are development calls and a device never makes either. A build
 * that does not define ML_GAME_AUTHORING accepts no level (ml_game_set_level
 * returns 0) and publishes no state (ml_game_state_int returns -1), which is
 * what the firmware image is built with.
 */

/*
 * Hand a game one of its levels, in that game's own wire form, before the
 * session that plays it is opened. Returns 1 when it was accepted, 0 for an id
 * with no authored level or a malformed blob, in which case the game keeps the
 * level it had. len 0 restores the shipped level.
 */
ML_GAME_EXPORT int ml_game_set_level(const char *game_id,
                                     const uint8_t *blob, size_t len);

/* One integer of the session's live game state, by name, or -1. */
ML_GAME_EXPORT int ml_game_state_int(const ml_game_session *s, const char *name);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_GAME_FFI_H */