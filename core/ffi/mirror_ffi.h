/*
 * mirror_ffi.h - the binding surface for the Flutter layout designer.
 *
 * Deliberately narrow: JSON goes in, pixels come out. The alternative would be
 * exposing ml_layout and ml_widget directly, but those embed fixed-size arrays
 * and would force Dart to replicate C struct padding exactly. That binding
 * would silently break the first time a field is added.
 *
 * So the split is: Dart owns editing (parse, mutate, serialize JSON, which is
 * a few lines with dart:convert), and C owns rendering. The pixel-exactness
 * guarantee is untouched, because C remains the only renderer.
 *
 * Two things deliberately do NOT happen here:
 *
 *   Selection highlights are not drawn. The moment editor chrome lands in the
 *   framebuffer, the preview stops being what the panel shows. Flutter draws
 *   selection as an overlay on top of the image instead.
 *
 *   Two-way mirror dimming is not applied. That simulates glass sitting
 *   between the panel and your eye, not anything the panel does, so it belongs
 *   in the view layer as a colour filter. Brightness IS applied here, because
 *   the device genuinely applies it before gamma.
 *
 * Every returned string and buffer is owned by the ml_sim and stays valid
 * until the next call that changes it, or until ml_sim_destroy. Dart must copy
 * anything it wants to keep.
 *
 * None of this is thread safe. One ml_sim per isolate.
 */
#ifndef MIRROR_FFI_H
#define MIRROR_FFI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#  define ML_EXPORT __declspec(dllexport)
#else
#  define ML_EXPORT __attribute__((visibility("default")))
#endif

typedef struct ml_sim ml_sim;

/* ------------------------------------------------------------- lifecycle */

ML_EXPORT ml_sim *ml_sim_create(void);
ML_EXPORT void    ml_sim_destroy(ml_sim *s);

/* ----------------------------------------------------------------- input */

/*
 * Load a layout from a NUL-terminated JSON string. Returns 1 on success and 0
 * on a hard failure, in which case ml_sim_error explains why and any previously
 * loaded layout is left intact so the designer can keep showing the last good
 * render while the user fixes their edit.
 *
 * Non-fatal problems (unknown widget type, rect off canvas) are reported
 * through ml_sim_diag_* and do not fail the load.
 */
ML_EXPORT int ml_sim_load(ml_sim *s, const char *json);

/* Serialize the loaded layout back to JSON. Round trips through the same
 * writer the device uses, so what the designer saves is what the device reads. */
ML_EXPORT const char *ml_sim_to_json(ml_sim *s);

/* ------------------------------------------------------------ diagnostics */

ML_EXPORT const char *ml_sim_error(const ml_sim *s);
ML_EXPORT int         ml_sim_diag_count(const ml_sim *s);
ML_EXPORT const char *ml_sim_diag_at(const ml_sim *s, int index);

/* -------------------------------------------------------------- geometry */

ML_EXPORT int         ml_sim_width(const ml_sim *s);
ML_EXPORT int         ml_sim_height(const ml_sim *s);
ML_EXPORT const char *ml_sim_name(const ml_sim *s);
ML_EXPORT int         ml_sim_widget_count(const ml_sim *s);

/* Widget rect in canvas pixels. Returns 1 on success, 0 for a bad index. */
ML_EXPORT int ml_sim_widget_rect(const ml_sim *s, int index,
                                 int *x, int *y, int *w, int *h);

ML_EXPORT const char *ml_sim_widget_type(const ml_sim *s, int index);
ML_EXPORT const char *ml_sim_widget_id(const ml_sim *s, int index);

/*
 * What a widget resolves to against the current mock data: the font cut it
 * draws with, and its scale in q8 (256 = 1x). A box resize changes these when
 * fit or a font family is in play, and the inspector shows them as the
 * widget's drawn state. Empty string and 0 for a widget with no text, or a
 * bad index.
 */
ML_EXPORT const char *ml_sim_widget_font(const ml_sim *s, int index);
ML_EXPORT int         ml_sim_widget_scale(const ml_sim *s, int index);

/*
 * Topmost visible widget whose rect covers a canvas pixel, or -1 for none.
 * Done here rather than in Dart so a tap always selects what is actually drawn
 * at that pixel, even if the two models ever disagree.
 */
ML_EXPORT int ml_sim_hit_test(const ml_sim *s, int x, int y);

/* ------------------------------------------------------------- rendering */

/* Mock data fixture, see ml_mock_variant. */
ML_EXPORT void        ml_sim_set_variant(ml_sim *s, int variant);
ML_EXPORT int         ml_sim_variant_count(void);
ML_EXPORT const char *ml_sim_variant_name(int variant);

/* Override the layout's brightness. Pass -1 to use whatever the layout says. */
ML_EXPORT void ml_sim_set_brightness(ml_sim *s, int brightness);

/*
 * Display settings for the preview: the 12/24-hour clock choice and the
 * Fahrenheit/Celsius temperature choice. These mirror the device config keys
 * (clock12h, temp_unit) so the designer shows exactly what a mirror with the
 * same settings would draw. Each takes 1 for 12-hour / Fahrenheit, 0 for
 * 24-hour / Celsius, and survives a variant change.
 */
ML_EXPORT void ml_sim_set_clock12h(ml_sim *s, int on);
ML_EXPORT void ml_sim_set_tempf(ml_sim *s, int on);

/*
 * Render and return width*height*4 bytes of RGBA8888, which is the format
 * Flutter's decodeImageFromPixels wants. Converting here avoids a per-pixel
 * loop in Dart on every repaint.
 *
 * These are the true panel pixels, gamma corrected exactly as the device
 * would. Returns NULL if no layout is loaded.
 */
ML_EXPORT const uint8_t *ml_sim_render_rgba(ml_sim *s);

/* Byte length of the buffer above, or 0 when nothing is loaded. */
ML_EXPORT int ml_sim_rgba_size(const ml_sim *s);

/* ------------------------------------------------------------- catalogue */

/* Fonts and widget types available to this build, for the designer's pickers.
 * Sourced from the engine rather than hardcoded in Dart, so adding a font or
 * widget shows up in the UI without touching the app. */
ML_EXPORT int         ml_sim_font_count(void);
ML_EXPORT const char *ml_sim_font_name(int index);
ML_EXPORT int         ml_sim_font_height(int index);

/*
 * The font's ml_font_role as an int: 0 text, 1 digits, 2 icons. What the picker
 * needs it for is knowing which fonts are not fonts. An icon set draws
 * pictograms from digit codepoints, so offering wx16 as a choice for a label is
 * offering to turn the text into weather symbols.
 */
ML_EXPORT int         ml_sim_font_role(int index);

/*
 * The font families, deduplicated in first-appearance order: "sans", "digits"
 * and friends, each standing for its whole ladder of cuts. The font picker
 * offers these rather than the raw cuts, because choosing a style is a
 * decision and choosing a size is a service the fit machinery provides.
 * A family's role is the role of its first cut; fontgen refuses to compile a
 * family whose cuts disagree.
 */
ML_EXPORT int         ml_sim_family_count(void);
ML_EXPORT const char *ml_sim_family_name(int index);
ML_EXPORT int         ml_sim_family_role(int index);

ML_EXPORT int         ml_sim_type_count(void);
ML_EXPORT const char *ml_sim_type_name(int index);

/* Bindable model paths, so the inspector can offer a list instead of asking
 * the user to remember "weather.temp_c". */
ML_EXPORT int         ml_sim_bind_count(void);
ML_EXPORT const char *ml_sim_bind_at(int index);

/* ------------------------------------------------------------ versioning */

/* Bumped when rendering changes in a way that invalidates golden images. The
 * app compares this against a connected device to warn about a mismatch. */
ML_EXPORT int         ml_sim_render_version(void);
ML_EXPORT const char *ml_sim_version_string(void);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_FFI_H */
