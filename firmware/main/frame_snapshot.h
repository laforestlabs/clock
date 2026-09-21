/*
 * frame_snapshot.h - the frame the panel really showed, captured for the app.
 *
 * The device dashboard shows a small preview of what each mirror is actually
 * displaying, and the app cannot reproduce it: a game, a pushed layout and an
 * uploaded picture all end up in the same canvas, and the panel driver then
 * rotates and channel-swaps the pixels on their way to the shift registers.
 * This module captures the composited frame in the render task and hands one
 * copy at a time to the LAN handler that serves GET /api/frame.
 *
 * Capture is a copy, made only while somebody is waiting for one:
 *
 *   - The render task calls frame_snapshot_prepare() with the exported,
 *     full-scale RGB888 frame immediately before panel_blit_rgb888(), which
 *     mutates that same buffer for flip180 and panel wiring. The copy is taken
 *     before the mutation, so the snapshot is the picture as the app should
 *     draw it: gamma corrected once, brightness scaled here, rotated 180
 *     degrees when the panel is mounted upside down, and never channel
 *     swapped. The app renders the bytes as they arrive and applies none of
 *     those steps again.
 *   - frame_snapshot_presented() follows the blit, so a frame is only leased
 *     to an acquirer after the panel really showed it.
 *
 * One buffer (header plus one panel frame) is allocated at init. There is no
 * per-frame allocation and no lock is ever held across socket I/O. An idle
 * mirror pays a single boolean load per frame; a snapshot allocation that
 * fails leaves the clock and the games drawing exactly as before.
 *
 * Wire format of one snapshot, little-endian:
 *
 *   bytes 0..3   ASCII "MRF1"
 *   bytes 4..5   u16 width
 *   bytes 6..7   u16 height
 *   bytes 8..11  u32 frame sequence (per displayed frame, resets on reboot)
 *   byte  12     u8 brightness the frame was scaled to (0..255)
 *   byte  13     u8 mirror_display_mode_t of the frame (clock/games/picture)
 *   byte  14     u8 flip180 the rotation applied (0 or 1), for diagnostics
 *   byte  15     reserved, zero
 *   then         exactly width*height*3 bytes of packed RGB888
 *
 * The sequence identifies one sampling, not a device: it is how the app can
 * tell that two responses are the same frame.
 */
#ifndef MIRROR_FRAME_SNAPSHOT_H
#define MIRROR_FRAME_SNAPSHOT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "display_store.h"   /* mirror_display_mode_t */
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/* "MRF1" plus dimensions, sequence, brightness, mode, flip and a reserved
 * byte, then the pixels. */
#define FRAME_SNAPSHOT_HEADER_LEN 16u

/*
 * Bring up the snapshot: create the state mutex, the completion semaphore and
 * the single PSRAM frame buffer, sized from panel_width()/panel_height().
 * Call once at boot, after panel_init(), before the render task starts.
 *
 * A failure is never fatal. The device still draws the clock, the games and
 * the picture; every acquire then reports ESP_ERR_INVALID_STATE and the LAN
 * handler answers 503, which is exactly what "no preview" means. Returns
 * ESP_ERR_NOT_SUPPORTED when this panel is too large for the picture payload
 * cap (such a build does not advertise the display API either), and
 * ESP_ERR_NO_MEM when the buffer cannot be allocated. Safe to call more than
 * once: the first call decides the outcome and later calls return it without
 * allocating again.
 */
esp_err_t frame_snapshot_init(void);

/*
 * Capture the frame the panel is about to show. Call from the render task,
 * immediately before panel_blit_rgb888(), with the frame it is about to blit:
 * the brightness and rotational compensation are applied to the copy here,
 * because the blit mutates rgb in place.
 *
 * rgb is the full-scale (brightness 255) gamma-corrected export, width x
 * height pixels. mode is the mode that frame was composed from, so a game
 * frame reports games even while the saved base display is the clock.
 *
 * Cheap and safe to call on every frame: with no request outstanding it does
 * one boolean check and returns without touching the pixels. A frame is only
 * composed when an acquirer is waiting, and never over a buffer an acquirer
 * is still reading.
 */
void frame_snapshot_prepare(const uint8_t *rgb, int width, int height,
                            uint32_t sequence, uint8_t brightness,
                            bool flip180, mirror_display_mode_t mode);

/*
 * The blit has happened. Call from the render task right after
 * panel_blit_rgb888(); this is what lets a waiting acquire see the frame as
 * one the panel showed rather than one that was composed and then discarded.
 * A no-op when no frame was prepared.
 */
void frame_snapshot_presented(void);

/*
 * Lease the most recent presented frame: on success *bytes points at the
 * header followed by width*height*3 pixels and *len is the total, and the
 * caller must call frame_snapshot_release() once it is done with them,
 * whether sending them succeeded or failed.
 *
 * Arms a fresh request and waits up to timeout_ms for the render task to
 * prepare and present it. One request is served at a time: a concurrent
 * acquire reports ESP_ERR_INVALID_STATE rather than queueing.
 * ESP_ERR_TIMEOUT invalidates this request's frame and completion; neither
 * can satisfy a later acquire.
 */
esp_err_t frame_snapshot_acquire(const uint8_t **bytes, size_t *len,
                                 uint32_t timeout_ms);

/*
 * End a lease. Always call it after a successful acquire, after the bytes
 * have been copied into the response, so the render task may write the buffer
 * again. A no-op when nothing is leased.
 */
void frame_snapshot_release(void);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_FRAME_SNAPSHOT_H */
