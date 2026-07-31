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

    const ml_font *body = ml_font_find("tom5x7");
    const ml_font *clock = ml_font_find("digits16");
    const ml_font *icons = ml_font_find("wx16");

    CHECK(body != NULL, "tom5x7 registered");
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
    CHECK(ml_font_default() == body, "default font is tom5x7, not whatever sorts first");
    CHECK(ml_font_at(0) != NULL, "registry entry zero exists");

    /* The rest of the catalogue. These are what the designer's picker lists. */
    CHECK(ml_font_find("bold5x7") != NULL, "bold5x7 registered");
    CHECK(ml_font_find("tiny4x6") != NULL, "tiny4x6 registered");
    CHECK(ml_font_find("digits10") != NULL, "digits10 registered");
    CHECK(ml_font_find("digits32") != NULL, "digits32 registered");
    CHECK(ml_font_count() == 7, "seven fonts in the registry");

    /*
     * Every body font carries the degree sign in the DEL slot, so a layout can
     * swap between them without a temperature losing its unit.
     */
    const ml_font *bold = ml_font_find("bold5x7");
    const ml_font *tiny = ml_font_find("tiny4x6");
    if (bold && tiny) {
        CHECK(ml_text_width(bold, "\177", 1) > 0, "bold5x7 has the degree sign");
        CHECK(ml_text_width(tiny, "\177", 1) > 0, "tiny4x6 has the degree sign");
        CHECK(tiny->height < body->height, "tiny4x6 is shorter than tom5x7");
        CHECK(bold->height == body->height, "bold5x7 shares the tom5x7 cell height");
        /* Same text costs more width in bold and less in tiny. */
        CHECK(ml_text_width(bold, "Standup", 1) > ml_text_width(body, "Standup", 1),
              "bold5x7 is wider than tom5x7");
        CHECK(ml_text_width(tiny, "Standup", 1) < ml_text_width(body, "Standup", 1),
              "tiny4x6 is narrower than tom5x7");
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

    const ml_font *body = ml_font_find("tom5x7");
    if (!body) return;

    CHECK(ml_text_width(body, "Hello", 2) == 2 * ml_text_width(body, "Hello", 1),
          "width scales exactly, gaps included");
    CHECK(ml_text_width(body, "Hello", 3) == 3 * ml_text_width(body, "Hello", 1),
          "and keeps scaling linearly");
    CHECK(ml_text_width(body, "Hello", 0) == ml_text_width(body, "Hello", 1),
          "a scale below one is treated as one");

    /*
     * 'i' in tom5x7 is a single column of ink, which makes it the clearest
     * possible probe: at 3x its stem must be exactly three pixels wide and
     * three tall per source row, with nothing beside it.
     */
    ml_canvas c;
    ml_canvas_init(&c, 32, 32, NULL);
    ml_canvas_clear(&c, ml_black);
    const int advance = ml_text_draw(&c, body, 0, 0, "i", ml_white, 3);
    CHECK(advance == 3 * ml_text_width(body, "i", 1),
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
    CHECK(max_x < 3 * ml_text_width(body, "i", 1),
          "scaled glyph stays inside its advance");
    CHECK(max_y < 3 * body->height, "scaled glyph stays inside its scaled height");
    ml_canvas_free(&c);

    /* Unscaled output must be untouched by all of the above. */
    ml_canvas a, b;
    ml_canvas_init(&a, 32, 16, NULL);
    ml_canvas_init(&b, 32, 16, NULL);
    ml_canvas_clear(&a, ml_black);
    ml_canvas_clear(&b, ml_black);
    ml_text_draw(&a, body, 1, 1, "Wg.", ml_white, 1);
    ml_text_draw_clipped(&b, body, 1, 1, 999, "Wg.", ml_white, 1);
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
        "{\"type\":\"text\",\"rect\":[0,0,64,32],\"text\":\"e\",\"fit\":true}"
        "]}";

    CHECK(ml_layout_parse(doc, strlen(doc), &l, &diag), "layout with scale parses");
    if (l.count < 5) return;

    CHECK(l.widgets[0].scale == 1, "scale defaults to 1 when absent");
    CHECK(l.widgets[0].fit == false, "fit defaults to off");
    CHECK(l.widgets[1].scale == 3, "an explicit scale is kept");
    CHECK(l.widgets[2].scale == ML_MAX_SCALE, "an absurd scale clamps, not rejects");
    CHECK(l.widgets[3].scale == 1, "a zero scale clamps up to 1");
    CHECK(l.widgets[4].fit == true, "fit is read");

    /* Round trip: both must survive a write and reparse, or pushing a layout to
     * the device and reading it back would quietly drop them. */
    char buf[2048];
    size_t want = ml_layout_write(&l, buf, sizeof(buf));
    CHECK(want < sizeof(buf), "layout fits the buffer");

    ml_layout back;
    CHECK(ml_layout_parse(buf, strlen(buf), &back, &diag), "reparses its own output");
    if (back.count < 5) return;
    CHECK(back.widgets[1].scale == 3, "round trip preserves scale");
    CHECK(back.widgets[4].fit == true, "round trip preserves fit");
    CHECK(back.widgets[0].scale == 1, "round trip leaves the default alone");
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
        "{\"type\":\"text\",\"rect\":[0,0,64,7],\"text\":\"8\",\"font\":\"tom5x7\","
        "\"color\":\"#FFFFFF\",\"fit\":true},"
        "{\"type\":\"text\",\"rect\":[0,8,64,21],\"text\":\"8\",\"font\":\"tom5x7\","
        "\"color\":\"#FFFFFF\",\"fit\":true}"
        "]}";

    if (!ml_layout_parse(doc, strlen(doc), &l, &diag)) {
        CHECK(false, "fit layout parses");
        return;
    }

    ml_canvas c;
    ml_canvas_init(&c, 64, 64, NULL);
    ml_render(&l, &m, &c);

    /* Count ink in each widget's band. The 21px box fits three rows of a 7px
     * font, so its glyph must be built from 3x3 blocks: nine times the ink. */
    int small_ink = 0, large_ink = 0;
    for (int y = 0; y < 7; y++)
        for (int x = 0; x < 64; x++)
            if (ml_canvas_get(&c, x, y).r != 0) small_ink++;
    for (int y = 8; y < 29; y++)
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
     * Width used to be ignored entirely. This box is two rows tall, so height
     * alone says 2x, and at 2x the string is 94px wide in a 64px box. The old
     * behaviour drew it at 2x and let the ellipsis eat the overflow.
     */
    static const char narrow[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"text\",\"rect\":[0,0,64,14],"
        "\"text\":\"88888888\",\"font\":\"tom5x7\",\"color\":\"#FFFFFF\","
        "\"fit\":true}]}";

    /* '8' inks 6 of the 7 rows in tom5x7; row 6 is the descender row, empty for
     * a digit. So the row count is 6 per unit of scale, not 7. */
    ml_canvas c;
    if (!render_doc(narrow, 64, 64, &c)) { CHECK(false, "narrow doc parses"); return; }
    CHECK(ink_rows(&c, 64, 64) == 6, "a box too narrow for 2x draws at 1x");
    CHECK(ink_right(&c, 64, 64) < 64, "fitted text stays inside the canvas");
    ml_canvas_free(&c);

    /* Same box, same font, a string short enough that 2x fits both ways. */
    static const char roomy[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"text\",\"rect\":[0,0,64,14],"
        "\"text\":\"88\",\"font\":\"tom5x7\",\"color\":\"#FFFFFF\","
        "\"fit\":true}]}";

    if (!render_doc(roomy, 64, 64, &c)) { CHECK(false, "roomy doc parses"); return; }
    CHECK(ink_rows(&c, 64, 64) == 12, "the same box still reaches 2x when the text is short");
    ml_canvas_free(&c);
}

static void test_scale_bounds(void)
{
    group("scale bounds");

    /* 28px of box over a 7px font is 4x, capped here at 2x. */
    static const char capped[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"text\",\"rect\":[0,0,64,28],"
        "\"text\":\"8\",\"font\":\"tom5x7\",\"color\":\"#FFFFFF\","
        "\"fit\":true,\"max_scale\":2}]}";

    ml_canvas c;
    if (!render_doc(capped, 64, 64, &c)) { CHECK(false, "capped doc parses"); return; }
    CHECK(ink_rows(&c, 64, 64) == 12, "max_scale caps what fit would have chosen");
    ml_canvas_free(&c);

    /* A one-row box is 1x on its own. min_scale insists on more, and the result
     * is drawn and clipped rather than silently shrunk back. */
    static const char floored[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"text\",\"rect\":[0,0,64,7],"
        "\"text\":\"8\",\"font\":\"tom5x7\",\"color\":\"#FFFFFF\","
        "\"fit\":true,\"min_scale\":3}]}";
    static const char plain[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"text\",\"rect\":[0,0,64,7],"
        "\"text\":\"8\",\"font\":\"tom5x7\",\"color\":\"#FFFFFF\","
        "\"fit\":true}]}";

    ml_canvas a, b;
    if (!render_doc(floored, 64, 64, &a) || !render_doc(plain, 64, 64, &b)) {
        CHECK(false, "min_scale docs parse");
        return;
    }
    CHECK(ink_total(&a, 64, 64) > ink_total(&b, 64, 64),
          "min_scale raises a scale the box would have kept at 1x");
    ml_canvas_free(&a);
    ml_canvas_free(&b);

    /*
     * A layout arriving over the network can carry nonsense. An inverted pair
     * must still draw something, because a widget that cannot be drawn is a
     * worse outcome than one drawn at the wrong size.
     */
    static const char inverted[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"text\",\"rect\":[0,0,64,28],"
        "\"text\":\"8\",\"font\":\"tom5x7\",\"color\":\"#FFFFFF\","
        "\"fit\":true,\"min_scale\":5,\"max_scale\":2}]}";

    if (!render_doc(inverted, 64, 64, &c)) { CHECK(false, "inverted doc parses"); return; }
    CHECK(ink_total(&c, 64, 64) > 0, "an inverted min/max pair still draws");
    ml_canvas_free(&c);
}

static void test_auto_font(void)
{
    group("automatic font choice");

    /*
     * A 64x32 clock box. digits16 fits once on height but its 52px would not
     * survive 2x, so it sits at 16 of the 32 rows. digits10 goes to 2x and
     * fills 20, which is what auto_font is for.
     */
    static const char named[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"clock\",\"rect\":[0,0,64,32],"
        "\"font\":\"digits16\",\"format\":\"%H:%M\",\"color\":\"#FFFFFF\","
        "\"fit\":true}]}";
    static const char automatic[] =
        "{\"canvas\":{\"width\":64,\"height\":64},\"background\":\"#000000\","
        "\"widgets\":[{\"type\":\"clock\",\"rect\":[0,0,64,32],"
        "\"font\":\"digits16\",\"format\":\"%H:%M\",\"color\":\"#FFFFFF\","
        "\"fit\":true,\"auto_font\":true}]}";

    ml_canvas a, b;
    if (!render_doc(named, 64, 64, &a) || !render_doc(automatic, 64, 64, &b)) {
        CHECK(false, "auto_font docs parse");
        return;
    }

    CHECK(ink_rows(&a, 64, 64) == 16, "a named font is left alone without auto_font");
    CHECK(ink_rows(&b, 64, 64) > ink_rows(&a, 64, 64),
          "auto_font finds a font that fills the box better");
    CHECK(ink_right(&b, 64, 64) < 64, "and the one it picks still fits the width");
    ml_canvas_free(&a);
    ml_canvas_free(&b);

    /*
     * Icons are indexed by digit and every body font has digits, so a naive
     * "which font can draw this string" would answer tom5x7 and put a numeral
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
    CHECK(ml_sim_type_count() == 9, "all widget types enumerated");
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

static void test_golden(void)
{
    group("golden images");

    const char *layouts[] = {"mini", "dual", "single", "quad"};
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
    test_fit();
    test_fit_axes();
    test_scale_bounds();
    test_auto_font();
    test_render_purity();
    test_ffi();
    test_golden();

    printf("\n%d checks, %d failure(s)\n", g_checks, g_fails);
    return g_fails == 0 ? 0 : 1;
}
