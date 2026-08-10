/*
 * api_server.c - the mirror's LAN API (station interface, port 80).
 *
 * Endpoints: GET /api/status, GET|PUT /api/layout, POST /api/ota. The layout
 * transport is the core's own JSON, so the designer can push the exact bytes
 * its preview renders and read back the same layout.
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

#include "esp_event.h"
#include "esp_heap_caps.h"
#include "esp_http_server.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "layout_store.h"
#include "mdns.h"
#include "mirror/mirror.h"
#include "net/ota.h"
#include "net/wifi.h"
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

static esp_err_t handle_get_status(httpd_req_t *req)
{
    /* Static: ml_layout is ~6.6KB and httpd runs handlers on one task. */
    static ml_layout layout;
    layout_store_snapshot(&layout);

    char esc_name[2 * ML_NAME_LEN];
    json_escape(esc_name, sizeof(esc_name), layout.name);

    char body[320];
    snprintf(body, sizeof(body),
             "{\"version\":\"%s\",\"ip\":\"%s\",\"online\":%s,\"rssi\":%d,"
             "\"uptime_s\":%llu,\"layout\":\"%s\",\"width\":%d,\"height\":%d,"
             "\"brightness\":%u}",
             ML_VERSION_STR, wifi_ip(),
             wifi_is_connected() ? "true" : "false",
             wifi_rssi(),
             (unsigned long long)(esp_timer_get_time() / 1000000),
             esc_name, layout.w, layout.h, (unsigned)layout.brightness);

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

    httpd_register_uri_handler(s_httpd, &get_status);
    httpd_register_uri_handler(s_httpd, &get_layout);
    httpd_register_uri_handler(s_httpd, &put_layout);
    httpd_register_uri_handler(s_httpd, &post_ota);
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
    /* The httpd task stack on PSRAM: internal SRAM is the scarce resource
     * (panel DMA, WiFi and the BT controller all live there). An 8KB stack
     * for a LAN JSON API is fine outside it. */
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

    /* mDNS runs independent of the httpd lifecycle. */
    if (mdns_init() != ESP_OK) {
        ESP_LOGE(TAG, "mDNS init failed, discovery via smart-mirror.local unavailable");
        return ESP_OK;   /* the API itself still works by IP */
    }
    mdns_hostname_set("smart-mirror");
    mdns_instance_name_set("Smart Mirror");
    mdns_service_add(NULL, "_smartmirror", "_tcp", 80, NULL, 0);
    ESP_LOGI(TAG, "mDNS: smart-mirror.local");

    return ESP_OK;
}
