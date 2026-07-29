/*
 * color.h - RGB color type, parsing, and the gamma curve.
 *
 * The gamma table here must match what the panel driver applies on device.
 * esp-hub75 applies a CIE 1931 lightness curve, so the simulator applies the
 * identical table. If these ever diverge, the desktop preview stops predicting
 * what the panel actually looks like, which defeats the whole point.
 */
#ifndef MIRROR_COLOR_H
#define MIRROR_COLOR_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint8_t r, g, b;
} ml_rgb;

#define ML_RGB(rr, gg, bb) ((ml_rgb){(uint8_t)(rr), (uint8_t)(gg), (uint8_t)(bb)})

extern const ml_rgb ml_black;
extern const ml_rgb ml_white;

/*
 * Parse a color string. Accepts "#RGB", "#RRGGBB", with or without the leading
 * '#', plus a small set of names ("black", "white", "red", "green", "blue",
 * "cyan", "magenta", "yellow", "orange", "gray"/"grey").
 * Returns false and leaves *out untouched if the string is not understood.
 */
bool ml_color_parse(const char *s, ml_rgb *out);

/*
 * CIE 1931 perceptual lightness correction for one channel.
 * Applied at scan-out, not during compositing, so that blending math stays
 * linear in the values the layout author typed.
 */
uint8_t ml_gamma8(uint8_t v);

/* Scale a color by brightness 0..255, before gamma. */
ml_rgb ml_rgb_scale(ml_rgb c, uint8_t brightness);

/* Linear interpolation, t in 0..255. */
ml_rgb ml_rgb_lerp(ml_rgb a, ml_rgb b, uint8_t t);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_COLOR_H */
