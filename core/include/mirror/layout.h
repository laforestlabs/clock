/*
 * layout.h - the widget tree, and parsing it from JSON.
 *
 * Layout is data, never code. That is what lets the designer push a new layout
 * to a running mirror over the LAN without a reflash, and what lets the same
 * bytes drive the desktop preview.
 *
 * Forward compatibility rule: an unknown widget type or an out-of-range rect is
 * a warning, not an error. A newer designer must never be able to brick an
 * older firmware by sending a layout it does not fully understand.
 */
#ifndef MIRROR_LAYOUT_H
#define MIRROR_LAYOUT_H

#include <stdbool.h>
#include <stddef.h>

#include "mirror/canvas.h"
#include "mirror/color.h"

#ifdef __cplusplus
extern "C" {
#endif

#define ML_MAX_WIDGETS    32
#define ML_NAME_LEN       16
#define ML_FORMAT_LEN     24
#define ML_BIND_LEN       32

/*
 * Upper bound on widget scale. Eight times the tallest font already overflows
 * any panel this drives, and a cap means a typo in a pushed layout cannot turn
 * into an enormous blit.
 */
#define ML_MAX_SCALE      8

typedef enum {
    ML_W_UNKNOWN = 0,
    ML_W_RECT,
    ML_W_LINE,
    ML_W_TEXT,
    ML_W_CLOCK,
    ML_W_DATE,
    ML_W_WEATHER,
    ML_W_ICON,
    ML_W_AGENDA,
    ML_W_TODO
} ml_widget_type;

typedef enum {
    ML_ALIGN_LEFT = 0,
    ML_ALIGN_CENTER,
    ML_ALIGN_RIGHT
} ml_align;

typedef enum {
    ML_VALIGN_TOP = 0,
    ML_VALIGN_MIDDLE,
    ML_VALIGN_BOTTOM
} ml_valign;

typedef struct {
    ml_widget_type type;
    char           type_name[ML_NAME_LEN];  /* as written, for diagnostics */
    char           id[ML_NAME_LEN];         /* optional, for the designer */

    ml_rect        rect;
    bool           visible;

    ml_rgb         color;
    ml_rgb         bg;
    bool           has_bg;
    ml_rgb         accent;      /* secondary color: times, bullets, dim rows */
    bool           has_accent;

    char           font[ML_NAME_LEN];
    char           format[ML_FORMAT_LEN];   /* strftime-ish or printf-ish */
    char           bind[ML_BIND_LEN];       /* dotted model path */
    char           text[ML_FORMAT_LEN];     /* literal text for ML_W_TEXT */
    char           icon_set[ML_NAME_LEN];

    ml_align       align;
    ml_valign      valign;

    /*
     * Whole-pixel glyph scale, 1 or more. Bitmap fonts have no intermediate
     * sizes, so growing text means repeating each pixel rather than resampling.
     */
    int            scale;
    /*
     * Derive scale from the box instead of taking it from the layout, so
     * resizing a widget in the designer grows the text inside it. Overrides
     * scale when set.
     *
     * Both axes are considered. Height alone was enough while every fit widget
     * held one short string, and silently overflowed as soon as the text was
     * long enough to matter.
     */
    bool           fit;

    /*
     * Bounds on whatever fit works out, 0 meaning unset. A headline that shrinks
     * to 1x to fit one long word has stopped being a headline, and a box given
     * more room than anyone intended should not grow into a wall of pixels.
     * An inverted pair is treated as the lower bound rather than as an error,
     * because a layout arriving over the network must not be able to make a
     * widget undrawable.
     */
    int            min_scale;
    int            max_scale;

    /*
     * Let the engine choose the font as well as the size, out of those that can
     * render the string in question. Off by default: naming a font has to keep
     * meaning exactly that font.
     */
    bool           auto_font;

    int            max_items;   /* agenda / todo row cap */
    int            line_gap;    /* extra pixels between rows */
    bool           show_time;   /* agenda: prefix each row with its time */
    bool           hide_done;   /* todo: skip completed entries */
} ml_widget;

typedef struct {
    char      name[ML_NAME_LEN];
    int       w, h;
    ml_rgb    bg;
    uint8_t   brightness;       /* 0..255, applied at export */
    ml_widget widgets[ML_MAX_WIDGETS];
    int       count;
} ml_layout;

#define ML_DIAG_MAX  8
#define ML_DIAG_LEN  96

/* Non-fatal problems found while parsing, surfaced in the designer's UI. */
typedef struct {
    char msg[ML_DIAG_MAX][ML_DIAG_LEN];
    int  count;      /* messages stored, capped at ML_DIAG_MAX */
    int  overflow;   /* messages dropped past the cap */
} ml_diag;

void ml_diag_reset(ml_diag *d);
void ml_diag_add(ml_diag *d, const char *fmt, ...);

/* Set an empty layout of the given size with sane defaults. */
void ml_layout_init(ml_layout *l, int w, int h);

/*
 * Parse layout JSON. Returns false only on a hard error: malformed JSON, or a
 * missing or nonsensical canvas block. Anything else is reported through diag
 * and the layout still renders. Pass diag = NULL to discard warnings.
 */
bool ml_layout_parse(const char *json, size_t len, ml_layout *out, ml_diag *diag);

/*
 * Serialize back to JSON. Returns the number of bytes that would be written,
 * excluding the terminator, so a return >= cap means the output was truncated.
 * Used by the designer's save path and the device's GET /api/layout.
 */
size_t ml_layout_write(const ml_layout *l, char *buf, size_t cap);

/* Map between widget type enum and the JSON spelling. */
ml_widget_type ml_widget_type_from_name(const char *name);
const char    *ml_widget_type_name(ml_widget_type t);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_LAYOUT_H */
