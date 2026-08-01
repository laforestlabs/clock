/*
 * gamerun.h - the host runtime: the loop, the services, the sessions.
 *
 * One runtime drives every game. It is plain C99 with no platform dependencies,
 * compiled once for the host (used by the CLI and tests) and again, later, as an
 * ESP-IDF component for the firmware. Its only job is to honour the contract in
 * game.h: pace fixed ticks, route inputs in order, broadcast snapshots, compute
 * the view, and expose the deterministic services a game reaches for through ctx.
 *
 * What is here today is the host simulation: an authoritative host session, a
 * peers-over-a-loopback-bus peer session, and a binary journal for record/replay.
 * Real radios are a later phase; this is enough to prove multiplayer and
 * determinism without a single byte on the air.
 */
#ifndef MIRROR_GAMERUN_H
#define MIRROR_GAMERUN_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "mirror/canvas.h"
#include "mirror/gamenet.h"
#include "mirror/game.h"
#include "mirror/model.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---- services a game reaches through ctx ---- */

/* Next value from the session PRNG. Deterministic: seeded once from the host
 * seed and agreed across peers in the hello handshake. */
uint32_t         ml_ctx_rng(ml_game_ctx *ctx);

/* The tick the current update or render is for. Monotonic per session; never a
 * wall clock, never read from the OS. */
uint32_t         ml_ctx_tick(const ml_game_ctx *ctx);

/* The read-only model, the same seam widgets use. NULL when the session was
 * opened without one (in which case it points at an all-invalid zero model). */
const ml_model  *ml_ctx_model(const ml_game_ctx *ctx);

/* Emit a game-defined discrete event to peers (sound, haptics, scoreboard FX).
 * Cheap on the host and ignored on a no-clients session; on the device it leaves
 * through the same path the firmware already uses for audio cues later. */
void             ml_ctx_emit_event(ml_game_ctx *ctx, uint16_t code, int32_t value);

/* ---- the authoritative host ---- */

typedef struct {
    const ml_game_vt  *game;     /* the game to run */
    const ml_model    *model;    /* optional; NULL -> an all-invalid model */
    int                panel_w, panel_h;
    uint32_t           seed;     /* 0 -> derived from time by the runtime */
    int                snapshot_every; /* ticks between snapshots; <=0 -> every tick */
} ml_host_opts;

typedef struct ml_host_session ml_host_session;

/* Create an authoritative session. Owns its own loopback bus internally; call
 * ml_host_attach_peer and ml_host_attach_controller to put ends on it. */
ml_host_session *ml_host_open(const ml_host_opts *opts);

/* Attach a read-only display peer. Returns a ready-to-step/render peer session
 * linked to this host over the internal bus. */
typedef struct ml_peer_session ml_peer_session;
ml_peer_session *ml_host_attach_peer(ml_host_session *h);

/* Attach a controller. The host calls the game's join and returns a net endpoint
 * the harness drives to push that player's inputs onto the session. */
ml_net          *ml_host_attach_controller(ml_host_session *h,
                                          uint16_t player_id, const char *name,
                                          uint8_t caps);

/* Inject a local player's input straight into the host. Used for single-player
 * and for keyboard-driven multi-player on one machine; also journalled. */
void             ml_host_local_input(ml_host_session *h, const ml_input_event *e);

/* Advance the session by wall_ms of real time: drain the bus for incoming
 * inputs, step as many fixed ticks as elapsed (capped), and broadcast a snapshot
 * on schedule. */
void             ml_host_step(ml_host_session *h, uint32_t wall_ms);

/* Compute the view and draw the current state into out (sized panel_w x h). */
void             ml_host_render(ml_host_session *h, ml_canvas *out);

/* Introspection for the harness. */
uint32_t         ml_host_tick(const ml_host_session *h);
int              ml_host_player_count(const ml_host_session *h);
size_t           ml_host_last_snapshot_len(const ml_host_session *h);

void             ml_host_destroy(ml_host_session *h);

/* ---- read-only display peer ---- */

typedef struct {
    const ml_game_vt  *game;     /* restore/draw/view need the vtable */
    int                panel_w, panel_h;
} ml_peer_opts;

/* Create a peer that renders snapshots arriving on link. For the in-process
 * simulation, link comes from a loopback pair; the host side is internal to an
 * ml_host_session. A peer never calls update. */
ml_peer_session *ml_peer_open(const ml_peer_opts *opts, ml_net *link);

/* Drain incoming snapshots/events from the link, restore, and optionally render
 * (at most once per call, throttled to the game's tick). */
void             ml_peer_step(ml_peer_session *p, uint32_t wall_ms);
void             ml_peer_render(ml_peer_session *p, ml_canvas *out);

uint32_t         ml_peer_tick(const ml_peer_session *p);
bool             ml_peer_alive(const ml_peer_session *p);   /* false once BYE or link closed */

void             ml_peer_destroy(ml_peer_session *p);

/* ---- record / replay journal ---- */

/* A binary file of seed, game id, panel size, then a stream of input events in
 * order. Record writes it; replay re-feeds the exact stream into a fresh host
 * from the same seed and asserts frame hashes match, the game-side analogue of
 * the render core's golden-image diff. */
typedef struct ml_journal ml_journal;

ml_journal      *ml_journal_open(const char *path, bool write);
void             ml_journal_close(ml_journal *j);

void             ml_journal_write_header(ml_journal *j, const ml_game_vt *game,
                                         uint32_t seed, int panel_w, int panel_h,
                                         int players, uint32_t ticks);
void             ml_journal_finalize_ticks(ml_journal *j, uint32_t ticks);
void             ml_journal_write_input(ml_journal *j, const ml_input_event *e);

bool             ml_journal_read_header(ml_journal *j, char game_id[32],
                                       uint32_t *seed, int *panel_w, int *panel_h,
                                       int *players, uint32_t *ticks);
int              ml_journal_read_input(ml_journal *j, ml_input_event *out); /* 1 ok, 0 eof, <0 err */

/* Attach an open journal so the host records every routed input (local and net).
 * The header is deferred: call ml_host_journal_commit once controllers are
 * attached so the recorded player count matches what was actually run. Pass
 * NULL to detach. */
void             ml_host_set_journal(ml_host_session *h, ml_journal *j);
void             ml_host_journal_commit(ml_host_session *h, int players);
void             ml_host_journal_finalize(ml_host_session *h);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_GAMERUN_H */