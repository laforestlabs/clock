/*
 * api_server.c - the mirror's LAN API (station interface, port 80).
 *
 * Endpoints: GET /api/status, GET|PUT /api/layout, POST /api/ota, plus the
 * display contract: GET /api/frame, PUT /api/mode, POST /api/image. The
 * layout transport is the core's own JSON, so the designer can push the exact
 * bytes its preview renders and read back the same layout; the display
 * endpoints let the app upload one panel-sized picture and read back what the
 * panel is actually showing.
 *
 * Lifecycle: the server starts on IP_EVENT_STA_GOT_IP and stops on
 * WIFI_EVENT_STA_DISCONNECTED. That keeps port 80 from colliding with the
 * provisioning portal's own httpd, which only runs while the station is
 * down. There is a brief overlap after a first-time join (the portal lingers
 * for a few seconds so the phone sees its confirmation page); a short retry
 * timer covers it.
 *
 * Security: plain HTTP, no authentication, same trust model as the open
 * setup portal and a home WPA2 network.
 */
#include "api_server.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "config.h"
#include "display_store.h"
#include "esp_app_desc.h"
#include "esp_event.h"
#include "esp_heap_caps.h"
#include "esp_http_server.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "frame_snapshot.h"
#include "games/game_runner.h"
#include "layout_store.h"
#include "mdns.h"
#include "mirror/mirror.h"
#include "net/ota.h"
#include "netlog.h"
#include "net/wifi.h"
#include "panel.h"
#include "sdkconfig.h"

static const char *TAG = "api";

/* Upper bound on a layout JSON document, on both the way in and the way out.
 * The designer's largest stock layout is a couple of KB; this is generous. */
#define LAYOUT_JSON_CAP 32768

/* How long to wait before retrying httpd_start after a port conflict with
 * the provisioning portal. */
#define RETRY_DELAY_US (2 * 1000000)

static httpd_handle_t s_httpd = NULL;
static esp_timer_handle_t s_retry;

static void api_server_start(void);

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

/* Upper bound on the /api/status document. The identity and display fields
 * pushed it past the 384-byte buffer it used to fit in, so the buffer is
 * sized for the worst case and the format's result is checked: a document
 * that does not fit is refused rather than sent cut in half. */
#define STATUS_JSON_CAP 1024

/*
 * Worst case, for the sizing above: json_escape can turn one byte into six,
 * and the escaped fields are the app version (char[32]), the layout name
 * (ML_NAME_LEN), the device name (24 characters plus the terminator) and the
 * IP (16 bytes). Every number is bounded too — 20 digits of uptime is the
 * widest — and the remaining key names and punctuation come to under 300
 * bytes, so the whole document cannot reach this cap.
 */
_Static_assert(STATUS_JSON_CAP >= 6 * (32 + ML_NAME_LEN + 25 + 16) + 300,
               "status JSON buffer must hold the worst-case document");

static esp_err_t handle_get_status(httpd_req_t *req)
{
    /* Static: ml_layout is ~6.6KB and httpd runs handlers on one task. */
    static ml_layout layout;
    layout_store_snapshot(&layout);

    char esc_layout[2 * ML_NAME_LEN];
    json_escape(esc_layout, sizeof(esc_layout), layout.name);
    char esc_device[2 * 25];
    json_escape(esc_device, sizeof(esc_device), mirror_config_device_name());
    char esc_version[64];
    json_escape(esc_version, sizeof(esc_version),
                esp_app_get_description()->version);

    /*
     * Effective display versus saved base display. Games are a transient
     * override owned by the render task, so "games" is reported only while a
     * session is live and "base_mode" stays whatever sits underneath it.
     *
     * Both come from the display store, which owns the saved base mode and
     * the stored picture: a mode change or an upload that commits while a
     * game is running updates what "base_mode" reports, not the game the
     * panel is drawing. "picture_ready" is the store's own verdict that a
     * valid stored image matches the current panel dimensions.
     */
    const mirror_display_mode_t base_mode = display_store_base_mode();
    const char *mode = game_runner_active() ? "games" : display_mode_name(base_mode);
    const bool picture_ready = display_store_picture_ready();

    /* "version" is the app image version so an OTA is verifiable; "core" is
     * the render core version, useful when the designer and the firmware
     * drift. "brightness" is the live panel value, not the layout's static
     * one, so a manual override set over BLE shows up here too. "id" is the
     * hardware identity (mirror_config_device_id) and "name" the friendly
     * one, which a rename changes without touching "id". "display_api" is 1
     * only when this build can hold a picture at all, so an app must read its
     * absence as "old firmware" rather than as a broken device. */
    char body[STATUS_JSON_CAP];
    const int n = snprintf(body, sizeof(body),
              "{\"version\":\"%s\",\"core\":\"%s\",\"ip\":\"%s\",\"online\":%s,"
              "\"rssi\":%d,\"uptime_s\":%llu,\"layout\":\"%s\",\"width\":%d,"
              "\"height\":%d,\"brightness\":%u,\"id\":\"%s\",\"name\":\"%s\","
              "\"display_api\":%d,\"mode\":\"%s\",\"base_mode\":\"%s\","
              "\"picture_ready\":%s,\"flip180\":%s}",
              esc_version, ML_VERSION_STR, wifi_ip(),
              wifi_is_connected() ? "true" : "false",
              wifi_rssi(),
              (unsigned long long)(esp_timer_get_time() / 1000000),
              esc_layout, panel_width(), panel_height(),
              (unsigned)panel_get_brightness(),
              mirror_config_device_id(), esc_device,
              panel_supports_picture() ? 1 : 0,
              mode, display_mode_name(base_mode),
              picture_ready ? "true" : "false",
              mirror_config_flip180() ? "true" : "false");

    if (n < 0 || (size_t)n >= sizeof(body)) {
        /* The cap above is sized so this cannot fire; refuse rather than send
         * a document the app would parse as corrupt if it ever does. */
        ESP_LOGE(TAG, "status document does not fit %u bytes",
                 (unsigned)sizeof(body));
        return httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR,
                                   "status too large");
    }

    httpd_resp_set_type(req, "application/json");
    return httpd_resp_send(req, body, HTTPD_RESP_USE_STRLEN);
}

static esp_err_t handle_get_layout(httpd_req_t *req)
{
    /* Static: ml_layout is ~6.6KB and httpd runs handlers on one task. */
    static ml_layout layout;
    layout_store_snapshot(&layout);

    /* PSRAM first: this is a 32KB transient buffer and internal SRAM is the
     * scarce resource (the DMA buffer cannot live anywhere else). */
    char *buf = heap_caps_malloc(LAYOUT_JSON_CAP, MALLOC_CAP_SPIRAM);
    if (buf == NULL) {
        buf = heap_caps_malloc(LAYOUT_JSON_CAP, MALLOC_CAP_INTERNAL);
    }
    if (buf == NULL) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR,
                            "out of memory");
        return ESP_FAIL;
    }

    const size_t need = ml_layout_write(&layout, buf, LAYOUT_JSON_CAP);
    if (need >= LAYOUT_JSON_CAP) {
        /* The serializer reports truncation by returning the would-be size. */
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR,
                            "layout too large to serialize");
        heap_caps_free(buf);
        return ESP_FAIL;
    }

    httpd_resp_set_type(req, "application/json");
    const esp_err_t ret = httpd_resp_send(req, buf, (ssize_t)need);
    heap_caps_free(buf);
    return ret;
}

static esp_err_t handle_get_log(httpd_req_t *req)
{
    /* Small internal-DRAM chunk: SPIFFS reads run on the flash-writer task
     * with the cache disabled, where PSRAM is unreachable, and a full 32 KB
     * internal buffer does not fit the fragmented internal heap. */
    enum { CHUNK = 1024 };
    char *chunk = heap_caps_malloc(CHUNK, MALLOC_CAP_INTERNAL);
    if (chunk == NULL) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "out of memory");
        return ESP_FAIL;
    }

    httpd_resp_set_type(req, "application/octet-stream");
    size_t off = 0;
    for (;;) {
        const size_t n = netlog_read(chunk, CHUNK, off);
        if (n == 0) break;
        if (httpd_resp_send_chunk(req, chunk, (ssize_t)n) != ESP_OK) break;
        off += n;
    }
    httpd_resp_send_chunk(req, NULL, 0);

    heap_caps_free(chunk);
    return ESP_OK;
}

static esp_err_t handle_put_layout(httpd_req_t *req)
{
    const int total = req->content_len;
    if (total <= 0) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "empty body");
        return ESP_FAIL;
    }
    if (total > LAYOUT_JSON_CAP) {
        httpd_resp_send_err(req, HTTPD_413_CONTENT_TOO_LARGE,
                            "layout too large");
        return ESP_FAIL;
    }

    char *body = heap_caps_malloc((size_t)total, MALLOC_CAP_SPIRAM);
    if (body == NULL) {
        body = heap_caps_malloc((size_t)total, MALLOC_CAP_INTERNAL);
    }
    if (body == NULL) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR,
                            "out of memory");
        return ESP_FAIL;
    }

    /* The recv loop pattern from provision.c's handle_post_root. */
    int received = 0;
    while (received < total) {
        const int r = httpd_req_recv(req, body + received,
                                     (size_t)(total - received));
        if (r <= 0) {
            heap_caps_free(body);
            httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST,
                                "incomplete request");
            return ESP_FAIL;
        }
        received += r;
    }

    ml_diag diag;
    ml_diag_reset(&diag);
    const esp_err_t err = layout_store_apply(body, (size_t)received, &diag);
    heap_caps_free(body);

    if (err == ESP_ERR_INVALID_ARG) {
        const char *msg = diag.count > 0 ? diag.msg[0] : "layout rejected";
        char esc[2 * ML_DIAG_LEN];
        char out[2 * ML_DIAG_LEN + 64];
        json_escape(esc, sizeof(esc), msg);
        snprintf(out, sizeof(out), "{\"ok\":false,\"error\":\"%s\"}", esc);
        httpd_resp_set_status(req, "400 Bad Request");
        httpd_resp_set_type(req, "application/json");
        return httpd_resp_send(req, out, HTTPD_RESP_USE_STRLEN);
    }

    /* 200 with the parser warnings, which the designer surfaces as a
     * SnackBar. Sized for the worst case (all eight slots full of long
     * messages) and malloc'd so the httpd stack stays shallow. */
    const size_t cap = 64 + (size_t)diag.count * (2 * ML_DIAG_LEN + 8);
    char *out = malloc(cap);
    if (out == NULL) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR,
                            "out of memory");
        return ESP_FAIL;
    }
    int off = snprintf(out, cap, "{\"ok\":true,\"diag\":[");
    for (int i = 0; i < diag.count && off >= 0 && (size_t)off < cap; i++) {
        char esc[2 * ML_DIAG_LEN];
        json_escape(esc, sizeof(esc), diag.msg[i]);
        off += snprintf(out + off, cap - (size_t)off, "%s\"%s\"",
                        i > 0 ? "," : "", esc);
    }
    if (off >= 0 && (size_t)off < cap) {
        snprintf(out + off, cap - (size_t)off, "]}");
    }
    httpd_resp_set_type(req, "application/json");
    const esp_err_t ret = httpd_resp_send(req, out, HTTPD_RESP_USE_STRLEN);
    free(out);
    return ret;
}

static esp_err_t handle_post_ota(httpd_req_t *req)
{
    return ota_handle_upload(req);
}

/*
 * ---------------------------------------------------- display endpoints
 *
 * PUT /api/mode and POST /api/image change the saved base display through
 * display_store, which routes every NVS/SPIFFS write through flash_write_run:
 * nothing writes flash on this PSRAM-stacked httpd task. GET /api/frame
 * returns one real composited frame from the render task, so a tile preview
 * is the panel's actual output rather than a re-render of the layout on the
 * phone. All three inherit the existing trusted-LAN/no-auth model and are not
 * meant to face the Internet.
 *
 * Games are never touched here: they are owned by the render task and start
 * and stop over Bluetooth. A mode or picture committed while a game is
 * running changes the saved base display underneath it, which is what the
 * result document reports.
 */

/* The mode document is a two-member object; the app sends 16-18 bytes. The
 * ceiling matches the documented request size and keeps a hostile or confused
 * client from making the receive buffer interesting. */
#define MODE_JSON_CAP 64

/* Total time allowed for one request body. httpd's own per-recv timeout is
 * 5s; these cap the whole transfer so a client that trickles bytes cannot
 * hold the single httpd task — and with it the rest of the API — for ever. */
#define MODE_RECV_DEADLINE_US  (5 * 1000000)
#define IMAGE_RECV_DEADLINE_US (30 * 1000000)

/* How long a preview request waits for the render task to hand over a frame.
 * The render task blits continuously, so this is short by design: a tile that
 * cannot be sampled quickly is better off keeping its last-known image than
 * holding the API. */
#define SNAPSHOT_TIMEOUT_MS 1500

/*
 * Every error body has the same shape as the layout endpoint's,
 * {"ok":false,"error":"<reason>"}, and the reason is the store's own wording
 * so the app can tell "picture missing" from a storage failure.
 *
 * Rejections close the request. Drain only a bounded amount after sending the
 * error: closing with ordinary queued upload bytes unread sends a TCP reset,
 * which can discard the JSON response before the client receives it.
 */
static esp_err_t send_json_error(httpd_req_t *req, const char *status,
                                 const char *reason)
{
    char esc[2 * 96];
    char body[sizeof(esc) + 32];
    json_escape(esc, sizeof(esc), reason);
    const int n = snprintf(body, sizeof(body),
                           "{\"ok\":false,\"error\":\"%s\"}", esc);
    if (n < 0 || (size_t)n >= sizeof(body)) {
        /* Only reachable from an unprintable 96-byte reason: keep the status
         * and drop the text rather than send a truncated document. */
        snprintf(body, sizeof(body), "{\"ok\":false,\"error\":\"rejected\"}");
    }
    httpd_resp_set_status(req, status);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Connection", "close");
    httpd_resp_send(req, body, HTTPD_RESP_USE_STRLEN);
    char discard[512];
    size_t drained = 0;
    const int64_t deadline = esp_timer_get_time() + 1000000;
    while (drained < PANEL_PICTURE_MAX_BYTES &&
           esp_timer_get_time() < deadline) {
        const int got = httpd_req_recv(req, discard, sizeof(discard));
        if (got <= 0) break;
        drained += (size_t)got;
    }
    return ESP_FAIL;
}

/*
 * The effective display after a mutation, read back from the store and the
 * game runner rather than echoed from the request: "mode" is what the panel
 * is showing now (games win while a session is live), "base_mode" is what it
 * returns to afterwards, and "picture_ready" is the store's verdict on the
 * stored image. Success is only reported once the store has committed, so a
 * 200 here means the choice survives a reboot.
 */
static esp_err_t send_display_result(httpd_req_t *req)
{
    const mirror_display_mode_t base = display_store_base_mode();
    char body[128];
    const int n = snprintf(body, sizeof(body),
                           "{\"ok\":true,\"mode\":\"%s\",\"base_mode\":\"%s\","
                           "\"picture_ready\":%s}",
                           game_runner_active() ? "games"
                                                : display_mode_name(base),
                           display_mode_name(base),
                           display_store_picture_ready() ? "true" : "false");
    if (n < 0 || (size_t)n >= sizeof(body)) {
        return send_json_error(req, "500 Internal Server Error",
                               "result could not be built");
    }
    httpd_resp_set_type(req, "application/json");
    return httpd_resp_send(req, body, HTTPD_RESP_USE_STRLEN);
}

/*
 * Receive exactly len bytes, waiting at most deadline_us in total. Returns the
 * number received: anything short of len means the client stalled, vanished,
 * or sent less than it declared. A socket timeout is retried (httpd's own
 * recv timeout is 5s, longer than a healthy client needs for a 192KB body on
 * a LAN) until the deadline, which the caller reports as an incomplete
 * request.
 */
static size_t recv_exact(httpd_req_t *req, char *buf, size_t len,
                         int64_t deadline_us)
{
    const int64_t deadline = esp_timer_get_time() + deadline_us;
    size_t received = 0;
    while (received < len && esp_timer_get_time() < deadline) {
        const int r = httpd_req_recv(req, buf + received, len - received);
        if (r == HTTPD_SOCK_ERR_TIMEOUT) {
            if (esp_timer_get_time() >= deadline) break;
            continue;
        }
        if (r <= 0) break;
        received += (size_t)r;
    }
    return received;
}

/* Strict positive decimal, for the upload's dimension headers: the app sends
 * plain digits, so a sign, space or unit is a malformed request rather than a
 * number to guess at. The bound keeps width*height*3 far from overflow. */
static bool parse_dimension(const char *s, int *out)
{
    size_t end = strlen(s);
    while (end > 0 && (s[end - 1] == ' ' || s[end - 1] == '\t')) end--;
    if (end == 0) return false;
    long v = 0;
    for (size_t i = 0; i < end; i++) {
        if (s[i] < '0' || s[i] > '9') return false;
        v = v * 10 + (s[i] - '0');
        if (v > 4096) return false;
    }
    if (v < 1) return false;
    *out = (int)v;
    return true;
}

/* Missing and malformed are the same rejection: an absent header reads as -1
 * from httpd and a 16-byte value that is not a number fails the parse. */
static bool dimension_header(httpd_req_t *req, const char *field, int *out)
{
    char val[16];
    if (httpd_req_get_hdr_value_str(req, field, val, sizeof(val)) != ESP_OK) {
        return false;
    }
    return parse_dimension(val, out);
}

/*
 * Rejections, in the order they are checked:
 *   415  Content-Type is not application/octet-stream
 *   400  X-Mirror-Width/Height missing or not a positive decimal
 *   413  the declared dimensions exceed the 256x256 payload cap
 *   409  they do not match this panel (the app sends for the geometry it
 *        prepared; a mismatch means the panel changed under it)
 *   400  empty body, or a nonempty body shorter than width*height*3
 *   413  a body longer than width*height*3
 *   500  the staging buffer could not be allocated
 *   400  the body ended early (stalled or disconnected client)
 *   then the store's verdict: 400 for an unusable payload, 409 when the size
 *   no longer matches the panel, 413 for a panel that cannot hold a picture,
 *   500 for an uninitialised store or a failed write.
 */
static esp_err_t handle_post_image(httpd_req_t *req)
{
    char ctype[48];
    if (httpd_req_get_hdr_value_str(req, "Content-Type", ctype,
                                    sizeof(ctype)) != ESP_OK ||
        strncasecmp(ctype, "application/octet-stream", 24) != 0 ||
        (ctype[24] != '\0' && ctype[24] != ';')) {
        return send_json_error(req, "415 Unsupported Media Type",
                               "content type must be application/octet-stream");
    }

    int width = 0, height = 0;
    if (!dimension_header(req, "X-Mirror-Width", &width)) {
        return send_json_error(req, "400 Bad Request", "invalid X-Mirror-Width");
    }
    if (!dimension_header(req, "X-Mirror-Height", &height)) {
        return send_json_error(req, "400 Bad Request", "invalid X-Mirror-Height");
    }

    const int64_t expected = (int64_t)width * height * 3;
    if (expected > PANEL_PICTURE_MAX_BYTES) {
        return send_json_error(req, "413 Content Too Large",
                               "picture exceeds the 256x256 payload cap");
    }
    if (width != panel_width() || height != panel_height()) {
        return send_json_error(req, "409 Conflict", "panel dimensions changed");
    }

    /* The declared length must be exactly the frame: a longer body is a
     * different picture than the headers describe, and a shorter one is
     * truncated. Both are refused before a byte is read, so an oversized
     * upload costs one response and a closed connection. */
    const int total = req->content_len;
    if (total <= 0) {
        return send_json_error(req, "400 Bad Request", "empty body");
    }
    if ((int64_t)total > expected) {
        return send_json_error(req, "413 Content Too Large",
                               "body is longer than the declared dimensions");
    }
    if ((int64_t)total < expected) {
        return send_json_error(req, "400 Bad Request",
                               "body is shorter than the declared dimensions");
    }

    /* PSRAM: up to 192KB, and internal DRAM is the scarce resource. */
    uint8_t *body = heap_caps_malloc((size_t)expected, MALLOC_CAP_SPIRAM);
    if (body == NULL) {
        body = heap_caps_malloc((size_t)expected, MALLOC_CAP_INTERNAL);
    }
    if (body == NULL) {
        return send_json_error(req, "500 Internal Server Error",
                               "out of memory");
    }

    const size_t received = recv_exact(req, (char *)body, (size_t)expected,
                                       IMAGE_RECV_DEADLINE_US);
    if (received != (size_t)expected) {
        ESP_LOGW(TAG, "image upload ended at %u of %d bytes",
                 (unsigned)received, (int)expected);
        heap_caps_free(body);
        return send_json_error(req, "400 Bad Request", "incomplete request");
    }

    /* The store validates, writes the inactive slot through flash_write_run,
     * rereads it and commits the NVS state byte, so a 200 below means the
     * picture is the base display and survives a reboot. */
    char err[96];
    const esp_err_t err_code = display_store_apply_picture(
        body, received, err, sizeof(err));
    heap_caps_free(body);

    switch (err_code) {
    case ESP_OK:
        return send_display_result(req);
    case ESP_ERR_INVALID_ARG:
        return send_json_error(req, "400 Bad Request", err);
    case ESP_ERR_INVALID_SIZE:
        return send_json_error(req, "409 Conflict", err);
    case ESP_ERR_NOT_SUPPORTED:
        return send_json_error(req, "413 Content Too Large", err);
    default:   /* ESP_ERR_INVALID_STATE, ESP_ERR_NO_MEM, ESP_FAIL */
        return send_json_error(req, "500 Internal Server Error", err);
    }
}

/*
 * Rejections: 400 for an empty body or a mode document over the cap, 400 for
 * a malformed or unsupported mode (including "games", which is started and
 * stopped over Bluetooth), 409 for picture mode with no valid stored image,
 * 500 when the store could not persist the change.
 */
static esp_err_t handle_put_mode(httpd_req_t *req)
{
    const int total = req->content_len;
    if (total <= 0) {
        return send_json_error(req, "400 Bad Request", "empty mode body");
    }
    if (total > MODE_JSON_CAP) {
        return send_json_error(req, "400 Bad Request",
                               "mode body must be at most 64 bytes");
    }

    char body[MODE_JSON_CAP];
    if (recv_exact(req, body, (size_t)total, MODE_RECV_DEADLINE_US) !=
        (size_t)total) {
        return send_json_error(req, "400 Bad Request", "incomplete request");
    }

    /* The same parser the BLE commit worker uses, so both transports accept
     * exactly the same document and answer with the same reason text. */
    char err[96];
    const esp_err_t err_code = display_store_apply_mode_json(body, (size_t)total,
                                                            err, sizeof(err));
    switch (err_code) {
    case ESP_OK:
        return send_display_result(req);
    case ESP_ERR_INVALID_STATE:
        /* The only conflict this endpoint has is a missing picture; an
         * uninitialised store is a server-side failure. display_store_set_mode
         * documents that exact text, and the app acts on the 409 by offering
         * to save a picture first. */
        return send_json_error(req, strcmp(err, "picture missing") == 0
                                        ? "409 Conflict"
                                        : "500 Internal Server Error",
                               err);
    case ESP_ERR_INVALID_ARG:
        return send_json_error(req, "400 Bad Request", err);
    default:
        return send_json_error(req, "500 Internal Server Error", err);
    }
}

/*
 * One real frame: the composited panel output with its MRF1 header, so the
 * app can show what the device is actually displaying without a JPEG/PNG
 * decoder in the firmware. The acquire/release lease is always released after
 * the send, successful or not, or the render task would stop publishing.
 * Retry policy lives in the app: 503 just means this poll found no frame.
 */
static esp_err_t handle_get_frame(httpd_req_t *req)
{
    const uint8_t *bytes = NULL;
    size_t len = 0;
    const esp_err_t err = frame_snapshot_acquire(&bytes, &len,
                                                 SNAPSHOT_TIMEOUT_MS);
    if (err != ESP_OK) {
        return send_json_error(req, "503 Service Unavailable",
                               err == ESP_ERR_TIMEOUT ? "snapshot timeout"
                                                      : "snapshot unavailable");
    }

    httpd_resp_set_type(req, "application/octet-stream");
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    httpd_resp_send(req, (const char *)bytes, (ssize_t)len);
    frame_snapshot_release();
    /* ESP_OK: the body was sent whole, so the socket stays usable. */
    return ESP_OK;
}

static const char *method_name(httpd_method_t method)
{
    switch (method) {
    case HTTP_GET:  return "GET";
    case HTTP_POST: return "POST";
    case HTTP_PUT:  return "PUT";
    case HTTP_DELETE: return "DELETE";
    default:        return "?";
    }
}

/*
 * Five original endpoints plus the three display ones. The count is
 * configured explicitly in api_server_start: httpd's default table is smaller
 * and a registration that does not fit fails at runtime.
 */
enum { URI_HANDLER_COUNT = 8 };

static void register_handlers(void)
{
    static const httpd_uri_t get_status = {
        .uri = "/api/status", .method = HTTP_GET, .handler = handle_get_status,
    };
    static const httpd_uri_t get_layout = {
        .uri = "/api/layout", .method = HTTP_GET, .handler = handle_get_layout,
    };
    static const httpd_uri_t put_layout = {
        .uri = "/api/layout", .method = HTTP_PUT, .handler = handle_put_layout,
    };
    static const httpd_uri_t post_ota = {
        .uri = "/api/ota", .method = HTTP_POST, .handler = handle_post_ota,
    };
    static const httpd_uri_t get_log = {
        .uri = "/api/log", .method = HTTP_GET, .handler = handle_get_log,
    };
    static const httpd_uri_t put_mode = {
        .uri = "/api/mode", .method = HTTP_PUT, .handler = handle_put_mode,
    };
    static const httpd_uri_t post_image = {
        .uri = "/api/image", .method = HTTP_POST, .handler = handle_post_image,
    };
    static const httpd_uri_t get_frame = {
        .uri = "/api/frame", .method = HTTP_GET, .handler = handle_get_frame,
    };

    static const httpd_uri_t *const handlers[] = {
        &get_status, &get_layout, &put_layout, &post_ota, &get_log,
        &put_mode, &post_image, &get_frame,
    };
    _Static_assert(sizeof(handlers) / sizeof(handlers[0]) == URI_HANDLER_COUNT,
                   "handler table and max_uri_handlers must agree");

    /* Checked one by one: a registration that fails would leave the endpoint
     * missing at runtime with nothing in the log to explain it. */
    for (size_t i = 0; i < sizeof(handlers) / sizeof(handlers[0]); i++) {
        const esp_err_t err = httpd_register_uri_handler(s_httpd, handlers[i]);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "registering %s %s failed: %s",
                     method_name(handlers[i]->method), handlers[i]->uri,
                     esp_err_to_name(err));
        }
    }
}

static void on_retry(void *arg)
{
    (void)arg;
    if (wifi_is_connected()) api_server_start();
}

static void api_server_start(void)
{
    if (s_httpd != NULL) return;

    httpd_config_t cfg = HTTPD_DEFAULT_CONFIG();
    cfg.stack_size = 8192;
    cfg.lru_purge_enable = true;
    /* Room for every endpoint in the table in register_handlers(). */
    cfg.max_uri_handlers = URI_HANDLER_COUNT;
    /* The httpd task stack lives in PSRAM: internal SRAM is the scarce
     * resource (panel DMA, WiFi and the BT controller all live there). Flash
     * writes that must not run on a PSRAM stack (OTA and the layout persist)
     * are routed to the dedicated internal-DRAM task in flash_write.c. */
    cfg.task_caps = MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT;

    const esp_err_t err = httpd_start(&s_httpd, &cfg);
    if (err != ESP_OK) {
        /* The provisioning portal may still hold port 80 briefly after a
         * first-time join, or internal RAM may be tight. Retry until either
         * the port is free or the link drops. */
        s_httpd = NULL;
        ESP_LOGW(TAG, "httpd start failed (%s), internal free %u, retrying",
                 esp_err_to_name(err),
                 (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
        esp_timer_start_once(s_retry, RETRY_DELAY_US);
        return;
    }

    esp_timer_stop(s_retry);
    register_handlers();
    ESP_LOGI(TAG, "LAN API listening on port 80");
}

static void api_server_stop(void)
{
    esp_timer_stop(s_retry);
    if (s_httpd != NULL) {
        httpd_stop(s_httpd);
        s_httpd = NULL;
        ESP_LOGI(TAG, "LAN API stopped (link dropped)");
    }
}

static void on_ip_event(void *arg, esp_event_base_t base,
                        int32_t id, void *data)
{
    (void)arg; (void)base; (void)data;
    if (id == IP_EVENT_STA_GOT_IP) api_server_start();
}

static void on_wifi_event(void *arg, esp_event_base_t base,
                          int32_t id, void *data)
{
    (void)arg; (void)base; (void)data;
    if (id == WIFI_EVENT_STA_DISCONNECTED) api_server_stop();
}

esp_err_t api_server_init(void)
{
    const esp_timer_create_args_t retry_args = {
        .callback = on_retry,
        .name     = "api_retry",
    };
    ESP_ERROR_CHECK(esp_timer_create(&retry_args, &s_retry));

    ESP_ERROR_CHECK(esp_event_handler_instance_register(
        IP_EVENT, IP_EVENT_STA_GOT_IP, &on_ip_event, NULL, NULL));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(
        WIFI_EVENT, WIFI_EVENT_STA_DISCONNECTED, &on_wifi_event, NULL, NULL));

    /* mDNS runs independent of the httpd lifecycle. Both names carry the
     * hardware identity: two mirrors on one LAN must not fight over one
     * hostname or one service instance, and an owner rename must not change
     * how the device is discovered. The service type and port are unchanged,
     * so existing discovery keeps working. */
    if (mdns_init() != ESP_OK) {
        ESP_LOGE(TAG, "mDNS init failed, discovery by name unavailable");
        return ESP_OK;   /* the API itself still works by IP */
    }
    const char *id = mirror_config_device_id();
    char hostname[sizeof("smart-mirror-") + 12];
    char instance[sizeof("Smart Mirror ") + 12];
    snprintf(hostname, sizeof(hostname), "smart-mirror-%s", id);
    snprintf(instance, sizeof(instance), "Smart Mirror %s", id);
    if (mdns_hostname_set(hostname) != ESP_OK ||
        mdns_instance_name_set(instance) != ESP_OK) {
        ESP_LOGW(TAG, "mDNS names for %s rejected, discovery may be ambiguous", id);
    }
    mdns_service_add(NULL, "_smartmirror", "_tcp", 80, NULL, 0);
    ESP_LOGI(TAG, "mDNS: %s.local (%s)", hostname, instance);

    return ESP_OK;
}
