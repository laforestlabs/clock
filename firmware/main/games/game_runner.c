/*
 * game_runner.c - runs a gamekit session on the render task.
 *
 * One session at a time, owned by the render task. The BLE host task only
 * enqueues: CMD_START/CMD_STOP items on the command queue and ml_input_event
 * packets on the input queue. The render task drains both in service() and
 * steps/draws in render(), so a game start or a button press never runs on
 * the NimBLE host task's small stack and never blocks the link.
 *
 * Input contract (from the phone, per the wire protocol in ble.c): one
 * packet per frame carrying the full held state, one event per control in
 * code order. The runtime stamps the host tick; player_id is 1.
 *
 * When the game reaches its terminal state (its is_over callback turns
 * true), the runner pushes one "game over <id>" status line so the phone
 * can swap its gamepad for a start-over button.
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
    CMD_STOP
} cmd_kind_t;

typedef struct {
    cmd_kind_t kind;
    char       id[24];    /* game id for CMD_START; unused otherwise */
} cmd_item;

#define CMD_Q_DEPTH  4
#define INPUT_Q_DEPTH 64

static QueueHandle_t s_cmd_q;
static QueueHandle_t s_input_q;
static SemaphoreHandle_t s_mutex;   /* guards s_active for other tasks */

static ml_host_session *s_session;
static bool             s_active;
static uint64_t         s_last_us;
static char             s_game_id[24];   /* id of the running game */
static bool             s_over_sent;     /* "game over" already pushed */

/* Latency diagnostic: the arrival time of the most recent input packet
 * (written by the BLE host task) and the measured input-to-render delta
 * (written by the render task). 32-bit microsecond timestamps so each field
 * is a single aligned store; the wrap-around ~71 min is irrelevant for a
 * live latency readout. */
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

/* ---------------------------------------------------- BLE host task */

void game_runner_request_start(const char *id)
{
    cmd_item item;
    item.kind = CMD_START;
    snprintf(item.id, sizeof(item.id), "%s", id ? id : "");
    if (xQueueSend(s_cmd_q, &item, 0) != pdTRUE) {
        /* The phone's wait times out and it can retry; depth 4 is never hit
         * in practice because the app serializes commands. */
        ESP_LOGW(TAG, "game start dropped: command queue full");
    }
}

void game_runner_request_stop(void)
{
    cmd_item item;
    item.kind = CMD_STOP;
    item.id[0] = '\0';
    if (xQueueSend(s_cmd_q, &item, 0) != pdTRUE) {
        ESP_LOGW(TAG, "game stop dropped: command queue full");
    }
}

void game_runner_request_input(const ml_input_event *e)
{
    /* A saturated link drops input rather than blocking the NimBLE host
     * task; the phone keeps sending fresh held state every frame anyway. */
    s_last_input_us = (uint32_t)esp_timer_get_time();
    xQueueSend(s_input_q, e, 0);
}

/* ---------------------------------------------------- render task */

bool game_runner_active(void)
{
    xSemaphoreTake(s_mutex, portMAX_DELAY);
    const bool active = s_active;
    xSemaphoreGive(s_mutex);
    return active;
}

bool game_runner_service(void)
{
    /* Commands first, then input: a start arriving with held buttons in
     * flight must see a live session before the inputs drain. */
    cmd_item item;
    while (xQueueReceive(s_cmd_q, &item, 0) == pdTRUE) {
        if (item.kind == CMD_START) {
            if (s_session != NULL) {
                ble_send_status_line("game error busy");
                continue;
            }

            const ml_game_vt *vt = ml_fw_game_find(item.id);
            if (vt == NULL) {
                ble_send_status_line("game error unknown game");
                continue;
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
                continue;
            }
            /* Return ignored, like game_ffi.c: the bus join cannot fail for
             * a host that already owns the loopback. */
            ml_host_attach_controller(h, 1, "phone", ML_CAP_BUTTON);

            s_session = h;
            s_active = true;
            s_active_vt = vt;
            s_last_us = esp_timer_get_time();
            snprintf(s_game_id, sizeof(s_game_id), "%s", item.id);
            s_over_sent = false;

            /* "game ok <id> <label>:<type>..." with the controls in code
             * order, space-separated; the phone builds its gamepad from
             * these. <type> is 'b' (button) or 'a' (axis). Labels are short
             * (<= 16 chars each) and there are at most 16, so 256 bytes is
             * plenty. */
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
        } else { /* CMD_STOP */
            if (s_session == NULL) {
                ble_send_status_line("game error no game");
                continue;
            }
            ml_host_destroy(s_session);
            s_session = NULL;
            s_active = false;
            s_active_vt = NULL;
            s_game_id[0] = '\0';
            s_over_sent = false;
            ble_send_status_line("game stopped");
        }
    }

    ml_input_event e;
    while (s_active && xQueueReceive(s_input_q, &e, 0) == pdTRUE) {
        ml_host_local_input(s_session, &e);
    }

    return s_active;
}

void game_runner_render(ml_canvas *out)
{
    if (!s_active || s_session == NULL) return;

    const uint64_t now = esp_timer_get_time();
    if (s_last_us == 0) {
        s_last_us = now;
        return;
    }
    uint32_t dt_ms = (uint32_t)((now - s_last_us) / 1000);
    s_last_us = now;
    if (dt_ms < 1) dt_ms = 1;
    if (dt_ms > 100) dt_ms = 100;

    ml_host_step(s_session, dt_ms);
    if (s_last_input_us != 0) {
        s_input_to_render_us =
            (uint32_t)((uint32_t)esp_timer_get_time() - s_last_input_us);
    }
    /* Tell the phone the game reached its end, once per session. The poll is
     * a pure read of game state; the line rides the same status notification
     * as every other reply, so the app sees it without polling. */
    if (!s_over_sent && ml_host_is_over(s_session)) {
        s_over_sent = true;
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
    if (vt != NULL && vt->controls != NULL &&
        code < (uint16_t)vt->control_count) {
        type = (ml_input_type)vt->controls[code].type;
    }
    xSemaphoreGive(s_mutex);
    return type;
}

uint32_t game_runner_input_to_render_us(void)
{
    return s_input_to_render_us;
}
