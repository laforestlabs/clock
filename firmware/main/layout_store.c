/*
 * layout_store.c - the live layout, with SPIFFS persistence.
 *
 * Layouts are pushed as JSON and parsed by the same core parser the boot
 * path and the host tests use. The store holds the parsed ml_layout behind a
 * mutex (the render task reads it every frame while a push may arrive from
 * the HTTP or BLE task), and persists the pushed JSON to SPIFFS so the
 * layout survives a reboot.
 *
 * The failure principle is "no saved layout can brick the device": a corrupt
 * stored file, a crash mid-write, or a partition that never got formatted all
 * land on the embedded layout, which is committed and host-tested.
 */
#include "layout_store.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "esp_log.h"
#include "esp_spiffs.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "config.h"
#include "panel.h"

static const char *TAG = "layout";

#define SPIFFS_PATH     "/spiffs"
#define LAYOUT_FILE     "/spiffs/layout.json"
#define MAX_LAYOUT_BYTES 32768   /* same cap as the LAN/BLE push paths */

static ml_layout           s_layout;
static SemaphoreHandle_t   s_lock;

static void lock(void)   { xSemaphoreTake(s_lock, portMAX_DELAY); }
static void unlock(void) { xSemaphoreGive(s_lock); }

/*
 * Read the whole stored file into a malloc'd buffer, or NULL when there is
 * nothing usable (absent, unreadable, or larger than the cap, which could
 * only be written by a bug and is not worth trusting).
 */
static char *read_stored_layout(size_t *out_len)
{
    FILE *f = fopen(LAYOUT_FILE, "r");
    if (f == NULL) return NULL;

    char *buf = NULL;
    long size;
    if (fseek(f, 0, SEEK_END) == 0 && (size = ftell(f)) > 0 &&
        size <= MAX_LAYOUT_BYTES) {
        rewind(f);
        buf = malloc((size_t)size);
        if (buf != NULL) {
            const size_t got = fread(buf, 1, (size_t)size, f);
            if (got != (size_t)size) {
                free(buf);
                buf = NULL;
            } else if (out_len != NULL) {
                *out_len = got;
            }
        }
    }
    fclose(f);
    return buf;
}

/* Parse json into out; returns true when the layout is usable. */
static bool parse_layout(const char *json, size_t len, ml_layout *out)
{
    ml_diag diag;
    if (!ml_layout_parse(json, len, out, &diag)) {
        for (int i = 0; i < diag.count; i++) {
            ESP_LOGE(TAG, "  %s", diag.msg[i]);
        }
        return false;
    }
    for (int i = 0; i < diag.count; i++) ESP_LOGW(TAG, "  %s", diag.msg[i]);
    return true;
}

static void log_layout(const char *source, const ml_layout *l)
{
    ESP_LOGI(TAG, "layout \"%s\" (%s): %dx%d, %d widgets, brightness %u",
             l->name, source, l->w, l->h, l->count, (unsigned)l->brightness);

    /*
     * A layout authored for a different panel geometry still renders, clipped,
     * because the canvas is the hardware's size. Worth a loud warning though:
     * silently cropping is confusing when half the widgets simply vanish.
     */
    if (l->w != panel_width() || l->h != panel_height()) {
        ESP_LOGW(TAG, "layout is %dx%d but the panel is %dx%d, content will be clipped",
                 l->w, l->h, panel_width(), panel_height());
    }
}

static esp_err_t mount_spiffs(void)
{
    esp_vfs_spiffs_conf_t conf = {
        .base_path              = SPIFFS_PATH,
        .partition_label        = "storage",
        .max_files              = 4,
        /* A virgin or corrupt partition gets formatted and remounted once.
         * The embedded layout is the fallback either way, so losing whatever
         * was stored is never worse than not booting. */
        .format_if_mount_failed = true,
    };

    esp_err_t err = esp_vfs_spiffs_register(&conf);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "could not mount SPIFFS: %s", esp_err_to_name(err));
    }
    return err;
}

esp_err_t layout_store_init(const char *embedded_json, size_t embedded_len)
{
    s_lock = xSemaphoreCreateMutex();
    if (s_lock == NULL) return ESP_ERR_NO_MEM;

    /* SPIFFS failure is not fatal: the embedded layout keeps the panel
     * drawing, and pushes still work in RAM for this boot. */
    mount_spiffs();

    size_t stored_len = 0;
    char *stored = read_stored_layout(&stored_len);

    /* Parse into the heap, never the stack: ml_layout is ~6.6KB and the main
     * task stack is 3584 bytes. PSRAM first, this is a transient block. */
    ml_layout *candidate = heap_caps_malloc(sizeof(ml_layout), MALLOC_CAP_SPIRAM);
    if (candidate == NULL) {
        candidate = heap_caps_malloc(sizeof(ml_layout), MALLOC_CAP_INTERNAL);
    }
    if (candidate == NULL) {
        ESP_LOGE(TAG, "out of memory loading the layout");
        if (stored != NULL) free(stored);
        return ESP_ERR_NO_MEM;
    }

    const char *source;
    bool ok = false;

    if (stored != NULL) {
        ok = parse_layout(stored, stored_len, candidate);
        if (ok) {
            source = "stored in SPIFFS";
        } else {
            ESP_LOGW(TAG, "stored layout did not parse, falling back to embedded");
        }
    }

    if (!ok) {
        if (stored != NULL) {
            free(stored);
            stored = NULL;
        }
        if (!parse_layout(embedded_json, embedded_len, candidate)) {
            /*
             * The embedded layout is committed and covered by the host tests,
             * so this should be impossible. Fall back to an empty canvas of
             * the right size rather than leaving the store uninitialised: a
             * blank panel is recoverable over the network, a crash loop is
             * not.
             */
            ESP_LOGE(TAG, "the embedded layout did not parse, which should not happen");
            ml_layout_init(candidate, panel_width(), panel_height());
        }
        source = "embedded";
    }

    lock();
    s_layout = *candidate;
    unlock();
    log_layout(source, candidate);

    if (stored != NULL) free(stored);
    heap_caps_free(candidate);
    return ESP_OK;
}

void layout_store_snapshot(ml_layout *out)
{
    if (out == NULL) return;
    lock();
    *out = s_layout;
    unlock();
}

/* Best-effort. A crash mid-write leaves a corrupt file, which next boot's
 * parse failure handles by falling back to the embedded layout. No atomic
 * rename dance needed. */
static void persist(const char *json, size_t len)
{
    FILE *f = fopen(LAYOUT_FILE, "w");
    if (f == NULL) {
        ESP_LOGW(TAG, "could not open %s for writing", LAYOUT_FILE);
        return;
    }
    const size_t wrote = fwrite(json, 1, len, f);
    const int err = fclose(f);
    if (wrote != len || err != 0) {
        ESP_LOGW(TAG, "layout persist incomplete (%u/%u bytes)",
                 (unsigned)wrote, (unsigned)len);
    } else {
        ESP_LOGI(TAG, "layout persisted (%u bytes)", (unsigned)len);
    }
}

esp_err_t layout_store_apply(const char *json, size_t len, ml_diag *diag)
{
    if (json == NULL || len == 0 || len > MAX_LAYOUT_BYTES) {
        if (diag != NULL) {
            ml_diag_reset(diag);
            ml_diag_add(diag, "layout is empty or too large");
        }
        return ESP_ERR_INVALID_ARG;
    }

    /* Parse into a heap buffer, never the stack: ml_layout is ~6.6KB and the
     * callers are the httpd task (8KB) and the BLE host task (4KB). PSRAM
     * first, this is a transient 6.6KB block. */
    ml_layout *candidate = heap_caps_malloc(sizeof(ml_layout), MALLOC_CAP_SPIRAM);
    if (candidate == NULL) {
        candidate = heap_caps_malloc(sizeof(ml_layout), MALLOC_CAP_INTERNAL);
    }
    if (candidate == NULL) {
        if (diag != NULL) {
            ml_diag_reset(diag);
            ml_diag_add(diag, "out of memory parsing layout");
        }
        return ESP_ERR_NO_MEM;
    }

    if (!ml_layout_parse(json, len, candidate, diag)) {
        /* Hard parse failure: diag carries the message, nothing changes. */
        heap_caps_free(candidate);
        return ESP_ERR_INVALID_ARG;
    }

    lock();
    s_layout = *candidate;
    unlock();

    /* Brightness is a real device setting applied by the driver in hardware.
     * A manual override (set over BLE) wins over what the layout asks for,
     * so a layout push only dims the panel when no override is set. */
    panel_set_brightness(mirror_config_effective_brightness(candidate->brightness));
    ESP_LOGI(TAG, "layout \"%s\": %dx%d, %d widgets, brightness %u",
             candidate->name, candidate->w, candidate->h, candidate->count,
             (unsigned)candidate->brightness);
    heap_caps_free(candidate);

    persist(json, len);

    /* Warnings are not failures: the layout still renders. */
    return ESP_OK;
}
