#include "panel.h"

#include <new>

#include "esp_heap_caps.h"
#include "esp_log.h"
#include "hub75.h"
#include "sdkconfig.h"

static const char *TAG = "panel";

static Hub75Driver *s_driver = nullptr;
static int s_width = 0;
static int s_height = 0;
/* Physical mount, not a layout property: true when the panel is upside down
 * and every blit must be rotated 180 degrees to compensate. */
static bool s_flip180 = false;

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
/* The S3 derives the HUB75 clock from a 160MHz PLL with an integer divider,
 * so any requested MHz resolves to the nearest 160/N. Cast through the enum's
 * underlying type rather than enumerating the driver's fixed choices, so
 * MIRROR_PANEL_CLOCK_MHZ can pick any value (e.g. 9 -> 8.89MHz). */
static Hub75ClockSpeed clock_speed_from_config()
{
    return static_cast<Hub75ClockSpeed>(CONFIG_MIRROR_PANEL_CLOCK_MHZ * 1000000u);
}

extern "C" esp_err_t panel_init(void)
{
    if (s_driver != nullptr) return ESP_OK;

#if CONFIG_MIRROR_NO_PANEL
    /* Diagnostic: keep the render path (and its CPU load) but never bring up
     * the driver, so no DMA runs and no panel GPIOs switch. Isolates panel
     * EMI and bus contention from WiFi problems. All blit/clear/brightness
     * calls below already no-op while s_driver is null. */
    s_width  = CONFIG_MIRROR_PANEL_WIDTH * CONFIG_MIRROR_PANEL_COLS;
    s_height = CONFIG_MIRROR_PANEL_HEIGHT * CONFIG_MIRROR_PANEL_ROWS;
    ESP_LOGW(TAG, "panel disabled (MIRROR_NO_PANEL): %dx%d off-panel render",
             s_width, s_height);
    return ESP_OK;
#endif

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

    cfg.output_clock_speed = clock_speed_from_config();
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

extern "C" bool panel_supports_picture(void)
{
    /* 64-bit arithmetic: the dimensions come from Kconfig and two large
     * ints overflow their own product long before the byte count does. */
    if (s_width <= 0 || s_height <= 0) return false;
    return (int64_t)s_width * s_height * 3 <= PANEL_PICTURE_MAX_BYTES;
}

extern "C" void panel_blit_rgb888(uint8_t *rgb)
{
    if (s_driver == nullptr || rgb == nullptr) return;

    /*
     * A panel mounted upside down shows the whole frame rotated 180 degrees,
     * so rotate it here, the last step before the shift registers. It lives in
     * the panel and not in the render core because the core's output has to
     * stay byte-identical to the host golden images: an installation quirk is
     * not part of the layout. Reverse the row order, then reverse the pixel
     * order within each row; reversing rows alone would be a mirror, not a
     * rotation. 64x32, so this is a few thousand byte moves through one 3-byte
     * temporary and nothing is allocated.
     */
    if (s_flip180) {
        const size_t row_bytes = (size_t)s_width * 3;
        uint8_t *top = rgb;
        uint8_t *bot = rgb + (size_t)(s_height - 1) * row_bytes;
        while (top < bot) {
            for (size_t i = 0; i < row_bytes; i++) {
                const uint8_t tmp = top[i];
                top[i] = bot[i];
                bot[i] = tmp;
            }
            top += row_bytes;
            bot -= row_bytes;
        }
        for (int y = 0; y < s_height; y++) {
            uint8_t *l = rgb + (size_t)y * row_bytes;
            uint8_t *r = l + row_bytes - 3;
            while (l < r) {
                for (int c = 0; c < 3; c++) {
                    const uint8_t tmp = l[c];
                    l[c] = r[c];
                    r[c] = tmp;
                }
                l += 3;
                r -= 3;
            }
        }
    }

#if CONFIG_MIRROR_SWAP_GB
    /* This panel's green and blue data lines are crossed at the connector:
     * blue comes out on the green line and vice versa. Compensate here, at
     * the last step before the shift registers, so
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

extern "C" void panel_set_flip180(bool on)
{
    /* The value lives here, not in the driver, so it is kept even while the
     * panel is down (MIRROR_NO_PANEL): the next blit picks it up. */
    s_flip180 = on;
}
