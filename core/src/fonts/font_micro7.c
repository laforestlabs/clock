/*
 * font_micro7.c - GENERATED FILE, DO NOT EDIT.
 *
 * Source:      fonts/micro7.font
 * Regenerate:  python3 tools/fontgen.py
 *
 * 10 glyphs, codepoints 48 to 57, role digits, 
 * cell height 7, baseline 7, 1 plane(s), 70 bytes of bitmap.
 */
#include "mirror/font.h"

static const uint8_t s_micro7_bitmap[70] = {
    /* 48 '0' width 3 */
    0xE0,                   /* |###| */
    0xA0,                   /* |# #| */
    0xA0,                   /* |# #| */
    0xA0,                   /* |# #| */
    0xA0,                   /* |# #| */
    0xA0,                   /* |# #| */
    0xE0,                   /* |###| */
    /* 49 '1' width 3 */
    0x20,                   /* |  #| */
    0x60,                   /* | ##| */
    0x20,                   /* |  #| */
    0x20,                   /* |  #| */
    0x20,                   /* |  #| */
    0x20,                   /* |  #| */
    0xE0,                   /* |###| */
    /* 50 '2' width 3 */
    0xC0,                   /* |## | */
    0x20,                   /* |  #| */
    0x20,                   /* |  #| */
    0x40,                   /* | # | */
    0x80,                   /* |#  | */
    0x80,                   /* |#  | */
    0xE0,                   /* |###| */
    /* 51 '3' width 3 */
    0xC0,                   /* |## | */
    0x20,                   /* |  #| */
    0x20,                   /* |  #| */
    0x60,                   /* | ##| */
    0x20,                   /* |  #| */
    0x20,                   /* |  #| */
    0xC0,                   /* |## | */
    /* 52 '4' width 3 */
    0xA0,                   /* |# #| */
    0xA0,                   /* |# #| */
    0xA0,                   /* |# #| */
    0xE0,                   /* |###| */
    0x20,                   /* |  #| */
    0x20,                   /* |  #| */
    0x20,                   /* |  #| */
    /* 53 '5' width 3 */
    0xE0,                   /* |###| */
    0x80,                   /* |#  | */
    0x80,                   /* |#  | */
    0xC0,                   /* |## | */
    0x20,                   /* |  #| */
    0x20,                   /* |  #| */
    0xC0,                   /* |## | */
    /* 54 '6' width 3 */
    0x60,                   /* | ##| */
    0x80,                   /* |#  | */
    0x80,                   /* |#  | */
    0xC0,                   /* |## | */
    0xA0,                   /* |# #| */
    0xA0,                   /* |# #| */
    0xE0,                   /* |###| */
    /* 55 '7' width 3 */
    0xE0,                   /* |###| */
    0x20,                   /* |  #| */
    0x20,                   /* |  #| */
    0x40,                   /* | # | */
    0x40,                   /* | # | */
    0x40,                   /* | # | */
    0x40,                   /* | # | */
    /* 56 '8' width 3 */
    0xE0,                   /* |###| */
    0xA0,                   /* |# #| */
    0xA0,                   /* |# #| */
    0xE0,                   /* |###| */
    0xA0,                   /* |# #| */
    0xA0,                   /* |# #| */
    0xE0,                   /* |###| */
    /* 57 '9' width 3 */
    0xE0,                   /* |###| */
    0xA0,                   /* |# #| */
    0xA0,                   /* |# #| */
    0xE0,                   /* |###| */
    0x20,                   /* |  #| */
    0x20,                   /* |  #| */
    0xC0,                   /* |## | */
};

static const uint8_t s_micro7_widths[10] = {
     3,  3,  3,  3,  3,  3,  3,  3,  3,  3,
};

static const uint16_t s_micro7_offsets[10] = {
        0,     7,    14,    21,    28,    35,    42,    49,    56,    63,
};

const ml_font ml_font_micro7 = {
    .name     = "micro7",
    .role     = ML_FONT_DIGITS,
    .first    = 48,
    .count    = 10,
    .height   = 7,
    .baseline = 7,
    .gap      = 1,
    .planes   = 1,
    .widths   = s_micro7_widths,
    .offsets  = s_micro7_offsets,
    .bitmap   = s_micro7_bitmap,
    .family   = "micro",
    .smooth   = false,
    .downscale = false,
};
