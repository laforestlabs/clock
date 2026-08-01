/*
 * net_loopback.c - the only transport for now: an in-process message bus.
 *
 * One hub, one host end, many peer ends. A send on the host end fans out to
 * every peer end; a send on a peer end arrives only at the host end. That is the
 * whole of in-session multiplayer for the simulation, and it shares the shape a
 * WiFi multicast or a BLE central will mimic later, so a game and a session never
 * learn which one carried the bytes.
 *
 * Non-blocking: the runtime polls with ml_net_recv(.., 0). Frames are copied per
 * send so lifetime is trivial; for the host simulation that is cheap enough, and
 * it keeps destruction a single free per frame. block_ms is accepted but never
 * slept on: loopback offers nothing to wait for.
 */
#include <stdlib.h>
#include <string.h>

#include "mirror/gamenet.h"

#define ML_NET_QCAP 64

typedef struct {
    ml_net_frame **buf;
    int head, tail, count, cap;
} frame_q;

struct ml_net_node {
    struct ml_bus   *bus;
    int              is_host;
    int              closed;
    frame_q          q;
};

struct ml_net {
    struct ml_net_node *node;
};

struct ml_bus {
    struct ml_net_node *host;
    struct ml_net_node *peers[ML_BUS_MAX_PEERS];
    int                 peer_count;
    struct ml_net       host_net;
    struct ml_net       peer_nets[ML_BUS_MAX_PEERS];
};

static void q_init(frame_q *q)
{
    q->cap = ML_NET_QCAP;
    q->buf = calloc((size_t)q->cap, sizeof(ml_net_frame *));
    q->head = q->tail = q->count = 0;
}

static void q_free(frame_q *q)
{
    for (int i = 0; i < q->count; i++) {
        free(q->buf[(q->head + i) % q->cap]);
    }
    free(q->buf);
    q->buf = NULL;
}

/* Returns 1 enqueued, 0 if full. Takes ownership of f (a malloc'd frame). */
static int q_push(frame_q *q, ml_net_frame *f)
{
    if (q->count >= q->cap) return 0;
    q->buf[q->tail] = f;
    q->tail = (q->tail + 1) % q->cap;
    q->count++;
    return 1;
}

/* Returns 1 and sets *out; 0 if empty. Caller frees *out. */
static int q_pop(frame_q *q, ml_net_frame **out)
{
    if (q->count == 0) return 0;
    *out = q->buf[q->head];
    q->head = (q->head + 1) % q->cap;
    q->count--;
    return 1;
}

static ml_net_frame *frame_dup(const ml_net_frame *f)
{
    ml_net_frame *copy = malloc(sizeof(*copy));
    if (copy) memcpy(copy, f, sizeof(*copy));
    return copy;
}

int ml_net_recv(ml_net *n, ml_net_frame *out, int block_ms)
{
    (void)block_ms;            /* loopback never blocks */
    if (!n || !n->node) return -1;
    ml_net_frame *f = NULL;
    if (q_pop(&n->node->q, &f)) {
        memcpy(out, f, sizeof(*out));
        free(f);
        return 1;
    }
    return n->node->closed ? -1 : 0;
}

int ml_net_send(ml_net *n, const ml_net_frame *f)
{
    if (!n || !n->node || n->node->closed) return -1;
    struct ml_bus *b = n->node->bus;

    if (n->node->is_host) {
        /* Fan out to every peer. A full peer drops the packet rather than
         * back-pressuring the host, which is the right call for a one-way
         * snapshot feed; a controller input path is a single peer->host hop
         * and will not run this branch. */
        for (int i = 0; i < b->peer_count; i++) {
            struct ml_net_node *p = b->peers[i];
            if (p->closed) continue;
            ml_net_frame *c = frame_dup(f);
            if (!c || !q_push(&p->q, c)) free(c);
        }
        return 1;
    }

    /* Peer -> host. */
    ml_net_frame *c = frame_dup(f);
    if (!c || !q_push(&b->host->q, c)) { free(c); return -1; }
    return 1;
}

void ml_net_close(ml_net *n)
{
    if (!n || !n->node) return;
    n->node->closed = 1;
}

int ml_net_send_input(ml_net *n, const ml_input_event *e)
{
    ml_net_frame f;
    memset(&f, 0, sizeof(f));
    f.kind = ML_NET_INPUT;
    f.player_id = e->player_id;
    f.len = (uint16_t)sizeof(*e);
    memcpy(f.payload, e, sizeof(*e));
    return ml_net_send(n, &f);
}

ml_bus *ml_bus_create(void)
{
    struct ml_bus *b = calloc(1, sizeof(*b));
    if (!b) return NULL;

    b->host = calloc(1, sizeof(struct ml_net_node));
    if (!b->host) { free(b); return NULL; }
    b->host->bus = b;
    b->host->is_host = 1;
    q_init(&b->host->q);
    b->host_net.node = b->host;
    b->peer_count = 0;
    return b;
}

ml_net *ml_bus_host(ml_bus *b)
{
    return b ? &b->host_net : NULL;
}

ml_net *ml_bus_join(ml_bus *b)
{
    if (!b || b->peer_count >= ML_BUS_MAX_PEERS) return NULL;
    struct ml_net_node *p = calloc(1, sizeof(struct ml_net_node));
    if (!p) return NULL;
    p->bus = b;
    q_init(&p->q);
    int i = b->peer_count++;
    b->peers[i] = p;
    b->peer_nets[i].node = p;
    return &b->peer_nets[i];
}

ml_net *ml_bus_take(ml_bus *b, int index)
{
    if (!b || index < 0 || index >= b->peer_count) return NULL;
    return &b->peer_nets[index];
}

int ml_bus_peer_count(const ml_bus *b)
{
    return b ? b->peer_count : 0;
}

void ml_bus_destroy(ml_bus *b)
{
    if (!b) return;
    if (b->host) { q_free(&b->host->q); free(b->host); b->host = NULL; }
    for (int i = 0; i < b->peer_count; i++) {
        struct ml_net_node *p = b->peers[i];
        if (!p) continue;
        q_free(&p->q);
        free(p);
        b->peers[i] = NULL;
    }
    b->peer_count = 0;
    free(b);
}