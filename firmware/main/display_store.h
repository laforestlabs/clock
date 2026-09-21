/*
 * display_store.h - the persistent base display: the clock or one picture.
 *
 * The device's base display is either the clock (the layout the render task
 * draws from layout_store) or a single uploaded picture. A BLE game is a
 * temporary override on top of the base display and is never persisted here;
 * see game_runner. This store only knows which of the two the device saves.
 *
 * The store owns the uploaded picture: it validates and keeps raw, row-major,
 * top-left RGB888 pixels in PSRAM, persists them into one of two SPIFFS slots
 * with a header and a CRC32, and records the choice in NVS as a single state
 * byte. "Raw" matters: these bytes are copied straight into the render task's
 * ml_canvas before the core's gamma transform, so an uploaded picture is
 * colour-corrected exactly once and exactly like a layout.
 *
 * The failure principle is "a picture can never brick the panel": a missing,
 * truncated, oversized or CRC-mismatched slot, a panel too large to hold the
 * payload, an unmounted SPIFFS, and an unreadable NVS record all land on the
 * clock with display_store_picture_ready() false, and every mutation reports
 * a real error instead of pretending to have stored something. Like the
 * layout store, init never stops the device from drawing.
 */
#ifndef MIRROR_DISPLAY_STORE_H
#define MIRROR_DISPLAY_STORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"
#include "mirror/mirror.h"   /* ml_canvas */

#ifdef __cplusplus
extern "C" {
#endif

/*
 * The effective display is "games" only while game_runner owns the panel;
 * everything a user can save is clock or picture. MIRROR_DISPLAY_GAMES
 * exists so /api/status and the BLE reply can name the override with the same
 * type, and is rejected by every function that persists a mode.
 */
typedef enum {
    MIRROR_DISPLAY_CLOCK = 0,
    MIRROR_DISPLAY_GAMES = 1,
    MIRROR_DISPLAY_PICTURE = 2
} mirror_display_mode_t;

/*
 * Bring up the store: mount SPIFFS if the layout store has not, open the
 * NVS namespace, and load the committed picture when the state record names
 * one. Call once at boot, after layout_store_init() and mirror_config_init().
 *
 * Returns ESP_OK on a normal boot, including one with no picture ever stored
 * (that is the default, not a failure). Returns ESP_ERR_NO_MEM or ESP_FAIL
 * when the store genuinely cannot work (mutex, NVS, or SPIFFS); the device
 * still boots and draws the clock and games, picture_ready() stays false, and
 * every mutation is rejected with a real error. Never fatal, never blocks the
 * render task, and it does not need the render task to be running.
 */
esp_err_t display_store_init(void);

/*
 * The saved base display: the clock, or the picture. Never
 * MIRROR_DISPLAY_GAMES, which is a transient override, not a stored choice.
 */
mirror_display_mode_t display_store_base_mode(void);

/*
 * True when a complete, CRC-valid picture for the current panel geometry is
 * loaded and can be rendered. False after a failed or partial load.
 */
bool display_store_picture_ready(void);

/* Stable lowercase name: "clock", "games", "picture". Anything outside the
 * enum falls back to "clock", the boot default. */
const char *display_mode_name(mirror_display_mode_t mode);

/*
 * Persist a new base display. Clock and picture only: MIRROR_DISPLAY_GAMES
 * is rejected (games are started and stopped over Bluetooth), as is any other
 * value.
 *
 * The state byte is committed to NVS before the in-RAM mode changes, so a
 * failure leaves the previous base display in force and nothing half-applied.
 * Selecting clock keeps a saved picture; selecting picture without one is
 * refused as "picture missing" and changes nothing.
 *
 * On failure returns the error and err holds a human message:
 *   ESP_ERR_INVALID_ARG   - not a savable mode
 *   ESP_ERR_INVALID_STATE - picture missing, or the store is not initialised
 *   ESP_FAIL              - NVS/storage could not be written
 */
esp_err_t display_store_set_mode(mirror_display_mode_t mode,
                                 char *err, size_t errsz);

/*
 * Same as display_store_set_mode(), parsed from {"mode":"clock"} or
 * {"mode":"picture"}. Shared by the HTTP handler and the BLE commit worker so
 * both transports accept exactly the same document and produce the same error
 * text. A missing, non-string, "games" or unknown mode is ESP_ERR_INVALID_ARG.
 */
esp_err_t display_store_apply_mode_json(const char *json, size_t len,
                                        char *err, size_t errsz);

/*
 * Store a picture and make it the base display. rgb is raw, row-major,
 * top-left RGB888, pre-gamma, and len must be exactly
 * panel_width() * panel_height() * 3 bytes (at most 256x256, the payload
 * cap); anything else is refused before a byte is written.
 *
 * The inactive slot is written and re-read to verify its header and CRC, and
 * only then is the single NVS state byte committed to select that slot and
 * picture mode. The in-RAM image is swapped only after the commit succeeds,
 * so a failed write leaves the previous picture and mode intact. A successful
 * commit survives reboot even if the HTTP acknowledgement is lost.
 *
 * On failure returns the error and err holds a human message:
 *   ESP_ERR_INVALID_ARG   - NULL/empty payload
 *   ESP_ERR_INVALID_SIZE  - payload is not the panel's exact frame size
 *   ESP_ERR_NOT_SUPPORTED - this panel is too large for a picture payload
 *   ESP_ERR_INVALID_STATE - the store is not initialised
 *   ESP_ERR_NO_MEM        - the PSRAM copy could not be allocated
 *   ESP_FAIL              - SPIFFS or NVS could not be written
 */
esp_err_t display_store_apply_picture(const uint8_t *rgb, size_t len,
                                      char *err, size_t errsz);

/*
 * Copy the stored picture into the render task's canvas when, and only when,
 * picture mode is the base display and a valid image is loaded. Returns false
 * without touching the canvas otherwise, which is the caller's signal to draw
 * the clock layout instead.
 *
 * The copy happens under a short read mutex: no allocation, no flash access,
 * and no writer can hold the lock across a flash write.
 */
bool display_store_render_picture(ml_canvas *canvas);

/*
 * Factory reset: erase the display state record and remove both slot files.
 * A missing record or file is success. Either everything goes or the error is
 * reported with the stored state still in force, so a reset reported as
 * successful can never leave a picture to reappear after the reboot.
 */
esp_err_t display_store_clear(void);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_DISPLAY_STORE_H */
