/*
 * game_runner.h - runs a gamekit session on the render task.
 *
 * The BLE host task must never allocate or run a game session (its stack is
 * small and blocking it stalls the link), so the runner is a queue pair: the
 * host task enqueues commands and input frames, and the render task drains
 * both and owns the session exclusively. The render task calls service()
 * once per frame and render() while a game is active; a waiting, paused or
 * finished session stays active, so the panel keeps showing its board.
 *
 * A round belongs to up to two BLE links, one seat each. A reply goes back to
 * the link that asked and nowhere else - one phone never reads another phone's
 * answer - while a state change (the round stopped, paused, resumed, a seat
 * filled, the game ended) is pushed to every link, because it changes what
 * every phone shows. A two-player round does not start until both seats are
 * filled, and a round that loses a seat freezes for both players instead of
 * quietly handing a human's paddle to the computer.
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

/* Whether a session is live. A waiting, paused or finished session still
 * counts as active: the render task keeps drawing its board. Safe from any
 * task. */
bool game_runner_active(void);

/* Queue a session command. Call from the BLE host task only; the render task
 * services the queue and answers on the BLE status line. `link` is the link
 * that asked: it alone gets the reply and the "game error ..." refusals, so a
 * refusal for one phone never appears on the other's screen.
 *
 * A full queue answers "game error busy" on the asking link immediately. */

/* Start a round. `arg` is "<id>", or "<id> <players>" with players 1 or 2;
 * only a trailing token that is exactly a seat count is read as one, so
 * today's "game start rally" stays a solo round with the AI on the far paddle.
 * A two-player round waits - "game players 1 2" is pushed and the panel holds
 * the board it will start from, with the missing seat's overlay over it -
 * until a second link joins, and only then does it step. */
void game_runner_request_start(const char *arg, uint16_t link);

/* Take a seat in a round that is running on the panel. Idempotent: a link that
 * already holds a seat is answered with its own. Filling the last seat of a
 * waiting round starts it. */
void game_runner_request_join(uint16_t link);

/* Ask what the panel is running: "game session none", or the round's id, the
 * seats filled, the seats it needs, its state (waiting, playing, paused or
 * over), and this link's player id, which is 0 when it holds no seat. */
void game_runner_request_session(uint16_t link);
void game_runner_request_stop(uint16_t link);
void game_runner_request_pause(uint16_t link);
void game_runner_request_resume(uint16_t link);

/* A link went away. Must be delivered even when the command queue is
 * saturated: a loss dropped there would leave a dead link holding its seat
 * and its player attached to a round nobody can play. */
void game_runner_request_link_lost(uint16_t link);

/* Feed one full-state input frame from `link`: `count` events, one per control
 * in code order (count 0 is a frame with every control released). Call from
 * the BLE host task only. The events are stamped with the player id of the
 * seat `link` holds, so a frame off one phone can never steer the other
 * phone's paddle.
 *
 * Returns false when the frame was rejected: `link` holds no seat, no session
 * is live, one of its codes is not a control of the running game, or the queue
 * is full. Only an accepted frame counts as proof that the controller is still
 * there, so a malformed packet, one addressed to another game, or one from a
 * link that is not in the round can neither steer it nor hold a frozen one
 * open. A full queue drops input rather than blocking the host task; the phone
 * re-sends the full held state every frame. */
bool game_runner_request_input_frame(uint16_t link, const ml_input_event *events,
                                     uint8_t count);

/* Drain the pending link losses, then the command and input queues, running
 * the side effects (start, join, stop, pause, or resume a session; feed
 * inputs). Input is only fed while a round is playing: while idle, waiting,
 * paused, or finished it is drained and discarded, so a press queued for one
 * round can never reach another. Call from the render task; returns whether a
 * session is live after the drain. */
bool game_runner_service(void);

/* Step the active session by the wall time since the last call and draw it
 * into out (sized panel_width() x panel_height()). No-op when idle. A round
 * waiting for its second seat is drawn but never stepped, and a paused or
 * finished one is redrawn unchanged with the frame clock kept current, so a
 * resume does not replay the frozen wall time. Call from the render task.
 *
 * This is also where the controller watchdog runs: while a round is playing,
 * 500 ms without an accepted frame from any seat freezes the shared round and
 * pushes one unsolicited "game paused" at every phone. Only "game resume" - or
 * a new start - leaves that state. */
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
