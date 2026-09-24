/*
 * game_runner.c - runs a gamekit session on the render task.
 *
 * One session at a time, owned by the render task, played by up to two BLE
 * links. The BLE host task only enqueues: CMD_START/CMD_JOIN/CMD_SESSION/
 * CMD_STOP/CMD_PAUSE/CMD_RESUME items on the command queue and full-state
 * input frames on the input queue. The render task drains both in service()
 * and steps/draws in render(), so a game start or a button press never runs on
 * the NimBLE host task's small stack and never blocks a link.
 *
 * Input contract (from the phone, per the wire protocol in ble.c): one
 * packet per frame carrying the full held state, one event per control in
 * code order. The runtime stamps the host tick; the runner stamps player_id
 * from the seat the sending link holds, so one phone's frame can never steer
 * the other phone's paddle.
 *
 * A round is started with the seats it needs: a two-player round does not run
 * until both phones are in, and until then the panel holds the board it will
 * start from, dimmed, with the missing seat's "P2?" over it. A solo round
 * seats only its starter and plays immediately, AI and all, exactly as it
 * always did.
 *
 * A live session is waiting, playing, paused, or finished (its is_over
 * callback says so); all four keep the panel on the game. Only a playing
 * session is stepped. Pausing releases every occupied seat's controls into the
 * host, discards queued input, and is entered either by the phone's "game
 * pause" or by the watchdog described below. Leaving it takes an explicit
 * "game resume" or a new start: fresh input alone never resumes, so a
 * controller that drifts back to life cannot make an abandoned round continue.
 *
 * A dropout freezes the round for whoever is left: a human's paddle is never
 * quietly handed to the AI, and a two-player round refuses to resume until
 * both seats are filled again. A solo round has no such rule to break -
 * losing its only seat ends it, as it always did.
 *
 * Watchdog: each seated phone sends a full-state frame every 100 ms while it
 * plays. 500 ms of silence from any seat means that controller is gone - the
 * app was suspended, or the link stalled without a disconnect - so the runner
 * freezes the shared round and pushes one "game paused" at every phone. The
 * grace period starts when a round starts or resumes, and only a frame whose
 * codes are all controls of the running game refreshes it.
 *
 * When the game reaches its terminal state, the runner pushes one
 * "game over <id>" status line so the phones can swap their gamepads for a
 * start-over button.
 */
#include "games/game_runner.h"

#include <stdio.h>
#include <string.h>

#include "esp_log.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "game_registry.h"
#include "mirror/font.h"
#include "mirror/game.h"
#include "mirror/gamerun.h"
#include "mirror/seats.h"
#include "net/ble.h"
#include "panel.h"

static const char *TAG = "game";

/* ------------------------------------------------------------- state */

typedef enum {
    CMD_START,
    CMD_JOIN,
    CMD_SESSION,
    CMD_STOP,
    CMD_PAUSE,
    CMD_RESUME
} cmd_kind_t;

typedef struct {
    cmd_kind_t kind;
    uint16_t   link;      /* the link that asked: its replies go back to it
                             alone, and its commands die with it */
    char       id[24];    /* game id plus optional seat count for CMD_START */
} cmd_item;

/* Two phones can hold commands in flight at once, and a start queued behind a
 * join must not be dropped by a busy answer, so the queue holds more than the
 * one phone it served before. */
#define CMD_Q_DEPTH  8
#define INPUT_Q_DEPTH 64

/* Seats a round can hold. Matches MAX_CONNS in ble.c - a seat is a link - so
 * the two move together. */
#define GAME_MAX_SEATS 2

/* How long a playing round tolerates silence from a controller before the
 * runner freezes it. The phone's heartbeat is 100 ms, so this is five missed
 * frames: long enough to ride out a busy radio, short enough that a suspended
 * phone leaves the mirror holding a frozen board instead of running the game
 * on its own. */
#define RX_SILENCE_PAUSE_US 500000

static QueueHandle_t s_cmd_q;
static QueueHandle_t s_input_q;

/* The mutex protects BLE-visible session identity, input acceptance, the seat
 * table and the pending link losses. Game mutation stays render-owned.
 * Transition flushes and complete packet enqueues share the same lock. */
static SemaphoreHandle_t s_mutex;

static ml_host_session *s_session;   /* render task only; NULL when idle */
static bool             s_active;    /* s_mutex: session live (playing or not) */
static bool             s_paused;    /* render task only: board frozen, live */
static bool             s_accept_input; /* s_mutex: playing only */
static uint64_t         s_last_us;   /* render task only: frame clock */
static char             s_game_id[24];   /* id of the running game */
static bool             s_over_sent;     /* "game over" already pushed */

/* Who holds which seat, and when each seat last proved it was there. The BLE
 * host task reads it from an input frame - to stamp the frame's player and to
 * refresh that seat's receipt - while the render task seats and unseats links,
 * so every access takes the mutex: the 64-bit receipts tear without it, and a
 * seat freed mid-validation must not leave a frame stamped for a player who
 * has left the round. */
static ml_seat_table    s_seats;

/* The seats the round was started with (1..max_players) and whether it is
 * still waiting for them. Render task only. */
static int              s_need;
static bool             s_waiting;

/* Links whose disconnect must still reach the render task when the command
 * queue is full: a loss dropped there would leave a dead link holding a seat
 * and its player attached to a round nobody can play. There is at most one
 * entry per live link (MAX_CONNS in ble.c, which GAME_MAX_SEATS tracks), and a
 * link can only disconnect once, so the array cannot fill with stale handles.
 * s_mutex. */
static uint16_t         s_lost[GAME_MAX_SEATS];
static int              s_lost_count;

/* Latency diagnostic: the arrival time of the most recent accepted input frame
 * (written by the BLE host task) and the measured input-to-render delta
 * (written by the render task). 32-bit microsecond timestamps so each field
 * is a single aligned store; the wrap-around ~71 min is irrelevant for a
 * live latency readout. Zeroed on start and stop so a readout never mixes
 * two sessions. */
static volatile uint32_t s_last_input_us;
static volatile uint32_t s_input_to_render_us;

/* The running game's vtable, guarded by s_mutex. Used by the BLE host task
 * to interpret an input packet's i16 value (button vs axis). */
static const ml_game_vt *s_active_vt;


/* -------------------------------------------------------------- init */

esp_err_t game_runner_init(void)
{
    s_cmd_q = xQueueCreate(CMD_Q_DEPTH, sizeof(cmd_item));
    if (s_cmd_q == NULL) return ESP_ERR_NO_MEM;

    s_input_q = xQueueCreate(INPUT_Q_DEPTH, sizeof(ml_input_event));
    if (s_input_q == NULL) {
        vQueueDelete(s_cmd_q);
        s_cmd_q = NULL;
        return ESP_ERR_NO_MEM;
    }

    s_mutex = xSemaphoreCreateMutex();
    if (s_mutex == NULL) {
        vQueueDelete(s_cmd_q);
        vQueueDelete(s_input_q);
        s_cmd_q = NULL;
        s_input_q = NULL;
        return ESP_ERR_NO_MEM;
    }

    ml_seats_init(&s_seats, GAME_MAX_SEATS);

    return ESP_OK;
}

/* ------------------------------------------------------------- helpers */

/* Publish (or clear) the session state the BLE host task can see. Called by
 * the render task, which is the only writer, through the same mutex the
 * readers take: a reader that sees s_active also sees the s_active_vt that
 * belongs to it. Clearing the vtable closes the input gate, so a frame
 * arriving after the session ends is rejected before it can arm anything. */
static void publish_session(const ml_game_vt *vt)
{
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    xQueueReset(s_input_q);
    s_active_vt = vt;
    s_active = vt != NULL;
    s_accept_input = vt != NULL;
    s_last_input_us = 0;
    s_input_to_render_us = 0;
    xSemaphoreGive(s_mutex);
}

/* Seats filled right now. The BLE host task stamps receipts into the same
 * table, so the read takes the mutex. */
static int seats_count(void)
{
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    const int n = ml_seats_count(&s_seats);
    xSemaphoreGive(s_mutex);
    return n;
}

/* Whether any seat has gone quiet past the watchdog timeout. An empty table is
 * never silent, so a round that lost every seat is stopped by its loss rather
 * than by the watchdog. */
static bool seats_any_silent(uint64_t now)
{
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    const bool silent = ml_seats_any_silent(&s_seats, now, RX_SILENCE_PAUSE_US);
    xSemaphoreGive(s_mutex);
    return silent;
}

static void input_gate(bool enabled, uint64_t now)
{
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    xQueueReset(s_input_q);
    s_accept_input = enabled;
    /* Opening the gate also starts a fresh watchdog grace window: the phones
     * only prove themselves after seeing the line that opened the round, so
     * their silence while it was closed is not held against them. */
    if (enabled) ml_seats_touch_all(&s_seats, now);
    xSemaphoreGive(s_mutex);
}

/* Drop every queued input event without feeding it to the session. Called on
 * every session transition: a press queued for the round that just ended
 * must never steer the next one. Render task only. */
static void input_flush(void)
{
    ml_input_event e;
    while (xQueueReceive(s_input_q, &e, 0) == pdTRUE) {
    }
}

/* Feed one neutral event into the live host for every occupied seat and every
 * control the running game declares, in code order and carrying the control's
 * own code and type: a button arrives released, an axis arrives idle. Draining
 * the queue is not enough to stop a held control: the game keeps what it was
 * last told, so the freeze has to say "released" explicitly, for each player -
 * one human's paddle must not keep drifting while the round is frozen for both.
 *
 * An axis is released to ML_AXIS_IDLE, never to zero. Zero is the centre of an
 * axis's travel, so writing it here would recentre the paddle the moment the
 * round is paused, and the player would resume somewhere they never put it.
 * Render task only: seats are only unseated on this task. */
static void release_declared_controls(void)
{
    const ml_game_vt *vt = s_active_vt;

    if (s_session == NULL || vt == NULL || vt->controls == NULL) return;
    for (int s = 0; s < ML_SEATS_MAX; s++) {
        if (!s_seats.seat[s].used) continue;
        for (int i = 0; i < vt->control_count; i++) {
            const bool axis = vt->controls[i].type == ML_INPUT_AXIS;
            const ml_input_event e = {
                .player_id = s_seats.seat[s].player,
                .seq = 0,
                .code = vt->controls[i].code,
                .value = axis ? ML_AXIS_IDLE : 0,
                .tick = 0,
                .type = vt->controls[i].type,
            };
            ml_host_local_input(s_session, &e);
        }
    }
}

/* Freeze the live session and keep the frame clock current, so the paused
 * wall time is not replayed as one long step on resume. Idempotent: freezing
 * a frozen board releases nothing again and answers the same line. Render
 * task only. */
static void session_freeze(uint64_t now)
{
    s_last_us = now;
    input_gate(false, now);
    if (s_paused) return;
    s_paused = true;
    release_declared_controls();
}

/* ---------------------------------------------------- BLE host task */

/* Queue overflow must answer on the same status stream as render replies, and
 * on the link that asked: a busy answer meant for one phone must not appear on
 * the other's screen. */
static void request_cmd(cmd_kind_t kind, const char *id, uint16_t link)
{
    cmd_item item = { .kind = kind, .link = link };
    snprintf(item.id, sizeof(item.id), "%s", id ? id : "");
    if (xQueueSend(s_cmd_q, &item, 0) != pdTRUE) {
        ble_send_status_line_to(link, "game error busy");
    }
}

void game_runner_request_start(const char *arg, uint16_t link)
{
    request_cmd(CMD_START, arg, link);
}

void game_runner_request_join(uint16_t link)
{
    request_cmd(CMD_JOIN, NULL, link);
}

void game_runner_request_session(uint16_t link)
{
    request_cmd(CMD_SESSION, NULL, link);
}

void game_runner_request_stop(uint16_t link)
{
    request_cmd(CMD_STOP, NULL, link);
}

void game_runner_request_pause(uint16_t link)
{
    request_cmd(CMD_PAUSE, NULL, link);
}

void game_runner_request_resume(uint16_t link)
{
    request_cmd(CMD_RESUME, NULL, link);
}

void game_runner_request_link_lost(uint16_t link)
{
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    bool known = false;
    for (int i = 0; i < s_lost_count; i++) {
        if (s_lost[i] == link) known = true;
    }
    if (!known && s_lost_count < GAME_MAX_SEATS) {
        s_lost[s_lost_count++] = link;
    }
    /* The gate is not closed here: the other link may still be playing, and
     * whether this loss ends anything is the render task's call. Until it
     * runs, a frame from the dead link can no longer arrive, and one already
     * queued cannot steer a seat that is about to be given up. */
    xSemaphoreGive(s_mutex);
}

bool game_runner_request_input_frame(uint16_t link, const ml_input_event *events,
                                     uint8_t count)
{
    if (count > 16 || (count > 0 && events == NULL)) return false;
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    const ml_game_vt *vt = s_active_vt;
    const uint16_t player = ml_seats_player(&s_seats, link);
    bool ok = vt != NULL && s_accept_input && player != 0;
    const int n = count == 0 && vt != NULL ? vt->control_count : count;
    if (ok && uxQueueSpacesAvailable(s_input_q) < (UBaseType_t)n) ok = false;
    for (int i = 0; ok && i < count; i++) {
        bool declared = false;
        for (int j = 0; j < vt->control_count; j++) {
            if (events[i].code == vt->controls[j].code) declared = true;
        }
        if (!declared) ok = false;
    }
    if (ok) {
        const uint64_t now = (uint64_t)esp_timer_get_time();
        /* Both stamps at once: this frame is the seat's proof of life, and
         * the frame carries that seat's player so the other paddle is not
         * moved by this phone. */
        ml_seats_touch(&s_seats, link, now);
        s_last_input_us = (uint32_t)now;
        for (int i = 0; i < n; i++) {
            ml_input_event e = count == 0 ? (ml_input_event){
                .code = vt->controls[i].code,
                .type = vt->controls[i].type,
                /* an axis is released to idle, not to its centre */
                .value = vt->controls[i].type == ML_INPUT_AXIS ? ML_AXIS_IDLE : 0,
            } : events[i];
            e.player_id = player;
            xQueueSend(s_input_q, &e, 0);
        }
    }
    // Enqueue and transition flush share this lock: an old validated frame
    // cannot be enqueued after stop/start or pause/resume has drained it.
    xSemaphoreGive(s_mutex);
    return ok;
}

/* ---------------------------------------------------- render task */

bool game_runner_active(void)
{
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    const bool active = s_active;
    xSemaphoreGive(s_mutex);
    return active;
}

/* Append the game's controls to `line` at offset `n` as " <label>:<type>", in
 * code order; <type> is 'b' (button) or 'a' (axis). The phone builds its
 * gamepad from them. Labels are short (<= 16 chars each) and there are at most
 * 16 controls, so a 256-byte line always holds them; the guard is for a game
 * that grows past that, which truncates rather than overflows. */
static int append_controls(char *line, size_t cap, int n, const ml_game_vt *vt)
{
    for (int i = 0; i < vt->control_count; i++) {
        const char t = (vt->controls[i].type == ML_INPUT_AXIS) ? 'a' : 'b';
        const int need = snprintf(NULL, 0, " %s:%c", vt->controls[i].label, t);
        if (n + need >= (int)cap) break;
        n += snprintf(line + n, cap - (size_t)n, " %s:%c",
                      vt->controls[i].label, t);
    }
    return n;
}

/* Split "game start"'s argument into a game id and an optional seat count.
 * Only a trailing token that is exactly "1" or "2" is a count; every other
 * tail stays part of the id, so a bare "game start rally" and the phones that
 * send one keep working. *players is 0 when no count was given, which the
 * caller reads as "the game's own default": one seat, today's solo round. */
static void split_start_arg(const char *arg, char *id, size_t id_cap,
                            int *players)
{
    int want = 0;
    snprintf(id, id_cap, "%s", arg ? arg : "");
    char *tail = strrchr(id, ' ');
    if (tail != NULL && (tail[1] == '1' || tail[1] == '2') && tail[2] == '\0') {
        want = tail[1] - '0';
        tail[0] = '\0';
    }
    *players = want;
}

/* Open a session for the id in `arg`, seating the asking link as player 1, and
 * answer that link alone with "game ok <id> <label>:<type>...". A round started
 * for more than one seat does not run yet: the seats it needs are pushed, and
 * the panel holds its board until they are filled. Render task only. */
static void session_start(const char *arg, uint16_t link)
{
    if (s_session != NULL) {
        ble_send_status_line_to(link, "game error busy");
        return;
    }

    char id[24];
    int want = 0;
    split_start_arg(arg, id, sizeof(id), &want);

    const ml_game_vt *vt = ml_fw_game_find(id);
    if (vt == NULL) {
        ble_send_status_line_to(link, "game error unknown game");
        return;
    }

    /* A round is started with the seats it needs, never more than the game
     * plays or the hardware holds. An unusable count is clamped rather than
     * refused: the phone's picker only offers the modes this build reports,
     * so a clamp here is a belt on a brace, and refusing would strand a phone
     * whose catalogue is a version behind. */
    int need = want > 0 ? want : 1;
    if (need > vt->max_players) need = vt->max_players;
    if (need > GAME_MAX_SEATS) need = GAME_MAX_SEATS;
    if (need < 1) need = 1;

    ml_host_opts opts = {
        .game = vt,
        .panel_w = panel_width(),
        .panel_h = panel_height(),
        .seed = esp_random(),
        .snapshot_every = 1,
    };
    ml_host_session *h = ml_host_open(&opts);
    if (!h) {
        ble_send_status_line_to(link, "game error out of memory");
        return;
    }

    const uint64_t now = (uint64_t)esp_timer_get_time();

    /* Seat the starter before the session is published: the phone's first
     * frame can only arrive after it has seen the reply, and that frame has to
     * find its link seated or it is rejected. */
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    ml_seats_init(&s_seats, GAME_MAX_SEATS);
    ml_seats_join(&s_seats, link, now);
    xSemaphoreGive(s_mutex);

    ml_host_attach_controller(h, 1, "phone", ML_CAP_BUTTON);

    s_session = h;
    s_need = need;
    s_waiting = need > 1;
    s_paused = false;
    s_over_sent = false;
    s_last_us = now;
    snprintf(s_game_id, sizeof(s_game_id), "%s", id);

    publish_session(vt);
    input_flush();
    if (s_waiting) {
        /* Nobody plays until every seat is in, so nothing is accepted either:
         * the phone stops sending frames as soon as it sees the reply, and one
         * that crossed it must not start the watchdog's clock on a round that
         * has not served yet. */
        input_gate(false, now);
    } else {
        input_gate(true, now);
    }

    char line[256];
    int n = snprintf(line, sizeof(line), "game ok %s", vt->id);
    append_controls(line, sizeof(line), n, vt);
    ble_send_status_line_to(link, line);

    if (s_waiting) {
        /* The starter is told how the round stands, and so is any other phone
         * listening: a seat count is a state every phone shows. */
        char seats[64];
        snprintf(seats, sizeof(seats), "game players %d %d",
                 seats_count(), s_need);
        ble_send_status_line(seats);
    }
}

/* Seat the asking link at the lowest free player id and answer it alone with
 * "game joined <player> <id> <label>:<type>...". Idempotent: a link that
 * already holds a seat is answered with its own, so a rejoin after a screen
 * change cannot take a second one. Filling the last seat of a waiting round is
 * what starts it. Render task only. */
static void session_join(uint16_t link)
{
    if (s_session == NULL) {
        ble_send_status_line_to(link, "game error no game");
        return;
    }

    xSemaphoreTake(s_mutex, portMAX_DELAY);
    uint16_t player = ml_seats_player(&s_seats, link);
    int seated = ml_seats_count(&s_seats);
    xSemaphoreGive(s_mutex);

    const bool fresh = player == 0;
    if (fresh) {
        if (seated >= s_need) {
            ble_send_status_line_to(link, "game error full");
            return;
        }
        const uint64_t now = (uint64_t)esp_timer_get_time();
        xSemaphoreTake(s_mutex, portMAX_DELAY);
        /* Seat and controller belong together: the id the game hears about is
         * the id the seat table will stamp this link's frames with. */
        player = ml_seats_join(&s_seats, link, now);
        seated = ml_seats_count(&s_seats);
        xSemaphoreGive(s_mutex);
        if (player == 0) {
            /* The table filled between the two reads. */
            ble_send_status_line_to(link, "game error full");
            return;
        }
        ml_host_attach_controller(s_session, player, "phone", ML_CAP_BUTTON);
    }

    char line[256];
    int n = snprintf(line, sizeof(line), "game joined %u %s",
                     (unsigned)player, s_game_id);
    append_controls(line, sizeof(line), n, s_active_vt);
    ble_send_status_line_to(link, line);

    if (fresh) {
        char seats[64];
        snprintf(seats, sizeof(seats), "game players %d %d", seated, s_need);
        ble_send_status_line(seats);
    }

    /* Filling the last seat is what starts a waiting round, and the grace
     * window opens with the round: the phones' first heartbeat follows this
     * push within well under 500 ms. A round that is already playing is not
     * restarted here, and one that lost a seat waits for an explicit
     * "game resume" like any other frozen round. */
    if (s_waiting && seated >= s_need) {
        const uint64_t now = (uint64_t)esp_timer_get_time();
        s_waiting = false;
        s_last_us = now;
        input_gate(true, now);
    }
}

/* Answer one link's "game session": what the panel is running, the seats the
 * round was started with, how many are filled, what it is doing, and which
 * seat this link holds (0 when it holds none). A phone uses it to offer a free
 * seat without racing the picker. Render task only. */
static void session_session(uint16_t link)
{
    if (s_session == NULL) {
        ble_send_status_line_to(link, "game session none");
        return;
    }

    const char *state = ml_host_is_over(s_session) ? "over"
                      : s_waiting ? "waiting"
                      : s_paused ? "paused" : "playing";

    xSemaphoreTake(s_mutex, portMAX_DELAY);
    const int seated = ml_seats_count(&s_seats);
    const uint16_t me = ml_seats_player(&s_seats, link);
    xSemaphoreGive(s_mutex);

    char line[80];
    snprintf(line, sizeof(line), "game session %s %d %d %s %u",
             s_game_id, seated, s_need, state, (unsigned)me);
    ble_send_status_line_to(link, line);
}

/* Close the session and push "game stopped" at every link. The published state
 * goes first so no input frame can be stamped against a session that is being
 * freed, and the seat table is emptied with it, so a frame from a link that was
 * in the round cannot be accepted into the next one. `link` is only used for
 * the "no game" refusal, which a stop caused by link loss can never reach: a
 * seat implies a session, and a session is what a seat belongs to. Render task
 * only. */
static void session_stop(uint16_t link)
{
    if (s_session == NULL) {
        ble_send_status_line_to(link, "game error no game");
        return;
    }

    publish_session(NULL);
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    ml_seats_init(&s_seats, GAME_MAX_SEATS);
    xSemaphoreGive(s_mutex);
    ml_host_destroy(s_session);
    s_session = NULL;
    s_paused = false;
    s_waiting = false;
    s_need = 0;
    s_game_id[0] = '\0';
    s_over_sent = false;
    s_last_us = 0;
    s_last_input_us = 0;
    s_input_to_render_us = 0;
    input_flush();
    ble_send_status_line("game stopped");
}

/* Push "game paused", freezing a playing round first. Idempotent: a round that
 * is already frozen - by an earlier pause, or by the watchdog, or by having
 * finished - pushes the same line and changes nothing. A waiting round is not
 * playing yet and cannot be paused: freezing it would leave a paused flag no
 * phone knows about, and the round would stay still after both seats filled.
 * Render task only. */
static void session_pause(uint16_t link)
{
    if (s_session == NULL) {
        ble_send_status_line_to(link, "game error no game");
        return;
    }
    if (s_waiting) {
        ble_send_status_line_to(link, "game error waiting");
        return;
    }
    session_freeze((uint64_t)esp_timer_get_time());
    input_flush();
    ble_send_status_line("game paused");
}

/* Push "game resumed", reopening the input gate and the watchdog grace window
 * for every seat. A finished round has nothing to resume - the phone offers
 * Play again, which is a new start - and a round that is missing a seat cannot
 * be resumed into a half-empty board, so both are refused with the reason the
 * app can act on. Render task only. */
static void session_resume(uint16_t link)
{
    if (s_session == NULL) {
        ble_send_status_line_to(link, "game error no game");
        return;
    }
    if (ml_host_is_over(s_session)) {
        ble_send_status_line_to(link, "game error game over");
        return;
    }
    if (s_waiting || seats_count() < s_need) {
        ble_send_status_line_to(link, "game error waiting");
        return;
    }
    if (s_paused) {
        const uint64_t now = (uint64_t)esp_timer_get_time();
        s_paused = false;
        s_last_us = now;      /* the paused wall time is not replayed */
        input_gate(true, now);
    }
    /* Whatever is queued predates this resume: either a press held while the
     * round was frozen or one meant for the round before it. The phones
     * re-send their current held state on the next heartbeat. */
    input_flush();
    ble_send_status_line("game resumed");
}

/* A link that held a seat is gone: give the seat up, detach its player, and
 * freeze the shared round for whoever is left. A human's paddle is never
 * handed to the AI by a dropout, and a two-player round stays frozen until the
 * seat is filled again. Render task only. */
static void link_lost(uint16_t link)
{
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    const uint16_t player = ml_seats_leave(&s_seats, link);
    const int seated = ml_seats_count(&s_seats);
    xSemaphoreGive(s_mutex);

    /* A link that never joined leaves nothing behind: the round, if one is
     * running, belongs to other phones. */
    if (player == 0) return;
    if (s_session != NULL) ml_host_detach_controller(s_session, player);

    if (seated == 0) {
        /* No seat left is nobody to play and nobody to tell: the layout comes
         * back, exactly as a lone phone's disconnect always did. */
        session_stop(link);
        return;
    }

    /* A waiting, paused, or finished round is already still, so only a playing
     * one has news for the phones. */
    const bool was_playing = !s_paused && !s_waiting && !ml_host_is_over(s_session);
    session_freeze((uint64_t)esp_timer_get_time());
    input_flush();
    if (was_playing) ble_send_status_line("game paused");

    char line[64];
    snprintf(line, sizeof(line), "game players %d %d", seated, s_need);
    ble_send_status_line(line);
}

/* Drop the commands a link queued before it went away. A start or join from a
 * dead phone would seat nobody - a seat is looked up when that phone's frame
 * arrives, and a dead link sends none - and would leave the board running with
 * no controller at all. The queue is rotated in place, so the surviving
 * commands keep their order. Render task only. */
static void drop_commands_from(uint16_t link)
{
    const UBaseType_t queued = uxQueueMessagesWaiting(s_cmd_q);
    for (UBaseType_t i = 0; i < queued; i++) {
        cmd_item item;
        if (xQueueReceive(s_cmd_q, &item, 0) != pdTRUE) break;
        if (item.link == link) continue;
        xQueueSend(s_cmd_q, &item, 0);
    }
}

bool game_runner_service(void)
{
    /* Pending link losses come first, and unconditionally: two phones can keep
     * the command queue full, and a loss dropped there would leave a dead link
     * holding a seat and its player attached to the round forever. The queue
     * they queued into goes with them. */
    uint16_t lost[GAME_MAX_SEATS];
    int lost_count = 0;
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    lost_count = s_lost_count;
    for (int i = 0; i < lost_count; i++) lost[i] = s_lost[i];
    s_lost_count = 0;
    xSemaphoreGive(s_mutex);
    for (int i = 0; i < lost_count; i++) {
        drop_commands_from(lost[i]);
        link_lost(lost[i]);
    }

    /* Commands next: a pause queued behind a start must see the new session
     * before any input drains into it. */
    cmd_item item;
    while (xQueueReceive(s_cmd_q, &item, 0) == pdTRUE) {
        switch (item.kind) {
        case CMD_START:   session_start(item.id, item.link); break;
        case CMD_JOIN:    session_join(item.link);           break;
        case CMD_SESSION: session_session(item.link);        break;
        case CMD_STOP:    session_stop(item.link);           break;
        case CMD_PAUSE:   session_pause(item.link);          break;
        case CMD_RESUME:  session_resume(item.link);         break;
        }
    }

    /* Input is drained on every call whatever the state, but only fed to a
     * round that is playing: idle, waiting, paused, and finished rounds drop
     * it, so the queue cannot hoard presses for a session that is gone and a
     * stale held control cannot spring into the next round. */
    const bool playing = s_session != NULL && !s_paused && !s_waiting &&
                         !ml_host_is_over(s_session);

    ml_input_event e;
    while (xQueueReceive(s_input_q, &e, 0) == pdTRUE) {
        if (playing) ml_host_local_input(s_session, &e);
    }

    return s_active;
}

/* Draw the waiting overlay over the board a round will start from: the board
 * dimmed to half so its paddles and ball stay readable as the round being
 * served, and "P<next_player>?" filling most of the panel with the seat that
 * is still missing. Render task only. */
static void draw_waiting_overlay(ml_canvas *c, int next_player)
{
    for (int i = 0; i < c->w * c->h; i++) {
        ml_rgb *p = &c->px[i];
        p->r /= 2;
        p->g /= 2;
        p->b /= 2;
    }

    /* Sized for the widest an int can print, not for the two seats a round
     * can hold: the IDF build treats a provably-truncating snprintf as an
     * error, and a seat count is only bounded by the table at runtime. */
    char buf[16];
    snprintf(buf, sizeof buf, "P%d?", next_player);

    const ml_font *f = ml_font_find("display24");
    if (f == NULL) f = ml_font_default();

    /* One measurement at 1x is what the fit divides by: a font that has
     * nothing to draw for this string has nothing to scale either. */
    const int w1 = ml_text_width(f, buf, ML_SCALE_1X);
    const int h1 = ml_text_height(f, ML_SCALE_1X);
    if (w1 <= 0 || h1 <= 0) return;

    /* The same Q8.8 fit rule a widget uses: the widest scale that stays inside
     * four fifths of the panel on both axes, never below the smallest render.
     * On the 64x32 panel this lands around 1.2x of the 24px master, so "P2?"
     * is roughly 50x29 pixels, centred on the dimmed board. */
    int q8 = (c->w * 4 / 5 * ML_SCALE_1X) / w1;
    const int by_h = (c->h * 4 / 5 * ML_SCALE_1X) / h1;
    if (by_h < q8) q8 = by_h;
    if (q8 < ML_SCALE_MIN) q8 = ML_SCALE_MIN;

    const int x = (c->w - ml_text_width(f, buf, q8)) / 2;
    const int y = (c->h - ml_text_height(f, q8)) / 2;
    ml_text_draw(c, f, x, y, buf, ML_RGB(220, 220, 220), q8);
}

void game_runner_render(ml_canvas *out)
{
    if (!s_active || s_session == NULL) return;

    const uint64_t now = (uint64_t)esp_timer_get_time();
    if (s_last_us == 0) s_last_us = now;

    /* Waiting for the second phone: the panel holds the board the round will
     * start from, dimmed, with the missing seat's overlay over it. No tick has
     * been served, so nothing is stepped, and the frame clock stays current so
     * the waiting wall time is never replayed as one long step once the seat
     * fills. */
    if (s_waiting) {
        s_last_us = now;
        ml_host_render(s_session, out);
        draw_waiting_overlay(out, seats_count() + 1);
        return;
    }

    const bool finished = ml_host_is_over(s_session);

    /* A seat stopped talking: freeze the shared round and tell every phone
     * once, whichever seat it was. The grace window starts at start/resume, so
     * a round is never frozen before the phones have had their chance to send
     * the first heartbeat. */
    if (!s_paused && !finished && seats_any_silent(now)) {
        session_freeze(now);
        ESP_LOGI(TAG, "no input for %d ms, pausing \"%s\"",
                 (int)(RX_SILENCE_PAUSE_US / 1000), s_game_id);
        ble_send_status_line("game paused");
    }

    if (!s_paused && !finished) {
        uint32_t dt_ms = (uint32_t)((now - s_last_us) / 1000);
        s_last_us = now;
        if (dt_ms < 1) dt_ms = 1;
        if (dt_ms > 100) dt_ms = 100;

        ml_host_step(s_session, dt_ms);
        const uint32_t last_input = s_last_input_us;
        if (last_input != 0) {
            s_input_to_render_us =
                (uint32_t)esp_timer_get_time() - last_input;
        }
    } else {
        /* Paused or finished: redraw the board as it stands and keep the
         * frame clock current, so the time spent frozen never becomes one
         * huge step when the round continues. */
        s_last_us = now;
    }

    /* Tell the phone the game reached its end, once per session. The poll is
     * a pure read of game state; the line rides the same status notification
     * as every other reply, so the app sees it without polling. */
    if (!s_over_sent && ml_host_is_over(s_session)) {
        s_over_sent = true;
        input_gate(false, now);
        char line[64];
        snprintf(line, sizeof(line), "game over %s", s_game_id);
        ble_send_status_line(line);
    }
    ml_host_render(s_session, out);
}

ml_input_type game_runner_control_type(uint16_t code)
{
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    const ml_game_vt *vt = s_active_vt;
    ml_input_type type = ML_INPUT_BUTTON;
    if (vt != NULL && vt->controls != NULL) {
        for (int i = 0; i < vt->control_count; i++) {
            if (vt->controls[i].code == code) {
                type = (ml_input_type)vt->controls[i].type;
                break;
            }
        }
    }
    xSemaphoreGive(s_mutex);
    return type;
}

uint32_t game_runner_input_to_render_us(void)
{
    return s_input_to_render_us;
}
