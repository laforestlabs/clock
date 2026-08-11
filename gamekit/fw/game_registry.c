/*
 * game_registry.c - the games compiled into this firmware build.
 *
 * Same order as gamekit/ffi/game_ffi.c so the phone's "game list" matches
 * the app's simulation picker: rally, snake, tetris, breakout, invaders.
 */
#include <string.h>

#include "game_registry.h"

extern const ml_game_vt ml_game_rally;
extern const ml_game_vt ml_game_snake;
extern const ml_game_vt ml_game_tetris;
extern const ml_game_vt ml_game_breakout;
extern const ml_game_vt ml_game_invaders;

static const ml_game_vt *const k_games[] = {
    &ml_game_rally,
    &ml_game_snake,
    &ml_game_tetris,
    &ml_game_breakout,
    &ml_game_invaders,
};

int ml_fw_game_count(void)
{
    return (int)(sizeof(k_games) / sizeof(k_games[0]));
}

const ml_game_vt *ml_fw_game_at(int index)
{
    if (index < 0 || index >= ml_fw_game_count()) return NULL;
    return k_games[index];
}

const ml_game_vt *ml_fw_game_find(const char *id)
{
    if (!id) return NULL;
    for (int i = 0; i < ml_fw_game_count(); i++) {
        if (strcmp(k_games[i]->id, id) == 0) return k_games[i];
    }
    return NULL;
}
