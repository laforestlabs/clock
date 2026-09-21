/*
 * frame_snapshot.c - one-frame capture shared with the LAN preview endpoint.
 *
 * See frame_snapshot.h for the contract and the wire format. This file owns
 * the buffer, the state machine and the handshake with the render task.
 *
 * The state machine, every transition under s_lock:
 *
 *   IDLE     nothing requested
 *   PENDING  an acquirer is waiting for the next rendered frame
 *   PREPARED a frame has been composed into the buffer; the blit is next
 *   READY    that frame was blitted and is waiting to be leased
 *   LEASED   an acquirer is sending it; the renderer must not write
 *
 * The races this shape has to close, and how it closes them:
 *
 *  - The render task never overwrites a leased buffer: prepare() only writes
 *    in PENDING, and a lease can only be taken from READY.
 *  - A timeout invalidates only its own request: the waiter records the
 *    generation it armed and clears its pending/prepared/ready state.
 *    A timed-out frame is discarded, never handed to a later caller.
 *  - A stale completion cannot satisfy a later request: presented() completes
 *    only the generation actually outstanding, the completion semaphore is
 *    drained before waiting, and a wake-up is accepted only when the ready
 *    generation equals the waiter's own.
 *  - A busy or idle path costs nothing: s_armed is an advisory flag the
 *    render task checks before taking the mutex, and the mutex stays the
 *    authority. No lock is ever held across the socket send.
 */
#include "frame_snapshot.h"

#include <string.h>
#include <stdatomic.h>

#include "esp_heap_caps.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "panel.h"

static const char *TAG = "snapshot";

typedef enum {
    SNAP_IDLE = 0,
    SNAP_PENDING,
    SNAP_PREPARED,
    SNAP_READY,
    SNAP_LEASED,
} snap_state_t;

/* The single header-plus-frame buffer, allocated once at init. */
static uint8_t      *s_frame;
static size_t        s_frame_cap;
static int           s_width;
static int           s_height;
static size_t        s_len;         /* header + payload of the current frame */

static SemaphoreHandle_t s_lock;    /* guards everything below */
static SemaphoreHandle_t s_done;    /* one completion signal per presented frame */

static snap_state_t s_state = SNAP_IDLE;
static uint32_t     s_gen;          /* increments per armed request; never 0 */
static uint32_t     s_pending_gen;  /* generation of the outstanding request */
static uint32_t     s_ready_gen;    /* generation of the frame in READY/LEASED */

/*
 * Advisory: true while a request is outstanding, so the render task can skip
 * the mutex entirely on the overwhelmingly common frame nobody asked for. It
 * is read without the lock, which is safe here because the mutex decides
 * everything: a stale read only makes prepare() take the lock and find no
 * request. Writes happen under the lock.
 */
static _Atomic bool s_armed;

/*
 * True between a prepare() that composed a frame and the presented() that
 * follows its blit. Both run on the render task, so this needs no lock; it
 * exists so the idle presented() return costs one load instead of a mutex.
 */
static bool s_prepared;

static inline uint8_t dim(uint8_t value, uint8_t brightness)
{
    /* Same curve as ml_canvas_export_rgb888: the bytes are already gamma
     * corrected, so this is exactly the scaling the panel path applies for a
     * frame exported at this brightness, with the same rounding. */
    return (uint8_t)(((unsigned)value * brightness + 127u) / 255u);
}

/*
 * Copy src into dst with the brightness and orientation the app expects: the
 * panel driver would otherwise apply them to rgb in place and for the shift
 * registers, which is not what a preview should show. 180 degrees is a whole
 * pixel reversal, so it is done per pixel rather than per byte (reversing the
 * bytes would also swap red and blue).
 */
static void compose(uint8_t *dst, const uint8_t *src, int w, int h,
                    uint8_t brightness, bool flip180)
{
    const size_t pixels = (size_t)w * (size_t)h;

    if (brightness == 255 && !flip180) {
        memcpy(dst, src, pixels * 3u);
        return;
    }

    for (int y = 0; y < h; y++) {
        const uint8_t *srow = src + (size_t)y * (size_t)w * 3u;
        const int dy = flip180 ? (h - 1 - y) : y;

        for (int x = 0; x < w; x++) {
            const uint8_t *s = srow + (size_t)x * 3u;
            const int dx = flip180 ? (w - 1 - x) : x;
            uint8_t *d = dst + ((size_t)dy * (size_t)w + (size_t)dx) * 3u;

            if (brightness == 255) {
                d[0] = s[0];
                d[1] = s[1];
                d[2] = s[2];
            } else {
                d[0] = dim(s[0], brightness);
                d[1] = dim(s[1], brightness);
                d[2] = dim(s[2], brightness);
            }
        }
    }
}

static inline void put_u16(uint8_t *p, uint16_t value)
{
    p[0] = (uint8_t)(value & 0xffu);
    p[1] = (uint8_t)((value >> 8) & 0xffu);
}

static inline void put_u32(uint8_t *p, uint32_t value)
{
    p[0] = (uint8_t)(value & 0xffu);
    p[1] = (uint8_t)((value >> 8) & 0xffu);
    p[2] = (uint8_t)((value >> 16) & 0xffu);
    p[3] = (uint8_t)((value >> 24) & 0xffu);
}

static bool      s_init_done;
static esp_err_t s_init_result;

esp_err_t frame_snapshot_init(void)
{
    if (s_init_done) {
        return s_init_result;   /* one attempt, so a retry cannot leak */
    }
    s_init_done = true;
    s_init_result = ESP_FAIL;

    const int w = panel_width();
    const int h = panel_height();

    /* Bounded before multiplying: a size_t is 32 bits here, and the caps make
     * an oversized panel a deliberate refusal rather than an overflow. */
    if (w <= 0 || h <= 0 || w > 4096 || h > 4096) {
        ESP_LOGW(TAG, "panel geometry %dx%d, no snapshot buffer", w, h);
        return (s_init_result = ESP_ERR_NOT_SUPPORTED);
    }

    const size_t payload = (size_t)w * (size_t)h * 3u;
    if (payload > PANEL_PICTURE_MAX_BYTES) {
        /* The same line the picture contract draws: a panel this large does
         * not advertise the display API, so no preview buffer is kept. */
        ESP_LOGW(TAG, "panel %dx%d exceeds the preview cap, no snapshot", w, h);
        return (s_init_result = ESP_ERR_NOT_SUPPORTED);
    }

    const size_t total = payload + FRAME_SNAPSHOT_HEADER_LEN;

    s_lock = xSemaphoreCreateMutex();
    s_done = xSemaphoreCreateBinary();
    if (s_lock == NULL || s_done == NULL) {
        ESP_LOGE(TAG, "could not create the snapshot signalling");
        if (s_lock != NULL) {
            vSemaphoreDelete(s_lock);
            s_lock = NULL;
        }
        if (s_done != NULL) {
            vSemaphoreDelete(s_done);
            s_done = NULL;
        }
        return (s_init_result = ESP_ERR_NO_MEM);
    }

    s_frame = heap_caps_malloc(total, MALLOC_CAP_SPIRAM);
    if (s_frame == NULL) {
        ESP_LOGW(TAG, "no memory for the %u byte snapshot buffer",
                 (unsigned)total);
        return (s_init_result = ESP_ERR_NO_MEM);
    }

    s_frame_cap = total;
    s_width = w;
    s_height = h;
    s_state = SNAP_IDLE;
    s_armed = false;
    s_prepared = false;

    ESP_LOGI(TAG, "snapshot buffer ready: %dx%d, %u bytes", w, h,
             (unsigned)total);
    return (s_init_result = ESP_OK);
}

void frame_snapshot_prepare(const uint8_t *rgb, int width, int height,
                            uint32_t sequence, uint8_t brightness,
                            bool flip180, mirror_display_mode_t mode)
{
    if (rgb == NULL || s_frame == NULL || s_lock == NULL) {
        return;
    }

    /* The common case: nobody asked for a frame, so nothing is copied. */
    if (!s_armed) {
        return;
    }

    if (width != s_width || height != s_height) {
        /* Panel geometry is fixed at boot, so this can only be a caller bug;
         * refuse rather than label a frame with dimensions it does not have. */
        return;
    }

    xSemaphoreTake(s_lock, portMAX_DELAY);

    if (s_state != SNAP_PENDING) {
        /* Either the request was withdrawn while this frame was being
         * composed, or the previous frame is still prepared or leased. Never
         * write over a buffer somebody else may be reading. */
        xSemaphoreGive(s_lock);
        return;
    }

    uint8_t *buf = s_frame;
    buf[0] = 'M';
    buf[1] = 'R';
    buf[2] = 'F';
    buf[3] = '1';
    put_u16(buf + 4, (uint16_t)width);
    put_u16(buf + 6, (uint16_t)height);
    put_u32(buf + 8, sequence);
    buf[12] = brightness;
    buf[13] = (uint8_t)mode;
    buf[14] = flip180 ? 1u : 0u;
    buf[15] = 0u;

    compose(buf + FRAME_SNAPSHOT_HEADER_LEN, rgb, width, height, brightness,
            flip180);

    s_len = (size_t)width * (size_t)height * 3u + FRAME_SNAPSHOT_HEADER_LEN;
    s_state = SNAP_PREPARED;
    s_armed = false;    /* the outstanding request is now a prepared frame */
    s_prepared = true;

    xSemaphoreGive(s_lock);
}

void frame_snapshot_presented(void)
{
    /* The common case: nothing was composed for anybody, so there is no
     * completion to signal. Same task as prepare(), so no lock is needed to
     * read this. */
    if (!s_prepared) {
        return;
    }

    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_prepared = false;
    if (s_state == SNAP_PREPARED) {
        /* Only the frame composed for the request that is still outstanding
         * is completed. A frame prepared for a request that has since timed
         * out has already been dropped by the invalidation below, and this
         * leaves it that way. */
        s_state = SNAP_READY;
        s_ready_gen = s_pending_gen;
        xSemaphoreGive(s_done);
    }
    xSemaphoreGive(s_lock);
}

esp_err_t frame_snapshot_acquire(const uint8_t **bytes, size_t *len,
                                 uint32_t timeout_ms)
{
    if (bytes == NULL || len == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    if (s_frame == NULL || s_lock == NULL) {
        return ESP_ERR_INVALID_STATE;
    }

    xSemaphoreTake(s_lock, portMAX_DELAY);

    if (s_state != SNAP_IDLE) {
        /* One waiter at a time; a second concurrent poll is answered "busy"
         * rather than queued behind the first. */
        xSemaphoreGive(s_lock);
        return ESP_ERR_INVALID_STATE;
    }


    /* Drain stale signals before arming, under the same lock as presented().
     * Draining after unlocking could consume this request's fresh signal. */
    while (xSemaphoreTake(s_done, 0) == pdTRUE) {
    }
    const uint32_t gen = ++s_gen;
    s_pending_gen = gen;
    s_state = SNAP_PENDING;
    s_armed = true;
    xSemaphoreGive(s_lock);


    const TickType_t start = xTaskGetTickCount();
    const TickType_t window = pdMS_TO_TICKS(timeout_ms);
    esp_err_t result = ESP_ERR_TIMEOUT;

    for (;;) {
        const TickType_t elapsed = xTaskGetTickCount() - start;
        if (elapsed >= window) {
            break;
        }
        if (xSemaphoreTake(s_done, window - elapsed) != pdTRUE) {
            break;
        }

        xSemaphoreTake(s_lock, portMAX_DELAY);
        const bool mine = (s_state == SNAP_READY && s_ready_gen == gen);
        if (mine) {
            s_state = SNAP_LEASED;
            *bytes = s_frame;
            *len = s_len;
            result = ESP_OK;
        }
        xSemaphoreGive(s_lock);

        if (mine) {
            return result;
        }
        /* Somebody else's completion: keep waiting for our own, within what
         * is left of the window. */
    }

    /* Cancel only our generation, including a prepared or just-presented
     * frame. A later acquire must request its own fresh frame. */
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (s_pending_gen == gen && s_state != SNAP_LEASED) {
        s_state = SNAP_IDLE;
        s_armed = false;
    }
    xSemaphoreGive(s_lock);

    return ESP_ERR_TIMEOUT;
}

void frame_snapshot_release(void)
{
    if (s_lock == NULL) {
        return;
    }

    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (s_state == SNAP_LEASED) {
        s_state = SNAP_IDLE;
        s_len = 0;
        s_armed = false;
    }
    xSemaphoreGive(s_lock);
}
