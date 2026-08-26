/*
 * game_ffi.c - the Flutter binding surface for the game simulation.
 *
 * A thin adapter that wraps the gamekit runtime (ml_host_session) into an
 * opaque handle Dart can drive: open by game id, step, feed buttons, render
 * RGBA. The session owns its host, a canvas, and (for the first player) a
 * controller on the loopback bus. No C struct crosses the boundary.
 *
 * The catalogue functions let Dart list available games and their controls
 * without hardcoding them, so adding a game's .c to the CMake build registers
 * it here for free.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "game_ffi.h"
#include "mirror/gamerun.h"

/* ---- game registry: the set compiled into this build ---- */

typedef struct {
    const char         *id;
    const char         *name;
    const ml_game_vt   *vt;
} game_entry;

extern const ml_game_vt ml_game_rally;
extern const ml_game_vt ml_game_snake;
extern const ml_game_vt ml_game_tetris;
extern const ml_game_vt ml_game_breakout;
extern const ml_game_vt ml_game_invaders;
extern const ml_game_vt ml_game_probe;
static const game_entry k_games[] = {
    { "rally",    "Rally",    &ml_game_rally },
    { "snake",    "Snake",    &ml_game_snake },
    { "tetris",   "Tetris",   &ml_game_tetris },
    { "breakout", "Breakout", &ml_game_breakout },
    { "invaders", "Invaders", &ml_game_invaders },
    { "probe",    "Probe",    &ml_game_probe },
};
#define GAME_COUNT ((int)(sizeof(k_games) / sizeof(k_games[0])))

static const game_entry *find_game(const char *id)
{
    for (int i = 0; i < GAME_COUNT; i++)
        if (strcmp(k_games[i].id, id) == 0) return &k_games[i];
    return NULL;
}

/* ---- the session Dart drives ---- */

struct ml_game_session {
    const ml_game_vt  *game;
    ml_host_session   *host;
    ml_canvas          canvas;
    uint8_t           *rgba;       /* w*h*4, RGBA8888 for Flutter */
    size_t             rgba_size;
    uint16_t           seq;        /* input sequence counter */
};

int ml_game_count(void) { return GAME_COUNT; }

const char *ml_game_id(int index)
{
    return (index >= 0 && index < GAME_COUNT) ? k_games[index].id : "";
}

const char *ml_game_name(int index)
{
    return (index >= 0 && index < GAME_COUNT) ? k_games[index].name : "";
}

int ml_game_max_players(int index)
{
    return (index >= 0 && index < GAME_COUNT) ? k_games[index].vt->max_players : 0;
}

int ml_game_control_count(int index)
{
    return (index >= 0 && index < GAME_COUNT) ? k_games[index].vt->control_count : 0;
}

const char *ml_game_control_label(int gi, int ci)
{
    if (gi < 0 || gi >= GAME_COUNT) return "";
    const ml_game_vt *g = k_games[gi].vt;
    if (ci < 0 || ci >= g->control_count || !g->controls) return "";
    return g->controls[ci].label;
}

ml_game_session *ml_game_open(const char *game_id, int panel_w, int panel_h,
                               uint32_t seed, int players)
{
    const game_entry *e = find_game(game_id);
    if (!e || panel_w <= 0 || panel_h <= 0) return NULL;

    const ml_game_vt *g = e->vt;
    if (players < 1) players = 1;
    if (players > g->max_players) players = g->max_players;

    ml_host_opts opts = {
        .game = g, .panel_w = panel_w, .panel_h = panel_h,
        .seed = seed, .snapshot_every = 1,
    };
    ml_host_session *host = ml_host_open(&opts);
    if (!host) return NULL;

    struct ml_game_session *s = calloc(1, sizeof(*s));
    if (!s) { ml_host_destroy(host); return NULL; }

    s->game = g;
    s->host = host;

    if (!ml_canvas_init(&s->canvas, panel_w, panel_h, NULL)) {
        ml_host_destroy(host);
        free(s);
        return NULL;
    }

    s->rgba_size = (size_t)panel_w * (size_t)panel_h * 4;
    s->rgba = malloc(s->rgba_size);
    if (!s->rgba) {
        ml_canvas_free(&s->canvas);
        ml_host_destroy(host);
        free(s);
        return NULL;
    }

    for (int i = 0; i < players; i++)
        ml_host_attach_controller(host, (uint16_t)(i + 1), "p", ML_CAP_BUTTON);

    return s;
}

void ml_game_close(ml_game_session *s)
{
    if (!s) return;
    ml_host_destroy(s->host);
    ml_canvas_free(&s->canvas);
    free(s->rgba);
    free(s);
}

int ml_game_width(const ml_game_session *s)  { return s ? s->canvas.w : 0; }
int ml_game_height(const ml_game_session *s) { return s ? s->canvas.h : 0; }
int ml_game_tick(const ml_game_session *s)   { return s ? (int)ml_host_tick(s->host) : 0; }

void ml_game_button(ml_game_session *s, uint16_t player_id, uint16_t code,
                     int16_t value)
{
    if (!s) return;
    ml_input_event e;
    memset(&e, 0, sizeof(e));
    e.player_id = player_id;
    e.code = code;
    e.value = value;
    e.type = ML_INPUT_BUTTON;
    e.seq = s->seq++;
    ml_host_local_input(s->host, &e);
}

void ml_game_step(ml_game_session *s, uint32_t ms)
{
    if (!s) return;
    ml_host_step(s->host, ms);
}

int ml_game_is_over(const ml_game_session *s)
{
    return s ? (ml_host_is_over(s->host) ? 1 : 0) : 0;
}

const uint8_t *ml_game_render_rgba(ml_game_session *s)
{
    if (!s) return NULL;

    ml_host_render(s->host, &s->canvas);

    /* ml_canvas_export_rgb888 gives gamma-corrected RGB888. Flutter wants
     * RGBA8888, so we expand here: one pass, no per-pixel Dart loop. */
    size_t n_rgb = (size_t)s->canvas.w * (size_t)s->canvas.h * 3;
    uint8_t *rgb = malloc(n_rgb);
    if (!rgb) return NULL;
    ml_canvas_export_rgb888(&s->canvas, 255, rgb);

    const uint8_t *src = rgb;
    uint8_t *dst = s->rgba;
    for (size_t i = 0; i < n_rgb; i += 3) {
        *dst++ = *src++;   /* R */
        *dst++ = *src++;   /* G */
        *dst++ = *src++;   /* B */
        *dst++ = 0xFF;    /* A: fully opaque */
    }
    free(rgb);
    return s->rgba;
}

int ml_game_rgba_size(const ml_game_session *s)
{
    return s ? (int)s->rgba_size : 0;
}