/*
 * game_runner.h - runs a gamekit session on the render task.
 *
 * The BLE host task must never allocate or run a game session (its stack is
 * small and blocking it stalls the link), so the runner is a queue pair: the
 * host task enqueues commands and input frames, and the render task drains
 * both and owns the session exclusively. The render task calls service()
 * once per frame and render() while a game is active; a paused or finished
 * session stays active, so the panel keeps showing its last frame.
 */
#ifndef MIRROR_GAME_RUNNER_H
#define MIRROR_GAME_RUNNER_H

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"
#include "mirror/canvas.h"
#include "mirror/game.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Create the command and input queues. Call early in app_main, before the
 * render task starts. */
esp_err_t game_runner_init(void);

/* Whether a session is live. A paused or finished session still counts as
 * active: the render task keeps drawing its board. Safe from any task. */
bool game_runner_active(void);

/* Queue a session command. Call from the BLE host task only; the render task
 * services the queue and answers on the BLE status line ("game ok ...",
 * "game stopped", "game paused", "game resumed", "game error ...").
 *
 * A full queue answers "game error busy" immediately. */
void game_runner_request_start(const char *id);
void game_runner_request_stop(void);
void game_runner_request_pause(void);
void game_runner_request_resume(void);

/* Link loss must stop even when the command queue is saturated. */
void game_runner_request_disconnect(void);

/* Feed one full-state input frame: `count` events, one per control in code
 * order (count 0 is a frame with every control released). Call from the BLE
 * host task only.
 *
 * Returns false when the frame was rejected: no session is live, one of its
 * codes is not a control of the running game, or the queue is full. Only an
 * accepted frame counts as proof that the controller is still there, so a
 * malformed packet or one addressed to another game can neither steer a
 * round nor hold a frozen one open. A full queue drops input rather than
 * blocking the host task; the phone re-sends the full held state every
 * frame. */
bool game_runner_request_input_frame(const ml_input_event *events, uint8_t count);

/* Drain the command and input queues, running the side effects (start, stop,
 * pause, or resume a session; feed inputs). Input is only fed while a round
 * is playing: while idle, paused, or finished it is drained and discarded,
 * so a press queued for one round can never reach another. Call from the
 * render task; returns whether a session is live after the drain. */
bool game_runner_service(void);

/* Step the active session by the wall time since the last call and draw it
 * into out (sized panel_width() x panel_height()). No-op when idle. A paused
 * or finished session is not stepped: its board is redrawn unchanged and the
 * frame clock kept current, so a resume does not replay the paused wall
 * time. Call from the render task.
 *
 * This is also where the controller watchdog runs: while a round is playing,
 * 500 ms without an accepted input frame freezes it and pushes one
 * unsolicited "game paused". Only "game resume" - or a new start - leaves
 * that state. */
void game_runner_render(ml_canvas *out);

/* The ml_input_type of control [code] in the running game, or
 * ML_INPUT_BUTTON when no game is running or the code is unknown. Used by
 * ble.c to interpret an input packet's i16 value: a button is 0/1, an axis
 * is -32768..32767. Safe from any task. */
ml_input_type game_runner_control_type(uint16_t code);

/* Microseconds from the most recent input packet arrival to the last
 * rendered game frame. 0 while no game is running. A diagnostic for input
 * latency, read by the BLE "get latency" command. Safe from any task. */
uint32_t game_runner_input_to_render_us(void);


#ifdef __cplusplus
}
#endif
#endif /* MIRROR_GAME_RUNNER_H */
