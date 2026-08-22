/*
 * ota.c - firmware update over the LAN API (POST /api/ota).
 *
 * The upload is a raw binary stream with a Content-Length. The httpd task
 * reads it whole into PSRAM (receiving never touches flash), then hands the
 * buffer to a dedicated internal-DRAM task that performs the flash write:
 * esp_ota_write freezes the cache and ESP-IDF asserts the calling task's
 * stack is in DRAM, which the PSRAM-stacked httpd task cannot satisfy.
 *
 * The source bytes must also be in internal DRAM: spi_flash copies the source
 * into a small stack buffer while the cache is frozen, and PSRAM is
 * unreachable in that window. The writer therefore streams the PSRAM buffer
 * through a small internal-DRAM chunk.
 *
 * Rollback story: with CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE, a booted-but-
 * unverified app is reverted by the boot loader unless the app calls
 * ota_mark_valid() once it is demonstrably running. A corrupted image never
 * even gets that far: esp_ota_end() validates the image before the boot
 * partition is switched.
 */
#include "ota.h"

#include <string.h>

#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_system.h"

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "flash_write.h"
#include "netlog.h"

static const char *TAG = "ota";

/* httpd handles requests on one task, so this needs no locking. */
static bool s_ota_active = false;

typedef struct {
    const esp_partition_t *part;
    const uint8_t *data;
    size_t len;
    esp_err_t result;
} ota_write_ctx_t;

/* Runs on the flash-writer task, whose stack is in internal DRAM. */
static void ota_write_fn(void *arg)
{
    ota_write_ctx_t *c = arg;
    esp_ota_handle_t handle = 0;

    c->result = esp_ota_begin(c->part, OTA_SIZE_UNKNOWN, &handle);

    /* The source must be internal DRAM while the cache is frozen during the
     * write, so stream the PSRAM buffer through a small chunk. The chunk is
     * on this task's stack (internal DRAM) and needs no heap: the internal
     * heap is nearly exhausted after boot. */
    uint8_t chunk[1024];

    size_t off = 0;
    while (c->result == ESP_OK && off < c->len) {
        const size_t n = (c->len - off < sizeof(chunk)) ? (c->len - off) : sizeof(chunk);
        memcpy(chunk, c->data + off, n);
        c->result = esp_ota_write(handle, chunk, n);
        off += n;
    }

    if (c->result == ESP_OK) {
        c->result = esp_ota_end(handle);
    }
    if (c->result == ESP_OK) {
        c->result = esp_ota_set_boot_partition(c->part);
    } else if (handle != 0) {
        esp_ota_abort(handle);
    }
}

static esp_err_t send_json(httpd_req_t *req, const char *status,
                           const char *body)
{
    httpd_resp_set_status(req, status);
    httpd_resp_set_type(req, "application/json");
    return httpd_resp_send(req, body, HTTPD_RESP_USE_STRLEN);
}

esp_err_t ota_handle_upload(httpd_req_t *req)
{
    if (s_ota_active) {
        return send_json(req, "409 Conflict",
                         "{\"ok\":false,\"error\":\"update already in progress\"}");
    }

    const int content_len = req->content_len;
    if (content_len <= 0) {
        return send_json(req, "411 Length Required",
                         "{\"ok\":false,\"error\":\"Content-Length required\"}");
    }

    const esp_partition_t *part = esp_ota_get_next_update_partition(NULL);
    if (part == NULL) {
        return send_json(req, "500 Internal Server Error",
                         "{\"ok\":false,\"error\":\"no OTA partition\"}");
    }
    if ((size_t)content_len > part->size) {
        return send_json(req, "413 Content Too Large",
                         "{\"ok\":false,\"error\":\"image larger than partition\"}");
    }

    s_ota_active = true;

    uint8_t *data = heap_caps_malloc((size_t)content_len, MALLOC_CAP_SPIRAM);
    if (data == NULL) {
        s_ota_active = false;
        return send_json(req, "500 Internal Server Error",
                         "{\"ok\":false,\"error\":\"out of memory\"}");
    }

    int received = 0;
    while (received < content_len) {
        const int r = httpd_req_recv(req, (char *)(data + received),
                                     (size_t)(content_len - received));
        if (r <= 0) {
            ESP_LOGW(TAG, "receive failed at %d of %d bytes",
                     received, content_len);
            heap_caps_free(data);
            s_ota_active = false;
            return send_json(req, "500 Internal Server Error",
                             "{\"ok\":false,\"error\":\"upload failed\"}");
        }
        received += r;
    }

    ota_write_ctx_t ctx = {
        .part = part,
        .data = data,
        .len = (size_t)content_len,
        .result = ESP_FAIL,
    };
    netlog_record(NETLOG_EVT_OTA_BEGIN, 0, 0);
    const esp_err_t run_err = flash_write_run(ota_write_fn, &ctx);
    heap_caps_free(data);

    if (run_err != ESP_OK || ctx.result != ESP_OK) {
        s_ota_active = false;
        const esp_err_t reason = run_err != ESP_OK ? run_err : ctx.result;
        ESP_LOGE(TAG, "flash write failed: %s", esp_err_to_name(reason));
        return send_json(req, "500 Internal Server Error",
                         "{\"ok\":false,\"error\":\"image rejected\"}");
    }

    s_ota_active = false;
    ESP_LOGI(TAG, "received %d bytes, new app on partition \"%s\", rebooting",
             received, part->label);
    netlog_record(NETLOG_EVT_OTA_OK, 0, 0);

    send_json(req, "200 OK", "{\"ok\":true}");
    /* The response is queued by the stack; a short delay on the httpd task
     * lets it flush to the network before the chip restarts, so the phone
     * sees "ok" instead of a dropped connection. */
    vTaskDelay(pdMS_TO_TICKS(500));
    esp_restart();
    return ESP_OK;   /* unreachable */
}

void ota_mark_valid(void)
{
    if (esp_ota_mark_app_valid_cancel_rollback() == ESP_OK) {
        ESP_LOGI(TAG, "app marked valid, rollback cancelled");
    }
}
