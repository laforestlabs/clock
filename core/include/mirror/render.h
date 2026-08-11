/*
 * render.h - the one function that matters.
 *
 * ml_render is pure: no I/O, no clock reads, no allocation, no globals touched.
 * Given the same layout and the same model it produces byte-identical pixels on
 * an ESP32-S3 and on a desktop. That property is the entire reason the layout
 * designer's preview can be trusted, and it is enforced by a test that diffs
 * the device's real framebuffer against a host render of the same inputs.
 *
 * Anything time-dependent must arrive through ml_model, never be read here.
 */
#ifndef MIRROR_RENDER_H
#define MIRROR_RENDER_H

#include "mirror/canvas.h"
#include "mirror/font.h"
#include "mirror/layout.h"
#include "mirror/model.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Render the whole layout, clearing to the layout background first. */
void ml_render(const ml_layout *layout, const ml_model *model, ml_canvas *out);

/* Render a single widget. Exposed so the designer can highlight one in isolation. */
void ml_render_widget(const ml_widget *w, const ml_model *model, ml_canvas *out);

/*
 * The font cut and q8 scale (256 = 1x) a widget draws with against this
 * model, or NULL when it draws no text: a rect, a line, an icon without
 * data, a hidden or zero-size widget. Measures exactly what ml_render_widget
 * would draw, so the designer can report the effect of a box resize without
 * rendering one.
 */
const ml_font *ml_widget_resolve_font(const ml_widget *w, const ml_model *model,
                                      int *scale_q8);

/*
 * Version of the render engine, bumped when output changes in a way that
 * invalidates golden images. Reported by the device so the designer can warn
 * about a mismatch with its own core.
 *
 *   1  initial
 *   2  brightness moved to a linear scale after gamma, matching how the panel
 *      driver actually dims (OE modulation applied after its gamma LUT)
 *   3  per-widget "scale" and "fit". Output for layouts that use neither is
 *      unchanged, but a version 2 device sent a scaled layout draws it at 1x
 *      and silently disagrees with the designer's preview, which is exactly
 *      the mismatch this constant exists to catch.
 *   4  "fit" derives a continuous fixed-point scale instead of the largest
 *      whole multiple, and fractional scales anti-alias. Explicit whole-pixel
 *      "scale" output is unchanged, but a version 3 device floors a fitted
 *      widget to a whole multiple and disagrees with the preview.
 *   5  fitted display text uses one high-resolution master that supports
 *      continuous downscaling, with gamma-compensated area coverage.
 *   6  weather symbols use the same continuous scaling path above and below
 *      their 16px master instead of flooring fitted sizes to integer steps.
 *   7  multi-colour weather icons: wx16 carries four colour planes drawn
 *      through a per-widget palette instead of a single tint.
 *   8  clock faces drop the leading zero from single-digit hours (12-hour
 *      "%l", 24-hour "%k") and the display face's inter-glyph gap tightens
 *      from 3 to 2. Every stock layout's output changes.
 */
#define ML_RENDER_VERSION 8

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_RENDER_H */
