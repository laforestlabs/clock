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
#include "mirror/layout.h"
#include "mirror/model.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Render the whole layout, clearing to the layout background first. */
void ml_render(const ml_layout *layout, const ml_model *model, ml_canvas *out);

/* Render a single widget. Exposed so the designer can highlight one in isolation. */
void ml_render_widget(const ml_widget *w, const ml_model *model, ml_canvas *out);

/* Version of the render engine, bumped when output changes in a way that
 * invalidates golden images. Reported by the device so the designer can warn
 * about a mismatch with its own core. */
#define ML_RENDER_VERSION 1

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_RENDER_H */
