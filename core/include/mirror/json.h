/*
 * json.h - a small zero-allocation JSON tokenizer.
 *
 * The core has to parse layouts and provider payloads on a microcontroller
 * without malloc, so this is a tokenizer rather than a DOM: it scans once and
 * records offsets into the caller's buffer. No copies, no allocation, and the
 * memory cost is exactly the token array the caller hands in.
 *
 * That is also why cJSON is not vendored here even though ESP-IDF ships it:
 * cJSON builds a heap-allocated tree, and heap fragmentation on a device that
 * runs for months is a problem worth designing out rather than monitoring.
 *
 * Token layout follows the jsmn convention. Inside an object, each key is a
 * child token of the object and each value is a child of its key, so a value
 * always sits at (key index + 1).
 */
#ifndef MIRROR_JSON_H
#define MIRROR_JSON_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    ML_JSON_UNDEFINED = 0,
    ML_JSON_OBJECT,
    ML_JSON_ARRAY,
    ML_JSON_STRING,
    ML_JSON_PRIMITIVE   /* number, true, false, or null */
} ml_json_type;

typedef struct {
    ml_json_type type;
    int          start;   /* byte offset of the first character */
    int          end;     /* byte offset one past the last character */
    int          size;    /* child count */
    int          parent;  /* index of the parent token, -1 at the root */
} ml_json_tok;

typedef struct {
    const char  *src;
    size_t       len;
    ml_json_tok *toks;
    int          cap;
    int          count;
} ml_json;

/* Negative return codes from ml_json_parse. */
#define ML_JSON_ERR_NOMEM   (-1)   /* ran out of tokens */
#define ML_JSON_ERR_INVALID (-2)   /* malformed input */
#define ML_JSON_ERR_PARTIAL (-3)   /* input ended mid-value */

/*
 * Tokenize src into the caller-provided token array. Returns the token count,
 * or one of the negative codes above. The source buffer must outlive every
 * subsequent call, since tokens only store offsets into it.
 */
int ml_json_parse(ml_json *j, const char *src, size_t len,
                  ml_json_tok *toks, int cap);

/* Value token for a key in an object, or -1 if absent. */
int ml_json_member(const ml_json *j, int obj, const char *key);

/* Element count of an array, and the token index of element n, or -1. */
int ml_json_array_count(const ml_json *j, int arr);
int ml_json_array_at(const ml_json *j, int arr, int index);

/*
 * Copy a string token out with escape sequences decoded, always NUL
 * terminated, truncated to cap. \u escapes below 0x80 pass through; °
 * becomes the degree glyph at codepoint 127; anything else non-ASCII becomes
 * '?' because the bitmap fonts are ASCII only.
 */
bool ml_json_str(const ml_json *j, int tok, char *out, size_t cap);

bool ml_json_int(const ml_json *j, int tok, int *out);
bool ml_json_double(const ml_json *j, int tok, double *out);
bool ml_json_bool(const ml_json *j, int tok, bool *out);

/* True when a string or primitive token equals s exactly. */
bool ml_json_streq(const ml_json *j, int tok, const char *s);

/*
 * Convenience readers that look up a key and convert in one step, leaving
 * *out untouched and returning false when the key is missing or the wrong
 * type. These keep the layout parser free of repetitive lookup boilerplate.
 */
bool ml_json_get_str(const ml_json *j, int obj, const char *key, char *out, size_t cap);
bool ml_json_get_int(const ml_json *j, int obj, const char *key, int *out);
bool ml_json_get_double(const ml_json *j, int obj, const char *key, double *out);
bool ml_json_get_bool(const ml_json *j, int obj, const char *key, bool *out);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_JSON_H */
