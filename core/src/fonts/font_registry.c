/*
 * font_registry.c - GENERATED FILE, DO NOT EDIT.
 *
 * Regenerate: python3 tools/fontgen.py
 *
 * The first entry is the fallback returned by ml_font_default() when a
 * layout names a font that does not exist, so keep a readable small font
 * first in sort order.
 */
#include "mirror/font.h"

extern const ml_font ml_font_tom5x7;
extern const ml_font ml_font_digits16;
extern const ml_font ml_font_wx16;

const ml_font *const ml_font_registry[3] = {
    &ml_font_tom5x7,
    &ml_font_digits16,
    &ml_font_wx16,
};

const int ml_font_registry_count = 3;
