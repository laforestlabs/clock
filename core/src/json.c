#include "mirror/json.h"

#include <string.h>

static ml_json_tok *tok_alloc(ml_json *j)
{
    if (j->count >= j->cap) return NULL;
    ml_json_tok *t = &j->toks[j->count++];
    t->type   = ML_JSON_UNDEFINED;
    t->start  = -1;
    t->end    = -1;
    t->size   = 0;
    t->parent = -1;
    return t;
}

/* Characters that legally terminate a bare primitive. */
static bool is_delim(char c)
{
    return c == ','  || c == '}' || c == ']' ||
           c == '\t' || c == '\r' || c == '\n' || c == ' ';
}

static int parse_primitive(ml_json *j, size_t *pos, int super)
{
    size_t start = *pos;

    for (; *pos < j->len && j->src[*pos]; (*pos)++) {
        char c = j->src[*pos];
        if (is_delim(c)) goto found;
        /* Control characters cannot appear in a bare value. */
        if (c < 32 || c >= 127) return ML_JSON_ERR_INVALID;
    }
    /* Reached the end of input without a delimiter. */
    *pos = start;
    return ML_JSON_ERR_PARTIAL;

found:;
    ml_json_tok *t = tok_alloc(j);
    if (!t) {
        *pos = start;
        return ML_JSON_ERR_NOMEM;
    }
    t->type   = ML_JSON_PRIMITIVE;
    t->start  = (int)start;
    t->end    = (int)*pos;
    t->parent = super;
    if (super != -1) j->toks[super].size++;

    (*pos)--;  /* the caller's loop advances past the delimiter */
    return 0;
}

static int parse_string(ml_json *j, size_t *pos, int super)
{
    size_t start = *pos;
    (*pos)++;  /* skip the opening quote */

    for (; *pos < j->len && j->src[*pos]; (*pos)++) {
        char c = j->src[*pos];

        if (c == '"') {
            ml_json_tok *t = tok_alloc(j);
            if (!t) {
                *pos = start;
                return ML_JSON_ERR_NOMEM;
            }
            t->type   = ML_JSON_STRING;
            t->start  = (int)start + 1;   /* offsets exclude the quotes */
            t->end    = (int)*pos;
            t->parent = super;
            if (super != -1) j->toks[super].size++;
            return 0;
        }

        if (c == '\\' && *pos + 1 < j->len) {
            (*pos)++;
            switch (j->src[*pos]) {
            case '"': case '/': case '\\': case 'b':
            case 'f': case 'r': case 'n':  case 't':
                break;
            case 'u':
                /* Require exactly four hex digits so a malformed escape is a
                 * parse error rather than a silent misread of later bytes. */
                if (*pos + 4 >= j->len) return ML_JSON_ERR_PARTIAL;
                for (int k = 1; k <= 4; k++) {
                    char h = j->src[*pos + k];
                    bool hex = (h >= '0' && h <= '9') ||
                               (h >= 'a' && h <= 'f') ||
                               (h >= 'A' && h <= 'F');
                    if (!hex) return ML_JSON_ERR_INVALID;
                }
                *pos += 4;
                break;
            default:
                return ML_JSON_ERR_INVALID;
            }
        }
    }

    *pos = start;
    return ML_JSON_ERR_PARTIAL;
}

int ml_json_parse(ml_json *j, const char *src, size_t len,
                  ml_json_tok *toks, int cap)
{
    if (!j || !src || !toks || cap <= 0) return ML_JSON_ERR_INVALID;

    j->src   = src;
    j->len   = len;
    j->toks  = toks;
    j->cap   = cap;
    j->count = 0;

    int super = -1;

    for (size_t pos = 0; pos < len && src[pos]; pos++) {
        char c = src[pos];
        int  rc;

        switch (c) {
        case '{':
        case '[': {
            ml_json_tok *t = tok_alloc(j);
            if (!t) return ML_JSON_ERR_NOMEM;
            if (super != -1) j->toks[super].size++;
            t->type   = (c == '{') ? ML_JSON_OBJECT : ML_JSON_ARRAY;
            t->start  = (int)pos;
            t->parent = super;
            super     = j->count - 1;
            break;
        }

        case '}':
        case ']': {
            ml_json_type want = (c == '}') ? ML_JSON_OBJECT : ML_JSON_ARRAY;

            /* Close the innermost container still open, checking that its type
             * matches so "{ ... ]" is rejected instead of silently accepted. */
            int i = j->count - 1;
            for (; i >= 0; i--) {
                if (j->toks[i].start != -1 && j->toks[i].end == -1) {
                    if (j->toks[i].type != want) return ML_JSON_ERR_INVALID;
                    j->toks[i].end = (int)pos + 1;
                    super = j->toks[i].parent;
                    break;
                }
            }
            if (i == -1) return ML_JSON_ERR_INVALID;

            /* Step back out of any key token to its enclosing container. */
            while (super != -1 &&
                   j->toks[super].type != ML_JSON_OBJECT &&
                   j->toks[super].type != ML_JSON_ARRAY) {
                super = j->toks[super].parent;
            }
            break;
        }

        case '"':
            rc = parse_string(j, &pos, super);
            if (rc < 0) return rc;
            break;

        case ':':
            /* The value that follows belongs to the key just read. */
            super = j->count - 1;
            break;

        case ',':
            /* Pop back out of the key so the next pair attaches to the object. */
            while (super != -1 &&
                   j->toks[super].type != ML_JSON_OBJECT &&
                   j->toks[super].type != ML_JSON_ARRAY) {
                super = j->toks[super].parent;
            }
            break;

        case ' ': case '\t': case '\r': case '\n':
            break;

        default:
            rc = parse_primitive(j, &pos, super);
            if (rc < 0) return rc;
            break;
        }
    }

    /* Any container left unclosed means the document was truncated. */
    for (int i = j->count - 1; i >= 0; i--) {
        if (j->toks[i].start != -1 && j->toks[i].end == -1) return ML_JSON_ERR_PARTIAL;
    }

    return j->count;
}

int ml_json_member(const ml_json *j, int obj, const char *key)
{
    if (!j || obj < 0 || obj >= j->count || !key) return -1;
    if (j->toks[obj].type != ML_JSON_OBJECT) return -1;

    for (int i = obj + 1; i < j->count; i++) {
        if (j->toks[i].parent != obj) continue;
        if (j->toks[i].type != ML_JSON_STRING) continue;
        if (ml_json_streq(j, i, key)) {
            /* The value is always the token immediately after its key. */
            return (i + 1 < j->count) ? i + 1 : -1;
        }
    }
    return -1;
}

int ml_json_array_count(const ml_json *j, int arr)
{
    if (!j || arr < 0 || arr >= j->count) return 0;
    if (j->toks[arr].type != ML_JSON_ARRAY) return 0;
    return j->toks[arr].size;
}

int ml_json_array_at(const ml_json *j, int arr, int index)
{
    if (!j || arr < 0 || arr >= j->count || index < 0) return -1;
    if (j->toks[arr].type != ML_JSON_ARRAY) return -1;

    int seen = 0;
    for (int i = arr + 1; i < j->count; i++) {
        if (j->toks[i].parent != arr) continue;
        if (seen == index) return i;
        seen++;
    }
    return -1;
}

bool ml_json_streq(const ml_json *j, int tok, const char *s)
{
    if (!j || tok < 0 || tok >= j->count || !s) return false;
    const ml_json_tok *t = &j->toks[tok];
    size_t n = (size_t)(t->end - t->start);
    return strlen(s) == n && strncmp(j->src + t->start, s, n) == 0;
}

static int hex4(const char *p)
{
    int v = 0;
    for (int i = 0; i < 4; i++) {
        char c = p[i];
        int d;
        if (c >= '0' && c <= '9') d = c - '0';
        else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
        else return -1;
        v = v * 16 + d;
    }
    return v;
}

bool ml_json_str(const ml_json *j, int tok, char *out, size_t cap)
{
    if (!j || tok < 0 || tok >= j->count || !out || cap == 0) return false;

    const ml_json_tok *t = &j->toks[tok];
    if (t->type != ML_JSON_STRING && t->type != ML_JSON_PRIMITIVE) {
        out[0] = '\0';
        return false;
    }

    size_t w = 0;
    for (int i = t->start; i < t->end && w + 1 < cap; i++) {
        char c = j->src[i];

        if (c != '\\' || i + 1 >= t->end) {
            out[w++] = c;
            continue;
        }

        i++;
        switch (j->src[i]) {
        case 'n':  out[w++] = '\n'; break;
        case 't':  out[w++] = '\t'; break;
        case 'r':  out[w++] = '\r'; break;
        case 'b':  out[w++] = '\b'; break;
        case 'f':  out[w++] = '\f'; break;
        case '"':  out[w++] = '"';  break;
        case '\\': out[w++] = '\\'; break;
        case '/':  out[w++] = '/';  break;
        case 'u': {
            if (i + 4 >= t->end) { out[w++] = '?'; break; }
            int cp = hex4(j->src + i + 1);
            i += 4;
            if (cp < 0)          out[w++] = '?';
            else if (cp < 0x80)  out[w++] = (char)cp;
            else if (cp == 0xB0) out[w++] = (char)127;  /* degree sign */
            else                 out[w++] = '?';        /* fonts are ASCII only */
            break;
        }
        default:
            out[w++] = j->src[i];
            break;
        }
    }

    out[w] = '\0';
    return true;
}

bool ml_json_double(const ml_json *j, int tok, double *out)
{
    if (!j || tok < 0 || tok >= j->count || !out) return false;
    const ml_json_tok *t = &j->toks[tok];
    if (t->type != ML_JSON_PRIMITIVE && t->type != ML_JSON_STRING) return false;

    const char *p   = j->src + t->start;
    const char *end = j->src + t->end;

    while (p < end && (*p == ' ' || *p == '\t')) p++;
    if (p >= end) return false;

    bool neg = false;
    if (*p == '-') { neg = true; p++; }
    else if (*p == '+') { p++; }

    /* Reject "true"/"false"/"null" before they parse as 0. */
    if (p < end && !(*p >= '0' && *p <= '9') && *p != '.') return false;

    double value = 0.0;
    bool   any   = false;
    for (; p < end && *p >= '0' && *p <= '9'; p++) {
        value = value * 10.0 + (double)(*p - '0');
        any = true;
    }

    if (p < end && *p == '.') {
        p++;
        double scale = 0.1;
        for (; p < end && *p >= '0' && *p <= '9'; p++) {
            value += (double)(*p - '0') * scale;
            scale *= 0.1;
            any = true;
        }
    }

    if (!any) return false;

    if (p < end && (*p == 'e' || *p == 'E')) {
        p++;
        bool eneg = false;
        if (p < end && (*p == '-' || *p == '+')) { eneg = (*p == '-'); p++; }
        int exp = 0;
        for (; p < end && *p >= '0' && *p <= '9'; p++) exp = exp * 10 + (*p - '0');
        if (exp > 308) exp = 308;
        for (int k = 0; k < exp; k++) value = eneg ? value / 10.0 : value * 10.0;
    }

    *out = neg ? -value : value;
    return true;
}

bool ml_json_int(const ml_json *j, int tok, int *out)
{
    double d;
    if (!ml_json_double(j, tok, &d)) return false;
    /* Round rather than truncate so 20.999 from a float source reads as 21. */
    *out = (int)(d < 0 ? d - 0.5 : d + 0.5);
    return true;
}

bool ml_json_bool(const ml_json *j, int tok, bool *out)
{
    if (!j || tok < 0 || tok >= j->count || !out) return false;
    if (ml_json_streq(j, tok, "true"))  { *out = true;  return true; }
    if (ml_json_streq(j, tok, "false")) { *out = false; return true; }
    /* Accept 1 and 0 too, since hand-written layouts routinely use them. */
    if (ml_json_streq(j, tok, "1")) { *out = true;  return true; }
    if (ml_json_streq(j, tok, "0")) { *out = false; return true; }
    return false;
}

bool ml_json_get_str(const ml_json *j, int obj, const char *key, char *out, size_t cap)
{
    int t = ml_json_member(j, obj, key);
    return t >= 0 && ml_json_str(j, t, out, cap);
}

bool ml_json_get_int(const ml_json *j, int obj, const char *key, int *out)
{
    int t = ml_json_member(j, obj, key);
    return t >= 0 && ml_json_int(j, t, out);
}

bool ml_json_get_double(const ml_json *j, int obj, const char *key, double *out)
{
    int t = ml_json_member(j, obj, key);
    return t >= 0 && ml_json_double(j, t, out);
}

bool ml_json_get_bool(const ml_json *j, int obj, const char *key, bool *out)
{
    int t = ml_json_member(j, obj, key);
    return t >= 0 && ml_json_bool(j, t, out);
}
