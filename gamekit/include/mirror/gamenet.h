/*
 * gamenet.h - transport abstraction and the in-process loopback bus.
 *
 * The session layer never sees a radio. It sees frames on a link, and the link
 * is one of this header's ml_net objects, whether the bytes behind it came from
 * the loopback bus (the only transport today, for the simulation) or, later, a
 * BLE GATT connection or a WiFi UDP flow. That is what lets multiplayer be
 * designed and replayed with nothing on the air, and lets the firmware swap in a
 * real transport without a game or a session changing.
 *
 * Frames are compact and fixed-layout so an ESP32 can parse them without a JSON
 * reader, and so a peer can resync from any one packet.
 */
#ifndef MIRROR_GAMENET_H
#define MIRROR_GAMENET_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "mirror/game.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---- frame kinds ---- */

typedef enum {
    /* controller or display introduces itself to the host: role, caps, the
     * transports it can speak. */
    ML_NET_HELLO     = 1,
    /* host replies: assigned player_id, session seed, tick origin, view hint. */
    ML_NET_WELCOME   = 2,
    /* a controller's input event, one per frame. */
    ML_NET_INPUT     = 3,
    /* host -> replicas: tick + the game's snapshot bytes; the only truth. */
    ML_NET_SNAPSHOT  = 4,
    /* host -> peers: a game-defined discrete event for sound/haptics/score. */
    ML_NET_EVENT     = 5,
    /* either direction: graceful leave. */
    ML_NET_BYE       = 6
} ml_net_kind;

#define ML_NET_PAYLOAD_MAX ML_SNAPSHOT_MAX

typedef struct {
    uint8_t  kind;            /* ml_net_kind */
    uint8_t  flags;           /* reserved */
    uint16_t player_id;       /* the player this frame concerns */
    uint16_t len;             /* payload bytes in use */
    uint16_t _pad;
    uint8_t  payload[ML_NET_PAYLOAD_MAX];
} ml_net_frame;

/* ---- a point-to-point link ---- */

typedef struct ml_net ml_net;

/* Block up to block_ms for a frame; returns 1 if one arrived, 0 if none, <0 on
 * a closed link. block_ms = 0 never blocks. */
int   ml_net_recv(ml_net *n, ml_net_frame *out, int block_ms);

/* Returns 1 on success, <0 on a closed/full link. */
int   ml_net_send(ml_net *n, const ml_net_frame *f);

/* Drop the link. Idempotent. */
void  ml_net_close(ml_net *n);

/* Convenience: frame and send one input event as ML_NET_INPUT. */
int   ml_net_send_input(ml_net *n, const ml_input_event *e);

/* ---- the loopback bus ---- */

/*
 * The host's hub. One ml_bus has one host end and any number of peer ends: a
 * send on the host end fans out to every peer end, a send on a peer end arrives
 * only at the host end. That single shape is the whole of in-process multiplayer
 * today, and is exactly what a WiFi multicast or a BLE central will mimic later.
 *
 * Owns its endpoints: close the endpoints you took; destroy the bus after. All
 * non-blocking; the runtime polls with ml_net_recv(.., 0).
 */
typedef struct ml_bus ml_bus;

ml_bus   *ml_bus_create(void);
/* The host end. The bus fans a send here to every peer end taken below. */
ml_net   *ml_bus_host(ml_bus *b);
/* A new peer end linked back to the host end. Returns NULL past ML_BUS_MAX_PEERS. */
ml_net   *ml_bus_join(ml_bus *b);
ml_net   *ml_bus_take(ml_bus *b, int index);   /* the i'th peer end, or NULL */
int       ml_bus_peer_count(const ml_bus *b);
void      ml_bus_destroy(ml_bus *b);

#define ML_BUS_MAX_PEERS 8

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_GAMENET_H */