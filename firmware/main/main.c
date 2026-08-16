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

#include "esp_app_desc.h"
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
#include "config.h"
#include "games/game_runner.h"
#include "layout_store.h"
#include "model_store.h"
#include "net/provision.h"
#include "net/sntp_time.h"
#include "net/wifi.h"
#include "net/api_server.h"
#include "net/ota.h"
#if CONFIG_BT_ENABLED
#include "net/ble.h"
#endif
#include "panel.h"
#include "providers/openmeteo.h"
#include "providers/provider.h"

static const char *TAG = "mirror";

/* The default layout, baked in by EMBED_TXTFILES. Same file the designer and
 * the golden-image tests use. */
extern const char layout_json_start[] asm("_binary_mini_json_start");
extern const char layout_json_end[] asm("_binary_mini_json_end");

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
        /* Owner display settings, read fresh so a config push lands at a
         * frame boundary without any extra signalling. */
        model.clock_12h = mirror_config_clock_12h();
        model.temp_f = mirror_config_temp_unit() == 'F';

        if (model.now.valid && !was_synced) {
            ESP_LOGI(TAG, "clock is valid, the panel now shows the real time");
            was_synced = true;
        }

        /*
         * The layout is owned by the layout store, which may swap it out from
         * under us when a push arrives (HTTP or BLE task). Snapshotting keeps
         * the render path free of locks and makes a push take effect at a
         * frame boundary instead of mid-draw. Static: ml_layout is ~6.6KB
         * and only this task reads the buffer.
         */
        static ml_layout layout;
        layout_store_snapshot(&layout);

        /* While a BLE-driven game runs, the panel shows the game instead of
         * the layout. The game draws into the same PSRAM canvas and blits
         * through the same frame buffer at roughly 60 fps; the layout path
         * (and its 500 ms cadence) is untouched for idle frames, so the
         * periodic log stays tied to layout frames. */
        if (game_runner_service()) {
            game_runner_render(&canvas);
            ml_canvas_export_rgb888(&canvas, 255, rgb);
            panel_blit_rgb888(rgb);
            vTaskDelay(pdMS_TO_TICKS(16));
            continue;
        }

        ml_render(&layout, &model, &canvas);

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

void app_main(void)
{
    const char *app_version = esp_app_get_description()->version;
    ESP_LOGI(TAG, "smart mirror app %s, core %s, render engine v%d",
             app_version, ML_VERSION_STR, ML_RENDER_VERSION);

#if CONFIG_BT_ENABLED
    /* The BLE commit worker needs an 8KB contiguous internal stack; claim it
     * now, before panel_init() takes the DMA buffers, or no block that large
     * survives to ble_init(). It just blocks on its queue until a commit
     * arrives. */
    ESP_ERROR_CHECK(ble_commit_init());
#endif

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

    /* The layout store loads the pushed layout from SPIFFS when there is one
     * and falls back to the embedded layout otherwise. */
    ESP_ERROR_CHECK(layout_store_init(layout_json_start,
                                      (size_t)(layout_json_end - layout_json_start)));

    /* Owner config (timezone, coordinates, place, brightness) from NVS,
     * seeded from Kconfig on first boot. Before the boot brightness and the
     * clock sync below: the brightness override must win from the first
     * frame, and sntp_time_start() needs the zone set. */
    ESP_ERROR_CHECK(mirror_config_init());

    /* The game runner's queues, before the render task starts: it drains
     * them every frame. */
    ESP_ERROR_CHECK(game_runner_init());

    /* Static, not stack: ml_layout is ~6.6KB and the main task stack is 3584
     * bytes. The snapshot exists only to read the brightness off. */
    static ml_layout boot;
    layout_store_snapshot(&boot);
    panel_set_brightness(mirror_config_effective_brightness(boot.brightness));
    /* Render before the network comes up, so the panel shows placeholders
     * within a second of power-on instead of staying dark while WiFi
     * associates. */
    /* 8KB rather than the usual 4KB: the widget draw path formats floats, and
     * newlib's float formatting is stack hungry. Overflowing here would look
     * like a random crash rather than a stack problem, and RAM is not scarce. */
    xTaskCreate(render_task, "render", 8192, NULL, 5, NULL);

    /* The render task running means this app demonstrably boots. Cancel the
     * rollback pending state; a crash before this point reverts to the
     * previous image automatically. */
    ota_mark_valid();

    /*
     * Provisioning owns the WiFi lifecycle: it joins the saved network, or
     * opens a captive-portal setup access point when nothing is saved or the
     * saved network does not answer. Either way it returns quickly and the
     * render task keeps drawing placeholders throughout.
     */
    ESP_ERROR_CHECK(provision_init());
    ESP_ERROR_CHECK(provision_start());
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

    /* The LAN API (status/layout/OTA) and the Bluetooth config+layout
     * service. Both are event-driven from here on; the API server starts
     * when the station gets an IP. */
    ESP_ERROR_CHECK(api_server_init());
#if CONFIG_BT_ENABLED
    ESP_ERROR_CHECK(ble_init());
#endif

    ESP_LOGI(TAG, "running");
}
