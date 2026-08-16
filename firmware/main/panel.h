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

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_PANEL_H */
