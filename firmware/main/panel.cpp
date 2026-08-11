#include "panel.h"

#include <new>

#include "esp_heap_caps.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "hub75.h"
#include "sdkconfig.h"

static const char *TAG = "panel";

static Hub75Driver *s_driver = nullptr;
static int s_width = 0;
static int s_height = 0;

static Hub75ShiftDriver shift_driver_from_config()
{
#if defined(CONFIG_MIRROR_SHIFT_FM6126A)
    return Hub75ShiftDriver::FM6126A;
#elif defined(CONFIG_MIRROR_SHIFT_ICN2038S)
    return Hub75ShiftDriver::ICN2038S;
#elif defined(CONFIG_MIRROR_SHIFT_FM6124)
    return Hub75ShiftDriver::FM6124;
#elif defined(CONFIG_MIRROR_SHIFT_MBI5124)
    return Hub75ShiftDriver::MBI5124;
#elif defined(CONFIG_MIRROR_SHIFT_DP3246)
    return Hub75ShiftDriver::DP3246;
#else
    return Hub75ShiftDriver::GENERIC;
#endif
}

static const char *shift_driver_name()
{
#if defined(CONFIG_MIRROR_SHIFT_FM6126A)
    return "FM6126A";
#elif defined(CONFIG_MIRROR_SHIFT_ICN2038S)
    return "ICN2038S";
#elif defined(CONFIG_MIRROR_SHIFT_FM6124)
    return "FM6124";
#elif defined(CONFIG_MIRROR_SHIFT_MBI5124)
    return "MBI5124";
#elif defined(CONFIG_MIRROR_SHIFT_DP3246)
    return "DP3246";
#else
    return "GENERIC";
#endif
}

extern "C" esp_err_t panel_init(void)
{
    if (s_driver != nullptr) return ESP_OK;

    Hub75Config cfg{};

    cfg.panel_width  = CONFIG_MIRROR_PANEL_WIDTH;
    cfg.panel_height = CONFIG_MIRROR_PANEL_HEIGHT;
    cfg.layout_cols  = CONFIG_MIRROR_PANEL_COLS;
    cfg.layout_rows  = CONFIG_MIRROR_PANEL_ROWS;
    cfg.layout       = Hub75PanelLayout::HORIZONTAL;
    cfg.scan_wiring  = Hub75ScanWiring::STANDARD_TWO_SCAN;
    cfg.shift_driver = shift_driver_from_config();

    cfg.pins.r1  = CONFIG_MIRROR_PIN_R1;
    cfg.pins.g1  = CONFIG_MIRROR_PIN_G1;
    cfg.pins.b1  = CONFIG_MIRROR_PIN_B1;
    cfg.pins.r2  = CONFIG_MIRROR_PIN_R2;
    cfg.pins.g2  = CONFIG_MIRROR_PIN_G2;
    cfg.pins.b2  = CONFIG_MIRROR_PIN_B2;
    cfg.pins.a   = CONFIG_MIRROR_PIN_A;
    cfg.pins.b   = CONFIG_MIRROR_PIN_B;
    cfg.pins.c   = CONFIG_MIRROR_PIN_C;
    cfg.pins.d   = CONFIG_MIRROR_PIN_D;
    cfg.pins.e   = CONFIG_MIRROR_PIN_E;
    cfg.pins.lat = CONFIG_MIRROR_PIN_LAT;
    cfg.pins.oe  = CONFIG_MIRROR_PIN_OE;
    cfg.pins.clk = CONFIG_MIRROR_PIN_CLK;

    cfg.min_refresh_rate = CONFIG_MIRROR_MIN_REFRESH_HZ;
    cfg.brightness       = CONFIG_MIRROR_BRIGHTNESS;

    /* Tear-free updates. The clock changing a digit should not show a partial
     * frame, and the DMA buffer for this geometry is small enough to double. */
    cfg.double_buffer = true;

    s_width  = cfg.panel_width * cfg.layout_cols;
    s_height = cfg.panel_height * cfg.layout_rows;

    ESP_LOGI(TAG, "%dx%d (%dx%d panels of %dx%d), shift driver %s, brightness %d",
             s_width, s_height, cfg.layout_cols, cfg.layout_rows,
             cfg.panel_width, cfg.panel_height,
             shift_driver_name(), cfg.brightness);

    /* The DMA buffer has to come out of internal SRAM. Report what is free
     * before allocating, because "begin() returned false" on its own is a
     * miserable thing to debug and running out of DMA-capable memory is the
     * most likely cause. */
    ESP_LOGI(TAG, "free internal DMA memory before init: %u bytes",
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL));

    s_driver = new (std::nothrow) Hub75Driver(cfg);
    if (s_driver == nullptr) {
        ESP_LOGE(TAG, "could not allocate the driver");
        return ESP_ERR_NO_MEM;
    }

    if (!s_driver->begin()) {
        ESP_LOGE(TAG, "driver begin() failed.");
        ESP_LOGE(TAG, "Most likely causes, in order:");
        ESP_LOGE(TAG, "  1. not enough internal DMA memory for this geometry");
        ESP_LOGE(TAG, "  2. a pin conflict. On an N16R8, GPIO33-37 belong to");
        ESP_LOGE(TAG, "     the octal PSRAM and cannot drive the panel.");
        ESP_LOGE(TAG, "  3. a GPIO that does not exist on this package");
        delete s_driver;
        s_driver = nullptr;
        return ESP_FAIL;
    }

    ESP_LOGI(TAG, "free internal DMA memory after init:  %u bytes",
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL));

    s_driver->clear();
    s_driver->flip_buffer();
    return ESP_OK;
}

extern "C" int panel_width(void) { return s_width; }
extern "C" int panel_height(void) { return s_height; }

extern "C" void panel_blit_rgb888(uint8_t *rgb)
{
    if (s_driver == nullptr || rgb == nullptr) return;

#if CONFIG_MIRROR_SWAP_GB
    /* This panel's green and blue data lines are crossed at the connector:
     * the boot test pattern reads red, blue, green instead of red, green,
     * blue. Compensate here, at the last step before the shift registers, so
     * the render core, the simulator and the golden tests all keep producing
     * the true colours and only this panel's quirk is corrected. The buffer
     * is the caller's per-frame scratch space, so mutating it in place is
     * safe. */
    const int pixels = s_width * s_height;
    for (int i = 0; i < pixels; i++) {
        uint8_t tmp  = rgb[i * 3 + 1];
        rgb[i * 3 + 1] = rgb[i * 3 + 2];
        rgb[i * 3 + 2] = tmp;
    }
#endif

    /* One bulk call rather than a set_pixel loop. For 128x64 that is 8192
     * pixels; per-pixel calls would spend most of their time in call overhead
     * and coordinate remapping that draw_pixels does once. */
    s_driver->draw_pixels(0, 0, (uint16_t)s_width, (uint16_t)s_height,
                          rgb, Hub75PixelFormat::RGB888,
                          Hub75ColorOrder::RGB, false);
    s_driver->flip_buffer();
}

extern "C" void panel_clear(void)
{
    if (s_driver == nullptr) return;
    s_driver->clear();
    s_driver->flip_buffer();
}

extern "C" void panel_set_brightness(uint8_t brightness)
{
    if (s_driver == nullptr) return;
    s_driver->set_brightness(brightness);
}

extern "C" uint8_t panel_get_brightness(void)
{
    return s_driver != nullptr ? s_driver->get_brightness() : 0;
}

extern "C" void panel_test_pattern(void)
{
    if (s_driver == nullptr) return;

    struct Bar {
        uint8_t r, g, b;
        const char *name;
    };
    static const Bar bars[] = {
        {255, 0, 0, "red"},
        {0, 255, 0, "green"},
        {0, 0, 255, "blue"},
        {255, 255, 255, "white"},
    };
    const int count = (int)(sizeof(bars) / sizeof(bars[0]));

    ESP_LOGI(TAG, "test pattern: expect red, green, blue, white bars left to right");
    ESP_LOGW(TAG, "if the colours are in a different order the data pins are swapped");
    ESP_LOGW(TAG, "if the board resets during the white bar the 5V supply is undersized");

    const int bar_w = s_width / count;
    s_driver->clear();
    for (int i = 0; i < count; i++) {
        /* The last bar takes the remainder so nothing is left unlit when the
         * width does not divide evenly. */
        const int w = (i == count - 1) ? (s_width - bar_w * i) : bar_w;
        s_driver->fill((uint16_t)(bar_w * i), 0, (uint16_t)w, (uint16_t)s_height,
                       bars[i].r, bars[i].g, bars[i].b);
    }
    s_driver->flip_buffer();

    vTaskDelay(pdMS_TO_TICKS(2000));

    s_driver->clear();
    s_driver->flip_buffer();
}
