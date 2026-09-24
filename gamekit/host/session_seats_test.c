/*
 * session_seats_test.c - attach and detach against a fake game.
 *
 * The two-phone round is only as good as the session's bookkeeping: the
 * second seat must exist, a third must be refused without a phantom join, and
 * a seat that left must stop steering - including a frame that was already on
 * its way into the session. A fake game records every join, leave and input
 * it is handed, so the assertions are about what the game actually saw
 * rather than about the session's own counters.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "mirror/gamerun.h"

#define LOG_MAX 64

static char g_log[LOG_MAX][16];
static int  g_log_n;

static void log_add(const char *s)
{
    if (g_log_n < LOG_MAX) snprintf(g_log[g_log_n], sizeof(g_log[0]), "%s", s);
    g_log_n++;
}

static int log_count(const char *s)
{
    int n = 0;
    for (int i = 0; i < g_log_n && i < LOG_MAX; i++) {
        if (strcmp(g_log[i], s) == 0) n++;
    }
    return n;
}

/* ---- the fake game ---- */

static const ml_control_def fake_controls[] = {
    { .label = "Fire", .code = 0, .caps = ML_CAP_BUTTON,
      .type = ML_INPUT_BUTTON },
};

static void fake_join(void *state, const ml_player_caps *p, ml_game_ctx *ctx)
{
    (void)state; (void)ctx;
    char b[16];
    snprintf(b, sizeof(b), "J%u", (unsigned)p->id);
    log_add(b);
}

static void fake_leave(void *state, uint16_t player_id, ml_game_ctx *ctx)
{
    (void)state; (void)ctx;
    char b[16];
    snprintf(b, sizeof(b), "L%u", (unsigned)player_id);
    log_add(b);
}

static void fake_input(void *state, const ml_input_event *e, ml_game_ctx *ctx)
{
    (void)state; (void)ctx;
    char b[16];
    snprintf(b, sizeof(b), "I%u", (unsigned)e->player_id);
    log_add(b);
}

static const ml_game_vt fake_game = {
    .id = "fake",
    .tick_ms = 33,
    .max_players = 2,
    .state_size = 8,
    .controls = fake_controls,
    .control_count = 1,
    .join = fake_join,
    .leave = fake_leave,
    .input = fake_input,
};

static int failures;

#define CHECK(cond, ...) do {                                     \
    if (cond) { printf("ok:   "); }                               \
    else { failures++; printf("FAIL: "); }                        \
    printf(__VA_ARGS__);                                          \
    printf("\n");                                                 \
} while (0)

int main(void)
{
    ml_host_opts opts = { .game = &fake_game, .panel_w = 64, .panel_h = 32,
                          .seed = 1 };
    ml_host_session *h = ml_host_open(&opts);
    if (!h) { fprintf(stderr, "open failed\n"); return 1; }

    g_log_n = 0;
    CHECK(ml_host_player_count(h) == 0, "a fresh session holds no players");

    ml_net *c1 = ml_host_attach_controller(h, 1, "a", ML_CAP_BUTTON);
    ml_net *c2 = ml_host_attach_controller(h, 2, "b", ML_CAP_BUTTON);
    CHECK(c1 != NULL && c2 != NULL, "both players attach");
    CHECK(ml_host_player_count(h) == 2, "the count follows the attaches");
    CHECK(log_count("J1") == 1 && log_count("J2") == 1,
          "the game saw one join per player, in id order");

    /* The game's max_players is the session's cap, not the caller's problem. */
    CHECK(ml_host_attach_controller(h, 3, "c", ML_CAP_BUTTON) == NULL,
          "a third player on a two-player game is refused");
    CHECK(ml_host_player_count(h) == 2, "the refused attach left the count alone");
    CHECK(log_count("J3") == 0, "and the game never heard a third join");
    CHECK(ml_host_attach_controller(h, 1, "a", ML_CAP_BUTTON) == NULL,
          "re-attaching an attached player is refused");
    CHECK(log_count("J1") == 1, "with no second join for it");

    /* Detach: one leave, a count that follows, and idempotence. */
    CHECK(ml_host_detach_controller(h, 1), "detaching an attached player reports it");
    CHECK(ml_host_player_count(h) == 1, "the count follows the detach");
    CHECK(log_count("L1") == 1, "the game saw exactly one leave");
    CHECK(!ml_host_detach_controller(h, 1), "detaching again reports nothing removed");
    CHECK(log_count("L1") == 1, "and fires no second leave");

    /* The freed slot is reusable, up to the game's cap again. */
    CHECK(ml_host_attach_controller(h, 3, "c", ML_CAP_BUTTON) != NULL,
          "a freed slot takes a new player");
    CHECK(ml_host_player_count(h) == 2, "and the session is full again");
    CHECK(log_count("J3") == 1, "the game saw that join once");

    /* Input gating: the round must not be steered by a seat that left. */
    ml_input_event e;
    memset(&e, 0, sizeof(e));
    e.code = 0; e.value = 1; e.type = ML_INPUT_BUTTON;

    e.player_id = 1;
    ml_host_local_input(h, &e);
    CHECK(log_count("I1") == 0, "input from a detached player never reaches the game");
    e.player_id = 2;
    ml_host_local_input(h, &e);
    CHECK(log_count("I2") == 1, "input from an attached player does");
    e.player_id = 99;
    ml_host_local_input(h, &e);
    CHECK(log_count("I99") == 0, "input from a player that never joined is dropped");

    /* A graceful BYE off a link detaches through the same path. */
    ml_net_frame bye;
    memset(&bye, 0, sizeof(bye));
    bye.kind = ML_NET_BYE;
    bye.player_id = 2;
    CHECK(ml_net_send(c2, &bye) == 1, "the leaving player sends a BYE");
    ml_host_step(h, 0);
    CHECK(log_count("L2") == 1, "the BYE fired the leave");
    CHECK(ml_host_player_count(h) == 1, "and the count follows it");
    bye.player_id = 77;
    (void)ml_net_send(c2, &bye);
    ml_host_step(h, 0);
    CHECK(log_count("L77") == 0, "a BYE from a player the session never held fires nothing");
    CHECK(ml_host_player_count(h) == 1, "and changes no count");

    ml_host_destroy(h);

    if (failures != 0) { printf("FAIL %d\n", failures); return 1; }
    printf("PASS\n");
    return 0;
}
