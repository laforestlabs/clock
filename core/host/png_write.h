/*
 * png_write.h - minimal PNG output, no zlib.
 *
 * Host-side only: used by the CLI harness and the golden-image tests. It emits
 * uncompressed ("stored") deflate blocks, which are perfectly legal zlib, so
 * the whole build needs nothing but a C compiler. Files are larger than a real
 * encoder would produce, which does not matter for 128x64 test output.
 */
#ifndef MIRROR_PNG_WRITE_H
#define MIRROR_PNG_WRITE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Write w*h packed RGB888 bytes to path as a PNG.
 * scale nearest-neighbour upscales each pixel to a scale x scale block, which
 * is what makes a 64px panel legible on a desktop monitor. Pass 1 for exact.
 */
bool png_write_rgb(const char *path, const uint8_t *rgb, int w, int h, int scale);

/*
 * Same, but draws a one-pixel dark gap between pixels so the output reads as
 * discrete LEDs rather than a smooth image. Only meaningful when scale >= 3.
 */
bool png_write_rgb_led(const char *path, const uint8_t *rgb, int w, int h, int scale);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_PNG_WRITE_H */
