/*
 * game_registry.h - the games compiled into this firmware build.
 *
 * The firmware counterpart of the FFI catalogue in gamekit/ffi/game_ffi.c:
 * a fixed, compile-time list of the example games. The render task looks a
 * game up by its stable string id when the phone sends "game start <id>".
 */
#ifndef MIRROR_FW_GAME_REGISTRY_H
#define MIRROR_FW_GAME_REGISTRY_H

#include "mirror/game.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Number of games in this build. */
int ml_fw_game_count(void);

/* The index-th game vtable, or NULL out of range. Index order matches the
 * FFI catalogue in gamekit/ffi/game_ffi.c. */
const ml_game_vt *ml_fw_game_at(int index);

/* The game with the given id, or NULL when this build does not ship it. */
const ml_game_vt *ml_fw_game_find(const char *id);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_FW_GAME_REGISTRY_H */
