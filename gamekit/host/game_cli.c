/*
 * game_cli.c - run a game without hardware.
 *
 * Mirrors mirror-cli deliberately, so the feedback loop is the one the project
 * already knows. Headless by design: it simulates a host (and, with --peer, a
 * display peer over the in-process bus), feeds a baked input script, and writes
 * PNG/ASCII frames. A panel-size sweep writes one frame per size, which is the
 * arbitrary-size guarantee made visible, and --hash prints a framebuffer digest
 * so record/replay can assert determinism the way the render core asserts golden
 * images.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mirror/gamerun.h"
#include "mirror/mock.h"
#include "png_write.h"

extern const ml_game_vt ml_game_rally;
extern const ml_game_vt ml_game_snake;
extern const ml_game_vt ml_game_tetris;
extern const ml_game_vt ml_game_breakout;
extern const ml_game_vt ml_game_invaders;

static const ml_game_vt *find_game(const char *name)
{
    if (!strcmp(name, "rally"))    return &ml_game_rally;
    if (!strcmp(name, "snake"))    return &ml_game_snake;
    if (!strcmp(name, "tetris"))   return &ml_game_tetris;
    if (!strcmp(name, "breakout")) return &ml_game_breakout;
    if (!strcmp(name, "invaders")) return &ml_game_invaders;
    return NULL;
}

static void usage(const char *argv0)
{
    printf(
        "Run a smart-mirror game on the host, no hardware.\n"
        "\n"
        "Usage: %s <game> [options]\n"
        "\n"
        "Games: rally, snake, tetris, breakout, invaders\n"
        "\n"
        "Options:\n"
        "  --panel WxH       Panel size (default 64x32)\n"
        "  --sizes A,B,..    Run one frame per size, e.g. 64x32,128x64,128x128\n"
        "  -s <n>            Pixel scale, default 6\n"
        "  --frames <n>       Ticks to simulate, default 90\n"
        "  --seed <n>         Session seed, default 1\n"
        "  --players <1|2>    Controllers to attach, default 1\n"
        "  --peer             Also render a display peer over the loopback bus\n"
        "  --record <path>    Journal the fed inputs for later --replay\n"
        "  --replay <path>    Re-feed a journal into a fresh host from its seed\n"
        "  -o <path>          Output PNG (default out/<game>-<WxH>.png)\n"
        "  --led             Draw inter-pixel gaps so it reads as discrete LEDs\n"
        "  --mirror <n>       Simulate two-way mirror transmission, percent\n"
        "  --ascii           Also print the result to the terminal\n"
        "  --hash            Print an FNV-1a digest of the framebuffer\n"
        "  -h, --help        This message\n",
        argv0);
}

/* A short, deterministic script: enough motion to exercise paddles and the
 * ball, identical on every run. */
typedef struct { uint32_t tick; uint16_t pid; uint16_t code; int16_t value; } step;
static const step DEMO[] = {
    { 2,  1, 1, 1 }, { 10, 1, 1, 0 }, { 18, 1, 0, 1 }, { 26, 1, 0, 0 },
    { 40, 1, 1, 1 }, { 55, 1, 1, 0 },
    { 5,  2, 0, 1 }, { 14, 2, 0, 0 }, { 22, 2, 1, 1 }, { 30, 2, 1, 0 },
    { 45, 2, 0, 1 }, { 60, 2, 0, 0 },
};
#define DEMO_LEN ((int)(sizeof(DEMO) / sizeof(DEMO[0])))

/* Snake demo: a U-shaped tour of a 64x32 board, deterministic from the seed.
 * The snake starts centre-heading-right; turns land on the step after each
 * press (one move per w/16 ticks, so ticks 0,4,8,..). Codes: 0 Up, 1 Down,
 * 2 Left, 3 Right. */
static const step SNAKE_DEMO[] = {
    { 2,  1, 1, 1 }, { 3,  1, 1, 0 },   /* down */
    { 30, 1, 3, 1 }, { 31, 1, 3, 0 },   /* right */
    { 58, 1, 0, 1 }, { 59, 1, 0, 0 },   /* up */
    { 74, 1, 2, 1 }, { 75, 1, 2, 0 },   /* left */
};
#define SNAKE_DEMO_LEN ((int)(sizeof(SNAKE_DEMO) / sizeof(SNAKE_DEMO[0])))

/* Tetris demo: nudge right, rotate, nudge left, hard-drop. Codes: 0 Up
 * (rotate), 1 Down (hard drop), 2 Left, 3 Right. */
static const step TETRIS_DEMO[] = {
    { 4,  1, 3, 1 }, { 5,  1, 3, 0 },   /* right */
    { 24, 1, 0, 1 }, { 25, 1, 0, 0 },   /* rotate */
    { 44, 1, 2, 1 }, { 45, 1, 2, 0 },   /* left */
    { 64, 1, 1, 1 }, { 65, 1, 1, 0 },   /* hard drop */
};
#define TETRIS_DEMO_LEN ((int)(sizeof(TETRIS_DEMO) / sizeof(TETRIS_DEMO[0])))

/* Breakout demo: paddle left, then right, while the ball bounces. Codes:
 * 0 Left, 1 Right. */
static const step BREAKOUT_DEMO[] = {
    { 4,  1, 0, 1 }, { 24, 1, 0, 0 },
    { 36, 1, 1, 1 }, { 76, 1, 1, 0 },
};
#define BREAKOUT_DEMO_LEN ((int)(sizeof(BREAKOUT_DEMO) / sizeof(BREAKOUT_DEMO[0])))

/* Invaders demo: sweep right, shoot, sweep left, shoot. Codes: 0 Left,
 * 1 Right, 2 Shoot. */
static const step INVADERS_DEMO[] = {
    { 2,  1, 1, 1 }, { 10, 1, 2, 1 }, { 11, 1, 2, 0 },
    { 30, 1, 2, 1 }, { 31, 1, 2, 0 }, { 40, 1, 1, 0 },
    { 42, 1, 0, 1 }, { 50, 1, 2, 1 }, { 51, 1, 2, 0 },
    { 70, 1, 2, 1 }, { 71, 1, 2, 0 }, { 80, 1, 0, 0 },
};
#define INVADERS_DEMO_LEN ((int)(sizeof(INVADERS_DEMO) / sizeof(INVADERS_DEMO[0])))

static void print_ascii(const uint8_t *rgb, int w, int h)
{
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            const uint8_t *p = rgb + ((size_t)y * w + x) * 3;
            int lum = (p[0] * 30 + p[1] * 59 + p[2] * 11) / 100;
            const char *c = lum > 160 ? "██" : lum > 80 ? "▓▓" : lum > 24 ? "░░" : "  ";
            fputs(c, stdout);
        }
        fputc('\n', stdout);
    }
}

static uint32_t fnv1a(const uint8_t *p, size_t n)
{
    uint32_t h = 0x811c9dc5u;
    for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 0x01000193u; }
    return h;
}

static void feed_demo(const ml_game_vt *g, ml_host_session *h, ml_net **ctrl,
                      int players, uint32_t tick)
{
    const step *demo = DEMO;
    int n = DEMO_LEN;
    if (!strcmp(g->id, "snake"))    { demo = SNAKE_DEMO;    n = SNAKE_DEMO_LEN; }
    else if (!strcmp(g->id, "tetris"))   { demo = TETRIS_DEMO;    n = TETRIS_DEMO_LEN; }
    else if (!strcmp(g->id, "breakout")) { demo = BREAKOUT_DEMO;  n = BREAKOUT_DEMO_LEN; }
    else if (!strcmp(g->id, "invaders")) { demo = INVADERS_DEMO;  n = INVADERS_DEMO_LEN; }
    uint16_t seq = 0;
    for (int i = 0; i < n; i++) {
        if (demo[i].tick != tick) continue;
        int idx = demo[i].pid - 1;
        if (idx < 0 || idx >= players) continue;
        ml_input_event e;
        memset(&e, 0, sizeof(e));
        e.player_id = demo[i].pid;
        e.code = demo[i].code;
        e.value = demo[i].value;
        e.type = ML_INPUT_BUTTON;
        e.seq = seq++;
        e.tick = tick;
        /* Exercise both input paths: player 1 over the net, the rest locally. */
        if (idx == 0 && ctrl[0]) ml_net_send_input(ctrl[0], &e);
        else                     ml_host_local_input(h, &e);
    }
}

static int render_frame(const ml_game_vt *g, int w, int h, int scale, bool led,
                        int mirror_pct, bool ascii, const char *out_path,
                        bool want_hash, uint32_t *hash_out,
                        uint32_t seed, int frames, int players,
                        const char *record_path)
{
    ml_host_opts opts = { .game = g, .panel_w = w, .panel_h = h, .seed = seed };
    ml_host_session *hs = ml_host_open(&opts);
    (void)want_hash;
    if (!hs) { fprintf(stderr, "error: cannot open host\n"); return 1; }
    if (record_path) {
        ml_journal *j = ml_journal_open(record_path, true);
        if (j) ml_host_set_journal(hs, j);
        else fprintf(stderr, "warning: cannot open journal %s\n", record_path);
    }

    if (players < 1) players = 1;
    if (players > 2) players = 2;
    ml_net *ctrl[2] = {0};
    for (int i = 0; i < players; i++)
        ctrl[i] = ml_host_attach_controller(hs, (uint16_t)(i + 1), "p", ML_CAP_BUTTON);

    if (record_path) ml_host_journal_commit(hs, players);

    uint32_t tick_ms = g->tick_ms ? g->tick_ms : 33;
    for (int t = 0; t < frames; t++) {
        feed_demo(g, hs, ctrl, players, (uint32_t)t);
        ml_host_step(hs, tick_ms);
    }
    if (record_path) ml_host_journal_finalize(hs);

    ml_canvas c;
    if (!ml_canvas_init(&c, w, h, NULL)) { ml_host_destroy(hs); return 1; }
    ml_host_render(hs, &c);

    size_t nbytes = (size_t)w * h * 3;
    uint8_t *rgb = malloc(nbytes);
    ml_canvas_export_rgb888(&c, 255, rgb);

    if (hash_out) *hash_out = fnv1a(rgb, nbytes);

    uint8_t *draw = malloc(nbytes);
    memcpy(draw, rgb, nbytes);
    if (mirror_pct > 0 && mirror_pct < 100)
        for (size_t i = 0; i < nbytes; i++) draw[i] = (uint8_t)(draw[i] * mirror_pct / 100);

    bool ok = led ? png_write_rgb_led(out_path, draw, w, h, scale)
                  : png_write_rgb(out_path, draw, w, h, scale);
    if (ok) printf("  %-8s %s (%dx%d at %dx)%s\n", g->id, out_path, w, h, scale,
                   mirror_pct > 0 ? " [mirror]" : "");
    else    fprintf(stderr, "error: cannot write %s\n", out_path);

    if (ascii) print_ascii(draw, w, h);
    free(rgb); free(draw);
    ml_canvas_free(&c);
    ml_host_destroy(hs);
    return ok ? 0 : 1;
}

static int run_peer(int w, int h, int scale, bool led, int mirror_pct,
                    bool ascii, const char *host_path, const char *peer_path,
                    bool want_hash)
{
    const ml_game_vt *g = &ml_game_rally;
    ml_host_opts opts = { .game = g, .panel_w = w, .panel_h = h, .seed = 1 };
    ml_host_session *hs = ml_host_open(&opts);
    ml_peer_session *peer = ml_host_attach_peer(hs);
    ml_canvas ch, cp;
    ml_canvas_init(&ch, w, h, NULL);
    ml_canvas_init(&cp, w, h, NULL);
    (void)want_hash;
    int players = 2;
    ml_net *ctrl[2] = {0};
    for (int i = 0; i < players; i++)
        ctrl[i] = ml_host_attach_controller(hs, (uint16_t)(i + 1), "p", ML_CAP_BUTTON);

    uint32_t tick_ms = g->tick_ms ? g->tick_ms : 33;
    for (int t = 0; t < 90; t++) {
        feed_demo(g, hs, ctrl, players, (uint32_t)t);
        ml_host_step(hs, tick_ms);
        ml_peer_step(peer, tick_ms);
    }
    ml_host_render(hs, &ch);
    ml_peer_render(peer, &cp);
    size_t n = (size_t)w * h * 3;
    uint8_t *rh = malloc(n), *rp = malloc(n);
    ml_canvas_export_rgb888(&ch, 255, rh);
    ml_canvas_export_rgb888(&cp, 255, rp);
    uint32_t hh = fnv1a(rh, n), hp = fnv1a(rp, n);

    char ph[256], pp[256];
    snprintf(ph, sizeof(ph), "%s", host_path);
    snprintf(pp, sizeof(pp), "%s", peer_path);
    if (mirror_pct > 0 && mirror_pct < 100) {
        for (size_t i = 0; i < n; i++) { rh[i] = (uint8_t)(rh[i] * mirror_pct / 100);
                                          rp[i] = (uint8_t)(rp[i] * mirror_pct / 100); }
    }
    bool use_led = led;
    if (use_led) { png_write_rgb_led(ph, rh, w, h, scale);
                   png_write_rgb_led(pp, rp, w, h, scale); }
    else         { png_write_rgb(ph, rh, w, h, scale);
                   png_write_rgb(pp, rp, w, h, scale); }
    if (ascii) { puts("host:"); print_ascii(rh, w, h); puts("peer:"); print_ascii(rp, w, h); }
    printf("  host %-8s %s  hash %08x\n", g->id, ph, hh);
    printf("  peer %-8s %s  hash %08x\n", g->id, pp, hp);

    if (hh == hp) printf("  MATCH: peer reproduces the host frame\n");
    else          fprintf(stderr, "  MISMATCH: peer drift from host\n");

    free(rh); free(rp); ml_canvas_free(&ch); ml_canvas_free(&cp);
    ml_peer_destroy(peer);
    ml_host_destroy(hs);
    return (hh == hp) ? 0 : 1;
}

static int run_replay(const char *path, int scale, bool led, int mirror_pct,
                      bool ascii, const char *out_path)
{
    ml_journal *j = ml_journal_open(path, false);
    if (!j) { fprintf(stderr, "error: cannot open journal %s\n", path); return 1; }
    char id[32];
    uint32_t seed, ticks = 0; int pw, ph, players = 1;
    if (!ml_journal_read_header(j, id, &seed, &pw, &ph, &players, &ticks)) {
        ml_journal_close(j); return 1;
    }
    const ml_game_vt *g = find_game(id);
    if (!g) { fprintf(stderr, "error: journal is for unknown game '%s'\n", id);
              ml_journal_close(j); return 1; }

    /* Buffer the events to find the last tick. */
    static ml_input_event ev[4096];
    int ne = 0; uint32_t maxtick = 0;
    int r;
    while ((r = ml_journal_read_input(j, &ev[ne])) == 1) {
        if (ev[ne].tick > maxtick) maxtick = ev[ne].tick;
        if (++ne >= (int)(sizeof(ev) / sizeof(ev[0]))) break;
    }
    ml_journal_close(j);

    ml_host_opts opts = { .game = g, .panel_w = pw, .panel_h = ph, .seed = seed };
    ml_host_session *hs = ml_host_open(&opts);
    if (players < 1) players = 1;
    if (players > g->max_players) players = g->max_players;
    for (int i = 0; i < players; i++)
        ml_host_attach_controller(hs, (uint16_t)(i + 1), "p", ML_CAP_BUTTON);

    uint32_t tick_ms = g->tick_ms ? g->tick_ms : 33;
    uint32_t sim_ticks = ticks > 0 ? ticks : (maxtick + 8);
    for (uint32_t t = 0; t < sim_ticks; t++) {
        for (int i = 0; i < ne; i++)
            if (ev[i].tick == t) ml_host_local_input(hs, &ev[i]);
        ml_host_step(hs, tick_ms);
    }

    ml_canvas c;
    ml_canvas_init(&c, pw, ph, NULL);
    ml_host_render(hs, &c);
    size_t n = (size_t)pw * ph * 3;
    uint8_t *rgb = malloc(n);
    ml_canvas_export_rgb888(&c, 255, rgb);
    uint32_t h = fnv1a(rgb, n);
    uint8_t *draw = malloc(n);
    memcpy(draw, rgb, n);
    if (mirror_pct > 0 && mirror_pct < 100)
        for (size_t i = 0; i < n; i++) draw[i] = (uint8_t)(draw[i] * mirror_pct / 100);
    bool ok = led ? png_write_rgb_led(out_path, draw, pw, ph, scale)
                  : png_write_rgb(out_path, draw, pw, ph, scale);
    printf("  replay %-8s %s  hash %08x  (seed %u, %dx%d, %d events, %u ticks)\n",
           g->id, out_path, h, seed, pw, ph, ne, sim_ticks);
    if (ascii) print_ascii(draw, pw, ph);
    free(rgb); free(draw); ml_canvas_free(&c); ml_host_destroy(hs);
    return ok ? 0 : 1;
}
int main(int argc, char **argv)
{
    if (argc < 2) { usage(argv[0]); return 2; }
    if (!strcmp(argv[1], "-h") || !strcmp(argv[1], "--help")) { usage(argv[0]); return 0; }

    const char *game_name = argv[1];
    const ml_game_vt *game = find_game(game_name);
    if (!game) { fprintf(stderr, "error: unknown game '%s'\n", game_name); return 2; }

    int W = 64, H = 32;
    int scale = 6, mirror_pct = 0;
    int frames = 90, seed = 1, players = 1;
    bool led = false, ascii = false, want_hash = false, peer = false;
    const char *out = NULL;
    const char *sizes = NULL;
    const char *record = NULL, *replay = NULL;

    for (int i = 2; i < argc; i++) {
        const char *a = argv[i];
        bool hn = (i + 1 < argc);
        if      (!strcmp(a, "--panel") && hn)  sscanf(argv[++i], "%dx%d", &W, &H);
        else if (!strcmp(a, "--sizes") && hn)  sizes = argv[++i];
        else if (!strcmp(a, "-s") && hn)       scale = atoi(argv[++i]);
        else if (!strcmp(a, "--frames") && hn) frames = atoi(argv[++i]);
        else if (!strcmp(a, "--seed") && hn)   seed = (int)strtoul(argv[++i], NULL, 0);
        else if (!strcmp(a, "--players") && hn) players = atoi(argv[++i]);
        else if (!strcmp(a, "--peer"))          peer = true;
        else if (!strcmp(a, "--record") && hn) record = argv[++i];
        else if (!strcmp(a, "--replay") && hn)  replay = argv[++i];
        else if (!strcmp(a, "-o") && hn)       out = argv[++i];
        else if (!strcmp(a, "--led"))          led = true;
        else if (!strcmp(a, "--mirror") && hn)  mirror_pct = atoi(argv[++i]);
        else if (!strcmp(a, "--ascii"))        ascii = true;
        else if (!strcmp(a, "--hash"))         want_hash = true;
        else if (!strcmp(a, "-h") || !strcmp(a, "--help")) { usage(argv[0]); return 0; }
        else { fprintf(stderr, "error: unrecognised arg '%s'\n", a); usage(argv[0]); return 2; }
    }

    if (scale < 1) scale = 1;
    if (scale > 32) scale = 32;
    if (players < 1) players = 1;
    if (players > 2) players = 2;

    if (replay) {
        char def[256];
        snprintf(def, sizeof(def), "out/%s-replay.png", game_name);
        return run_replay(replay, scale, led, mirror_pct, ascii, out ? out : def);
    }

    if (peer) {
        char hpath[256], ppath[256];
        snprintf(hpath, sizeof(hpath), "out/%s-%dx%d-peer-host.png", game_name, W, H);
        snprintf(ppath, sizeof(ppath), "out/%s-%dx%d-peer.png", game_name, W, H);
        return run_peer(W, H, scale, led, mirror_pct, ascii,
                        out ? out : hpath, ppath, want_hash);
    }

    /* The demo is deterministic from seed; record mode just attaches a journal
     * so the same script can be re-fed with --replay and reproduce the frame. */

    if (sizes) {
        int rc = 0;
        char buf[256];
        const char *p = sizes;
        while (*p) {
            int w = 0, hgt = 0;
            int got = sscanf(p, "%dx%d", &w, &hgt);
            if (got == 2 && w > 0 && hgt > 0) {
                snprintf(buf, sizeof(buf), "out/%s-%dx%d.png", game_name, w, hgt);
                uint32_t hash = 0;
                rc |= render_frame(game, w, hgt, scale, led, mirror_pct, ascii,
                                   buf, true, &hash, seed, frames, players, NULL);
            }
            const char *comma = strchr(p, ',');
            if (!comma) break;
            p = comma + 1;
        }
        return rc;
    }

    char def[256];
    snprintf(def, sizeof(def), "out/%s-%dx%d.png", game_name, W, H);
    uint32_t hash = 0;
    int rc = render_frame(game, W, H, scale, led, mirror_pct, ascii,
                          out ? out : def, want_hash, &hash,
                          seed, frames, players, record);
    if (want_hash) printf("  %s %dx%d  hash %08x\n", game_name, W, H, hash);
    return rc;
}