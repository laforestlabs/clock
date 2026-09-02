/*
 * ble.c - NimBLE GATT server for config + layout push from the phone.
 *
 * The service carries the same two payloads as the LAN API, over a phone-
 * friendly channel: a small command characteristic, a data characteristic
 * that receives the payload in chunks, and a status characteristic that
 * notifies responses and returns the last one on read. The phone drives the
 * protocol: "begin <kind> <len>", a series of data writes, "commit" or
 * "abort". Chunking is explicit on the client, so every data write is a
 * single ATT write within the negotiated MTU; the server is MTU-agnostic and
 * just appends.
 *
 * Trust model: one connection, no pairing or security, same as the open
 * setup portal. It is a home device on a home network.
 *
 * Commits (the actual NVS/SPIFFS writes, tzset, provider refreshes) run on a
 * dedicated "ble_commit" task with its own 8KB stack, not on the BLE host
 * task: those paths together need more stack than the host task has, and
 * blocking the host task on a flash write would stall the link. cmd_commit
 * detaches the staging buffer and queues it; the commit task owns it from
 * there and sends the commit's status line itself.
 *
 * UUIDs are 128-bit, base 5f1b3c2a-9e74-4f6d-8a2b-1c3d5e7f9a01, with the
 * characteristic suffixes ...02 (cmd), ...03 (data), ...04 (status), ...05
 * (game_in, the gamepad input channel). NimBLE stores 128-bit UUIDs with
 * the canonical string reversed, so the value arrays below are that
 * reversed form.
 */
#include "ble.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "config.h"
#include "esp_app_desc.h"
#include "esp_bt.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "game_registry.h"
#include "games/game_runner.h"
#include "host/ble_gap.h"
#include "host/ble_gatt.h"
#include "host/ble_hs.h"
#include "host/ble_hs_adv.h"
#include "host/util/util.h"
#include "layout_store.h"
#include "mirror/game.h"
#include "mirror/json.h"
#include "mirror/mirror.h"
#include "net/provision.h"
#include "net/wifi.h"

#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "os/os_mbuf.h"
#include "panel.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include "sdkconfig.h"

static const char *TAG = "ble";

/* ------------------------------------------------------------- UUIDs */

/* Tail shared by all five UUIDs: base 5f1b3c2a-9e74-4f6d-8a2b-1c3d5e7f9a01
 * with the first byte (value[0], the last canonical octet) varying per
 * characteristic. */
#define UUID_TAIL \
    0x9a, 0x7f, 0x5e, 0x3d, 0x1c, 0x2b, 0x8a, 0x6d, \
    0x4f, 0x74, 0x9e, 0x2a, 0x3c, 0x1b, 0x5f

static const ble_uuid128_t s_svc_uuid    = BLE_UUID128_INIT(0x01, UUID_TAIL);
static const ble_uuid128_t s_chr_cmd     = BLE_UUID128_INIT(0x02, UUID_TAIL);
static const ble_uuid128_t s_chr_data    = BLE_UUID128_INIT(0x03, UUID_TAIL);
static const ble_uuid128_t s_chr_status  = BLE_UUID128_INIT(0x04, UUID_TAIL);
static const ble_uuid128_t s_chr_game_in = BLE_UUID128_INIT(0x05, UUID_TAIL);

/* ------------------------------------------------------------ limits */

/* Protocol bounds, mirrored in the Dart protocol writer. */
#define MAX_CMD_LEN      63
#define MAX_PAYLOAD      32768
#define MAX_STATUS_LEN   256
#define MAX_DEV_NAME     32

/* ------------------------------------------------------------- state */

typedef enum {
    TRANSFER_NONE,
    TRANSFER_LAYOUT,
    TRANSFER_CONFIG,
    TRANSFER_WIFI
} transfer_kind_t;

typedef struct {
    transfer_kind_t kind;
    char           *buf;        /* NULL when idle */
    size_t          declared;   /* len from "begin" */
    size_t          received;
} transfer_t;

static transfer_t      s_xfer;
static SemaphoreHandle_t s_lock;
static SemaphoreHandle_t s_status_lock;
static char            s_dev_name[MAX_DEV_NAME];
static char            s_last_status[MAX_STATUS_LEN];
static size_t          s_last_status_len;
static uint16_t        s_status_handle;
static uint16_t        s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
static uint8_t         s_adv_addr_type;
/* Set by the "wifi scan" command and cleared when the results are streamed,
 * so scan-done notifications from the portal's own scans do not emit an
 * unsolicited network list. Guarded by s_lock. */
static bool s_wifi_scan_awaiting = false;


/*
 * Commit processing (NVS/SPIFFS writes, tzset, provider refresh) runs on a
 * dedicated task, not on the BLE host task: those paths together need more
 * stack than the host task has, and holding the host task on a flash write
 * delays the link. cmd_commit detaches the staging buffer and hands it over
 * through this queue; the commit task owns it from there and sends the
 * commit's status line itself. The phone pushes one transfer at a time, so
 * the queue only ever has a single job in practice; the depth is defensive
 * and a full queue is rejected rather than blocking the host task.
 */
#define COMMIT_Q_DEPTH      2
#define COMMIT_STACK_BYTES  8192

typedef struct {
    transfer_kind_t kind;
    char           *buf;
    size_t          len;
} commit_job_t;

static QueueHandle_t s_commit_q;

static int gap_event_cb(struct ble_gap_event *event, void *arg);

static void lock(void)   { xSemaphoreTake(s_lock, portMAX_DELAY); }
static void unlock(void) { xSemaphoreGive(s_lock); }

static void advertise(void);

/* ---------------------------------------------------------- transfer */

static void transfer_clear_locked(void)
{
    if (s_xfer.buf != NULL) {
        heap_caps_free(s_xfer.buf);
        s_xfer.buf = NULL;
    }
    s_xfer.kind = TRANSFER_NONE;
    s_xfer.declared = 0;
    s_xfer.received = 0;
}

/* Frees any staging buffer. Called on abort, commit, and disconnect. */
static void transfer_reset(void)
{
    lock();
    transfer_clear_locked();
    unlock();
}

static void *alloc_payload_buffer(void)
{
    void *p = heap_caps_malloc(MAX_PAYLOAD, MALLOC_CAP_SPIRAM);
    if (p == NULL) p = heap_caps_malloc(MAX_PAYLOAD, MALLOC_CAP_INTERNAL);
    return p;
}

/* ------------------------------------------------------------ status */

static void send_status(const char *fmt, ...)
{
    /*
     * Serialized: the host task and the commit task both write the shared
     * status buffer and notify from it. The lock is never held by a caller
     * (no send_status call runs under s_lock), so taking it here cannot
     * deadlock.
     */
    xSemaphoreTake(s_status_lock, portMAX_DELAY);
    va_list ap;
    va_start(ap, fmt);
    const int len = vsnprintf(s_last_status, sizeof(s_last_status), fmt, ap);
    va_end(ap);
    if (len < 0) {
        xSemaphoreGive(s_status_lock);
        return;
    }
    s_last_status_len = (size_t)len;
    if (s_last_status_len >= sizeof(s_last_status)) {
        s_last_status_len = sizeof(s_last_status) - 1;
    }

    if (s_conn_handle != BLE_HS_CONN_HANDLE_NONE) {
        struct os_mbuf *om = ble_hs_mbuf_from_flat(s_last_status,
                                                   s_last_status_len);
        if (om != NULL) {
            /* Consumed by the stack regardless of the outcome. Notifications
             * only reach the client once it has subscribed (CCCD); until
             * then the READ path returns the same buffer. */
            ble_gatts_notify_custom(s_conn_handle, s_status_handle, om);
        }
    }
    xSemaphoreGive(s_status_lock);
}

/* Public one-line wrapper for send_status: the game runner replies through
 * this from the render task. The %s keeps the line verbatim (a label could
 * contain a %). */
void ble_send_status_line(const char *line)
{
    send_status("%s", line);
}

static void json_escape(char *out, size_t outsz, const char *in)
{
    size_t o = 0;
    for (const unsigned char *s = (const unsigned char *)in;
         *s != '\0' && o + 6 < outsz; s++) {
        switch (*s) {
        case '"':  out[o++] = '\\'; out[o++] = '"'; break;
        case '\\': out[o++] = '\\'; out[o++] = '\\'; break;
        case '\n': out[o++] = '\\'; out[o++] = 'n'; break;
        case '\r': out[o++] = '\\'; out[o++] = 'r'; break;
        case '\t': out[o++] = '\\'; out[o++] = 't'; break;
        default:
            out[o++] = (*s < 0x20) ? '?' : (char)*s;
            break;
        }
    }
    out[o] = '\0';
}

/* -------------------------------------------------------------- cmd */

static void cmd_ping(void)
{
    /* Static: ml_layout is ~6.6KB, too big for a stack buffer on either the
     * host task or this one, and only the host task touches it. */
    static ml_layout layout;
    layout_store_snapshot(&layout);

    /* The version token is the app image version (esp_app_get_description),
     * not the render core version: it is what the phone shows next to the
     * firmware update, and an OTA must be verifiable. The app uses the pong's
     * IP for the WiFi OTA upload, and its width/height as the panel geometry,
     * so those must be the hardware size, not the stored layout's. */
    send_status("pong %s %s %s %d %d",
                esp_app_get_description()->version, wifi_ip(),
                layout.name, panel_width(), panel_height());
}

static void cmd_get_config(void)
{
    char esc_tz[128], esc_place[64];
    json_escape(esc_tz, sizeof(esc_tz), mirror_config_timezone());
    json_escape(esc_place, sizeof(esc_place), mirror_config_place());

    send_status("config {\"timezone\":\"%s\",\"latitude\":\"%s\","
                "\"longitude\":\"%s\",\"place\":\"%s\",\"brightness\":%d,"
                "\"clock12h\":%s,\"temp_unit\":\"%c\"}",
                esc_tz, mirror_config_latitude(),
                mirror_config_longitude(), esc_place,
                mirror_config_brightness(),
                mirror_config_clock_12h() ? "true" : "false",
                mirror_config_temp_unit());
}

static void cmd_begin(const char *arg)
{
    char kind[16];
    int len = 0;
    if (sscanf(arg, "%15s %d", kind, &len) != 2) {
        send_status("begin error bad kind");
        return;
    }

    transfer_kind_t k;
    if (strcmp(kind, "layout") == 0) {
        k = TRANSFER_LAYOUT;
    } else if (strcmp(kind, "wifi") == 0) {
        k = TRANSFER_WIFI;
    } else if (strcmp(kind, "config") == 0) {
        k = TRANSFER_CONFIG;
    } else {
        send_status("begin error bad kind");
        return;
    }
    if (len < 1 || len > MAX_PAYLOAD) {
        send_status("begin error too large");
        return;
    }

    lock();
    if (s_xfer.buf != NULL) {
        unlock();
        send_status("begin error busy");
        return;
    }
    s_xfer.buf = alloc_payload_buffer();
    if (s_xfer.buf == NULL) {
        unlock();
        send_status("begin error out of memory");
        return;
    }
    s_xfer.kind = k;
    s_xfer.declared = (size_t)len;
    s_xfer.received = 0;
    unlock();

    ESP_LOGI(TAG, "begin %s, %d bytes", kind, len);
    send_status("begin ok");
}

static void cmd_commit(void)
{
    lock();
    if (s_xfer.buf == NULL) {
        unlock();
        send_status("commit error no transfer");
        return;
    }
    if (s_xfer.received != s_xfer.declared) {
        ESP_LOGW(TAG, "commit with %u of %u bytes",
                 (unsigned)s_xfer.received, (unsigned)s_xfer.declared);
        transfer_clear_locked();
        unlock();
        send_status("commit error length mismatch");
        return;
    }

    /* Detach the staging buffer: the caller owns it from here on, so the
     * transfer slot is free for the next push while the commit work runs on
     * the copied-out payload. */
    const transfer_kind_t kind = s_xfer.kind;
    char *buf = s_xfer.buf;
    const size_t len = s_xfer.received;
    s_xfer.buf = NULL;
    s_xfer.kind = TRANSFER_NONE;
    s_xfer.declared = 0;
    s_xfer.received = 0;
    unlock();

    /* Hand the payload to the commit task: the transfer state is free and
     * the store/config modules are themselves locked, so a concurrent push
     * can start cleanly while the commit work runs off the host task. */
    if (s_commit_q == NULL) {
        /* ble_commit_init() failing at boot is the only way to get here. */
        ESP_LOGE(TAG, "commit queue missing, rejecting");
        send_status("commit error busy");
        heap_caps_free((void *)buf);
        return;
    }
    const commit_job_t job = { .kind = kind, .buf = buf, .len = len };
    if (xQueueSend(s_commit_q, &job, 0) != pdTRUE) {
        /* The phone pushes one transfer at a time, so a full queue means a
         * commit is already in flight. Reject rather than block the host
         * task on a queue send. */
        ESP_LOGW(TAG, "commit queue full, rejecting");
        send_status("commit error busy");
        heap_caps_free((void *)buf);
        return;
    }
    ESP_LOGI(TAG, "commit queued, %u bytes", (unsigned)len);
}

/*
 * The commit worker. NVS/SPIFFS writes, tzset, provider refreshes and the
 * layout re-parse together need more stack than the BLE host task has, and
 * blocking the host task on a flash write would stall the link, so commits
 * arrive detached here through s_commit_q and the task owns them. Status
 * lines go back over the same notification as always, so the phone sees no
 * difference from a synchronous commit. A disconnect while a commit is
 * queued does not cancel it: the payload is already detached, and send_status
 * simply no-ops once there is no connection.
 */
static void commit_task(void *arg)
{
    (void)arg;
    for (;;) {
        commit_job_t job;
        if (xQueueReceive(s_commit_q, &job, portMAX_DELAY) != pdTRUE) {
            continue;
        }

        if (job.kind == TRANSFER_LAYOUT) {
            ml_diag diag;
            ml_diag_reset(&diag);
            if (layout_store_apply(job.buf, job.len, &diag) == ESP_ERR_INVALID_ARG) {
                const char *msg = diag.count > 0 ? diag.msg[0] : "layout rejected";
                ESP_LOGW(TAG, "layout commit rejected: %s", msg);
                send_status("commit error %s", msg);
                heap_caps_free((void *)job.buf);
                continue;
            }
            /* Re-parse just for the widget count the status line reports.
             * ml_layout is ~6.6KB, so this lives on the heap. */
            ml_layout *parsed = heap_caps_malloc(sizeof(ml_layout),
                                                 MALLOC_CAP_SPIRAM);
            int count = 0;
            if (parsed != NULL) {
                ml_diag count_diag;
                ml_diag_reset(&count_diag);
                if (ml_layout_parse(job.buf, job.len, parsed, &count_diag)) {
                    count = parsed->count;
                }
                heap_caps_free(parsed);
            }
            send_status("commit ok %d widgets", count);
        } else if (job.kind == TRANSFER_WIFI) {
            char err[96];
            if (provision_apply_json(job.buf, job.len, err, sizeof(err)) != ESP_OK) {
                ESP_LOGW(TAG, "wifi commit rejected: %s", err);
                send_status("commit error %s", err);
                heap_caps_free((void *)job.buf);
                continue;
            }
            send_status("commit ok");
        } else {   /* TRANSFER_CONFIG */
            char err[96];
            if (mirror_config_apply_json(job.buf, job.len, err, sizeof(err)) != ESP_OK) {
                ESP_LOGW(TAG, "config commit rejected: %s", err);
                send_status("commit error %s", err);
                heap_caps_free((void *)job.buf);
                continue;
            }
            send_status("commit ok");
        }

        ESP_LOGI(TAG, "committed %u bytes", (unsigned)job.len);
        heap_caps_free((void *)job.buf);
    }
}

static void cmd_abort(void)
{
    transfer_reset();
    send_status("abort ok");
}

static void cmd_get_brightness(void)
{
    send_status("brightness %u %s", panel_get_brightness(),
                mirror_config_brightness() >= 0 ? "manual" : "auto");
}

static void cmd_get_latency(void)
{
    struct ble_gap_conn_desc desc;
    uint32_t conn_itvl_ms = 0;
    if (s_conn_handle != BLE_HS_CONN_HANDLE_NONE &&
        ble_gap_conn_find(s_conn_handle, &desc) == 0) {
        /* conn_itvl is in 1.25 ms units. */
        conn_itvl_ms = (uint32_t)desc.conn_itvl * 5u / 4u;
    }
    /* input_to_render is the render task's measured input-to-pixel delta;
     * conn_itvl_ms is the negotiated radio interval. Both are diagnostics
     * for the phone's latency readout. */
    send_status("latency %lu %lu",
                (unsigned long)game_runner_input_to_render_us(),
                (unsigned long)conn_itvl_ms);
}

static void cmd_set_brightness(const char *arg)
{
    if (strcmp(arg, "auto") == 0) {
        mirror_config_clear_brightness();
        /* Re-apply the layout's brightness, which the override had hidden. */
        static ml_layout layout;
        layout_store_snapshot(&layout);
        panel_set_brightness(layout.brightness);
        send_status("brightness ok auto");
        return;
    }

    int n;
    if (sscanf(arg, "%d", &n) != 1) {
        send_status("brightness error not a number");
        return;
    }
    if (n < 0 || n > 255) {
        send_status("brightness error out of range");
        return;
    }

    /* Persist as an override through the config module, which validates and
     * applies the panel change atomically. */
    char err[96];
    char json[32];
    snprintf(json, sizeof(json), "{\"brightness\":%d}", n);
    if (mirror_config_apply_json(json, strlen(json), err, sizeof(err)) != ESP_OK) {
        send_status("brightness error %s", err);
        return;
    }
    send_status("brightness ok %u", panel_get_brightness());
}

static void cmd_reboot(void)
{
    send_status("reboot ok");
    /* The notification is queued by the stack; a short delay on the host
     * task lets it go out before the chip restarts, so the phone sees the
     * status line instead of a hung request. */
    vTaskDelay(pdMS_TO_TICKS(300));
    esp_restart();
}

static void cmd_get_wifi(void)
{
    char esc_ssid[96];
    json_escape(esc_ssid, sizeof(esc_ssid), provision_saved_ssid());
    send_status("wifi {\"saved\":%s,\"ssid\":\"%s\",\"ip\":\"%s\","
                "\"connected\":%s}",
                provision_has_creds() ? "true" : "false",
                esc_ssid, wifi_ip(),
                wifi_is_connected() ? "true" : "false");
}

static void cmd_wifi_scan(void)
{
    lock();
    s_wifi_scan_awaiting = true;
    unlock();

    if (provision_scan_start() != ESP_OK) {
        lock();
        s_wifi_scan_awaiting = false;
        unlock();
        send_status("wifi-scan error could not start");
        return;
    }
    send_status("wifi-scan start");
}

static void cmd_wifi_forget(void)
{
    if (provision_forget() != ESP_OK) {
        send_status("wifi forget error");
        return;
    }
    send_status("wifi forget ok");
}

/* provision.c invokes these on the event-loop task. send_status locks
 * internally, so both are safe to call off the BLE host task. */

static void ble_wifi_scan_done_cb(void)
{
    lock();
    const bool awaiting = s_wifi_scan_awaiting;
    s_wifi_scan_awaiting = false;
    unlock();
    if (!awaiting) return;

    /* PSRAM, not internal RAM: the DMA-capable internal pool is what the BT
     * controller and panel DMA both need, and this buffer is only used
     * transiently by the event-loop task. */
    provision_scan_result_t *results = heap_caps_malloc(
        24 * sizeof(provision_scan_result_t), MALLOC_CAP_SPIRAM);
    if (results == NULL) {
        send_status("wifi-scan done 0");
        return;
    }
    const int n = provision_scan_results(results, 24);
    for (int i = 0; i < n; i++) {
        char esc[96];
        json_escape(esc, sizeof(esc), results[i].ssid);
        send_status("wifi-net {\"ssid\":\"%s\",\"rssi\":%d,\"open\":%s}",
                    esc, results[i].rssi, results[i].open ? "true" : "false");
    }
    send_status("wifi-scan done %d", n);
    heap_caps_free(results);
}

static void ble_wifi_result_cb(bool connected, const char *arg)
{
    send_status(connected ? "wifi connect ok %s" : "wifi connect error %s",
                arg);
}

/* Parse and run one command line. Commands are the ASCII protocol described
 * at the top of the file. */
static void handle_cmd(char *line)
{
    if (strcmp(line, "ping") == 0) {
        cmd_ping();
    } else if (strcmp(line, "get config") == 0) {
        cmd_get_config();
    } else if (strcmp(line, "get brightness") == 0) {
        cmd_get_brightness();
    } else if (strcmp(line, "get wifi") == 0) {
        cmd_get_wifi();
    } else if (strcmp(line, "wifi scan") == 0) {
        cmd_wifi_scan();
    } else if (strcmp(line, "wifi forget") == 0) {
        cmd_wifi_forget();
    } else if (strcmp(line, "get latency") == 0) {
        cmd_get_latency();
    } else if (strncmp(line, "set brightness ", 15) == 0) {
        cmd_set_brightness(line + 15);
    } else if (strcmp(line, "reboot") == 0) {
        cmd_reboot();
    } else if (strncmp(line, "begin ", 6) == 0) {
        cmd_begin(line + 6);
    } else if (strcmp(line, "commit") == 0) {
        cmd_commit();
    } else if (strcmp(line, "abort") == 0) {
        cmd_abort();
    } else if (strcmp(line, "game list") == 0) {
        /* Answered synchronously: the registry is static and the render task
         * is not involved. Format "games <id>[,<id>...]", empty list
         * "games". Ids are short (<= 16 chars) and there are five, so the
         * status buffer is plenty. */
        char buf[MAX_STATUS_LEN];
        int n = snprintf(buf, sizeof(buf), "games");
        for (int i = 0; i < ml_fw_game_count(); i++) {
            const ml_game_vt *g = ml_fw_game_at(i);
            if (g == NULL) break;
            const int need = snprintf(NULL, 0, "%s%s", i == 0 ? " " : ",",
                                      g->id);
            if (n + need >= (int)sizeof(buf)) break;
            n += snprintf(buf + n, sizeof(buf) - (size_t)n, "%s%s",
                          i == 0 ? " " : ",", g->id);
        }
        send_status("%s", buf);
    } else if (strncmp(line, "game start ", 11) == 0) {
        /* Queued, not run here: opening a session allocates and must not run
         * on the NimBLE host task. The render task answers "game ok ..." or
         * "game error ...". */
        game_runner_request_start(line + 11);
    } else if (strcmp(line, "game stop") == 0) {
        /* Queued like start; the render task answers "game stopped" or
         * "game error no game". */
        game_runner_request_stop();
    } else {
        send_status("unknown command");
    }
}

/* --------------------------------------------------------- GATT svc */

static int cmd_write_cb(uint16_t conn_handle, uint16_t attr_handle,
                        struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle; (void)attr_handle; (void)arg;

    const uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
    if (len == 0) return 0;

    char line[MAX_CMD_LEN + 1];
    if (len > MAX_CMD_LEN) {
        send_status("cmd too long");
        return 0;
    }
    os_mbuf_copydata(ctxt->om, 0, len, line);
    line[len] = '\0';

    handle_cmd(line);
    return 0;
}

static int data_write_cb(uint16_t conn_handle, uint16_t attr_handle,
                         struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle; (void)attr_handle; (void)arg;

    const uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
    if (len == 0) return 0;

    lock();
    if (s_xfer.buf == NULL) {
        /* No transfer open: the chunk is dropped, per the protocol. */
        unlock();
        return 0;
    }

    /* Never write past the declared length. A client that overshoots is
     * violating the protocol; commit's length check reports it. */
    const size_t room = s_xfer.declared - s_xfer.received;
    const size_t take = len < room ? len : room;
    os_mbuf_copydata(ctxt->om, 0, take, s_xfer.buf + s_xfer.received);
    s_xfer.received += take;
    unlock();
    return 0;
}

static int status_read_cb(uint16_t conn_handle, uint16_t attr_handle,
                          struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle; (void)attr_handle; (void)arg;

    if (ctxt->op != BLE_GATT_ACCESS_OP_READ_CHR) return 0;
    if (s_last_status_len == 0) return 0;

    return os_mbuf_append(ctxt->om, s_last_status, s_last_status_len);
}

/*
 * game_in: one write carrying the phone's full input state, little-endian.
 * byte 0 is the control count (1..16, 0 = all released), then per control
 * u8 code + i16 value. A button's value is 0/1; an axis's is -32768..32767.
 * The type is resolved from the running game (game_runner_control_type)
 * rather than trusted from a byte on the wire. Max packet 49 bytes. Any
 * other shape is a protocol violation and is dropped, matching the Dart
 * writer in mirror_ble_game.dart.
 */
static int game_in_write_cb(uint16_t conn_handle, uint16_t attr_handle,
                            struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle; (void)attr_handle; (void)arg;

    const uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
    if (len < 1) return 0;

    /* Copy first so count can be validated regardless of how the packet is
     * segmented in the mbuf chain. len is bounded by the count<=16 check
     * below and the buffer is 49 bytes. */
    uint8_t p[1 + 3 * 16];
    os_mbuf_copydata(ctxt->om, 0, len, p);

    const uint8_t count = p[0];
    if (count > 16 || len != 1 + 3 * (uint16_t)count) {
        ESP_LOGW(TAG, "game input: protocol violation (%u controls, %u bytes)",
                 (unsigned)count, (unsigned)len);
        return 0;
    }

    for (uint8_t i = 0; i < count; i++) {
        const uint16_t code = p[1 + 3 * i];
        const int16_t raw =
            (int16_t)(p[2 + 3 * i] | ((int16_t)p[3 + 3 * i] << 8));
        const ml_input_type type = game_runner_control_type(code);
        const int16_t value = (type == ML_INPUT_AXIS) ? raw : (raw ? 1 : 0);
        /* seq/tick left 0: the runtime stamps the host tick and games never
         * read seq. */
        ml_input_event e = {
            .player_id = 1,
            .seq = 0,
            .code = code,
            .value = value,
            .tick = 0,
            .type = type,
        };
        game_runner_request_input(&e);
    }
    return 0;
}

static const struct ble_gatt_svc_def s_gatt_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &s_svc_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]){
            {
                .uuid = &s_chr_cmd.u,
                .access_cb = cmd_write_cb,
                .flags = BLE_GATT_CHR_F_WRITE,
            },
            {
                .uuid = &s_chr_data.u,
                .access_cb = data_write_cb,
                .flags = BLE_GATT_CHR_F_WRITE,
            },
            {
                .uuid = &s_chr_game_in.u,
                .access_cb = game_in_write_cb,
                .flags = BLE_GATT_CHR_F_WRITE_NO_RSP,
            },
            {
                .uuid = &s_chr_status.u,
                .access_cb = status_read_cb,
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY,
                .val_handle = &s_status_handle,
            },
            { 0 },
        },
    },
    { 0 },
};

static void on_gatts_register(struct ble_gatt_register_ctxt *ctxt, void *arg)
{
    (void)arg;
    if (ctxt->op == BLE_GATT_REGISTER_OP_CHR &&
        ble_uuid_cmp(ctxt->chr.chr_def->uuid, &s_chr_status.u) == 0) {
        s_status_handle = ctxt->chr.val_handle;
    }
}

/* -------------------------------------------------------------- gap */

static void advertise(void)
{
    int rc;

    struct ble_hs_adv_fields fields = {0};
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;

    /* The full name (17 chars) plus the 128-bit service UUID (18 bytes)
     * overflows the 31-byte advertising payload, so the name rides in the
     * advertising packet and the UUID in the scan response. Phones combine
     * both during discovery, which is all the app's scan filter needs. */
    fields.name = (const uint8_t *)s_dev_name;
    fields.name_len = (uint8_t)strlen(s_dev_name);
    fields.name_is_complete = 1;

    rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) {
        ESP_LOGE(TAG, "adv fields failed: %d", rc);
        return;
    }

    struct ble_hs_adv_fields rsp = {0};
    rsp.uuids128 = &s_svc_uuid;
    rsp.num_uuids128 = 1;
    rsp.uuids128_is_complete = 1;

    rc = ble_gap_adv_rsp_set_fields(&rsp);
    if (rc != 0) {
        ESP_LOGE(TAG, "scan response fields failed: %d", rc);
        return;
    }

    struct ble_gap_adv_params adv_params = {
        .conn_mode = BLE_GAP_CONN_MODE_UND,
        .disc_mode = BLE_GAP_DISC_MODE_GEN,
    };

    rc = ble_gap_adv_start(s_adv_addr_type, NULL, BLE_HS_FOREVER,
                           &adv_params, gap_event_cb, NULL);
    if (rc != 0 && rc != BLE_HS_EALREADY) {
        ESP_LOGE(TAG, "advertising failed: %d", rc);
    }
}

/*
 * Ask the phone's central for a fast connection interval. The central owns
 * the final decision, but Android honours a peripheral's parameter update,
 * and the app also requests ConnectionPriority.high, so both ends agree on a
 * short interval. Without this a game input packet waits up to one whole
 * interval (30-50 ms at Android's balanced default) before the radio sends
 * it. The mirror is mains-powered and the phone only connects when actively
 * controlling, so the higher radio duty is a fair trade.
 */
static void request_fast_conn_params(uint16_t conn_handle)
{
    struct ble_gap_upd_params params = {
        .itvl_min = 6,               /* 7.5 ms */
        .itvl_max = 12,              /* 15 ms */
        .latency = 0,
        .supervision_timeout = 200,  /* 2 s, in 10 ms units */
        .min_ce_len = 0,
        .max_ce_len = 0,
    };
    const int rc = ble_gap_update_params(conn_handle, &params);
    if (rc != 0) {
        ESP_LOGW(TAG, "connection param update request failed: %d", rc);
    }
}


static int gap_event_cb(struct ble_gap_event *event, void *arg)
{
    (void)arg;

    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0) {
            s_conn_handle = event->connect.conn_handle;
            ESP_LOGI(TAG, "connected (handle %u)", s_conn_handle);
            request_fast_conn_params(s_conn_handle);
        } else {
            /* Connect attempt failed; keep advertising. */
            advertise();
        }
        return 0;

    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(TAG, "disconnected");
        s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
        transfer_reset();
        /* A game only ever runs for the one connected phone; drop it. The
         * queued stop is answered by the render task, whose status line
         * no-ops here because s_conn_handle is already NONE. */
        game_runner_request_stop();
        advertise();
        return 0;

    case BLE_GAP_EVENT_ADV_COMPLETE:
        /* Undirected advertising does not normally complete, but if it does
         * the device should be discoverable again. */
        advertise();
        return 0;

    default:
        return 0;
    }
}

static void on_sync(void)
{
    int rc = ble_hs_util_ensure_addr(0);
    if (rc != 0) {
        ESP_LOGE(TAG, "could not ensure an identity address: %d", rc);
        return;
    }
    rc = ble_hs_id_infer_auto(0, &s_adv_addr_type);
    if (rc != 0) {
        ESP_LOGE(TAG, "could not infer the address type: %d", rc);
        return;
    }
    advertise();
}

static void on_reset(int reason)
{
    ESP_LOGW(TAG, "NimBLE reset, reason %d", reason);
}

static void host_task(void *param)
{
    (void)param;
    /* Runs until nimble_port_stop(), which nothing in this build calls. */
    nimble_port_run();
    nimble_port_freertos_deinit();
}

/* entry */

esp_err_t ble_commit_init(void)
{
    s_commit_q = xQueueCreate(COMMIT_Q_DEPTH, sizeof(commit_job_t));
    if (s_commit_q == NULL) {
        ESP_LOGE(TAG, "commit queue allocation failed");
        return ESP_ERR_NO_MEM;
    }

    /* The worker needs COMMIT_STACK_BYTES of contiguous internal RAM (its
     * stack, in bytes per ESP-IDF's xTaskCreate, must stay internal: the task
     * runs NVS/SPIFFS writes, performed with the flash cache disabled, and a
     * PSRAM-backed stack would be unreachable mid-write). That is only
     * available here, before the panel claims its DMA buffers. */
    xTaskCreate(commit_task, "ble_commit", COMMIT_STACK_BYTES, NULL, 5, NULL);

    return ESP_OK;
}

esp_err_t ble_init(void)
{
    s_lock = xSemaphoreCreateMutex();
    if (s_lock == NULL) return ESP_ERR_NO_MEM;

    s_status_lock = xSemaphoreCreateMutex();
    /* Forward the provisioning module's scan-completion and connect-outcome
     * notifications to the phone over the status characteristic. */
    provision_set_scan_done_cb(ble_wifi_scan_done_cb);
    provision_set_wifi_result_cb(ble_wifi_result_cb);

    /* Same naming convention as the setup access point (build_ap_ssid):
     * last four hex digits of the STA MAC, so several mirrors in one house
     * do not collide. */
    uint8_t mac[6];
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    snprintf(s_dev_name, sizeof(s_dev_name), "Smart Mirror-%02X%02X",
             mac[4], mac[5]);

    /* BLE-only on the S3: release the memory the BR/EDR stack would claim. */
    esp_bt_controller_mem_release(ESP_BT_MODE_CLASSIC_BT);

    esp_err_t ret = nimble_port_init();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "nimble_port_init failed: %s", esp_err_to_name(ret));
        return ret;
    }

    ble_hs_cfg.reset_cb = on_reset;
    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.gatts_register_cb = on_gatts_register;

    ble_svc_gap_init();
    ble_svc_gatt_init();

    int rc = ble_gatts_count_cfg(s_gatt_svcs);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_gatts_count_cfg failed: %d", rc);
        return ESP_FAIL;
    }
    rc = ble_gatts_add_svcs(s_gatt_svcs);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_gatts_add_svcs failed: %d", rc);
        return ESP_FAIL;
    }

    rc = ble_svc_gap_device_name_set(s_dev_name);
    if (rc != 0) {
        ESP_LOGW(TAG, "device name set failed: %d", rc);
    }

    /* The host task is created by the ESP-IDF port at
     * configMAX_PRIORITIES - 4 with CONFIG_BT_NIMBLE_HOST_TASK_STACK_SIZE
     * bytes. */
    nimble_port_freertos_init(host_task);

    ESP_LOGI(TAG, "advertising as \"%s\"", s_dev_name);
    return ESP_OK;
}
