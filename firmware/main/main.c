/*
 * main.c - smart mirror firmware entry point.
 *
 * M2 scope: bring the panel up, join WiFi, sync the clock, and render the
 * embedded layout continuously. Weather, calendar and todos arrive in M3, and
 * until then those widgets draw their placeholders, which is exactly the
 * "cold" fixture the designer previews.
 *
 * Structure worth noting: nothing in the render path talks to the network, and
 * nothing in the network path touches the panel. The render task reads a
 * snapshot of the model and draws it, so a DNS timeout or a router reboot can
 * never stall or tear the display.
 */
#include <string.h>

#include "esp_err.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs_flash.h"
#include "sdkconfig.h"

#include "mirror/mirror.h"
#include "model_store.h"
#include "net/sntp_time.h"
#include "net/wifi.h"
#include "panel.h"
#include "providers/openmeteo.h"
#include "providers/provider.h"

static const char *TAG = "mirror";

/* The default layout, baked in by EMBED_TXTFILES. Same file the designer and
 * the golden-image tests use. */
extern const char layout_json_start[] asm("_binary_mini_json_start");
extern const char layout_json_end[] asm("_binary_mini_json_end");

static ml_layout s_layout;

/* Two frames a second. The clock only changes once a minute, but a cheap
 * redraw keeps the path warm and makes a hang obvious rather than looking like
 * a static image. */
#define RENDER_PERIOD_MS 500

/* Allocate from PSRAM when it is there, keeping internal SRAM free for the
 * DMA buffer, which is the one allocation that genuinely cannot go elsewhere:
 * PSRAM-backed HUB75 buffers cap the shift clock near 13MHz and flicker. */
static void *alloc_preferring_psram(size_t bytes, const char *what)
{
    void *p = heap_caps_malloc(bytes, MALLOC_CAP_SPIRAM);
    if (p != NULL) {
        ESP_LOGI(TAG, "%s: %u bytes in PSRAM", what, (unsigned)bytes);
        return p;
    }

    p = heap_caps_malloc(bytes, MALLOC_CAP_INTERNAL);
    if (p != NULL) {
        ESP_LOGW(TAG, "%s: %u bytes in internal SRAM (no PSRAM available)",
                 what, (unsigned)bytes);
    }
    return p;
}

static void render_task(void *arg)
{
    (void)arg;

    const int w = panel_width();
    const int h = panel_height();

    ml_rgb *pixels = alloc_preferring_psram((size_t)w * h * sizeof(ml_rgb), "canvas");
    uint8_t *rgb = alloc_preferring_psram((size_t)w * h * 3, "frame buffer");

    if (pixels == NULL || rgb == NULL) {
        ESP_LOGE(TAG, "cannot allocate render buffers for %dx%d", w, h);
        vTaskDelete(NULL);
        return;
    }

    ml_canvas canvas;
    if (!ml_canvas_init(&canvas, w, h, pixels)) {
        ESP_LOGE(TAG, "canvas init failed for %dx%d", w, h);
        vTaskDelete(NULL);
        return;
    }

    ml_model model;
    ml_model_init(&model);

    uint32_t frames = 0;
    bool was_synced = false;

    for (;;) {
        /*
         * Provider-sourced fields come from the shared store. Time and link
         * state are local and free to read, so they are filled per frame
         * instead of going through a provider: the clock keeps ticking at
         * frame rate no matter what the network is doing.
         */
        model_store_snapshot(&model);
        sntp_time_fill(&model.now);
        model.online = wifi_is_connected();
        model.wifi_rssi = wifi_rssi();
        model.uptime_s = (uint32_t)(esp_timer_get_time() / 1000000);

        if (model.now.valid && !was_synced) {
            ESP_LOGI(TAG, "clock is valid, the panel now shows the real time");
            was_synced = true;
        }

        ml_render(&s_layout, &model, &canvas);

        /*
         * Export at full scale. Dimming is the driver's job, done by
         * shortening LED on-time, which keeps the colour depth that scaling
         * these bytes would throw away.
         *
         * These are the exact bytes the golden-image tests hash, which is what
         * makes the device-versus-host framebuffer diff in M4 meaningful.
         */
        ml_canvas_export_rgb888(&canvas, 255, rgb);
        panel_blit_rgb888(rgb);

        /* Roughly every 30 seconds. */
        if ((frames % (30000 / RENDER_PERIOD_MS)) == 0) {
            ESP_LOGI(TAG,
                     "up %lus, wifi %s (%s, %d dBm), clock %s, weather %s, free heap %u",
                     (unsigned long)model.uptime_s,
                     model.online ? "up" : "down",
                     wifi_ip(), model.wifi_rssi,
                     model.now.valid ? "set" : "unset",
                     model.weather.valid ? "ok" : "stale",
                     (unsigned)esp_get_free_heap_size());
        }
        frames++;

        vTaskDelay(pdMS_TO_TICKS(RENDER_PERIOD_MS));
    }
}

static void load_embedded_layout(void)
{
    const size_t len = (size_t)(layout_json_end - layout_json_start);

    ml_diag diag;
    if (!ml_layout_parse(layout_json_start, len, &s_layout, &diag)) {
        /*
         * The embedded layout is committed and covered by the host tests, so
         * this should be impossible. Fall back to an empty canvas of the right
         * size rather than leaving s_layout uninitialised: a blank panel is
         * recoverable over the network in M4, a crash loop is not.
         */
        ESP_LOGE(TAG, "the embedded layout did not parse, which should not happen");
        for (int i = 0; i < diag.count; i++) ESP_LOGE(TAG, "  %s", diag.msg[i]);
        ml_layout_init(&s_layout, panel_width(), panel_height());
        return;
    }

    ESP_LOGI(TAG, "layout \"%s\": %dx%d, %d widgets, brightness %u",
             s_layout.name, s_layout.w, s_layout.h, s_layout.count,
             (unsigned)s_layout.brightness);

    for (int i = 0; i < diag.count; i++) ESP_LOGW(TAG, "  %s", diag.msg[i]);

    /*
     * A layout authored for a different panel geometry still renders, clipped,
     * because the canvas is the hardware's size. Worth a loud warning though:
     * silently cropping is confusing when half the widgets simply vanish.
     */
    if (s_layout.w != panel_width() || s_layout.h != panel_height()) {
        ESP_LOGW(TAG, "layout is %dx%d but the panel is %dx%d, content will be clipped",
                 s_layout.w, s_layout.h, panel_width(), panel_height());
    }
}

void app_main(void)
{
    ESP_LOGI(TAG, "smart mirror, core %s, render engine v%d",
             ML_VERSION_STR, ML_RENDER_VERSION);

    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        /* Happens after a partition table change, which this project has
         * already done once by moving to an OTA-capable layout. */
        ESP_LOGW(TAG, "erasing NVS: %s", esp_err_to_name(err));
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    /* Before the render task, which reads through it every frame. */
    ESP_ERROR_CHECK(model_store_init());

    /*
     * Panel first, deliberately. It needs the largest contiguous block of
     * DMA-capable internal SRAM in the system, and asking for it before WiFi
     * has fragmented the heap is the difference between working and a
     * confusing out-of-memory failure.
     */
    if (panel_init() != ESP_OK) {
        ESP_LOGE(TAG, "panel init failed, halting");
        return;
    }

#if CONFIG_MIRROR_TEST_PATTERN
    panel_test_pattern();
#endif

    load_embedded_layout();
    panel_set_brightness(s_layout.brightness);

    /* Render before the network comes up, so the panel shows placeholders
     * within a second of power-on instead of staying dark while WiFi
     * associates. */
    /* 8KB rather than the usual 4KB: the widget draw path formats floats, and
     * newlib's float formatting is stack hungry. Overflowing here would look
     * like a random crash rather than a stack problem, and RAM is not scarce. */
    xTaskCreate(render_task, "render", 8192, NULL, 5, NULL);

    ESP_ERROR_CHECK(wifi_start());
    sntp_time_start();

    /*
     * Data providers last. They tolerate being offline, backing off and
     * marking their data stale rather than blocking, so there is no need to
     * wait for an association before starting them.
     */
    static ml_provider providers[1];
    int provider_count = 0;

    if (openmeteo_init() == ESP_OK) {
        providers[provider_count++] = *openmeteo_provider();
    } else {
        ESP_LOGE(TAG, "weather disabled: buffers could not be allocated");
    }

    if (provider_count > 0) {
        ESP_ERROR_CHECK(providers_start(providers, provider_count));
    }

    ESP_LOGI(TAG, "running");
}
