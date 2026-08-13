/*
 * runtime.c - the host simulation runtime.
 *
 * Owns the loop, the deterministic services a game reaches through ctx, the
 * authoritative host session, the read-only display peer, and the record/replay
 * journal. Plain C99, no platform deps: on the host this is the only build of it;
 * the firmware (a later phase) compiles the same source against the panel task.
 *
 * Design held to in here:
 *   - update is called for exactly one fixed tick, in order, only on the host;
 *   - inputs are stamped with the host tick and routed before that tick's update;
 *   - snapshots are the only truth peers see, and carry the host tick in-band;
 *   - draw never mutates state and gets a const ctx, so ml_ctx_rng (which would
 *     desync a peer's draw schedule) is a discarded-qualifier warning if used.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "mirror/gamenet.h"
#include "mirror/gamerun.h"

/* ---- deterministic PRNG: xorshift32 ---- */

static uint32_t rng_next(uint32_t *s)
{
    uint32_t x = *s;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return *s = x;
}

/* ---- the ctx a game sees ---- */

struct ml_game_ctx {
    uint32_t       tick;
    uint32_t       rng_state;
    uint32_t       seed;
    const ml_model *model;          /* NULL -> the zero model fallback */
    void         (*emit_cb)(void *user, uint16_t code, int32_t value);
    void          *emit_user;
};

static ml_model g_zero_model;

static const ml_model *ctx_model(const ml_game_ctx *ctx)
{
    return ctx->model ? ctx->model : &g_zero_model;
}

uint32_t        ml_ctx_rng(ml_game_ctx *ctx)            { return rng_next(&ctx->rng_state); }
uint32_t        ml_ctx_tick(const ml_game_ctx *ctx)     { return ctx->tick; }
const ml_model *ml_ctx_model(const ml_game_ctx *ctx)    { return ctx_model(ctx); }

void ml_ctx_emit_event(ml_game_ctx *ctx, uint16_t code, int32_t value)
{
    if (ctx->emit_cb) ctx->emit_cb(ctx->emit_user, code, value);
}

/* ---- a helper: integer-scaled blit of one canvas into another ---- */

static void blit_scaled(const ml_canvas *src, ml_canvas *dst,
                         int ox, int oy, int sx, int sy)
{
    for (int y = 0; y < src->h; y++) {
        for (int x = 0; x < src->w; x++) {
            ml_rgb c = ml_canvas_get(src, x, y);
            ml_canvas_fill_rect(dst, ML_RECT(ox + x * sx, oy + y * sy, sx, sy), c);
        }
    }
}

/* Render with the view policy. Fast path for adaptive/1:1 draws straight into
 * the panel canvas; the rest renders into a logical canvas and blits. */
static void render_with_view(const ml_game_vt *g, const void *state,
                             const ml_game_ctx *ctx, ml_canvas *out,
                             ml_canvas *logical, bool *logical_ready,
                             int *lw, int *lh)
{
    ml_view v;
    ml_view_compute(&v, g->pref_w, g->pref_h, g->fit, out->w, out->h);

    bool fast = (v.sx == 1 && v.sy == 1 && v.ox == 0 && v.oy == 0 &&
                 v.active.w == out->w && v.active.h == out->h);
    if (fast) {
        g->draw(state, &v, out, ctx);
        return;
    }

    if (!*logical_ready || *lw != v.pref_w || *lh != v.pref_h) {
        if (*logical_ready) ml_canvas_free(logical);
        if (!ml_canvas_init(logical, v.pref_w, v.pref_h, NULL)) return;
        *logical_ready = true;
        *lw = v.pref_w; *lh = v.pref_h;
    }

    ml_canvas_clear(out, ml_black);
    g->draw(state, &v, logical, ctx);
    blit_scaled(logical, out, v.ox, v.oy, v.sx, v.sy);
}


/* ---- host session ---- */

struct ml_host_session {
    const ml_game_vt  *game;
    ml_game_cfg        cfg;
    ml_game_ctx        ctx;
    void              *state;
    ml_model           local_model;          /* when none provided */

    ml_bus            *bus;
    ml_net            *host_net;

    uint32_t           tick_ms;
    uint32_t           tick;
    int32_t            accum_ms;
    int                snapshot_every;
    int                snap_counter;

    ml_journal        *journal;
    bool               journaling;

    ml_canvas          logical;
    bool               logical_ready;
    int                logical_w, logical_h;

    uint8_t            snap_buf[ML_SNAPSHOT_MAX];
    size_t             last_snap_len;

    int                player_count;
};

void ml_host_set_journal(ml_host_session *h, ml_journal *j)
{
    if (!h) return;
    if (h->journaling) { ml_journal_close(h->journal); h->journaling = false; }
    h->journal = j;
    h->journaling = (j != NULL);
    /* Header is committed by ml_host_journal_commit once controllers are
     * attached, so the recorded player count matches what was actually run. */
}

void ml_host_journal_commit(ml_host_session *h, int players)
{
    if (!h || !h->journaling) return;
    /* ticks is patched by finalize once the sim has run; write 0 for now. */
    ml_journal_write_header(h->journal, h->game, h->cfg.seed,
                            h->cfg.panel_w, h->cfg.panel_h, players, 0);
}

void ml_host_journal_finalize(ml_host_session *h)
{
    if (!h || !h->journaling || !h->journal) return;
    ml_journal_finalize_ticks(h->journal, h->tick);
}

static void host_emit(void *user, uint16_t code, int32_t value)
{
    struct ml_host_session *h = user;
    ml_net_frame f;
    memset(&f, 0, sizeof(f));
    f.kind = ML_NET_EVENT;
    f.len = 6;
    memcpy(f.payload, &code, 2);
    memcpy(f.payload + 2, &value, 4);
    ml_net_send(h->host_net, &f);   /* fans to all peers */
}

static void route_one_input(struct ml_host_session *h, const ml_input_event *e)
{
    ml_input_event stamped = *e;
    stamped.tick = h->tick;        /* host stamps, never trusts the peer clock */
    h->game->input(h->state, &stamped, &h->ctx);
    if (h->journaling) ml_journal_write_input(h->journal, &stamped);
}

ml_host_session *ml_host_open(const ml_host_opts *opts)
{
    if (!opts || !opts->game) return NULL;

    static bool zero_inited = false;
    if (!zero_inited) { ml_model_init(&g_zero_model); zero_inited = true; }

    struct ml_host_session *h = calloc(1, sizeof(*h));
    if (!h) return NULL;

    h->game = opts->game;
    h->tick_ms = opts->game->tick_ms ? opts->game->tick_ms : 33;
    h->snapshot_every = opts->snapshot_every > 0 ? opts->snapshot_every : 1;

    h->cfg.seed = opts->seed ? opts->seed : (uint32_t)time(NULL);
    h->cfg.panel_w = opts->panel_w;
    h->cfg.panel_h = opts->panel_h;

    if (opts->model) h->local_model = *opts->model;
    else             ml_model_init(&h->local_model);

    h->ctx.model = &h->local_model;
    h->ctx.seed = h->cfg.seed;
    h->ctx.emit_cb = host_emit;
    h->ctx.emit_user = h;

    h->state = calloc(1, opts->game->state_size);
    if (!h->state) { free(h); return NULL; }

    h->bus = ml_bus_create();
    if (!h->bus) { free(h->state); free(h); return NULL; }
    h->host_net = ml_bus_host(h->bus);

    /* Seed before each lifecycle callback so reset is idempotent for replays. */
    h->ctx.rng_state = h->ctx.seed;
    if (h->game->init) h->game->init(h->state, &h->cfg, &h->ctx);
    h->ctx.rng_state = h->ctx.seed;
    if (h->game->reset) h->game->reset(h->state, &h->ctx);

    return h;
}

ml_peer_session *ml_host_attach_peer(ml_host_session *h)
{
    if (!h) return NULL;
    ml_net *link = ml_bus_join(h->bus);
    if (!link) return NULL;

    ml_peer_opts po = { .game = h->game, .panel_w = h->cfg.panel_w,
                        .panel_h = h->cfg.panel_h };
    return ml_peer_open(&po, link);
}

ml_net *ml_host_attach_controller(ml_host_session *h, uint16_t player_id,
                                  const char *name, uint8_t caps)
{
    if (!h) return NULL;
    ml_net *link = ml_bus_join(h->bus);
    if (!link) return NULL;

    ml_player_caps p;
    memset(&p, 0, sizeof(p));
    p.id = player_id;
    p.role = ML_ROLE_CONTROLLER;
    p.caps = caps;
    snprintf(p.name, sizeof(p.name), "%s", name ? name : "p");
    if (h->game->join) h->game->join(h->state, &p, &h->ctx);
    h->player_count++;
    return link;
}

void ml_host_local_input(ml_host_session *h, const ml_input_event *e)
{
    if (!h || !e) return;
    route_one_input(h, e);
}

void ml_host_step(ml_host_session *h, uint32_t wall_ms)
{
    if (!h) return;
    h->accum_ms += (int32_t)wall_ms;

    /* Drain any inputs the controllers pushed onto the bus, in arrival order. */
    ml_net_frame f;
    while (ml_net_recv(h->host_net, &f, 0) == 1) {
        if (f.kind == ML_NET_INPUT && f.len >= (uint16_t)sizeof(ml_input_event)) {
            ml_input_event e;
            memcpy(&e, f.payload, sizeof(e));
            route_one_input(h, &e);
        } else if (f.kind == ML_NET_BYE) {
            if (h->game->leave) h->game->leave(h->state, f.player_id, &h->ctx);
            if (h->player_count > 0) h->player_count--;
        }
    }

    /* Fixed-timestep advance, capped so a stalled peer cannot spiral the host. */
    int steps = 0;
    while (h->accum_ms >= (int32_t)h->tick_ms && steps < 5) {
        h->ctx.tick = h->tick;
        h->game->update(h->state, &h->ctx);
        h->tick++;
        h->accum_ms -= (int32_t)h->tick_ms;
        steps++;

        /* Broadcast a snapshot on schedule. */
        if (++h->snap_counter >= h->snapshot_every) {
            h->snap_counter = 0;
            size_t len = 0;
            if (h->game->snapshot(h->state, h->snap_buf, sizeof(h->snap_buf), &len)
                && len <= sizeof(h->snap_buf) - 4) {
                ml_net_frame sf;
                memset(&sf, 0, sizeof(sf));
                sf.kind = ML_NET_SNAPSHOT;
                uint32_t t = h->tick;
                memcpy(sf.payload, &t, 4);
                memcpy(sf.payload + 4, h->snap_buf, len);
                sf.len = (uint16_t)(4 + len);
                ml_net_send(h->host_net, &sf);
                h->last_snap_len = len;
            }
        }
    }
}

void ml_host_render(ml_host_session *h, ml_canvas *out)
{
    if (!h) return;
    h->ctx.tick = h->tick;
    render_with_view(h->game, h->state, &h->ctx, out,
                     &h->logical, &h->logical_ready,
                     &h->logical_w, &h->logical_h);
}

uint32_t ml_host_tick(const ml_host_session *h)            { return h ? h->tick : 0; }
int      ml_host_player_count(const ml_host_session *h)    { return h ? h->player_count : 0; }
size_t   ml_host_last_snapshot_len(const ml_host_session *h){ return h ? h->last_snap_len : 0; }

bool ml_host_is_over(const ml_host_session *h)
{
    return h && h->game->is_over && h->game->is_over(h->state);
}

void ml_host_destroy(ml_host_session *h)
{
    if (!h) return;
    if (h->logical_ready) ml_canvas_free(&h->logical);
    if (h->journaling) ml_journal_close(h->journal);
    ml_bus_destroy(h->bus);
    free(h->state);
    free(h);
}

/* ---- read-only display peer ---- */

struct ml_peer_session {
    const ml_game_vt  *game;
    ml_game_ctx        ctx;
    void              *state;
    ml_model           local_model;

    ml_net            *link;
    uint32_t           tick;
    bool               alive;

    ml_canvas          logical;
    bool               logical_ready;
    int                logical_w, logical_h;
};

ml_peer_session *ml_peer_open(const ml_peer_opts *opts, ml_net *link)
{
    if (!opts || !opts->game || !link) return NULL;
    struct ml_peer_session *p = calloc(1, sizeof(*p));
    if (!p) return NULL;
    p->game = opts->game;
    p->link = link;
    p->alive = true;

    ml_model_init(&p->local_model);
    p->ctx.model = &p->local_model;

    p->state = calloc(1, opts->game->state_size);
    if (!p->state) { free(p); return NULL; }

    ml_game_cfg cfg = { .seed = 0, .panel_w = opts->panel_w, .panel_h = opts->panel_h };
    p->ctx.rng_state = 0;
    if (p->game->init) p->game->init(p->state, &cfg, &p->ctx);

    return p;
}

void ml_peer_step(ml_peer_session *p, uint32_t wall_ms)
{
    (void)wall_ms;
    if (!p || !p->alive) return;

    ml_net_frame f;
    while (ml_net_recv(p->link, &f, 0) == 1) {
        if (f.kind == ML_NET_SNAPSHOT && f.len >= 4) {
            uint32_t t;
            memcpy(&t, f.payload, 4);
            if (p->game->restore)
                p->game->restore(p->state, f.payload + 4, f.len - 4);
            p->tick = t;
        } else if (f.kind == ML_NET_BYE) {
            p->alive = false;
        }
    }
}

void ml_peer_render(ml_peer_session *p, ml_canvas *out)
{
    if (!p) return;
    p->ctx.tick = p->tick;
    render_with_view(p->game, p->state, &p->ctx, out,
                     &p->logical, &p->logical_ready,
                     &p->logical_w, &p->logical_h);
}

uint32_t ml_peer_tick(const ml_peer_session *p)  { return p ? p->tick : 0; }
bool     ml_peer_alive(const ml_peer_session *p) { return p ? p->alive : false; }

void ml_peer_destroy(ml_peer_session *p)
{
    if (!p) return;
    if (p->logical_ready) ml_canvas_free(&p->logical);
    if (p->link) ml_net_close(p->link);
    free(p->state);
    free(p);
}

/* ---- record / replay journal ---- */

#define ML_JOURNAL_MAGIC 0x4A474C4Du   /* "MLGJ" little-endian */
#define ML_JOURNAL_VER   2u               /* v2 adds the players field */

struct ml_journal {
    FILE  *fp;
    bool   write;
};

ml_journal *ml_journal_open(const char *path, bool write)
{
    if (!path) return NULL;
    FILE *fp = fopen(path, write ? "wb" : "rb");
    if (!fp) return NULL;
    struct ml_journal *j = calloc(1, sizeof(*j));
    if (!j) { fclose(fp); return NULL; }
    j->fp = fp;
    j->write = write;
    return j;
}

void ml_journal_close(ml_journal *j)
{
    if (!j) return;
    if (j->fp) fclose(j->fp);
    free(j);
}

void ml_journal_write_header(ml_journal *j, const ml_game_vt *game,
                             uint32_t seed, int panel_w, int panel_h,
                             int players, uint32_t ticks)
{
    if (!j || !j->write) return;
    uint32_t magic = ML_JOURNAL_MAGIC, ver = ML_JOURNAL_VER;
    char id[32] = {0};
    if (game && game->id) snprintf(id, sizeof(id), "%s", game->id);
    fwrite(&magic, 4, 1, j->fp);
    fwrite(&ver, 4, 1, j->fp);
    fwrite(id, 1, 32, j->fp);
    fwrite(&seed, 4, 1, j->fp);
    fwrite(&panel_w, 4, 1, j->fp);
    fwrite(&panel_h, 4, 1, j->fp);
    fwrite(&players, 4, 1, j->fp);
    fwrite(&ticks, 4, 1, j->fp);
}

/* Patch the ticks field in an already-written header once the sim is done. */
void ml_journal_finalize_ticks(ml_journal *j, uint32_t ticks)
{
    if (!j || !j->write || !j->fp) return;
    long off = 4 + 4 + 32 + 4 + 4 + 4 + 4;   /* offset of the ticks field */
    if (fseek(j->fp, off, SEEK_SET) != 0) return;
    fwrite(&ticks, 4, 1, j->fp);
    fseek(j->fp, 0, SEEK_END);               /* leave the stream at the tail */
}

void ml_journal_write_input(ml_journal *j, const ml_input_event *e)
{
    if (!j || !j->write || !e) return;
    fwrite(e, sizeof(*e), 1, j->fp);
}

bool ml_journal_read_header(ml_journal *j, char game_id[32],
                            uint32_t *seed, int *panel_w, int *panel_h,
                            int *players, uint32_t *ticks)
{
    if (!j || j->write) return false;
    uint32_t magic = 0, ver = 0;
    char id[32];
    if (fread(&magic, 4, 1, j->fp) != 1 || magic != ML_JOURNAL_MAGIC) return false;
    if (fread(&ver, 4, 1, j->fp) != 1 || ver != ML_JOURNAL_VER) return false;
    if (fread(id, 1, 32, j->fp) != 32) return false;
    uint32_t s, tk = 0; int pw, ph, pl = 1;
    if (fread(&s, 4, 1, j->fp) != 1) return false;
    if (fread(&pw, 4, 1, j->fp) != 1) return false;
    if (fread(&ph, 4, 1, j->fp) != 1) return false;
    if (fread(&pl, 4, 1, j->fp) != 1) pl = 1;
    if (fread(&tk, 4, 1, j->fp) != 1) tk = 0;
    if (game_id) memcpy(game_id, id, 32);
    if (seed) *seed = s;
    if (panel_w) *panel_w = pw;
    if (panel_h) *panel_h = ph;
    if (players) *players = pl;
    if (ticks) *ticks = tk;
    return true;
}

int ml_journal_read_input(ml_journal *j, ml_input_event *out)
{
    if (!j || j->write || !out) return -1;
    size_t got = fread(out, sizeof(*out), 1, j->fp);
    if (got == 1) return 1;
    return feof(j->fp) ? 0 : -1;
}