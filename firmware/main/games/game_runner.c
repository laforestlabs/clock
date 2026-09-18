/*
 * game_runner.c - runs a gamekit session on the render task.
 *
 * One session at a time, owned by the render task. The BLE host task only
 * enqueues: CMD_START/CMD_STOP/CMD_PAUSE/CMD_RESUME items on the command
 * queue and full-state input frames on the input queue. The render task
 * drains both in service() and steps/draws in render(), so a game start or a
 * button press never runs on the NimBLE host task's small stack and never
 * blocks the link.
 *
 * Input contract (from the phone, per the wire protocol in ble.c): one
 * packet per frame carrying the full held state, one event per control in
 * code order. The runtime stamps the host tick; player_id is 1.
 *
 * A live session is playing, paused, or finished (its is_over callback says
 * so); all three keep the panel on the game. Only a playing session is
 * stepped. Pausing releases every control the game declares into the host,
 * discards queued input, and is entered either by the phone's "game pause" or
 * by the watchdog described below. Leaving it takes an explicit "game
 * resume" or a new start: fresh input alone never resumes, so a controller
 * that drifts back to life cannot make an abandoned round continue.
 *
 * Watchdog: the phone sends a full-state frame every 100 ms while it plays.
 * 500 ms of silence means the controller is gone - the app was suspended, or
 * the link stalled without a disconnect - so the runner freezes the round and
 * pushes one "game paused" at the phone. The grace period starts when a
 * session starts or resumes, and only a frame whose codes are all controls of
 * the running game refreshes it.
 *
 * When the game reaches its terminal state, the runner pushes one
 * "game over <id>" status line so the phone can swap its gamepad for a
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
#include "mirror/game.h"
#include "mirror/gamerun.h"
#include "net/ble.h"
#include "panel.h"

static const char *TAG = "game";

/* ------------------------------------------------------------- state */

typedef enum {
    CMD_START,
    CMD_STOP,
    CMD_PAUSE,
    CMD_RESUME
} cmd_kind_t;

typedef struct {
    cmd_kind_t kind;
    char       id[24];    /* game id for CMD_START; unused otherwise */
} cmd_item;

#define CMD_Q_DEPTH  4
#define INPUT_Q_DEPTH 64

/* How long a playing round tolerates silence from the controller before the
 * runner freezes it. The phone's heartbeat is 100 ms, so this is five missed
 * frames: long enough to ride out a busy radio, short enough that a suspended
 * phone leaves the mirror holding a frozen board instead of running the game
 * on its own. */
#define RX_SILENCE_PAUSE_US 500000

static QueueHandle_t s_cmd_q;
static QueueHandle_t s_input_q;

/* The mutex protects BLE-visible session identity, input acceptance, pending
 * disconnect and the 64-bit receipt clock. Game mutation stays render-owned.
 * Transition flushes and complete packet enqueues share the same lock. */
static SemaphoreHandle_t s_mutex;

static ml_host_session *s_session;   /* render task only; NULL when idle */
static bool             s_active;    /* s_mutex: session live (playing or not) */
static bool             s_paused;    /* render task only: board frozen, live */
static bool             s_accept_input; /* s_mutex: playing only */
static bool             s_disconnect;   /* s_mutex: mandatory render-task stop */
static uint64_t         s_last_us;   /* render task only: frame clock */
static uint64_t         s_rx_us;     /* s_mutex: last accepted input frame */
static char             s_game_id[24];   /* id of the running game */
static bool             s_over_sent;     /* "game over" already pushed */

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

    return ESP_OK;
}

/* ------------------------------------------------------------- helpers */

/* Publish (or clear) the session state the BLE host task can see. Called by
 * the render task, which is the only writer, through the same mutex the
 * readers take: a reader that sees s_active also sees the s_active_vt that
 * belongs to it. Clearing the vtable also drops the watchdog's stamp, so a
 * frame arriving after the session ends cannot arm a later one. */
static void publish_session(const ml_game_vt *vt)
{
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    xQueueReset(s_input_q);
    s_active_vt = vt;
    s_active = vt != NULL;
    s_accept_input = vt != NULL;
    s_rx_us = vt != NULL ? (uint64_t)esp_timer_get_time() : 0;
    s_last_input_us = 0;
    s_input_to_render_us = 0;
    xSemaphoreGive(s_mutex);
}

/* The 64-bit receipt stamp is written by the BLE host task and read by the
 * render task; a 64-bit load or store is two 32-bit accesses on this target,
 * and a torn value would read as ~71 minutes either side of the truth. The
 * mutex is what makes it atomic. */
static uint64_t rx_stamp_get(void)
{
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    const uint64_t stamp = s_rx_us;
    xSemaphoreGive(s_mutex);
    return stamp;
}

static void input_gate(bool enabled, uint64_t now)
{
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    xQueueReset(s_input_q);
    s_accept_input = enabled;
    if (enabled) s_rx_us = now;
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

/* Feed one neutral event into the live host for every control the running
 * game declares, in code order and carrying the control's own code and type:
 * a button arrives released, an axis arrives idle. Draining the queue is not
 * enough to stop a held control: the game keeps what it was last told, so the
 * freeze has to say "released" explicitly.
 *
 * An axis is released to ML_AXIS_IDLE, never to zero. Zero is the centre of an
 * axis's travel, so writing it here would recentre the paddle the moment the
 * round is paused, and the player would resume somewhere they never put it.
 * Render task only. */
static void release_declared_controls(void)
{
    const ml_game_vt *vt = s_active_vt;

    if (s_session == NULL || vt == NULL || vt->controls == NULL) return;
    for (int i = 0; i < vt->control_count; i++) {
        const bool axis = vt->controls[i].type == ML_INPUT_AXIS;
        const ml_input_event e = {
            .player_id = 1,
            .seq = 0,
            .code = vt->controls[i].code,
            .value = axis ? ML_AXIS_IDLE : 0,
            .tick = 0,
            .type = vt->controls[i].type,
        };
        ml_host_local_input(s_session, &e);
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

/* Queue overflow must answer on the same status stream as render replies. */
static void request_cmd(cmd_kind_t kind, const char *id)
{
    cmd_item item = { .kind = kind };
    snprintf(item.id, sizeof(item.id), "%s", id ? id : "");
    if (xQueueSend(s_cmd_q, &item, 0) != pdTRUE) {
        ble_send_status_line("game error busy");
    }
}

void game_runner_request_start(const char *id)
{
    request_cmd(CMD_START, id);
}

void game_runner_request_stop(void)
{
    request_cmd(CMD_STOP, NULL);
}

void game_runner_request_pause(void)
{
    request_cmd(CMD_PAUSE, NULL);
}

void game_runner_request_resume(void)
{
    request_cmd(CMD_RESUME, NULL);
}

void game_runner_request_disconnect(void)
{
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    s_disconnect = true;
    s_accept_input = false;
    xSemaphoreGive(s_mutex);
}

bool game_runner_request_input_frame(const ml_input_event *events, uint8_t count)
{
    if (count > 16 || (count > 0 && events == NULL)) return false;
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    const ml_game_vt *vt = s_active_vt;
    bool ok = vt != NULL && s_accept_input;
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
        s_rx_us = now;
        s_last_input_us = (uint32_t)now;
        for (int i = 0; i < n; i++) {
            ml_input_event e = count == 0 ? (ml_input_event){
                .player_id = 1, .code = vt->controls[i].code,
                .type = vt->controls[i].type,
                /* an axis is released to idle, not to its centre */
                .value = vt->controls[i].type == ML_INPUT_AXIS ? ML_AXIS_IDLE : 0,
            } : events[i];
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

/* Open a session for item->id and answer "game ok <id> <label>:<type>...".
 * The controls go out in code order, space-separated, and the phone builds
 * its gamepad from them; <type> is 'b' (button) or 'a' (axis). Labels are
 * short (<= 16 chars each) and there are at most 16, so 256 bytes is plenty.
 * Render task only. */
static void session_start(const char *id)
{
    if (s_session != NULL) {
        ble_send_status_line("game error busy");
        return;
    }

    const ml_game_vt *vt = ml_fw_game_find(id);
    if (vt == NULL) {
        ble_send_status_line("game error unknown game");
        return;
    }

    ml_host_opts opts = {
        .game = vt,
        .panel_w = panel_width(),
        .panel_h = panel_height(),
        .seed = esp_random(),
        .snapshot_every = 1,
    };
    ml_host_session *h = ml_host_open(&opts);
    if (!h) {
        ble_send_status_line("game error out of memory");
        return;
    }
    ml_host_attach_controller(h, 1, "phone", ML_CAP_BUTTON);

    const uint64_t now = (uint64_t)esp_timer_get_time();

    s_session = h;
    s_paused = false;
    s_over_sent = false;
    s_last_us = now;
    snprintf(s_game_id, sizeof(s_game_id), "%s", id);

    /* Publish the session, then start its watchdog grace window: the phone's
     * first heartbeat can only arrive after it has seen this reply. */
    publish_session(vt);
    input_flush();

    char line[256];
    int n = snprintf(line, sizeof(line), "game ok %s", vt->id);
    for (int i = 0; i < vt->control_count; i++) {
        const char t =
            (vt->controls[i].type == ML_INPUT_AXIS) ? 'a' : 'b';
        const int need = snprintf(NULL, 0, " %s:%c",
                                  vt->controls[i].label, t);
        if (n + need >= (int)sizeof(line)) break;
        n += snprintf(line + n, sizeof(line) - (size_t)n, " %s:%c",
                      vt->controls[i].label, t);
    }
    ble_send_status_line(line);
}

/* Close the session and answer "game stopped". The published state goes first
 * so no input frame can be stamped against a session that is being freed.
 * Render task only. */
static void session_stop(void)
{
    if (s_session == NULL) {
        ble_send_status_line("game error no game");
        return;
    }

    publish_session(NULL);
    ml_host_destroy(s_session);
    s_session = NULL;
    s_paused = false;
    s_game_id[0] = '\0';
    s_over_sent = false;
    s_last_us = 0;
    s_last_input_us = 0;
    s_input_to_render_us = 0;
    input_flush();
    ble_send_status_line("game stopped");
}

/* Answer "game paused", freezing a playing round first. Idempotent: a round
 * that is already frozen - by an earlier pause, or by the watchdog, or by
 * having finished - answers the same line and changes nothing. Render task
 * only. */
static void session_pause(void)
{
    if (s_session == NULL) {
        ble_send_status_line("game error no game");
        return;
    }
    session_freeze((uint64_t)esp_timer_get_time());
    input_flush();
    ble_send_status_line("game paused");
}

/* Answer "game resumed", restarting the watchdog grace window. A finished
 * round has nothing to resume - the phone offers Play again, which is a new
 * start - so it is refused with the reason the app can act on. Render task
 * only. */
static void session_resume(void)
{
    if (s_session == NULL) {
        ble_send_status_line("game error no game");
        return;
    }
    if (ml_host_is_over(s_session)) {
        ble_send_status_line("game error game over");
        return;
    }
    if (s_paused) {
        const uint64_t now = (uint64_t)esp_timer_get_time();
        s_paused = false;
        s_last_us = now;      /* the paused wall time is not replayed */
        input_gate(true, now);
    }
    /* Whatever is queued predates this resume: either a press held while the
     * round was frozen or one meant for the round before it. The phone
     * re-sends its current held state on the next heartbeat. */
    input_flush();
    ble_send_status_line("game resumed");
}

bool game_runner_service(void)
{
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    const bool disconnected = s_disconnect;
    s_disconnect = false;
    if (disconnected) xQueueReset(s_cmd_q);
    xSemaphoreGive(s_mutex);
    if (disconnected) {
        if (s_session != NULL) session_stop();
        return false;
    }
    /* Commands first: a pause queued behind a start must see the new session
     * before any input drains into it. */
    cmd_item item;
    while (xQueueReceive(s_cmd_q, &item, 0) == pdTRUE) {
        switch (item.kind) {
        case CMD_START:  session_start(item.id); break;
        case CMD_STOP:   session_stop();         break;
        case CMD_PAUSE:  session_pause();        break;
        case CMD_RESUME: session_resume();       break;
        }
    }

    /* Input is drained on every call whatever the state, but only fed to a
     * round that is playing: idle, paused, and finished rounds drop it, so
     * the queue cannot hoard presses for a session that is gone and a stale
     * held control cannot spring into the next round. */
    const bool playing = s_session != NULL && !s_paused &&
                         !ml_host_is_over(s_session);

    ml_input_event e;
    while (xQueueReceive(s_input_q, &e, 0) == pdTRUE) {
        if (playing) ml_host_local_input(s_session, &e);
    }

    return s_active;
}

void game_runner_render(ml_canvas *out)
{
    if (!s_active || s_session == NULL) return;

    const uint64_t now = (uint64_t)esp_timer_get_time();
    if (s_last_us == 0) s_last_us = now;

    const bool finished = ml_host_is_over(s_session);

    /* The controller stopped talking: freeze and tell the phone once. The
     * grace window starts at start/resume, so a round is never frozen before
     * the phone has had its chance to send the first heartbeat. */
    const uint64_t last_rx = rx_stamp_get();
    if (!s_paused && !finished && now >= last_rx &&
        now - last_rx >= RX_SILENCE_PAUSE_US) {
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
