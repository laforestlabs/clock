/*
 * test_core.c - unit tests plus golden-image regression tests.
 *
 * Run from the core directory: make -f Makefile.host test
 *
 * The golden tests hash the exact bytes the panel would receive, so any change
 * in glyphs, gamma, layout parsing, or widget drawing shows up immediately. On
 * a mismatch the actual frame is written to out/ as a PNG so the difference can
 * be inspected rather than guessed at.
 *
 * To accept intentional rendering changes:
 *     MIRROR_UPDATE_GOLDEN=1 make -f Makefile.host test
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mirror/json.h"
#include "mirror/mirror.h"
#include "mirror/mock.h"
#include "mirror_ffi.h"
#include "png_write.h"

static int g_checks;
static int g_fails;
static const char *g_group = "";

static void check(bool ok, const char *what, int line)
{
    g_checks++;
    if (!ok) {
        g_fails++;
        printf("  FAIL  [%s:%d] %s\n", g_group, line, what);
    }
}

#define CHECK(ok, what) check((ok), (what), __LINE__)

static void group(const char *name)
{
    g_group = name;
    printf("%s\n", name);
}

/* ------------------------------------------------------------- utilities */

static uint64_t fnv1a(const uint8_t *data, size_t n)
{
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < n; i++) {
        h ^= data[i];
        h *= 1099511628211ULL;
    }
    return h;
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
    if (out_len) *out_len = got;
    return buf;
}

/* ------------------------------------------------------------ unit tests */

static void test_color(void)
{
    group("color");

    ml_rgb c;
    CHECK(ml_color_parse("#FF8000", &c) && c.r == 255 && c.g == 128 && c.b == 0,
          "six digit hex");
    CHECK(ml_color_parse("FF8000", &c) && c.r == 255, "hex without leading hash");
    /* A nibble must expand to 0xFF, not 0xF0, or bright colours come out dim. */
    CHECK(ml_color_parse("#F80", &c) && c.r == 255 && c.g == 136 && c.b == 0,
          "three digit hex expands per nibble");
    CHECK(ml_color_parse("cyan", &c) && c.r == 0 && c.g == 255 && c.b == 255,
          "named colour");
    CHECK(ml_color_parse("CYAN", &c), "named colour is case insensitive");
    CHECK(!ml_color_parse("#GGGGGG", &c), "invalid hex rejected");
    CHECK(!ml_color_parse("chartreuse", &c), "unknown name rejected");

    /* Whitespace is measured off both ends, and used to be honoured on the
     * leading side only, so "red " failed where " red" worked. */
    CHECK(ml_color_parse(" red", &c) && c.r == 255 && c.g == 0, "leading space ignored");
    CHECK(ml_color_parse("red ", &c) && c.r == 255 && c.g == 0, "trailing space ignored");
    CHECK(ml_color_parse("  RED  ", &c) && c.r == 255, "space around a named colour");
    CHECK(ml_color_parse("#00FF00 ", &c) && c.g == 255, "trailing space after hex");
    CHECK(!ml_color_parse("red x", &c), "a trailing word is still rejected");

    CHECK(ml_gamma8(0) == 0, "gamma maps 0 to 0");
    CHECK(ml_gamma8(255) == 255, "gamma maps 255 to 255");

    bool monotonic = true;
    for (int i = 1; i < 256; i++) {
        if (ml_gamma8((uint8_t)i) < ml_gamma8((uint8_t)(i - 1))) monotonic = false;
    }
    CHECK(monotonic, "gamma is monotonic");
    /* 50 percent perceptual lightness is about 18 percent linear luminance. */
    CHECK(ml_gamma8(128) > 40 && ml_gamma8(128) < 55, "gamma midpoint is CIE-like");
}

static void test_rect(void)
{
    group("rect");

    ml_rect a = ML_RECT(0, 0, 10, 10);
    ml_rect b = ML_RECT(5, 5, 10, 10);
    ml_rect i = ml_rect_intersect(a, b);
    CHECK(i.x == 5 && i.y == 5 && i.w == 5 && i.h == 5, "overlapping intersect");

    ml_rect none = ml_rect_intersect(a, ML_RECT(20, 20, 5, 5));
    CHECK(ml_rect_is_empty(none), "disjoint intersect is empty");

    /* Must not produce a negative width, which would wrap in loop bounds. */
    CHECK(none.w >= 0 && none.h >= 0, "empty intersect has non-negative extent");

    CHECK(ml_rect_contains(a, 0, 0), "contains top-left corner");
    CHECK(!ml_rect_contains(a, 10, 10), "excludes bottom-right corner");
}

static void test_canvas_clip(void)
{
    group("canvas clip");

    ml_canvas c;
    CHECK(ml_canvas_init(&c, 16, 16, NULL), "canvas init");
    ml_canvas_clear(&c, ml_black);

    ml_canvas_push_clip(&c, ML_RECT(4, 4, 4, 4));
    ml_canvas_fill_rect(&c, ML_RECT(0, 0, 16, 16), ml_white);
    ml_canvas_pop_clip(&c);

    CHECK(ml_canvas_get(&c, 5, 5).r == 255, "inside clip is drawn");
    CHECK(ml_canvas_get(&c, 1, 1).r == 0, "outside clip is untouched");

    /* Nested clips must intersect, so a child cannot escape its parent. */
    ml_canvas_clear(&c, ml_black);
    ml_canvas_push_clip(&c, ML_RECT(0, 0, 8, 8));
    ml_canvas_push_clip(&c, ML_RECT(4, 4, 8, 8));
    ml_canvas_fill_rect(&c, ML_RECT(0, 0, 16, 16), ml_white);
    ml_canvas_pop_clip(&c);
    ml_canvas_pop_clip(&c);

    CHECK(ml_canvas_get(&c, 5, 5).r == 255, "nested clip keeps the overlap");
    CHECK(ml_canvas_get(&c, 9, 9).r == 0, "nested clip drops the parent's excess");

    /* Overflowing the clip stack must fail loudly, not corrupt it. */
    for (int i = 0; i < ML_CLIP_STACK_DEPTH; i++) {
        ml_canvas_push_clip(&c, ML_RECT(0, 0, 16, 16));
    }
    CHECK(!ml_canvas_push_clip(&c, ML_RECT(0, 0, 16, 16)),
          "clip stack overflow is refused");

    ml_canvas_free(&c);
}

static void test_json(void)
{
    group("json");

    static const char doc[] =
        "{\"a\": 1, \"b\": \"two\", \"c\": [10, 20, 30],"
        " \"d\": {\"e\": true}, \"f\": -2.5, \"g\": \"x\\u00b0y\"}";

    ml_json_tok toks[64];
    ml_json j;
    int n = ml_json_parse(&j, doc, strlen(doc), toks, 64);
    CHECK(n > 0, "parses a nested document");

    int v;
    CHECK(ml_json_get_int(&j, 0, "a", &v) && v == 1, "integer member");

    char s[32];
    CHECK(ml_json_get_str(&j, 0, "b", s, sizeof(s)) && !strcmp(s, "two"), "string member");

    int arr = ml_json_member(&j, 0, "c");
    CHECK(ml_json_array_count(&j, arr) == 3, "array length");
    CHECK(ml_json_int(&j, ml_json_array_at(&j, arr, 1), &v) && v == 20, "array element");

    int obj = ml_json_member(&j, 0, "d");
    bool b = false;
    CHECK(ml_json_get_bool(&j, obj, "e", &b) && b, "nested object member");

    double d;
    CHECK(ml_json_get_double(&j, 0, "f", &d) && d < -2.49 && d > -2.51, "negative double");

    /* The degree escape has to land on codepoint 127, where the font keeps it. */
    CHECK(ml_json_get_str(&j, 0, "g", s, sizeof(s)) &&
          s[0] == 'x' && (unsigned char)s[1] == 127 && s[2] == 'y',
          "\\u00b0 maps to the degree glyph");

    CHECK(ml_json_member(&j, 0, "missing") < 0, "absent key returns -1");

    /* Malformed input must be rejected rather than half-accepted. */
    static const char bad1[] = "{\"a\": 1";
    CHECK(ml_json_parse(&j, bad1, strlen(bad1), toks, 64) == ML_JSON_ERR_PARTIAL,
          "truncated document rejected");

    static const char bad2[] = "{\"a\": [1, 2}";
    CHECK(ml_json_parse(&j, bad2, strlen(bad2), toks, 64) < 0,
          "mismatched bracket rejected");

    /* Running out of tokens must be an error, not a silent truncation. */
    ml_json_tok tiny[2];
    CHECK(ml_json_parse(&j, doc, strlen(doc), tiny, 2) == ML_JSON_ERR_NOMEM,
          "token exhaustion reported");

    /*
     * Raw UTF-8, which is what a JSON encoder that does not escape non-ASCII
     * emits, and Dart's does not. A degree sign typed into the designer arrives
     * as the two bytes C2 B0 and has to fold to the same codepoint 127 that
     * ° does, or the temperature reaches the panel with no degree sign and
     * nothing anywhere reports why.
     */
    static const char utf8[] =
        "{\"deg\": \"25\xC2\xB0""C\", \"other\": \"caf\xC3\xA9\","
        " \"bad\": \"a\xFF""b\", \"cut\": \"x\xC2\"}";
    n = ml_json_parse(&j, utf8, strlen(utf8), toks, 64);
    CHECK(n > 0, "parses raw UTF-8 in strings");

    CHECK(ml_json_get_str(&j, 0, "deg", s, sizeof(s)) &&
          s[0] == '2' && s[1] == '5' && (unsigned char)s[2] == 127 &&
          s[3] == 'C' && s[4] == '\0',
          "raw UTF-8 degree folds to the degree glyph");

    /* Anything the fonts cannot draw becomes a visible '?', never a dropped
     * character: a line that silently shortens is far harder to diagnose. */
    CHECK(ml_json_get_str(&j, 0, "other", s, sizeof(s)) && !strcmp(s, "caf?"),
          "other non-ASCII folds to a question mark");
    CHECK(ml_json_get_str(&j, 0, "bad", s, sizeof(s)) && !strcmp(s, "a?b"),
          "an invalid lead byte consumes exactly one byte");
    CHECK(ml_json_get_str(&j, 0, "cut", s, sizeof(s)) && !strcmp(s, "x?"),
          "a sequence truncated by the token end does not read past it");

    /* A long run of exponent digits must not overflow the accumulator. */
    static const char bigexp[] = "{\"a\": 1e99999999999999999999}";
    CHECK(ml_json_parse(&j, bigexp, strlen(bigexp), toks, 64) > 0 &&
          ml_json_get_double(&j, 0, "a", &d),
          "an absurd exponent parses without overflowing");
}

static void test_layout(void)
{
    group("layout");

    static const char doc[] =
        "{\"canvas\":{\"width\":64,\"height\":32},\"background\":\"#101010\","
        "\"widgets\":["
        "{\"type\":\"text\",\"rect\":[0,0,64,7],\"text\":\"hi\"},"
        "{\"type\":\"teleporter\",\"rect\":[0,8,64,7]},"
        "{\"type\":\"rect\",\"rect\":[0,16,64,4],\"color\":\"#FF0000\"}"
        "]}";

    ml_layout l;
    ml_diag   diag;
    CHECK(ml_layout_parse(doc, strlen(doc), &l, &diag), "parses a valid layout");
    CHECK(l.w == 64 && l.h == 32, "canvas dimensions");
    CHECK(l.bg.r == 0x10, "background colour");
    CHECK(l.count == 3, "all widgets retained");

    /*
     * Forward compatibility: a widget type this build does not know must be
     * skipped with a warning, never reject the whole layout. Otherwise a newer
     * designer could brick an older mirror by pushing one unknown widget.
     */
    CHECK(l.widgets[1].type == ML_W_UNKNOWN, "unknown type recorded as unknown");
    CHECK(!l.widgets[1].visible, "unknown type is not drawn");
    CHECK(diag.count > 0, "unknown type produced a warning");
    CHECK(l.widgets[2].type == ML_W_RECT, "widgets after an unknown one still parse");

    /* Hard errors: these must fail rather than render something wrong. */
    static const char no_canvas[] = "{\"widgets\":[]}";
    CHECK(!ml_layout_parse(no_canvas, strlen(no_canvas), &l, &diag),
          "missing canvas is rejected");

    static const char huge[] = "{\"canvas\":{\"width\":99999,\"height\":10}}";
    CHECK(!ml_layout_parse(huge, strlen(huge), &l, &diag),
          "absurd canvas size is rejected");

    static const char broken[] = "{ this is not json ";
    CHECK(!ml_layout_parse(broken, strlen(broken), &l, &diag),
          "malformed JSON is rejected");

    /* Round trip: writing then reparsing must preserve the widget set. */
    CHECK(ml_layout_parse(doc, strlen(doc), &l, &diag), "reparse for round trip");
    char buf[4096];
    size_t need = ml_layout_write(&l, buf, sizeof(buf));
    CHECK(need > 0 && need < sizeof(buf), "serializes within the buffer");

    ml_layout back;
    CHECK(ml_layout_parse(buf, strlen(buf), &back, &diag), "reparses its own output");
    CHECK(back.w == l.w && back.h == l.h, "round trip preserves canvas");
    CHECK(back.count == l.count, "round trip preserves widget count");

    /* Truncation must be reported, not silently produce invalid JSON. */
    char small[16];
    size_t want = ml_layout_write(&l, small, sizeof(small));
    CHECK(want >= sizeof(small), "truncated write reports the full length");

    /*
     * Strings the user typed have to survive being written back out. An
     * unescaped quote closes the string early, and the damage is quiet: the
     * document still reparses, with the field cut off at the quote, so the
     * text simply gets shorter every time the layout is saved.
     */
    static const char nasty[] =
        "{\"canvas\":{\"width\":64,\"height\":32},\"name\":\"a \\\"b\\\" c\","
        "\"widgets\":[{\"type\":\"text\",\"rect\":[0,0,64,7],"
        "\"text\":\"5\\\" nail\",\"bind\":\"back\\\\slash\"}]}";

    ml_layout quoted;
    CHECK(ml_layout_parse(nasty, strlen(nasty), &quoted, &diag),
          "parses text containing quotes");
    CHECK(!strcmp(quoted.widgets[0].text, "5\" nail"), "quote survives the parse");

    size_t qn = ml_layout_write(&quoted, buf, sizeof(buf));
    CHECK(qn > 0 && qn < sizeof(buf), "serializes quoted text");

    ml_layout requoted;
    CHECK(ml_layout_parse(buf, strlen(buf), &requoted, &diag),
          "reparses output containing quotes");
    CHECK(requoted.count == 1, "quoted round trip keeps the widget");
    CHECK(!strcmp(requoted.widgets[0].text, "5\" nail"),
          "quote survives the round trip intact");
    CHECK(!strcmp(requoted.widgets[0].bind, "back\\slash"),
          "backslash survives the round trip intact");
    CHECK(!strcmp(requoted.name, quoted.name), "name survives the round trip intact");

    /*
     * The degree byte is written as ° rather than as a raw 0x7F, because
     * that byte is the degree sign as far as the fonts are concerned and a
     * saved layout should be readable. Either spelling has to fold back to it.
     */
    static const char degree[] =
        "{\"canvas\":{\"width\":64,\"height\":32},\"widgets\":["
        "{\"type\":\"text\",\"rect\":[0,0,64,7],\"bind\":\"weather.temp_c\","
        "\"format\":\"%.0f\\u00b0C\"}]}";

    ml_layout deg;
    CHECK(ml_layout_parse(degree, strlen(degree), &deg, &diag), "parses a degree format");
    CHECK((unsigned char)deg.widgets[0].format[4] == 127, "degree stored as codepoint 127");

    ml_layout deg_back;
    ml_layout_write(&deg, buf, sizeof(buf));
    CHECK(strstr(buf, "\\u00B0") != NULL, "degree written back as an escape");
    CHECK(ml_layout_parse(buf, strlen(buf), &deg_back, &diag), "reparses the degree format");
    CHECK(!strcmp(deg_back.widgets[0].format, deg.widgets[0].format),
          "degree survives the round trip");

    /*
     * A field width long enough to overflow the accumulator that parses it.
     * ML_FORMAT_LEN is only 24 bytes, but that is still room for enough digits
     * to wrap a signed int, and layouts arrive over the network, so computing
     * the value has to stay defined.
     *
     * Checked by rendering it against the documented cap rather than by
     * asserting it merely survived: both must clamp to the same width, which
     * only holds if the digits were accumulated without wrapping.
     */
    static const char wide_absurd[] =
        "{\"canvas\":{\"width\":64,\"height\":32},\"widgets\":["
        "{\"type\":\"text\",\"rect\":[0,0,64,7],\"bind\":\"weather.temp_c\","
        "\"format\":\"%999999999999999999999d\"}]}";
    static const char wide_capped[] =
        "{\"canvas\":{\"width\":64,\"height\":32},\"widgets\":["
        "{\"type\":\"text\",\"rect\":[0,0,64,7],\"bind\":\"weather.temp_c\","
        "\"format\":\"%24d\"}]}";

    ml_model wm;
    ml_model_mock(&wm, ML_MOCK_TYPICAL);

    uint64_t hashes[2] = {0, 0};
    const char *sources[2] = {wide_absurd, wide_capped};
    bool parsed_both = true;

    for (int k = 0; k < 2; k++) {
        ml_layout wl;
        if (!ml_layout_parse(sources[k], strlen(sources[k]), &wl, &diag)) {
            parsed_both = false;
            break;
        }
        ml_canvas wc;
        ml_canvas_init(&wc, wl.w, wl.h, NULL);
        ml_render(&wl, &wm, &wc);
        hashes[k] = fnv1a((const uint8_t *)wc.px,
                          (size_t)wl.w * (size_t)wl.h * sizeof(ml_rgb));
        ml_canvas_free(&wc);
    }

    CHECK(parsed_both, "parses an absurd field width");
    CHECK(hashes[0] == hashes[1], "an absurd field width clamps to the capped one");
}

static void test_fonts(void)
{
    group("fonts");

    const ml_font *body = ml_font_find("sans9");
    const ml_font *clock = ml_font_find("digits16");
    const ml_font *icons = ml_font_find("wx16");

    CHECK(body != NULL, "sans9 registered");
    CHECK(clock != NULL, "digits16 registered");
    CHECK(icons != NULL, "wx16 registered");
    CHECK(ml_font_find("nosuchfont") == NULL, "unknown font not found");
    CHECK(ml_font_default() != NULL, "a default font always exists");

    /*
     * The default is pinned by name, not by registry position. fontgen sorts
     * the registry by (height, name), so adding a shorter font, or one of the
     * same height sorting earlier, would otherwise change what every widget
     * naming no font renders as. Adding a .font file must not do that.
     */
    CHECK(ml_font_default() == body, "default font is sans9, not whatever sorts first");
    CHECK(ml_font_at(0) != NULL, "registry entry zero exists");

    /* The rest of the catalogue. The cuts are what the designer's picker
     * groups into families: one text family from 6px up, one clock family,
     * one icon set. */
    CHECK(ml_font_find("sans8") != NULL, "sans8 registered");
    CHECK(ml_font_find("sans9") != NULL, "sans9 registered");
    CHECK(ml_font_find("digits10") != NULL, "digits10 registered");
    CHECK(ml_font_find("digits32") != NULL, "digits32 registered");
    CHECK(ml_font_find("sans24") != NULL, "sans24 registered");
    CHECK(ml_font_find("digits48") != NULL, "digits48 registered");
    CHECK(ml_font_find("display24") != NULL, "scalable display master registered");
    CHECK(ml_font_find("display-thin24") != NULL,
          "scalable thin display master registered");
    CHECK(ml_font_count() == 25, "25 font cuts in the registry");
    CHECK(ml_font_find("display24")->downscale,
          "the display master supports continuous downscaling");
    CHECK(ml_font_find("display-thin24")->downscale,
          "the thin display master supports continuous downscaling");

    /*
     * Families and smoothness. A layout naming a family gets the cut that
     * fills its box; a layout naming a cut pins that cut. Every text and
     * clock cut anti-aliases between whole scales; only the icon set keeps
     * hard pixels, and any widget can overrule its font with "smooth".
     */
    CHECK(ml_font_is_family("sans"), "sans is a family");
    CHECK(ml_font_is_family("digits"), "digits is a family");
    CHECK(ml_font_is_family("display-thin"), "display-thin is a family");
    CHECK(ml_font_is_family("wx"), "wx is a family");
    CHECK(!ml_font_is_family("pixel"), "the pixel families are gone");
    CHECK(!ml_font_is_family("sans9"), "a cut is not a family");
    CHECK(!ml_font_is_family("nosuch"), "an unknown name is not a family");
    CHECK(strcmp(body->family, "sans") == 0, "sans9 is in the sans family");
    CHECK(strcmp(clock->family, "digits") == 0, "digits16 is in the digits family");
    CHECK(body->smooth == true, "sans anti-aliases");
    CHECK(ml_font_find("sans8")->smooth == true, "even the smallest cut anti-aliases");
    CHECK(clock->smooth == true, "the digits face anti-aliases");
    CHECK(icons->smooth == true, "wx16 scales smoothly");
    CHECK(icons->downscale == true, "wx16 supports boxes below its master size");

    /*
     * Roles. Coverage cannot separate a clock face from an icon set, because the
     * digits are the whole of what either one carries, so the declared role is
     * the only thing keeping the weather pictograms out of the font pickers and
     * out of substitution.
     */
    CHECK(body->role == ML_FONT_TEXT, "sans9 is a text font");
    CHECK(clock->role == ML_FONT_DIGITS, "digits16 is a clock face");
    CHECK(icons->role == ML_FONT_ICONS, "wx16 is an icon set");
    CHECK(ml_font_find("sans8")->role == ML_FONT_TEXT, "sans8 is a text font");
    CHECK(ml_font_find("sans24")->role == ML_FONT_TEXT, "sans24 is a text font");
    CHECK(ml_font_find("digits10")->role == ML_FONT_DIGITS, "digits10 is a clock face");
    CHECK(ml_font_find("digits32")->role == ML_FONT_DIGITS, "digits32 is a clock face");
    CHECK(ml_font_covers(icons, "23"),
          "an icon set covers the digits, which is why coverage alone cannot judge");

    /*
     * Every body font carries the degree sign in the DEL slot, so a layout can
     * swap between cuts without a temperature losing its unit.
     */
    const ml_font *small = ml_font_find("sans8");
    const ml_font *large = ml_font_find("sans24");
    if (small && large) {
        CHECK(ml_text_width(small, "\177", 1) > 0, "sans8 has the degree sign");
        CHECK(ml_text_width(large, "\177", 1) > 0, "sans24 has the degree sign");
        CHECK(small->height < body->height, "sans8 is shorter than sans9");
        CHECK(large->height > body->height, "sans24 is taller than sans9");
        /* The same text costs less width in a shorter cut. */
        CHECK(ml_text_width(small, "Standup", 1) < ml_text_width(body, "Standup", 1),
              "sans8 is narrower than sans9");
        CHECK(ml_text_width(large, "Standup", 1) > ml_text_width(body, "Standup", 1),
              "sans24 is wider than sans9");
    }

    /* The new clock faces must keep the placeholder-width property too. */
    const ml_font *clock10 = ml_font_find("digits10");
    const ml_font *clock32 = ml_font_find("digits32");
    if (clock10 && clock32) {
        CHECK(ml_text_width(clock10, "--:--", 1) == ml_text_width(clock10, "09:41", 1),
              "digits10 placeholder matches real time width");
        CHECK(ml_text_width(clock32, "--:--", 1) == ml_text_width(clock32, "09:41", 1),
              "digits32 placeholder matches real time width");
        CHECK(ml_text_width(clock10, "09:41", 1) < ml_text_width(clock, "09:41", 1),
              "digits10 is narrower than digits16");
        CHECK(ml_text_width(clock32, "09:41", 1) > ml_text_width(clock, "09:41", 1),
              "digits32 is wider than digits16");
    }

    if (!body || !clock) return;

    CHECK(ml_text_width(body, "", 1) == 0, "empty string has zero width");
    /* Proportional metrics: 'i' is 1px of ink, 'M' is 5. */
    CHECK(ml_text_width(body, "i", 1) < ml_text_width(body, "M", 1), "font is proportional");

    /*
     * The clock placeholder must be exactly as wide as a real time, or the
     * layout visibly reflows the moment the first SNTP sync lands.
     */
    CHECK(ml_text_width(clock, "--:--", 1) == ml_text_width(clock, "09:41", 1),
          "clock placeholder matches real time width");

    /* Characters with no glyph in a font must be skipped, not indexed out of
     * range. digits16 has no letters at all. */
    CHECK(ml_text_width(clock, "abc", 1) == 0, "missing glyphs contribute no width");

    ml_canvas c;
    ml_canvas_init(&c, 32, 8, NULL);
    ml_canvas_clear(&c, ml_black);
    ml_text_draw(&c, body, 0, 0, "\x01\x02\xff", ml_white, 1);
    bool blank = true;
    for (int y = 0; y < 8; y++)
        for (int x = 0; x < 32; x++)
            if (ml_canvas_get(&c, x, y).r != 0) blank = false;
    CHECK(blank, "out of range bytes draw nothing");
    ml_canvas_free(&c);
}

/*
 * Scaling a bitmap font is pixel replication, so everything about it should be
 * exactly predictable: widths multiply, and every lit pixel becomes a solid
 * block with nothing bleeding into its neighbours.
 */
static void test_scale(void)
{
    group("glyph scale");

    const ml_font *body = ml_font_find("sans9");
    if (!body) return;

    CHECK(ml_text_width(body, "Hello", 2 * ML_SCALE_1X) == 2 * ml_text_width(body, "Hello", ML_SCALE_1X),
          "width scales exactly, gaps included");
    CHECK(ml_text_width(body, "Hello", 3 * ML_SCALE_1X) == 3 * ml_text_width(body, "Hello", ML_SCALE_1X),
          "and keeps scaling linearly");
    CHECK(ml_text_width(body, "Hello", 0) == ml_text_width(body, "Hello", ML_SCALE_1X),
          "a scale below one is treated as one");
    CHECK(ml_text_width(body, "Hello", ML_SCALE_1X / 2) == ml_text_width(body, "Hello", ML_SCALE_1X),
          "and a fractional scale below one is too");

    /*
     * 'i' in sans9 is a narrow column of ink, which makes it the clearest
     * possible probe: at 3x every source pixel must become a 3x3 block with
     * nothing beside it.
     */
    ml_canvas c;
    ml_canvas_init(&c, 32, 32, NULL);
    ml_canvas_clear(&c, ml_black);
    const int advance = ml_text_draw(&c, body, 0, 0, "i", ml_white, 3 * ML_SCALE_1X);
    CHECK(advance == 3 * ml_text_width(body, "i", ML_SCALE_1X),
          "draw reports the scaled advance");

    int lit = 0, max_x = -1, max_y = -1;
    for (int y = 0; y < 32; y++) {
        for (int x = 0; x < 32; x++) {
            if (ml_canvas_get(&c, x, y).r == 0) continue;
            lit++;
            if (x > max_x) max_x = x;
            if (y > max_y) max_y = y;
        }
    }
    CHECK(lit > 0, "scaled text draws something");
    /* Every source pixel becomes a 3x3 block, so the total must divide by 9. */
    CHECK(lit % 9 == 0, "scaled ink is whole 3x3 blocks");
    CHECK(max_x < 3 * ml_text_width(body, "i", ML_SCALE_1X),
          "scaled glyph stays inside its advance");
    CHECK(max_y < 3 * body->height, "scaled glyph stays inside its scaled height");
    ml_canvas_free(&c);

    /* Unscaled output must be untouched by all of the above. */
    ml_canvas a, b;
    ml_canvas_init(&a, 32, 16, NULL);
    ml_canvas_init(&b, 32, 16, NULL);
    ml_canvas_clear(&a, ml_black);
    ml_canvas_clear(&b, ml_black);
    ml_text_draw(&a, body, 1, 1, "Wg.", ml_white, ML_SCALE_1X);
    ml_text_draw_clipped(&b, body, 1, 1, 999, "Wg.", ml_white, ML_SCALE_1X);
    bool same = true;
    for (int y = 0; y < 16; y++)
        for (int x = 0; x < 32; x++)
            if (ml_canvas_get(&a, x, y).r != ml_canvas_get(&b, x, y).r) same = false;
    CHECK(same, "clipped and plain draw agree when nothing is clipped");
    ml_canvas_free(&a);
    ml_canvas_free(&b);
}

/*
 * scale and fit come off the wire, so the parser has to be as forgiving with
 * them as with everything else: clamp nonsense, never reject the layout.
 */
static void test_scale_parse(void)
{
    group("scale parsing");

    ml_diag diag;
    ml_layout l;

    static const char doc[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"widgets\":["
        "{\"type\":\"text\",\"rect\":[0,0,64,32],\"text\":\"a\"},"
        "{\"type\":\"text\",\"rect\":[0,0,64,32],\"text\":\"b\",\"scale\":3},"
        "{\"type\":\"text\",\"rect\":[0,0,64,32],\"text\":\"c\",\"scale\":999},"
        "{\"type\":\"text\",\"rect\":[0,0,64,32],\"text\":\"d\",\"scale\":0},"
        "{\"type\":\"text\",\"rect\":[0,0,64,32],\"text\":\"e\",\"fit\":true},"
        "{\"type\":\"text\",\"rect\":[0,0,64,32],\"text\":\"f\",\"smooth\":false},"
        "{\"type\":\"text\",\"rect\":[0,0,64,32],\"text\":\"g\",\"smooth\":true}"
        "]}";

    CHECK(ml_layout_parse(doc, strlen(doc), &l, &diag), "layout with scale parses");
    if (l.count < 5) return;

    CHECK(l.widgets[0].scale == 1, "scale defaults to 1 when absent");
    CHECK(l.widgets[0].fit == false, "fit defaults to off");
    CHECK(l.widgets[1].scale == 3, "an explicit scale is kept");
    CHECK(l.widgets[2].scale == ML_MAX_SCALE, "an absurd scale clamps, not rejects");
    CHECK(l.widgets[3].scale == 1, "a zero scale clamps up to 1");
    CHECK(l.widgets[4].fit == true, "fit is read");
    CHECK(l.widgets[0].has_smooth == false, "smooth is unset by default");
    CHECK(l.widgets[5].has_smooth && !l.widgets[5].smooth, "smooth false is read");
    CHECK(l.widgets[6].has_smooth && l.widgets[6].smooth, "smooth true is read");

    /* Round trip: both must survive a write and reparse, or pushing a layout to
     * the device and reading it back would quietly drop them. */
    char buf[2048];
    size_t want = ml_layout_write(&l, buf, sizeof(buf));
    CHECK(want < sizeof(buf), "layout fits the buffer");

    ml_layout back;
    CHECK(ml_layout_parse(buf, strlen(buf), &back, &diag), "reparses its own output");
    if (back.count < 7) return;
    CHECK(back.widgets[1].scale == 3, "round trip preserves scale");
    CHECK(back.widgets[4].fit == true, "round trip preserves fit");
    CHECK(back.widgets[0].scale == 1, "round trip leaves the default alone");
    CHECK(back.widgets[0].has_smooth == false, "round trip leaves smooth unset");
    CHECK(back.widgets[5].has_smooth && !back.widgets[5].smooth,
          "round trip preserves an explicit smooth false");
    CHECK(back.widgets[6].has_smooth && back.widgets[6].smooth,
          "round trip preserves an explicit smooth true");
}

/*
 * Multi-colour icon palettes: the colors array survives a round trip, the
 * icon draws each plane in its own colour, and a layout without one stays a
 * single tint (every pre-palette layout's rendering is unchanged).
 */
static void test_icon_palette(void)
{
    group("icon palette");

    ml_diag diag;
    ml_layout l;

    static const char doc[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":["
        "{\"type\":\"icon\",\"rect\":[0,0,16,16],\"icon_set\":\"wx16\","
        "\"bind\":\"weather.code\",\"color\":\"#FFD24D\","
        "\"colors\":[\"#C9CDD6\",\"#5AA0E0\",\"#E8EEF4\"]},"
        "{\"type\":\"icon\",\"rect\":[16,0,16,16],\"icon_set\":\"wx16\","
        "\"bind\":\"weather.code\",\"color\":\"#FFD24D\"}"
        "]}";

    CHECK(ml_layout_parse(doc, strlen(doc), &l, &diag), "palette layout parses");
    if (l.count < 2) return;

    CHECK(l.widgets[0].color_count == 3, "colors array is read");
    CHECK(l.widgets[0].colors[0].r == 0xC9 && l.widgets[0].colors[0].g == 0xCD &&
          l.widgets[0].colors[0].b == 0xD6, "cloud colour lands in colors[0]");
    CHECK(l.widgets[1].color_count == 0, "no colors array means a single tint");

    char buf[2048];
    size_t want = ml_layout_write(&l, buf, sizeof(buf));
    CHECK(want < sizeof(buf), "palette layout fits the buffer");

    ml_layout back;
    CHECK(ml_layout_parse(buf, strlen(buf), &back, &diag), "palette reparses");
    if (back.count < 2) return;
    CHECK(back.widgets[0].color_count == 3 &&
          back.widgets[0].colors[1].b == 0xE0, "round trip preserves colors");
    CHECK(back.widgets[1].color_count == 0, "round trip leaves a plain icon plain");

    /* The typical mock is partly cloudy: yellow sun plus grey cloud on the
     * same glyph. The plain widget must render the same art as one tint. */
    ml_model m;
    ml_model_mock(&m, ML_MOCK_TYPICAL);
    ml_canvas c;
    ml_canvas_init(&c, 64, 64, NULL);
    ml_render(&l, &m, &c);

    int yellow = 0, grey = 0, white = 0, blue = 0;
    int tinted = 0, other = 0;
    for (int y = 0; y < 16; y++) {
        for (int x = 0; x < 16; x++) {
            ml_rgb p = ml_canvas_get(&c, x, y);
            if (p.r == 0xFF && p.g == 0xD2 && p.b == 0x4D) yellow++;
            else if (p.r == 0xC9 && p.g == 0xCD && p.b == 0xD6) grey++;
            else if (p.r == 0x5A && p.g == 0xA0 && p.b == 0xE0) blue++;
            else if (p.r == 0xE8 && p.g == 0xEE && p.b == 0xF4) white++;
        }
        for (int x = 16; x < 32; x++) {
            ml_rgb p = ml_canvas_get(&c, x, y);
            if (p.r == 0xFF && p.g == 0xD2 && p.b == 0x4D) tinted++;
            else if (p.r || p.g || p.b) other++;
        }
    }
    CHECK(yellow > 0 && grey > 0, "cloudy icon draws sun and cloud in their own colours");
    CHECK(blue == 0 && white == 0, "cloudy icon uses no precipitation plane");
    CHECK(tinted > 0 && other == 0, "a palette-less icon stays a single tint");

    ml_canvas_free(&c);
}

/*
 * fit is the whole point of the resize handles: a taller box must draw taller
 * text, and a box that shrinks must give it back.
 */
static void test_fit(void)
{
    group("fit to box");

    ml_diag diag;
    ml_layout l;
    ml_model m;
    ml_model_mock(&m, ML_MOCK_TYPICAL);

    /* Same text, same font, three box heights. Only fit is on. */
    static const char doc[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":["
        "{\"type\":\"text\",\"rect\":[0,0,64,10],\"text\":\"8\",\"font\":\"digits10\","
        "\"color\":\"#FFFFFF\",\"fit\":true},"
        "{\"type\":\"text\",\"rect\":[0,10,64,30],\"text\":\"8\",\"font\":\"digits10\","
        "\"color\":\"#FFFFFF\",\"fit\":true}"
        "]}";

    if (!ml_layout_parse(doc, strlen(doc), &l, &diag)) {
        CHECK(false, "fit layout parses");
        return;
    }

    ml_canvas c;
    ml_canvas_init(&c, 64, 64, NULL);
    ml_render(&l, &m, &c);

    /* Count ink in each widget's band. The 30px box lands exactly on 3x, a
     * whole multiple, so its glyph is built from 3x3 blocks: nine times the
     * ink, the case where smooth scaling is exact rather than anti-aliased. */
    int small_ink = 0, large_ink = 0;
    for (int y = 0; y < 10; y++)
        for (int x = 0; x < 64; x++)
            if (ml_canvas_get(&c, x, y).r != 0) small_ink++;
    for (int y = 10; y < 40; y++)
        for (int x = 0; x < 64; x++)
            if (ml_canvas_get(&c, x, y).r != 0) large_ink++;

    CHECK(small_ink > 0, "a box exactly one row tall draws at 1x");
    CHECK(large_ink == 9 * small_ink, "a box three rows tall draws at 3x");
    ml_canvas_free(&c);
}

/* Rows carrying any ink. Proportional to the glyph scale however the text is
 * aligned, which makes it a stable way to ask "how big did that draw?". */
static int ink_rows(ml_canvas *c, int w, int h)
{
    int rows = 0;
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            ml_rgb p = ml_canvas_get(c, x, y);
            if (p.r || p.g || p.b) { rows++; break; }
        }
    }
    return rows;
}

static int ink_total(ml_canvas *c, int w, int h)
{
    int n = 0;
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            ml_rgb p = ml_canvas_get(c, x, y);
            if (p.r || p.g || p.b) n++;
        }
    return n;
}

/* Rightmost column with ink, or -1. Catches text escaping its box. */
static int ink_right(ml_canvas *c, int w, int h)
{
    for (int x = w - 1; x >= 0; x--)
        for (int y = 0; y < h; y++) {
            ml_rgb p = ml_canvas_get(c, x, y);
            if (p.r || p.g || p.b) return x;
        }
    return -1;
}

/* Parse and render one document into a fresh canvas. Caller frees. */
static bool render_doc(const char *doc, int w, int h, ml_canvas *out)
{
    ml_layout l;
    ml_diag   diag;
    ml_model  m;

    ml_model_mock(&m, ML_MOCK_TYPICAL);
    if (!ml_layout_parse(doc, strlen(doc), &l, &diag)) return false;

    ml_canvas_init(out, w, h, NULL);
    ml_render(&l, &m, out);
    return true;
}

static void test_fit_axes(void)
{
    group("fit on both axes");

    /*
     * Width used to be ignored entirely. This box is two scales tall, so height
     * alone says 2x, and at 2x the string is 190px wide in a 64px box. The old
     * behaviour drew it at 2x and let the ellipsis eat the overflow. The widget
     * pins smooth off, so its box-derived scale floors to a whole multiple and
     * width pulls it back to 1x.
     */
    static const char narrow[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"text\",\"rect\":[0,0,64,16],"
        "\"text\":\"8888888888888888\",\"font\":\"sans8\",\"color\":\"#FFFFFF\","
        "\"fit\":true,\"smooth\":false}]}";

    /* '8' inks 6 of the 8 rows in sans8; the rest is descender room a digit
     * never uses. So the row count is 6 per unit of scale. */
    ml_canvas c;
    if (!render_doc(narrow, 64, 64, &c)) { CHECK(false, "narrow doc parses"); return; }
    CHECK(ink_rows(&c, 64, 64) == 6, "blocky text too narrow for 2x floors to 1x");
    CHECK(ink_right(&c, 64, 64) < 64, "fitted text stays inside the canvas");
    ml_canvas_free(&c);

    /* Same box, same font, a string short enough that 2x fits both ways. */
    static const char roomy[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"text\",\"rect\":[0,0,64,16],"
        "\"text\":\"88\",\"font\":\"sans8\",\"color\":\"#FFFFFF\","
        "\"fit\":true,\"smooth\":false}]}";

    if (!render_doc(roomy, 64, 64, &c)) { CHECK(false, "roomy doc parses"); return; }
    CHECK(ink_rows(&c, 64, 64) == 12, "the same box still reaches 2x when the text is short");
    ml_canvas_free(&c);
}

/*
 * The two scaling personalities. A smooth font grows one panel pixel at a
 * time as its box grows, anti-aliasing the fractions; a blocky font holds its
 * size until the box reaches the next whole multiple, which is the dead band
 * pixel-art edges cost.
 */
static void test_fit_continuous(void)
{
    group("continuous fit");

    /* '8' fills the digits10 cell top to bottom and one narrow glyph leaves
     * the 64px box width irrelevant: the height decides alone. Every added
     * box row grows the text by exactly one row. */
    int prev = 0;
    for (int box_h = 10; box_h <= 20; box_h++) {
        char doc[256];
        snprintf(doc, sizeof(doc),
                 "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
                 "\"widgets\":[{\"type\":\"text\",\"rect\":[0,0,64,%d],"
                 "\"text\":\"8\",\"font\":\"digits10\",\"color\":\"#FFFFFF\","
                 "\"fit\":true}]}",
                 box_h);
        ml_canvas c;
        if (!render_doc(doc, 64, 64, &c)) { CHECK(false, "continuous doc parses"); return; }
        const int rows = ink_rows(&c, 64, 64);
        CHECK(rows == box_h, "every added box row grows the text by one row");
        if (box_h > 10) CHECK(rows == prev + 1, "no dead bands and no jumps");
        prev = rows;
        ml_canvas_free(&c);
    }

    /* The text must also never outgrow the box, at any step. */
    for (int box_h = 7; box_h <= 30; box_h++) {
        char doc[256];
        snprintf(doc, sizeof(doc),
                 "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
                 "\"widgets\":[{\"type\":\"text\",\"rect\":[0,0,64,%d],"
                 "\"text\":\"Wg\",\"font\":\"sans12\",\"color\":\"#FFFFFF\","
                 "\"fit\":true}]}",
                 box_h);
        ml_canvas c;
        if (!render_doc(doc, 64, 64, &c)) { CHECK(false, "containment doc parses"); return; }
        int bottom = -1;
        for (int y = 63; y >= 0; y--) {
            for (int x = 0; x < 64; x++) {
                ml_rgb p = ml_canvas_get(&c, x, y);
                if (p.r || p.g || p.b) { bottom = y; break; }
            }
            if (bottom >= 0) break;
        }
        CHECK(bottom < box_h, "fitted text never spills below its box");
        ml_canvas_free(&c);
    }

    /* The display family is one 24px master, including below 1x. Resizing the
     * box changes only its scale; it never jumps to a different optical cut. */
    int previous_scale = 0;
    for (int box_h = 6; box_h <= 24; box_h++) {
        char doc[256];
        snprintf(doc, sizeof(doc),
                 "{\"canvas\":{\"width\":64,\"height\":64},\"widgets\":["
                 "{\"type\":\"text\",\"rect\":[0,0,64,%d],\"text\":\"Ag\","
                 "\"font\":\"display\",\"fit\":true}]}", box_h);
        ml_layout l;
        ml_diag d;
        CHECK(ml_layout_parse(doc, strlen(doc), &l, &d),
              "scalable display doc parses");
        int scale = 0;
        const ml_font *f = ml_widget_resolve_font(&l.widgets[0], &(ml_model){0},
                                                  &scale);
        CHECK(f && strcmp(f->name, "display24") == 0,
              "every box size keeps the same display master");
        CHECK(scale > previous_scale,
              "each added box row increases the display scale");
        previous_scale = scale;
    }
}

/* Whether two canvases of the same size hold identical pixels. */
static bool same_canvas(const ml_canvas *a, const ml_canvas *b, int w, int h)
{
    return memcmp(a->px, b->px, (size_t)w * (size_t)h * sizeof(ml_rgb)) == 0;
}

/*
 * A layout naming a family leaves the size to the engine: the cut is picked
 * per box, and a smooth family fills the box continuously at any size.
 */
static void test_family_pick(void)
{
    group("font families");

    /* The same clock widget, same family, two boxes. Each gets the cut and
     * scale that fills it, with no layout change between them. */
    static const char tall[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"clock\",\"rect\":[0,0,64,32],"
        "\"font\":\"digits\",\"format\":\"%H:%M\",\"color\":\"#FFFFFF\","
        "\"fit\":true}]}";
    static const char squat[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"clock\",\"rect\":[0,0,64,13],"
        "\"font\":\"digits\",\"format\":\"%H:%M\",\"color\":\"#FFFFFF\","
        "\"fit\":true}]}";

    ml_canvas a, b;
    if (!render_doc(tall, 64, 64, &a) || !render_doc(squat, 64, 64, &b)) {
        CHECK(false, "family docs parse");
        return;
    }
    CHECK(ink_rows(&a, 64, 64) == 17, "a wide 32px box gets a large cut, filled");
    CHECK(ink_rows(&b, 64, 64) == 13, "a 13px box gets a small cut, filled exactly");
    ml_canvas_free(&a);
    ml_canvas_free(&b);

    /* An exact cut in the squat box for contrast: digits10 is smooth, so it
     * still fills continuously, but the choice of cut was the layout's. */
    static const char pinned[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"clock\",\"rect\":[0,0,64,13],"
        "\"font\":\"digits10\",\"format\":\"%H:%M\",\"color\":\"#FFFFFF\","
        "\"fit\":true}]}";
    if (!render_doc(pinned, 64, 64, &a)) { CHECK(false, "pinned doc parses"); return; }
    CHECK(ink_rows(&a, 64, 64) == 13, "a pinned smooth cut also fills the box");
    ml_canvas_free(&a);

    /* A family that cannot carry the string is never picked for it. An agenda
     * names no sample to measure, so only full text fonts qualify: "digits"
     * has no business here and the default body font stands in. */
    static const char agenda[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"agenda\",\"rect\":[0,0,64,32],"
        "\"font\":\"digits\",\"color\":\"#FFFFFF\",\"fit\":true}]}";
    static const char agenda_default[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"agenda\",\"rect\":[0,0,64,32],"
        "\"font\":\"display24\",\"color\":\"#FFFFFF\",\"fit\":true}]}";
    if (!render_doc(agenda, 64, 64, &a) || !render_doc(agenda_default, 64, 64, &b)) {
        CHECK(false, "agenda docs parse");
        return;
    }
    CHECK(same_canvas(&a, &b, 64, 64),
          "a digits-only family never hosts a text list");
    ml_canvas_free(&a);
    ml_canvas_free(&b);
}

/*
 * The blocky exception. "smooth": false asks for whole-pixel steps on
 * purpose: the fitted scale floors to a whole multiple, so a box growing
 * from 7 to 13 rows changes nothing and the 14th doubles the text. That is
 * a deliberate rendering choice, not a dead band to fix.
 */
static void test_fit_blocky(void)
{
    group("blocky fit");

    /* 'g' inks 7 of the 8 rows in sans8, descender included. */
    for (int box_h = 8; box_h <= 17; box_h++) {
        char doc[256];
        snprintf(doc, sizeof(doc),
                 "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
                 "\"widgets\":[{\"type\":\"text\",\"rect\":[0,0,64,%d],"
                 "\"text\":\"g\",\"font\":\"sans8\",\"color\":\"#FFFFFF\","
                 "\"fit\":true,\"smooth\":false}]}",
                 box_h);
        ml_canvas c;
        if (!render_doc(doc, 64, 64, &c)) { CHECK(false, "blocky doc parses"); return; }
        const int rows = ink_rows(&c, 64, 64);
        const int want = box_h < 16 ? 7 : 14;
        CHECK(rows == want, "smooth off only moves at whole multiples");
        ml_canvas_free(&c);
    }

    /* Weather symbols use one master continuously above and below 1x. Every
     * one-pixel square-box change must produce a new fractional scale. */
    ml_sim *s = ml_sim_create();
    if (!s) { CHECK(false, "sim created"); return; }
    int previous = 0;
    for (int size = 8; size <= 32; size++) {
        char doc[256];
        snprintf(doc, sizeof(doc),
                 "{\"canvas\":{\"width\":64,\"height\":64},\"widgets\":["
                 "{\"type\":\"icon\",\"rect\":[0,0,%d,%d],"
                 "\"icon_set\":\"wx16\",\"bind\":\"weather.code\","
                 "\"fit\":true}]}", size, size);
        CHECK(ml_sim_load(s, doc) == 1, "scalable weather icon doc loads");
        const int scale = ml_sim_widget_scale(s, 0);
        CHECK(scale > previous, "each box pixel increases weather icon scale");
        previous = scale;
    }
    ml_sim_destroy(s);
}

static void test_auto_font(void)
{
    group("automatic font choice");

    /*
     * A 64x32 clock box. A named digits10 is held to 1.6x by its width and
     * inks 16 rows. auto_font shops every family and finds the cut whose
     * scaled ink fills the box best: digits12 at 1.45x, 18 rows. Measured in
     * ink rather than cells, so a text cut whose digits sit in a padded cell
     * cannot outbid a clock face for a clock string.
     */
    static const char named[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"clock\",\"rect\":[0,0,64,32],"
        "\"font\":\"digits10\",\"format\":\"%H:%M\",\"color\":\"#FFFFFF\","
        "\"fit\":true}]}";
    static const char automatic[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"clock\",\"rect\":[0,0,64,32],"
        "\"font\":\"digits10\",\"format\":\"%H:%M\",\"color\":\"#FFFFFF\","
        "\"fit\":true,\"auto_font\":true}]}";

    ml_canvas a, b;
    if (!render_doc(named, 64, 64, &a) || !render_doc(automatic, 64, 64, &b)) {
        CHECK(false, "auto_font docs parse");
        return;
    }

    CHECK(ink_rows(&a, 64, 64) == 16, "a named font is left alone without auto_font");
    CHECK(ink_rows(&b, 64, 64) == 18,
          "auto_font finds a font that fills the box better");
    CHECK(ink_right(&b, 64, 64) < 64, "and the one it picks still fits the width");
    ml_canvas_free(&a);
    ml_canvas_free(&b);

    /*
     * Icons are indexed by digit and every body font has digits, so a naive
     * "which font can draw this string" would answer sans9 and put a numeral
     * where the weather icon belongs. Icon widgets must render identically
     * whether or not auto_font is set.
     */
    static const char icon_plain[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"icon\",\"rect\":[0,0,32,32],"
        "\"icon_set\":\"wx16\",\"bind\":\"weather.code\",\"color\":\"#FFFFFF\","
        "\"fit\":true}]}";
    static const char icon_auto[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"icon\",\"rect\":[0,0,32,32],"
        "\"icon_set\":\"wx16\",\"bind\":\"weather.code\",\"color\":\"#FFFFFF\","
        "\"fit\":true,\"auto_font\":true}]}";

    if (!render_doc(icon_plain, 64, 64, &a) || !render_doc(icon_auto, 64, 64, &b)) {
        CHECK(false, "icon docs parse");
        return;
    }

    bool same = true;
    for (int y = 0; y < 64 && same; y++)
        for (int x = 0; x < 64; x++) {
            ml_rgb p = ml_canvas_get(&a, x, y), q = ml_canvas_get(&b, x, y);
            if (p.r != q.r || p.g != q.g || p.b != q.b) { same = false; break; }
        }
    CHECK(same, "auto_font never substitutes a font for an icon set");
    CHECK(ink_total(&a, 64, 64) > 0, "the icon actually drew");
    ml_canvas_free(&a);
    ml_canvas_free(&b);
}

/*
 * What happens when the box runs out of room.
 *
 * Two separate failures used to live here. A box shorter than every registered
 * font kept the font the layout named and drew its top few rows, so dragging a
 * widget past a threshold turned its text into stumps instead of into small
 * text. And substitution went by height alone, so a box too small for a named
 * clock face could land on a shorter clock face and silently drop every letter.
 */
/*
 * The resolved font and scale the designer's inspector reports. The accessor
 * must answer what the renderer actually does, or the inspector lies about
 * the panel.
 */
static void test_resolve_font(void)
{
    group("resolved font reporting");

    ml_sim *s = ml_sim_create();
    CHECK(s != NULL, "sim created");
    if (!s) return;

    /* A pinned cut at a pinned scale must report exactly that. */
    static const char pinned[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"clock\",\"rect\":[0,0,64,32],"
        "\"font\":\"sans9\",\"scale\":2,\"color\":\"#FFFFFF\"}]}";
    CHECK(ml_sim_load(s, pinned) == 1, "pinned doc loads");
    CHECK(strcmp(ml_sim_widget_font(s, 0), "sans9") == 0,
          "a pinned cut reports itself");
    CHECK(ml_sim_widget_scale(s, 0) == 2 * ML_SCALE_1X,
          "a pinned scale reports itself");

    /* digits16 is held to 1.18x by its width in this box. With smooth off the
     * fitted scale floors to a whole multiple; with the font left to decide it
     * keeps the fraction and anti-aliases. Same cut, same box, one toggle. */
    static const char fitted[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"clock\",\"rect\":[0,0,64,32],"
        "\"font\":\"digits16\",\"format\":\"%H:%M\",\"color\":\"#FFFFFF\","
        "\"fit\":true,\"smooth\":false}]}";
    CHECK(ml_sim_load(s, fitted) == 1, "fitted doc loads");
    CHECK(strcmp(ml_sim_widget_font(s, 0), "digits16") == 0,
          "a named cut keeps its name under fit");
    CHECK(ml_sim_widget_scale(s, 0) == ML_SCALE_1X,
          "smooth off floors the fitted scale");

    static const char fitted_smooth[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"clock\",\"rect\":[0,0,64,32],"
        "\"font\":\"digits16\",\"format\":\"%H:%M\",\"color\":\"#FFFFFF\","
        "\"fit\":true}]}";
    CHECK(ml_sim_load(s, fitted_smooth) == 1, "smooth fitted doc loads");
    CHECK(ml_sim_widget_scale(s, 0) > ML_SCALE_1X &&
          (ml_sim_widget_scale(s, 0) & 255) != 0,
          "the font default keeps the fractional scale");

    /*
     * auto_font shops every family. The renderer's choice inks 18 rows in
     * this box (test_auto_font counts them), so drawing the reported cut at
     * the reported scale must ink the same 18: the report has to describe
     * what the renderer actually did.
     */
    static const char automatic[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"clock\",\"rect\":[0,0,64,32],"
        "\"font\":\"digits10\",\"format\":\"%H:%M\",\"color\":\"#FFFFFF\","
        "\"fit\":true,\"auto_font\":true}]}";
    CHECK(ml_sim_load(s, automatic) == 1, "auto_font doc loads");
    const ml_font *picked = ml_font_find(ml_sim_widget_font(s, 0));
    CHECK(picked != NULL && strcmp(picked->name, "digits10") != 0,
          "auto_font reports the font it upgraded to");
    if (picked) {
        ml_canvas probe;
        ml_canvas_init(&probe, 64, 64, NULL);
        ml_text_draw(&probe, picked, 0, 0, "09:41", ML_RGB(255, 255, 255),
                     ml_sim_widget_scale(s, 0));
        CHECK(ink_rows(&probe, 64, 64) == 18,
              "and the report agrees with what the renderer drew");
        ml_canvas_free(&probe);
    }

    /*
     * The resize case the inspector exists for. Naming a family lets the box
     * decide the cut, so a shorter box must resolve to a shorter cut, which
     * is the update the inspector shows while the box is being dragged.
     */
    static const char family_wide[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"clock\",\"rect\":[0,0,64,32],"
        "\"font\":\"digits\",\"format\":\"%H:%M\",\"color\":\"#FFFFFF\","
        "\"fit\":true}]}";
    static const char family_short[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"clock\",\"rect\":[0,0,64,12],"
        "\"font\":\"digits\",\"format\":\"%H:%M\",\"color\":\"#FFFFFF\","
        "\"fit\":true}]}";

    CHECK(ml_sim_load(s, family_wide) == 1, "wide family doc loads");
    const ml_font *wide = ml_font_find(ml_sim_widget_font(s, 0));
    CHECK(wide != NULL && strncmp(wide->name, "digits", 6) == 0,
          "a family resolves to one of its own cuts");

    CHECK(ml_sim_load(s, family_short) == 1, "short family doc loads");
    const ml_font *shorter = ml_font_find(ml_sim_widget_font(s, 0));
    CHECK(shorter != NULL && wide != NULL && shorter->height < wide->height,
          "shrinking the box resolves to a shorter cut");

    /*
     * A named cut steps down within its family as the box shrinks and never
     * across styles, all the way under the family's shortest cut. Auto font
     * is off here: shopping other faces is its job, not the fallback's.
     */
    char doc[512];
    for (int bh = 32; bh >= 4; bh -= 4) {
        snprintf(doc, sizeof(doc),
                 "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
                 "\"widgets\":[{\"type\":\"clock\",\"rect\":[0,0,64,%d],"
                 "\"font\":\"digits16\",\"format\":\"%H:%M\",\"color\":\"#FFFFFF\","
                 "\"fit\":true}]}",
                 bh);
        CHECK(ml_sim_load(s, doc) == 1, "resize doc loads");
        CHECK(strncmp(ml_sim_widget_font(s, 0), "digits", 6) == 0,
              "a resize never leaves the named family");
    }

    /* Widgets with no text report none, and out-of-range access never hands
     * Dart a NULL. */
    static const char shapes[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"rect\",\"rect\":[0,0,64,10],\"color\":\"#202020\"},"
        "{\"type\":\"clock\",\"rect\":[0,12,64,16],\"visible\":false}]}";
    CHECK(ml_sim_load(s, shapes) == 1, "shapes doc loads");
    CHECK(ml_sim_widget_font(s, 0)[0] == '\0', "a rect draws no font");
    CHECK(ml_sim_widget_scale(s, 0) == 0, "a rect draws at no scale");
    CHECK(ml_sim_widget_font(s, 1)[0] == '\0', "a hidden widget reports none");
    CHECK(ml_sim_widget_font(s, 99) != NULL, "out of range font is not NULL");
    CHECK(ml_sim_widget_font(s, 99)[0] == '\0', "out of range font is empty");
    CHECK(ml_sim_widget_scale(s, -1) == 0, "negative index scale is 0");

    ml_sim_destroy(s);
}

/*
 * A pinned scale multiplies the cut the engine picked; it never re-picks it.
 * Selection runs at 1x, so every position of the designer's Scale slider
 * draws the same face, and a higher scale can never come out smaller. Both
 * were broken while the pin filtered candidates: each step chose a different
 * cut, and the step where nothing fitted dropped to the shortest cut at 1x.
 */
static void test_pinned_scale(void)
{
    group("pinned scale");

    ml_sim *s = ml_sim_create();
    CHECK(s != NULL, "sim created");
    if (!s) return;

    char doc[512];
    for (int n = 1; n <= 8; n++) {
        snprintf(doc, sizeof(doc),
                 "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
                 "\"widgets\":[{\"type\":\"clock\",\"rect\":[0,0,64,32],"
                 "\"font\":\"digits\",\"format\":\"%H:%M\",\"color\":\"#FFFFFF\","
                 "\"scale\":%d}]}",
                 n);
        CHECK(ml_sim_load(s, doc) == 1, "pinned family doc loads");
        CHECK(strcmp(ml_sim_widget_font(s, 0), "digits18") == 0,
              "the cut for the box is stable across the slider");
        CHECK(ml_sim_widget_scale(s, 0) == n * ML_SCALE_1X,
              "the pinned scale stands at every step");
    }

    /* The old dead zone: past the scale every cut fitted at, the slider kept
     * moving but the draw did not. A narrow box hits it at scale 2. */
    for (int n = 1; n <= 8; n++) {
        snprintf(doc, sizeof(doc),
                 "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
                 "\"widgets\":[{\"type\":\"clock\",\"rect\":[0,0,40,20],"
                 "\"font\":\"digits\",\"format\":\"%H:%M\",\"color\":\"#FFFFFF\","
                 "\"scale\":%d}]}",
                 n);
        CHECK(ml_sim_load(s, doc) == 1, "narrow doc loads");
        CHECK(ml_sim_widget_scale(s, 0) == n * ML_SCALE_1X,
              "no step of the slider is dead");
    }

    ml_sim_destroy(s);
}

static void test_scale_floor(void)
{
    group("scale floor");

    /*
     * A box shorter than every cut of the named family draws the family's
     * shortest, clipped. The floor is family-relative: a clock asking for
     * digits16 means digits, and five rows of digits10 keeps that style
     * where a switch to sans8, the shortest text cut, would not.
     */
    static const char under_floor[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"clock\",\"rect\":[0,0,64,5],"
        "\"font\":\"digits16\",\"format\":\"%H:%M\",\"color\":\"#FFFFFF\","
        "\"fit\":true}]}";
    static const char family_floor[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"clock\",\"rect\":[0,0,64,5],"
        "\"font\":\"digits10\",\"format\":\"%H:%M\",\"color\":\"#FFFFFF\","
        "\"fit\":true}]}";
    static const char other_style[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"clock\",\"rect\":[0,0,64,5],"
        "\"font\":\"sans8\",\"format\":\"%H:%M\",\"color\":\"#FFFFFF\","
        "\"fit\":true}]}";

    ml_canvas a, b;
    if (!render_doc(under_floor, 64, 64, &a) || !render_doc(family_floor, 64, 64, &b)) {
        CHECK(false, "scale floor docs parse");
        return;
    }
    CHECK(ink_total(&a, 64, 64) > 0, "a box under the shortest family cut still draws");
    CHECK(same_canvas(&a, &b, 64, 64),
          "and it draws the family's shortest cut, not the top of a tall one");
    ml_canvas_free(&a);
    ml_canvas_free(&b);

    if (!render_doc(other_style, 64, 64, &a) || !render_doc(under_floor, 64, 64, &b)) {
        CHECK(false, "other style doc parses");
        return;
    }
    CHECK(!same_canvas(&a, &b, 64, 64),
          "a smaller font of another style does not win over the family");
    ml_canvas_free(&a);
    ml_canvas_free(&b);

    /* With room for a shorter face it still takes the tallest that fits. The
     * floor is a floor, not a shortcut past the search. */
    static const char ten_high[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"clock\",\"rect\":[0,0,64,10],"
        "\"font\":\"digits32\",\"format\":\"%H:%M\",\"color\":\"#FFFFFF\","
        "\"fit\":true}]}";
    if (!render_doc(ten_high, 64, 64, &a)) {
        CHECK(false, "ten_high parses");
        return;
    }
    CHECK(ink_rows(&a, 64, 64) == 10, "a 10px box takes the 10px face, not the floor");
    ml_canvas_free(&a);

    /*
     * A word in a box too small for the named face has to keep its letters.
     * digits10 fits this 12px box on height and carries no letters at all, so
     * height-only substitution chose it and drew a completely empty widget.
     */
    static const char word[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"text\",\"rect\":[0,0,64,12],\"text\":\"Cloudy\","
        "\"font\":\"digits32\",\"color\":\"#FFFFFF\",\"fit\":true}]}";
    if (!render_doc(word, 64, 64, &a)) {
        CHECK(false, "word parses");
        return;
    }
    CHECK(ink_total(&a, 64, 64) > 0,
          "letters survive a box too small for the named clock face");
    /* sans12 takes it at 1x, held there by the box height: a face that
     * carries every letter, descender reaching the twelfth row. */
    CHECK(ink_rows(&a, 64, 64) == 12, "and land in a font that has them");
    ml_canvas_free(&a);

    /*
     * A list widget names no single string to measure, since it fits each row
     * separately by design. With nothing to check coverage against, the only
     * safe stand-in is a full text font: a clock face fits the box and carries
     * the times, so the old rule drew an agenda's clock columns and dropped
     * every title.
     */
    static const char list_named[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"agenda\",\"rect\":[0,0,64,14],\"max_items\":2,"
        "\"font\":\"digits32\",\"color\":\"#FFFFFF\",\"show_time\":true}]}";
    static const char list_face[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"agenda\",\"rect\":[0,0,64,14],\"max_items\":2,"
        "\"font\":\"sans8\",\"color\":\"#FFFFFF\",\"show_time\":true}]}";
    if (!render_doc(list_named, 64, 64, &a) || !render_doc(list_face, 64, 64, &b)) {
        CHECK(false, "list docs parse");
        return;
    }
    CHECK(ink_total(&a, 64, 64) > 0, "an agenda in a 14px box draws");
    CHECK(same_canvas(&a, &b, 64, 64),
          "a list falls back to the shortest compatible text face");
    ml_canvas_free(&a);
    ml_canvas_free(&b);
}

static void test_render_purity(void)
{
    group("render purity");

    static const char doc[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"widgets\":["
        "{\"type\":\"clock\",\"rect\":[0,0,64,16]},"
        "{\"type\":\"agenda\",\"rect\":[0,20,64,40],\"max_items\":3}]}";

    ml_layout l;
    ml_diag   diag;
    if (!ml_layout_parse(doc, strlen(doc), &l, &diag)) {
        CHECK(false, "fixture layout parses");
        return;
    }

    ml_model m;
    ml_model_mock(&m, ML_MOCK_TYPICAL);

    ml_canvas a, b;
    ml_canvas_init(&a, l.w, l.h, NULL);
    ml_canvas_init(&b, l.w, l.h, NULL);

    ml_render(&l, &m, &a);
    ml_render(&l, &m, &b);

    /* Same inputs must give identical output. If this ever fails, something in
     * the renderer is reading the wall clock or uninitialised memory, and every
     * golden image below becomes meaningless. */
    CHECK(memcmp(a.px, b.px, (size_t)l.w * (size_t)l.h * sizeof(ml_rgb)) == 0,
          "rendering is deterministic");

    /* Rendering into a dirty canvas must give the same result as into a fresh
     * one, or the device's double buffer would show ghosting. */
    ml_canvas_clear(&b, ML_RGB(255, 0, 255));
    ml_render(&l, &m, &b);
    CHECK(memcmp(a.px, b.px, (size_t)l.w * (size_t)l.h * sizeof(ml_rgb)) == 0,
          "rendering fully overwrites previous contents");

    ml_canvas_free(&a);
    ml_canvas_free(&b);
}

/* ------------------------------------------------------- the FFI facade */

static const char k_ffi_doc[] =
    "{\"name\":\"ffitest\",\"canvas\":{\"width\":64,\"height\":32},"
    "\"brightness\":200,\"widgets\":["
    "{\"type\":\"rect\",\"id\":\"bg\",\"rect\":[0,0,64,10],\"color\":\"#202020\"},"
    "{\"type\":\"clock\",\"id\":\"c\",\"rect\":[0,12,64,16]}"
    "]}";

static void test_ffi(void)
{
    group("ffi facade");

    ml_sim *s = ml_sim_create();
    CHECK(s != NULL, "sim created");
    if (!s) return;

    CHECK(ml_sim_load(s, k_ffi_doc) == 1, "loads a valid layout");
    CHECK(ml_sim_width(s) == 64 && ml_sim_height(s) == 32, "reports canvas size");
    CHECK(strcmp(ml_sim_name(s), "ffitest") == 0, "reports layout name");
    CHECK(ml_sim_widget_count(s) == 2, "reports widget count");
    CHECK(strcmp(ml_sim_widget_type(s, 0), "rect") == 0, "reports widget type");
    CHECK(strcmp(ml_sim_widget_id(s, 1), "c") == 0, "reports widget id");

    int x, y, w, h;
    CHECK(ml_sim_widget_rect(s, 1, &x, &y, &w, &h) && x == 0 && y == 12 && w == 64 && h == 16,
          "reports widget rect");
    CHECK(!ml_sim_widget_rect(s, 99, &x, &y, &w, &h), "rejects a bad widget index");

    /* Hit testing must pick the topmost widget covering a pixel. */
    CHECK(ml_sim_hit_test(s, 5, 5) == 0, "hit test finds the first widget");
    CHECK(ml_sim_hit_test(s, 5, 20) == 1, "hit test finds the second widget");
    CHECK(ml_sim_hit_test(s, 5, 11) == -1, "hit test returns -1 in a gap");

    /*
     * A failed load must leave the previous layout intact. The designer keeps
     * rendering the last good version while the user is midway through
     * breaking their JSON, rather than flashing an empty panel on every
     * keystroke.
     */
    CHECK(ml_sim_load(s, "{ broken") == 0, "rejects malformed JSON");
    CHECK(ml_sim_width(s) == 64 && ml_sim_widget_count(s) == 2,
          "failed load preserves the previous layout");
    CHECK(strlen(ml_sim_error(s)) > 0, "failed load sets an error message");

    /* Accessors must never hand Dart a NULL char*. */
    CHECK(ml_sim_widget_type(s, 999) != NULL, "out of range type is not NULL");
    CHECK(ml_sim_widget_id(s, -1) != NULL, "negative index id is not NULL");
    CHECK(ml_sim_diag_at(s, 999) != NULL, "out of range diag is not NULL");
    CHECK(ml_sim_variant_name(999) != NULL, "out of range variant is not NULL");

    /* Reload the good layout for the rendering checks. */
    CHECK(ml_sim_load(s, k_ffi_doc) == 1, "reloads cleanly");

    const uint8_t *rgba = ml_sim_render_rgba(s);
    CHECK(rgba != NULL, "renders");
    CHECK(ml_sim_rgba_size(s) == 64 * 32 * 4, "reports the buffer size");

    bool opaque = true;
    for (int i = 0; i < 64 * 32; i++) {
        if (rgba[i * 4 + 3] != 255) opaque = false;
    }
    CHECK(opaque, "every pixel is fully opaque");

    /*
     * The guarantee the whole architecture rests on: what the designer draws
     * must be exactly what the panel receives. Render the same layout and
     * model through the plain core path and compare channel by channel.
     */
    ml_layout direct;
    ml_diag   ddiag;
    ml_model  dmodel;
    ml_canvas dcanvas;

    ml_layout_parse(k_ffi_doc, strlen(k_ffi_doc), &direct, &ddiag);
    ml_model_mock(&dmodel, ML_MOCK_TYPICAL);
    ml_canvas_init(&dcanvas, direct.w, direct.h, NULL);
    ml_render(&direct, &dmodel, &dcanvas);

    uint8_t *reference = (uint8_t *)malloc((size_t)direct.w * (size_t)direct.h * 3);
    ml_canvas_export_rgb888(&dcanvas, direct.brightness, reference);

    bool identical = true;
    for (int i = 0; i < direct.w * direct.h; i++) {
        if (rgba[i * 4 + 0] != reference[i * 3 + 0] ||
            rgba[i * 4 + 1] != reference[i * 3 + 1] ||
            rgba[i * 4 + 2] != reference[i * 3 + 2]) {
            identical = false;
            break;
        }
    }
    CHECK(identical, "FFI pixels are identical to the panel's pixels");

    free(reference);
    ml_canvas_free(&dcanvas);

    /* Brightness override has to actually change the output, and -1 has to
     * restore whatever the layout asked for. */
    uint64_t at_layout_brightness = fnv1a(rgba, (size_t)ml_sim_rgba_size(s));

    ml_sim_set_brightness(s, 40);
    uint64_t dimmed = fnv1a(ml_sim_render_rgba(s), (size_t)ml_sim_rgba_size(s));
    CHECK(dimmed != at_layout_brightness, "brightness override changes the render");

    ml_sim_set_brightness(s, -1);
    uint64_t restored = fnv1a(ml_sim_render_rgba(s), (size_t)ml_sim_rgba_size(s));
    CHECK(restored == at_layout_brightness, "brightness -1 restores the layout value");

    /* Switching fixtures must change what is drawn, or the variant picker is
     * doing nothing. */
    ml_sim_set_variant(s, ML_MOCK_COLD);
    uint64_t cold = fnv1a(ml_sim_render_rgba(s), (size_t)ml_sim_rgba_size(s));
    CHECK(cold != restored, "changing the mock variant changes the render");
    ml_sim_set_variant(s, ML_MOCK_TYPICAL);

    /* Round trip through the same writer the device uses. */
    const char *json = ml_sim_to_json(s);
    CHECK(json && strlen(json) > 0, "serializes to JSON");

    ml_sim *reloaded = ml_sim_create();
    CHECK(ml_sim_load(reloaded, json) == 1, "its own output reloads");
    CHECK(ml_sim_widget_count(reloaded) == 2, "round trip preserves widgets");
    CHECK(ml_sim_width(reloaded) == 64, "round trip preserves canvas");
    ml_sim_destroy(reloaded);

    /* Catalogue drives the designer's pickers, so it must be non-empty. */
    CHECK(ml_sim_font_count() >= 3, "fonts enumerated");
    CHECK(strlen(ml_sim_font_name(0)) > 0, "font names available");
    CHECK(ml_sim_font_height(0) > 0, "font heights available");

    /* The role the designer filters its pickers on. Crosses as an int, so the
     * enumerator order is part of the contract. */
    CHECK(ml_sim_font_role(0) == (int)ML_FONT_TEXT, "the shortest font reads as text");
    bool saw_icons = false;
    for (int i = 0; i < ml_sim_font_count(); i++) {
        if (strcmp(ml_sim_font_name(i), "wx16") == 0)
            saw_icons = ml_sim_font_role(i) == (int)ML_FONT_ICONS;
    }
    CHECK(saw_icons, "wx16 crosses the boundary as an icon set");
    CHECK(ml_sim_font_role(9999) == (int)ML_FONT_TEXT, "a bad index reads as text");
    CHECK(ml_sim_type_count() == 11, "all widget types enumerated");
    CHECK(ml_sim_bind_count() > 10, "bind paths enumerated");

    /* Every advertised bind path must actually resolve, or the inspector would
     * offer users paths that silently render as a placeholder. */
    ml_model probe;
    ml_model_mock(&probe, ML_MOCK_TYPICAL);
    bool all_resolve = true;
    for (int i = 0; i < ml_sim_bind_count(); i++) {
        bool is_num; double num; const char *sval;
        if (!ml_model_lookup(&probe, ml_sim_bind_at(i), &is_num, &num, &sval)) {
            all_resolve = false;
            printf("        unresolvable bind path: %s\n", ml_sim_bind_at(i));
        }
    }
    CHECK(all_resolve, "every advertised bind path resolves");

    /* Every advertised widget type must be recognised by the parser. */
    bool all_types = true;
    for (int i = 0; i < ml_sim_type_count(); i++) {
        if (ml_widget_type_from_name(ml_sim_type_name(i)) == ML_W_UNKNOWN) {
            all_types = false;
            printf("        unrecognised widget type: %s\n", ml_sim_type_name(i));
        }
    }
    CHECK(all_types, "every advertised widget type is recognised");

    CHECK(ml_sim_render_version() == ML_RENDER_VERSION, "reports the engine version");

    /* A fresh sim with no layout must not render or crash. */
    ml_sim *empty = ml_sim_create();
    CHECK(ml_sim_render_rgba(empty) == NULL, "unloaded sim renders nothing");
    CHECK(ml_sim_rgba_size(empty) == 0, "unloaded sim reports zero size");
    ml_sim_destroy(empty);

    /* NULL handles must be survivable, since Dart can pass one after a failed
     * create. */
    ml_sim_destroy(NULL);
    CHECK(ml_sim_render_rgba(NULL) == NULL, "NULL sim renders nothing");
    CHECK(ml_sim_width(NULL) == 0, "NULL sim reports zero width");
    CHECK(ml_sim_error(NULL) != NULL, "NULL sim error is not NULL");

    ml_sim_destroy(s);
}

/* --------------------------------------------------------- golden images */

#define GOLDEN_PATH "test/golden/digests.txt"

typedef struct {
    char     key[64];
    uint64_t digest;
} golden_entry;

static golden_entry g_golden[64];
static int          g_golden_count;

static void golden_load(void)
{
    size_t len = 0;
    char *text = read_file(GOLDEN_PATH, &len);
    if (!text) return;

    char *line = strtok(text, "\n");
    while (line && g_golden_count < 64) {
        if (*line != '#' && *line != '\0') {
            char key[64];
            unsigned long long digest;
            if (sscanf(line, "%63s %llx", key, &digest) == 2) {
                snprintf(g_golden[g_golden_count].key, sizeof(g_golden[0].key), "%s", key);
                g_golden[g_golden_count].digest = (uint64_t)digest;
                g_golden_count++;
            }
        }
        line = strtok(NULL, "\n");
    }
    free(text);
}

static bool golden_lookup(const char *key, uint64_t *out)
{
    for (int i = 0; i < g_golden_count; i++) {
        if (!strcmp(g_golden[i].key, key)) { *out = g_golden[i].digest; return true; }
    }
    return false;
}

static void test_display_settings(void)
{
    group("display settings");

    /* Factory defaults: a fresh model is a 12-hour, Fahrenheit device, and
     * the firmware overwrites these per frame from the owner config. */
    ml_model m;
    ml_model_init(&m);
    CHECK(m.clock_12h == true, "clock defaults to 12-hour");
    CHECK(m.temp_f == true, "temperature defaults to Fahrenheit");

    ml_model_mock(&m, ML_MOCK_TYPICAL);
    bool is_num;
    double num = 0.0;
    const char *sval = NULL;

    /* Typical mock: 21.4 C is 70.52 F, which rounds to 71. */
    m.temp_f = true;
    CHECK(ml_model_lookup(&m, "weather.temp", &is_num, &num, &sval) && !is_num,
          "weather.temp is a string path");
    CHECK(sval && strcmp(sval, "71" ML_DEGREE_GLYPH "F") == 0,
          "weather.temp renders Fahrenheit");
    CHECK(ml_model_lookup(&m, "weather.temp_max", &is_num, &num, &sval) && is_num,
          "weather.temp_max is a number");
    CHECK(num > 75.19 && num < 75.21, "temp_max converts to Fahrenheit");
    CHECK(ml_model_lookup(&m, "weather.temp_min", &is_num, &num, &sval) &&
          num > 57.19 && num < 57.21, "temp_min converts to Fahrenheit");

    m.temp_f = false;
    CHECK(ml_model_lookup(&m, "weather.temp", &is_num, &num, &sval) && sval &&
          strcmp(sval, "21" ML_DEGREE_GLYPH "C") == 0,
          "weather.temp renders Celsius");
    CHECK(ml_model_lookup(&m, "weather.temp_max", &is_num, &num, &sval) &&
          num == 24.0, "temp_max stays Celsius");
    CHECK(ml_model_lookup(&m, "weather.temp_min", &is_num, &num, &sval) &&
          num == 14.0, "temp_min stays Celsius");

    /* The raw provider paths are untouched by the unit setting. */
    CHECK(ml_model_lookup(&m, "weather.temp_c", &is_num, &num, &sval) &&
          num > 21.39 && num < 21.41, "temp_c stays Celsius by name");
    CHECK(ml_model_lookup(&m, "weather.temp_max_c", &is_num, &num, &sval) &&
          num == 24.0, "temp_max_c stays Celsius by name");

    /*
     * The clock setting reaches the panel through the model, observable via
     * the sim: digits16 has no letters, so a 12-hour face ("10:07 PM") falls
     * back to a text cut while a 24-hour face ("22:07") stays on digits.
     */
    ml_sim *s = ml_sim_create();
    CHECK(s != NULL, "sim created");
    if (s) {
        static const char clockdoc[] =
            "{\"canvas\":{\"width\":64,\"height\":32},\"background\":\"#000000\","
            "\"widgets\":[{\"type\":\"clock\",\"rect\":[0,0,64,16],"
            "\"font\":\"digits16\",\"color\":\"#FFFFFF\"}]}";
        CHECK(ml_sim_load(s, clockdoc) == 1, "clock-only doc loads");

        /*
         * The clock setting reaches the panel through the model. Both faces
         * stay on the digits font (the 12-hour face is plain "%l:%M", no
         * AM/PM), but the evening mock renders differently: 10:07 vs 22:07.
         */
        ml_sim_set_variant(s, ML_MOCK_EVENING);   /* 22:07 */
        ml_sim_set_clock12h(s, 1);
        const uint8_t *r12 = ml_sim_render_rgba(s);
        const int rsz = ml_sim_rgba_size(s);
        const uint64_t h12 = r12 ? fnv1a(r12, (size_t)rsz) : 0;
        ml_sim_set_clock12h(s, 0);
        const uint8_t *r24 = ml_sim_render_rgba(s);
        const uint64_t h24 = r24 ? fnv1a(r24, (size_t)rsz) : 0;
        CHECK(rsz > 0 && h12 != 0 && h24 != 0, "clock renders in both modes");
        CHECK(h12 != h24, "12-hour and 24-hour faces differ (10:07 vs 22:07)");
        CHECK(strcmp(ml_sim_widget_font(s, 0), "digits16") == 0,
              "both clock faces stay on the digits font");

        /* The 24-hour choice survives a data-variant switch, which re-mocks
         * the model; a reset to the 12-hour default would show 10:07 again. */
        ml_sim_set_variant(s, ML_MOCK_EVENING);
        const uint8_t *r24b = ml_sim_render_rgba(s);
        CHECK(r24b && fnv1a(r24b, (size_t)rsz) == h24,
              "the clock choice survives a variant switch");

        /* An explicit widget format beats the device setting. */
        static const char pinned[] =
            "{\"canvas\":{\"width\":64,\"height\":32},\"background\":\"#000000\","
            "\"widgets\":[{\"type\":\"clock\",\"rect\":[0,0,64,16],"
            "\"font\":\"digits16\",\"format\":\"%H:%M\",\"color\":\"#FFFFFF\"}]}";
        CHECK(ml_sim_load(s, pinned) == 1, "pinned doc loads");
        ml_sim_set_clock12h(s, 1);
        const uint8_t *rp = ml_sim_render_rgba(s);
        CHECK(rp && fnv1a(rp, (size_t)rsz) == h24,
              "an explicit 24-hour format beats the 12-hour setting");

        /* The unit setting changes what the panel draws: the same layout
         * bound to weather.temp renders different bytes in F and C. */
        static const char tempdoc[] =
            "{\"canvas\":{\"width\":64,\"height\":32},\"background\":\"#000000\","
            "\"widgets\":[{\"type\":\"text\",\"rect\":[0,0,64,8],"
            "\"font\":\"sans9\",\"bind\":\"weather.temp\",\"color\":\"#FFFFFF\"}]}";
        CHECK(ml_sim_load(s, tempdoc) == 1, "temp doc loads");
        ml_sim_set_variant(s, ML_MOCK_TYPICAL);
        ml_sim_set_tempf(s, 1);
        const uint8_t *fa = ml_sim_render_rgba(s);
        const int fsz = ml_sim_rgba_size(s);
        /* The render buffer is one per sim and reused, so the F frame must
         * be copied before the C render overwrites it. */
        uint8_t *f_copy = (uint8_t *)malloc((size_t)fsz);
        if (f_copy && fa) memcpy(f_copy, fa, (size_t)fsz);
        ml_sim_set_tempf(s, 0);
        const uint8_t *ca = ml_sim_render_rgba(s);
        CHECK(f_copy && ca && fsz > 0 &&
              memcmp(f_copy, ca, (size_t)fsz) != 0,
              "Fahrenheit and Celsius frames differ");
        free(f_copy);

        ml_sim_destroy(s);
    }
}

static void test_countdown(void)
{
    group("countdown");

    static const char doc[] =
        "{\"canvas\":{\"width\":64,\"height\":16},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"countdown\",\"rect\":[0,0,64,16],"
        "\"until\":1785501905,\"font\":\"digits16\",\"color\":\"#FFFFFF\"}]}";

    ml_layout l;
    ml_diag   diag;
    CHECK(ml_layout_parse(doc, strlen(doc), &l, &diag), "countdown doc parses");
    CHECK(l.count == 1, "one widget parsed");
    CHECK(l.widgets[0].type == ML_W_COUNTDOWN, "widget type is countdown");
    CHECK(l.widgets[0].until_s == 1785501905, "until parsed");

    /* Round-trip preserves the deadline. */
    char json[1024];
    size_t n = ml_layout_write(&l, json, sizeof(json));
    CHECK(n > 0 && n < sizeof(json), "layout serializes");
    ml_layout r;
    ml_diag   rdiag;
    CHECK(ml_layout_parse(json, n, &r, &rdiag), "serialized layout reparses");
    CHECK(r.widgets[0].until_s == 1785501905, "until survives round-trip");

    ml_model  m;
    ml_canvas c;
    ml_model_mock(&m, ML_MOCK_TYPICAL);
    ml_canvas_init(&c, l.w, l.h, NULL);

    /* Active target (51:04:05 ahead of the fixed mock now): non-black ink. */
    ml_render(&l, &m, &c);
    uint8_t *rgb = (uint8_t *)malloc((size_t)l.w * (size_t)l.h * 3);
    ml_canvas_export_rgb888(&c, l.brightness, rgb);
    bool ink = false;
    for (int i = 0; i < l.w * l.h * 3; i++) {
        if (rgb[i] > 0) { ink = true; break; }
    }
    CHECK(ink, "active countdown draws ink");

    /* Expired: 90 seconds past zeroes the readout, and the blink phase (the
     * wall-clock second's parity) changes the frame. */
    l.widgets[0].until_s = 1785317970;
    m.now.second = 0;
    ml_render(&l, &m, &c);
    ml_canvas_export_rgb888(&c, l.brightness, rgb);
    const uint64_t h_even = fnv1a(rgb, (size_t)l.w * (size_t)l.h * 3);
    m.now.second = 1;
    ml_render(&l, &m, &c);
    ml_canvas_export_rgb888(&c, l.brightness, rgb);
    const uint64_t h_odd = fnv1a(rgb, (size_t)l.w * (size_t)l.h * 3);
    CHECK(h_even != h_odd, "expired readout blinks with the second parity");

    /* Clamp: any past deadline renders the same zeroed frame, no negative-time
     * wrap. */
    m.now.second = 0;
    l.widgets[0].until_s = 1;
    ml_render(&l, &m, &c);
    ml_canvas_export_rgb888(&c, l.brightness, rgb);
    const uint64_t h_clamp = fnv1a(rgb, (size_t)l.w * (size_t)l.h * 3);
    CHECK(h_clamp == h_even, "past deadlines clamp to 00:00:00");

    free(rgb);
    ml_canvas_free(&c);
}

static bool px_black(ml_rgb p)
{
    return p.r == 0 && p.g == 0 && p.b == 0;
}

/*
 * The precip chart: one full-height bar where the chance is 100%, nothing
 * where it is 0%, and a baseline-only placeholder before the forecast lands.
 */
static void test_precip(void)
{
    group("precip chart");

    const char *doc =
        "{\"name\":\"p\",\"canvas\":{\"width\":48,\"height\":24},"
        "\"background\":\"#000000\",\"widgets\":["
        "{\"type\":\"precip\",\"rect\":[0,0,48,24],"
        "\"color\":\"#5AA0E0\",\"accent\":\"#2A3B4D\"}]}";

    ml_layout l;
    ml_diag   diag;
    ml_model  m;
    ml_canvas c;

    CHECK(ml_layout_parse(doc, strlen(doc), &l, &diag), "precip layout parses");
    CHECK(diag.count == 0, "precip layout parses clean");

    /* Hour 0 at 100%, the rest at zero: exactly one full-height bar. The box
     * is 48 wide, so each of the 12 columns is 4px. */
    ml_model_mock(&m, ML_MOCK_TYPICAL);
    for (int i = 0; i < ML_PRECIP_HOURS; i++) m.weather.precip_hourly[i] = 0;
    m.weather.precip_hourly[0]     = 100;
    m.weather.precip_hourly_valid  = true;

    CHECK(ml_canvas_init(&c, l.w, l.h, NULL), "precip canvas allocates");
    ml_render(&l, &m, &c);

    /* Baseline is the bottom row; a 24px box puts it at y=23. */
    CHECK(!px_black(ml_canvas_get(&c, 0, 23)), "baseline is drawn");
    /* The 100% bar (column 0, x=1..2) inks a mid-height row... */
    CHECK(!px_black(ml_canvas_get(&c, 1, 5)), "100% bar inks the middle");
    /* ...while a zero-chance hour (column 1, x=5) stays dark there. */
    CHECK(px_black(ml_canvas_get(&c, 5, 5)), "0% hour draws no bar");
    ml_canvas_free(&c);

    /* No forecast yet: baseline only, no bars and no reference lines. */
    ml_model_mock(&m, ML_MOCK_COLD);
    CHECK(!m.weather.precip_hourly_valid, "cold mock has no hourly forecast");

    CHECK(ml_canvas_init(&c, l.w, l.h, NULL), "precip canvas allocates (cold)");
    ml_render(&l, &m, &c);
    CHECK(!px_black(ml_canvas_get(&c, 0, 23)), "placeholder baseline is drawn");
    CHECK(px_black(ml_canvas_get(&c, 1, 0)), "placeholder draws no bars");
    ml_canvas_free(&c);
}

static void test_golden(void)
{
    group("golden images");

    const char *layouts[] = {"mini", "dual", "single", "quad", "precip"};
    bool update = getenv("MIRROR_UPDATE_GOLDEN") != NULL;

    golden_load();

    FILE *out = NULL;
    if (update) {
        out = fopen(GOLDEN_PATH, "w");
        if (out) {
            fprintf(out, "# Golden render digests. FNV-1a 64 over the exact\n");
            fprintf(out, "# gamma-corrected RGB888 bytes sent to the panel.\n");
            fprintf(out, "#\n");
            fprintf(out, "# Regenerate deliberately after an intended rendering change:\n");
            fprintf(out, "#   MIRROR_UPDATE_GOLDEN=1 make -f Makefile.host test\n");
            fprintf(out, "#\n");
            fprintf(out, "# render engine version %d\n\n", ML_RENDER_VERSION);
        }
    }

    for (size_t li = 0; li < sizeof(layouts) / sizeof(layouts[0]); li++) {
        char path[128];
        snprintf(path, sizeof(path), "../layouts/%s.json", layouts[li]);

        size_t len = 0;
        char *json = read_file(path, &len);
        if (!json) {
            CHECK(false, "layout file is readable");
            printf("        cannot read %s\n", path);
            continue;
        }

        ml_layout l;
        ml_diag   diag;
        bool ok = ml_layout_parse(json, len, &l, &diag);
        free(json);

        char what[128];
        snprintf(what, sizeof(what), "%s parses", layouts[li]);
        CHECK(ok, what);
        if (!ok) continue;

        /* Stock layouts must be clean. A warning here means a widget is off
         * canvas or misspelt, which is a bug in the shipped layout. */
        snprintf(what, sizeof(what), "%s parses without warnings", layouts[li]);
        CHECK(diag.count == 0, what);
        for (int d = 0; d < diag.count; d++) printf("        %s\n", diag.msg[d]);

        for (int v = 0; v < ML_MOCK_VARIANTS; v++) {
            ml_model m;
            ml_model_mock(&m, v);

            ml_canvas c;
            if (!ml_canvas_init(&c, l.w, l.h, NULL)) {
                CHECK(false, "canvas allocation");
                continue;
            }
            ml_render(&l, &m, &c);

            size_t nbytes = (size_t)l.w * (size_t)l.h * 3;
            uint8_t *rgb = (uint8_t *)malloc(nbytes);
            if (!rgb) { ml_canvas_free(&c); continue; }
            ml_canvas_export_rgb888(&c, l.brightness, rgb);

            char key[64];
            snprintf(key, sizeof(key), "%s:%s", layouts[li], ml_mock_name(v));
            uint64_t digest = fnv1a(rgb, nbytes);

            if (out) {
                fprintf(out, "%-24s %016llx\n", key, (unsigned long long)digest);
            } else {
                uint64_t want = 0;
                if (!golden_lookup(key, &want)) {
                    printf("  NEW   %s has no golden yet (%016llx)\n",
                           key, (unsigned long long)digest);
                } else {
                    snprintf(what, sizeof(what), "%s matches golden", key);
                    check(digest == want, what, __LINE__);
                    if (digest != want) {
                        /* Write the actual frame so the change can be looked at
                         * rather than argued about. */
                        char actual[160];
                        snprintf(actual, sizeof(actual), "../out/%s-actual.png", key);
                        for (char *p = actual; *p; p++) if (*p == ':') *p = '-';
                        png_write_rgb(actual, rgb, l.w, l.h, 6);
                        printf("        expected %016llx got %016llx\n",
                               (unsigned long long)want, (unsigned long long)digest);
                        printf("        wrote %s\n", actual);
                    }
                }
            }

            free(rgb);
            ml_canvas_free(&c);
        }
    }

    if (out) {
        fclose(out);
        printf("  wrote %s\n", GOLDEN_PATH);
    }
}

int main(void)
{
    printf("mirror core tests (engine version %d)\n\n", ML_RENDER_VERSION);

    test_color();
    test_rect();
    test_canvas_clip();
    test_json();
    test_layout();
    test_fonts();
    test_scale();
    test_scale_parse();
    test_icon_palette();
    test_fit();
    test_fit_axes();
    test_fit_continuous();
    test_family_pick();
    test_fit_blocky();
    test_auto_font();
    test_pinned_scale();
    test_scale_floor();
    test_render_purity();
    test_resolve_font();
    test_ffi();
    test_display_settings();
    test_countdown();
    test_precip();
    test_golden();

    printf("\n%d checks, %d failure(s)\n", g_checks, g_fails);
    return g_fails == 0 ? 0 : 1;
}
