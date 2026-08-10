/*
 * ota.c - firmware update over the LAN API (POST /api/ota).
 *
 * The upload is a raw binary stream with a Content-Length, written straight
 * into the inactive OTA partition in whatever chunk sizes the HTTP server
 * delivers. Flash writes through esp_ota_write are buffered, so small chunks
 * cost nothing.
 *
 * Rollback story: with CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE, a booted-but-
 * unverified app is reverted by the boot loader unless the app calls
 * ota_mark_valid() once it is demonstrably running. A corrupted image never
 * even gets that far: esp_ota_end() validates the image before the boot
 * partition is switched.
 */
#include "ota.h"

#include <string.h>

#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_system.h"

static const char *TAG = "ota";

/* httpd handles requests on one task, so this needs no locking. */
static bool s_ota_active = false;

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

    esp_ota_handle_t handle;
    esp_err_t err = esp_ota_begin(part, OTA_SIZE_UNKNOWN, &handle);
    if (err != ESP_OK) {
        s_ota_active = false;
        ESP_LOGE(TAG, "esp_ota_begin: %s", esp_err_to_name(err));
        return send_json(req, "500 Internal Server Error",
                         "{\"ok\":false,\"error\":\"could not start update\"}");
    }

    char buf[1024];
    int received = 0;
    while (received < content_len) {
        const int r = httpd_req_recv(req, buf, sizeof(buf));
        if (r <= 0) {
            err = ESP_FAIL;
            ESP_LOGW(TAG, "receive failed at %d of %d bytes",
                     received, content_len);
            break;
        }
        received += r;
        err = esp_ota_write(handle, buf, (size_t)r);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "esp_ota_write: %s", esp_err_to_name(err));
            break;
        }
    }

    if (err != ESP_OK) {
        esp_ota_abort(handle);
        s_ota_active = false;
        return send_json(req, "500 Internal Server Error",
                         "{\"ok\":false,\"error\":\"upload failed\"}");
    }

    /* Validates the whole image; a bad one is rejected here and rolled back
     * cleanly, never booted. */
    err = esp_ota_end(handle);
    if (err != ESP_OK) {
        esp_ota_abort(handle);
        s_ota_active = false;
        ESP_LOGE(TAG, "esp_ota_end rejected the image: %s", esp_err_to_name(err));
        return send_json(req, "500 Internal Server Error",
                         "{\"ok\":false,\"error\":\"image rejected\"}");
    }

    err = esp_ota_set_boot_partition(part);
    if (err != ESP_OK) {
        s_ota_active = false;
        ESP_LOGE(TAG, "esp_ota_set_boot_partition: %s", esp_err_to_name(err));
        return send_json(req, "500 Internal Server Error",
                         "{\"ok\":false,\"error\":\"could not set boot partition\"}");
    }

    s_ota_active = false;
    ESP_LOGI(TAG, "received %d bytes, new app on partition \"%s\", rebooting",
             received, part->label);

    send_json(req, "200 OK", "{\"ok\":true}");
    esp_restart();
    return ESP_OK;   /* unreachable */
}

void ota_mark_valid(void)
{
    if (esp_ota_mark_app_valid_cancel_rollback() == ESP_OK) {
        ESP_LOGI(TAG, "app marked valid, rollback cancelled");
    }
}
