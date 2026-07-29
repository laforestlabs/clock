/*
 * mirror_cli.c - render a layout to a PNG without any hardware.
 *
 * This is the fastest feedback loop in the project: edit a layout JSON, run
 * this, look at the picture. It is also what produces and checks the golden
 * images, and the --dump flag writes the exact framebuffer bytes the device
 * should produce, which is how the simulator gets held honest.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mirror/mirror.h"
#include "mirror/mock.h"
#include "png_write.h"

static void usage(const char *argv0)
{
    printf(
        "Render a smart-mirror layout to a PNG.\n"
        "\n"
        "Usage: %s <layout.json> [options]\n"
        "\n"
        "Options:\n"
        "  -o <path>     Output PNG (default: out/<layout>-<variant>.png)\n"
        "  -s <n>        Pixel scale, default 6\n"
        "  -m <variant>  Mock data: typical, cold, overflow, evening (default typical)\n"
        "  -b <n>        Override brightness 0-255\n"
        "  --all         Render every mock variant\n"
        "  --led         Draw inter-pixel gaps so it reads as discrete LEDs\n"
        "  --mirror <n>  Simulate two-way mirror transmission, percent (e.g. 20)\n"
        "  --ascii       Also print the result to the terminal\n"
        "  --dump <path> Write raw gamma-corrected RGB888 bytes for device diffing\n"
        "  -h, --help    This message\n",
        argv0);
}

static char *read_file(const char *path, size_t *out_len)
{
    FILE *fp = fopen(path, "rb");
    if (!fp) return NULL;

    fseek(fp, 0, SEEK_END);
    long size = ftell(fp);
    fseek(fp, 0, SEEK_SET);

    if (size < 0) { fclose(fp); return NULL; }

    char *buf = (char *)malloc((size_t)size + 1);
    if (!buf) { fclose(fp); return NULL; }

    size_t got = fread(buf, 1, (size_t)size, fp);
    fclose(fp);

    buf[got] = '\0';
    *out_len = got;
    return buf;
}

static int variant_from_name(const char *s)
{
    for (int i = 0; i < ML_MOCK_VARIANTS; i++) {
        if (strcmp(ml_mock_name(i), s) == 0) return i;
    }
    /* Also accept a bare number so scripts can loop over variants. */
    char *end = NULL;
    long v = strtol(s, &end, 10);
    if (end && *end == '\0' && v >= 0 && v < ML_MOCK_VARIANTS) return (int)v;
    return -1;
}

/* Strip directory and extension so "layouts/dual.json" becomes "dual". */
static void basename_noext(const char *path, char *out, size_t cap)
{
    const char *slash = strrchr(path, '/');
    const char *base  = slash ? slash + 1 : path;

    snprintf(out, cap, "%s", base);
    char *dot = strrchr(out, '.');
    if (dot) *dot = '\0';
}

static void print_ascii(const uint8_t *rgb, int w, int h)
{
    /* Two blocks per pixel keeps the aspect ratio roughly square in a terminal. */
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            const uint8_t *p = rgb + ((size_t)y * (size_t)w + (size_t)x) * 3;
            int lum = (p[0] * 30 + p[1] * 59 + p[2] * 11) / 100;
            const char *cell = lum > 160 ? "██" : lum > 80 ? "▓▓" : lum > 24 ? "░░" : "  ";
            fputs(cell, stdout);
        }
        fputc('\n', stdout);
    }
}

static int render_one(const ml_layout *layout, int variant, const char *out_path,
                      int scale, bool led, int mirror_pct, bool ascii,
                      const char *dump_path, int brightness_override)
{
    ml_model model;
    ml_model_mock(&model, variant);

    ml_canvas canvas;
    if (!ml_canvas_init(&canvas, layout->w, layout->h, NULL)) {
        fprintf(stderr, "error: cannot allocate a %dx%d canvas\n", layout->w, layout->h);
        return 1;
    }

    ml_render(layout, &model, &canvas);

    uint8_t brightness = layout->brightness;
    if (brightness_override >= 0) brightness = (uint8_t)brightness_override;

    size_t nbytes = (size_t)layout->w * (size_t)layout->h * 3;
    uint8_t *rgb = (uint8_t *)malloc(nbytes);
    if (!rgb) {
        ml_canvas_free(&canvas);
        return 1;
    }

    ml_canvas_export_rgb888(&canvas, brightness, rgb);

    /* The dump is written before any mirror simulation, because it has to be
     * exactly what the panel receives for the device diff to mean anything. */
    if (dump_path) {
        FILE *fp = fopen(dump_path, "wb");
        if (!fp) {
            fprintf(stderr, "error: cannot write %s\n", dump_path);
        } else {
            fwrite(rgb, 1, nbytes, fp);
            fclose(fp);
            printf("  dump   %s (%zu bytes)\n", dump_path, nbytes);
        }
    }

    if (mirror_pct > 0 && mirror_pct < 100) {
        /* A two-way mirror passes only a fraction of the light through. This
         * is the check that matters before cutting glass: text that is crisp
         * at full brightness can be unreadable at 20 percent transmission. */
        for (size_t i = 0; i < nbytes; i++) {
            rgb[i] = (uint8_t)((rgb[i] * mirror_pct) / 100);
        }
    }

    bool ok = led
        ? png_write_rgb_led(out_path, rgb, layout->w, layout->h, scale)
        : png_write_rgb(out_path, rgb, layout->w, layout->h, scale);

    if (ok) {
        printf("  %-8s %s (%dx%d at %dx)\n",
               ml_mock_name(variant), out_path, layout->w, layout->h, scale);
    } else {
        fprintf(stderr, "error: cannot write %s\n", out_path);
    }

    if (ascii) print_ascii(rgb, layout->w, layout->h);

    free(rgb);
    ml_canvas_free(&canvas);
    return ok ? 0 : 1;
}

int main(int argc, char **argv)
{
    if (argc < 2) { usage(argv[0]); return 2; }
    if (!strcmp(argv[1], "-h") || !strcmp(argv[1], "--help")) { usage(argv[0]); return 0; }

    const char *layout_path = argv[1];
    const char *out_path    = NULL;
    const char *dump_path   = NULL;
    int  scale      = 6;
    int  variant    = ML_MOCK_TYPICAL;
    int  mirror_pct = 0;
    int  brightness = -1;
    bool led        = false;
    bool ascii      = false;
    bool all        = false;

    for (int i = 2; i < argc; i++) {
        const char *a = argv[i];
        bool has_next = (i + 1 < argc);

        if (!strcmp(a, "-o") && has_next)              out_path = argv[++i];
        else if (!strcmp(a, "-s") && has_next)         scale = atoi(argv[++i]);
        else if (!strcmp(a, "-b") && has_next)         brightness = atoi(argv[++i]);
        else if (!strcmp(a, "--dump") && has_next)     dump_path = argv[++i];
        else if (!strcmp(a, "--mirror") && has_next)   mirror_pct = atoi(argv[++i]);
        else if (!strcmp(a, "--led"))                  led = true;
        else if (!strcmp(a, "--ascii"))                ascii = true;
        else if (!strcmp(a, "--all"))                  all = true;
        else if (!strcmp(a, "-h") || !strcmp(a, "--help")) { usage(argv[0]); return 0; }
        else if (!strcmp(a, "-m") && has_next) {
            variant = variant_from_name(argv[++i]);
            if (variant < 0) {
                fprintf(stderr, "error: unknown mock variant '%s'\n", argv[i]);
                return 2;
            }
        } else {
            fprintf(stderr, "error: unrecognised argument '%s'\n", a);
            usage(argv[0]);
            return 2;
        }
    }

    if (scale < 1)  scale = 1;
    if (scale > 32) scale = 32;

    size_t len = 0;
    char *json = read_file(layout_path, &len);
    if (!json) {
        fprintf(stderr, "error: cannot read %s\n", layout_path);
        return 1;
    }

    ml_layout layout;
    ml_diag   diag;
    bool ok = ml_layout_parse(json, len, &layout, &diag);
    free(json);

    /* Warnings are printed whether or not the parse succeeded, since they are
     * usually the reason a layout does not look the way its author expected. */
    for (int i = 0; i < diag.count; i++) {
        fprintf(stderr, "warning: %s\n", diag.msg[i]);
    }
    if (diag.overflow > 0) {
        fprintf(stderr, "warning: %d further warning(s) suppressed\n", diag.overflow);
    }

    if (!ok) {
        fprintf(stderr, "error: %s could not be parsed\n", layout_path);
        return 1;
    }

    printf("%s: %dx%d, %d widget(s), brightness %u\n",
           layout.name, layout.w, layout.h, layout.count, (unsigned)layout.brightness);

    char stem[64];
    basename_noext(layout_path, stem, sizeof(stem));

    int rc = 0;
    int first = all ? 0 : variant;
    int last  = all ? ML_MOCK_VARIANTS - 1 : variant;

    for (int v = first; v <= last; v++) {
        char generated[256];
        const char *target = out_path;

        if (!target || all) {
            snprintf(generated, sizeof(generated), "out/%s-%s.png", stem, ml_mock_name(v));
            target = generated;
        }
        rc |= render_one(&layout, v, target, scale, led, mirror_pct, ascii,
                         (v == first) ? dump_path : NULL, brightness);
    }

    return rc;
}
