/*
 * ota.c - resumable firmware streaming over Bluetooth.
 *
 * The session streams bytes into flash as they arrive; it does not buffer the
 * image in PSRAM. The flash writer task has an internal-DRAM stack, and copies
 * each ring-buffered chunk into its stack before esp_ota_write while the cache
 * is frozen. The source bytes must therefore be reachable in that window.
 */
#include "ota.h"

#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/stream_buffer.h"
#include "freertos/task.h"
#include "flash_write.h"
#include "netlog.h"

#define OTA_RING_BYTES 8192
#define OTA_WRITE_CHUNK 4096
#define OTA_RECEIVE_TICK_MS 250
#define OTA_STARVE_MS 5000
#define OTA_RESUME_GRACE_MS 120000
#define OTA_APPEND_WAIT_MS 5000
#define OTA_FINISH_WAIT_MS 30000

static const char *TAG = "ota";
static SemaphoreHandle_t s_lock;
static SemaphoreHandle_t s_finished;
static StreamBufferHandle_t s_ring;
static StaticStreamBuffer_t s_ring_struct;
static uint8_t *s_ring_storage;
static const esp_partition_t *s_part;
static esp_ota_handle_t s_handle;
static size_t s_total;
static volatile size_t s_written;
static bool s_worker_running;
static esp_err_t s_result;
static esp_timer_handle_t s_expire;
static volatile bool s_end_requested;
static volatile bool s_abort_requested;

static void ota_session_abort_locked(void)
{
    esp_timer_stop(s_expire);
    if (s_handle != 0) {
        esp_ota_abort(s_handle);
        s_handle = 0;
    }
    if (s_ring_storage != NULL) heap_caps_free(s_ring_storage);
    s_ring_storage = NULL;
    s_ring = NULL;
    s_part = NULL;
    s_total = 0;
    s_written = 0;
    s_worker_running = false;
    s_end_requested = false;
    s_abort_requested = false;
}

static void ota_worker_exit(esp_err_t result, bool finished)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_result = result;
    s_worker_running = false;
    if (!finished && s_total != 0) {
        esp_timer_start_once(s_expire, (uint64_t)OTA_RESUME_GRACE_MS * 1000);
        ESP_LOGI(TAG, "stream stalled at %u of %u bytes",
                 (unsigned)s_written, (unsigned)s_total);
    }
    xSemaphoreGive(s_lock);
    xSemaphoreGive(s_finished);
}

static void ota_stream_fn(void *arg)
{
    (void)arg;
    esp_ota_handle_t handle = s_handle;
    esp_err_t err = ESP_OK;
    if (handle == 0) {
        err = esp_ota_begin(s_part, s_total, &handle);
        if (err != ESP_OK) {
            ota_worker_exit(err, false);
            return;
        }
        s_handle = handle;
    }

    uint8_t chunk[OTA_WRITE_CHUNK];
    int64_t idle_since = esp_timer_get_time();
    for (;;) {
        const size_t n = xStreamBufferReceive(s_ring, chunk, sizeof(chunk),
                                              pdMS_TO_TICKS(OTA_RECEIVE_TICK_MS));
        if (n > 0) {
            err = esp_ota_write(handle, chunk, n);
            if (err != ESP_OK) {
                esp_ota_abort(handle);
                s_handle = 0;
                ota_worker_exit(err, true);
                return;
            }
            s_written += n;
            idle_since = esp_timer_get_time();
            continue;
        }
        if (s_abort_requested) {
            esp_ota_abort(handle);
            s_handle = 0;
            ota_worker_exit(ESP_ERR_INVALID_STATE, true);
            return;
        }
        if (s_end_requested) {
            if (s_written != s_total) {
                esp_ota_abort(handle);
                s_handle = 0;
                ota_worker_exit(ESP_ERR_INVALID_STATE, true);
                return;
            }
            break;
        }
        if (esp_timer_get_time() - idle_since > (int64_t)OTA_STARVE_MS * 1000) {
            s_end_requested = false;
            ota_worker_exit(ESP_ERR_TIMEOUT, false);
            return;
        }
    }

    err = esp_ota_end(handle);
    s_handle = 0;
    if (err == ESP_OK) err = esp_ota_set_boot_partition(s_part);
    ota_worker_exit(err, true);
}

static esp_err_t ota_submit_locked(void)
{
    const esp_err_t err = flash_write_submit(ota_stream_fn, NULL);
    if (err == ESP_OK) s_worker_running = true;
    return err;
}

static void ota_expire_cb(void *arg)
{
    (void)arg;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (s_total != 0 && !s_worker_running) {
        if (s_handle != 0) esp_ota_abort(s_handle);
        s_handle = 0;
        if (s_ring_storage != NULL) heap_caps_free(s_ring_storage);
        s_ring_storage = NULL;
        s_ring = NULL;
        s_total = 0;
        s_written = 0;
        s_end_requested = false;
        s_abort_requested = false;
        s_result = ESP_ERR_TIMEOUT;
        ESP_LOGW(TAG, "idle OTA session dropped");
    }
    xSemaphoreGive(s_lock);
}

esp_err_t ota_init(void)
{
    s_lock = xSemaphoreCreateMutex();
    s_finished = xSemaphoreCreateBinary();
    const esp_timer_create_args_t args = {
        .callback = ota_expire_cb, .name = "ota_expire",
    };
    if (s_lock == NULL || s_finished == NULL ||
        esp_timer_create(&args, &s_expire) != ESP_OK) {
        return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
}

esp_err_t ota_session_begin(size_t total, size_t offset)
{
    const esp_partition_t *part = esp_ota_get_next_update_partition(NULL);
    if (part == NULL) return ESP_ERR_INVALID_STATE;
    if (total == 0 || total > part->size) return ESP_ERR_INVALID_ARG;

    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (offset > 0) {
        if (s_total != total || s_written != offset) {
            xSemaphoreGive(s_lock);
            return ESP_ERR_INVALID_ARG;
        }
        esp_timer_stop(s_expire);
        if (!s_worker_running) {
            const esp_err_t err = ota_submit_locked();
            if (err != ESP_OK) {
                xSemaphoreGive(s_lock);
                return ESP_ERR_INVALID_STATE;
            }
        }
        ESP_LOGI(TAG, "update resumed at %u of %u bytes",
                 (unsigned)offset, (unsigned)total);
        xSemaphoreGive(s_lock);
        return ESP_OK;
    }

    ota_session_abort_locked();
    if (s_ring_storage != NULL) heap_caps_free(s_ring_storage);
    s_ring_storage = heap_caps_malloc(OTA_RING_BYTES, MALLOC_CAP_INTERNAL);
    if (s_ring_storage == NULL) {
        xSemaphoreGive(s_lock);
        return ESP_ERR_NO_MEM;
    }
    s_ring = xStreamBufferCreateStatic(OTA_RING_BYTES, 1, s_ring_storage,
                                       &s_ring_struct);
    if (s_ring == NULL) {
        heap_caps_free(s_ring_storage);
        s_ring_storage = NULL;
        xSemaphoreGive(s_lock);
        return ESP_ERR_NO_MEM;
    }
    s_part = part;
    s_total = total;
    s_written = 0;
    s_result = ESP_FAIL;
    s_end_requested = false;
    s_abort_requested = false;
    xSemaphoreTake(s_finished, 0);
    const esp_err_t err = ota_submit_locked();
    if (err != ESP_OK) {
        ota_session_abort_locked();
        xSemaphoreGive(s_lock);
        return ESP_ERR_INVALID_STATE;
    }
    ESP_LOGI(TAG, "update started, %u bytes", (unsigned)total);
    xSemaphoreGive(s_lock);
    return ESP_OK;
}

esp_err_t ota_session_append(const uint8_t *data, size_t len)
{
    if (data == NULL || len == 0) return ESP_ERR_INVALID_ARG;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (s_total == 0) {
        xSemaphoreGive(s_lock);
        return ESP_ERR_INVALID_STATE;
    }
    /* The writer may still be inside esp_ota_begin (partition erase) or may
     * have just yielded its completion credit. The ring remains valid for the
     * session, so accept bytes while it starts; backpressure is provided by
     * xStreamBufferSend below. */
    StreamBufferHandle_t ring = s_ring;
    xSemaphoreGive(s_lock);
    const size_t sent = xStreamBufferSend(ring, data, len,
                                          pdMS_TO_TICKS(OTA_APPEND_WAIT_MS));
    return sent == len ? ESP_OK : ESP_ERR_TIMEOUT;
}

esp_err_t ota_session_finish(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (s_total == 0) {
        xSemaphoreGive(s_lock);
        return ESP_ERR_INVALID_STATE;
    }
    s_end_requested = true;
    if (!s_worker_running) {
        xSemaphoreTake(s_finished, 0);
        if (ota_submit_locked() != ESP_OK) {
            xSemaphoreGive(s_lock);
            return ESP_ERR_INVALID_STATE;
        }
    }
    xSemaphoreGive(s_lock);
    if (xSemaphoreTake(s_finished, pdMS_TO_TICKS(OTA_FINISH_WAIT_MS)) != pdTRUE) {
        ota_session_abort();
        return ESP_ERR_TIMEOUT;
    }
    const esp_err_t err = s_result;
    ota_session_abort();
    return err;
}

void ota_session_abort(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    const bool running = s_worker_running;
    if (running) s_abort_requested = true;
    xSemaphoreGive(s_lock);
    if (running) xSemaphoreTake(s_finished, pdMS_TO_TICKS(2000));
    xSemaphoreTake(s_lock, portMAX_DELAY);
    ota_session_abort_locked();
    xSemaphoreGive(s_lock);
}

/* 32-bit aligned loads are atomic on this target; the writer only increments
 * s_written and these accessors read it, so no lock is needed. */
size_t ota_session_written(void) { return s_written; }
size_t ota_session_total(void) { return s_total; }
bool ota_session_active(void) { return s_total != 0; }

void ota_mark_valid(void)
{
    if (esp_ota_mark_app_valid_cancel_rollback() == ESP_OK) {
        ESP_LOGI(TAG, "app marked valid, rollback cancelled");
    }
}
