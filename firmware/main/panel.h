/*
 * panel.h - HUB75 output.
 *
 * A C facade over esp-hub75, which is C++. Keeping the boundary here means the
 * rest of the firmware stays C and the render core never learns that a display
 * driver exists.
 *
 * Brightness is handled by the driver in hardware, by shortening LED on-time.
 * That is deliberate: scaling colour values instead would work, but it throws
 * away colour depth, and at the low settings a mirror behind two-way glass
 * actually runs at there is very little depth left to lose. So frames are
 * blitted at full scale and the driver dims them.
 */
#ifndef MIRROR_PANEL_H
#define MIRROR_PANEL_H

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Bring up the panel and start DMA refresh. After this returns the panel is
 * scanning continuously with no further CPU involvement, so a busy or blocked
 * application task cannot make the image flicker or tear.
 */
esp_err_t panel_init(void);

/* Full canvas size across all chained panels, in pixels. */
int panel_width(void);
int panel_height(void);

/*
 * Ceiling on an RGB888 picture payload: 256x256 pixels, 196608 bytes. It is
 * the router's payload cap, not a panel property, but the two are compared
 * together everywhere a picture is accepted, so they live next to the
 * geometry they are checked against.
 */
#define PANEL_PICTURE_MAX_BYTES (256 * 256 * 3)

/*
 * True when this panel's frame fits the picture payload cap, i.e. the build
 * can store and render an uploaded picture. Bigger builds still draw the
 * clock and the games; they just do not advertise the picture display
 * contract, so the app offers the clock instead of a doomed upload.
 */
bool panel_supports_picture(void);

/*
 * Blit a full frame. Expects panel_width() * panel_height() * 3 bytes of
 * packed RGB888, already gamma corrected, which is exactly what
 * ml_canvas_export_rgb888 produces at brightness 255.
 *
 * Do not gamma correct twice: the driver's own CIE 1931 pass is disabled in
 * sdkconfig.defaults precisely so the core stays the single implementation.
 *
 * With CONFIG_MIRROR_SWAP_GB the green and blue channels are exchanged in
 * place first, correcting a panel whose data lines are crossed; rgb must
 * then be writable scratch memory.
 */
void panel_blit_rgb888(uint8_t *rgb);

void panel_clear(void);

void    panel_set_brightness(uint8_t brightness);
uint8_t panel_get_brightness(void);

/*
 * Physical-mount compensation: true when the panel is installed upside down,
 * in which case every blit is rotated 180 degrees on the way to the shift
 * registers. This corrects the hardware, so it covers the whole canvas at
 * once, the layout frames and the BLE game frames alike; the layout itself is
 * never mirrored. panel_blit_rgb888 already documents rgb as writable scratch,
 * which is what the in-place rotation needs.
 */
void panel_set_flip180(bool on);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_PANEL_H */
