#include "mirror/color.h"

#include <string.h>

const ml_rgb ml_black = {0, 0, 0};
const ml_rgb ml_white = {255, 255, 255};

/* Defined in the generated gamma_table.c. */
extern const uint8_t ml_gamma_table[256];

/* strcasecmp is POSIX, not C99, and this library stays strictly portable. */
static int ci_equal(const char *a, const char *b)
{
    for (;; a++, b++) {
        char ca = *a, cb = *b;
        if (ca >= 'A' && ca <= 'Z') ca = (char)(ca - 'A' + 'a');
        if (cb >= 'A' && cb <= 'Z') cb = (char)(cb - 'A' + 'a');
        if (ca != cb) return 0;
        if (!ca) return 1;
    }
}

static int hex_val(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

struct named_color {
    const char *name;
    ml_rgb      rgb;
};

/* Deliberately small. Layout authors should use hex; these exist so a
 * hand-written layout stays readable for the handful of obvious cases. */
static const struct named_color k_named[] = {
    {"black",   {0, 0, 0}},
    {"white",   {255, 255, 255}},
    {"red",     {255, 0, 0}},
    {"green",   {0, 255, 0}},
    {"blue",    {0, 0, 255}},
    {"cyan",    {0, 255, 255}},
    {"magenta", {255, 0, 255}},
    {"yellow",  {255, 255, 0}},
    {"orange",  {255, 128, 0}},
    {"gray",    {128, 128, 128}},
    {"grey",    {128, 128, 128}},
};

bool ml_color_parse(const char *s, ml_rgb *out)
{
    if (!s || !out) return false;

    while (*s == ' ' || *s == '\t') s++;
    if (*s == '#') s++;

    size_t len = strlen(s);
    while (len > 0 && (s[len - 1] == ' ' || s[len - 1] == '\t')) len--;

    if (len == 6) {
        int v[6];
        for (int i = 0; i < 6; i++) {
            v[i] = hex_val(s[i]);
            if (v[i] < 0) goto try_named;
        }
        out->r = (uint8_t)(v[0] * 16 + v[1]);
        out->g = (uint8_t)(v[2] * 16 + v[3]);
        out->b = (uint8_t)(v[4] * 16 + v[5]);
        return true;
    }

    if (len == 3) {
        int v[3];
        for (int i = 0; i < 3; i++) {
            v[i] = hex_val(s[i]);
            if (v[i] < 0) goto try_named;
        }
        /* Expand nibble to byte so 0xF becomes 0xFF, not 0xF0. */
        out->r = (uint8_t)(v[0] * 17);
        out->g = (uint8_t)(v[1] * 17);
        out->b = (uint8_t)(v[2] * 17);
        return true;
    }

try_named:
    for (size_t i = 0; i < sizeof(k_named) / sizeof(k_named[0]); i++) {
        if (ci_equal(s, k_named[i].name)) {
            *out = k_named[i].rgb;
            return true;
        }
    }
    return false;
}

ml_rgb ml_rgb_scale(ml_rgb c, uint8_t brightness)
{
    if (brightness == 255) return c;
    ml_rgb r;
    r.r = (uint8_t)((c.r * brightness + 127) / 255);
    r.g = (uint8_t)((c.g * brightness + 127) / 255);
    r.b = (uint8_t)((c.b * brightness + 127) / 255);
    return r;
}

ml_rgb ml_rgb_lerp(ml_rgb a, ml_rgb b, uint8_t t)
{
    ml_rgb r;
    r.r = (uint8_t)((a.r * (255 - t) + b.r * t + 127) / 255);
    r.g = (uint8_t)((a.g * (255 - t) + b.g * t + 127) / 255);
    r.b = (uint8_t)((a.b * (255 - t) + b.b * t + 127) / 255);
    return r;
}
