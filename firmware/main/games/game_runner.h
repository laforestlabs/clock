/*
 * game_runner.h - runs a gamekit session on the render task.
 *
 * The BLE host task must never allocate or run a game session (its stack is
 * small and blocking it stalls the link), so the runner is a queue pair: the
 * host task enqueues commands and input packets, and the render task drains
 * both and owns the session exclusively. The render task calls service()
 * once per frame and render() while a game is active.
 */
#ifndef MIRROR_GAME_RUNNER_H
#define MIRROR_GAME_RUNNER_H

#include <stdbool.h>

#include "esp_err.h"
#include "mirror/canvas.h"
#include "mirror/game.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Create the command and input queues. Call early in app_main, before the
 * render task starts. */
esp_err_t game_runner_init(void);

/* Whether a game is currently running. Safe from any task. */
bool game_runner_active(void);

/* Queue a game start/stop. Call from the BLE host task only; the render
 * task services the queue and answers on the BLE status line. */
void game_runner_request_start(const char *id);
void game_runner_request_stop(void);

/* Queue one input event (full held state per frame, one event per control).
 * Call from the BLE host task only. A full queue drops the input rather than
 * blocking the host task. */
void game_runner_request_input(const ml_input_event *e);

/* Drain the command and input queues, running the side effects (start/stop
 * a session, feed inputs). Call from the render task; returns whether a game
 * is active after the drain. */
bool game_runner_service(void);

/* Step the active session by the wall time since the last call and draw it
 * into out (sized panel_width() x panel_height()). No-op when idle. */
void game_runner_render(ml_canvas *out);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_GAME_RUNNER_H */
