#include "png_write.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------ checksums */

static uint32_t crc_table[256];
static bool     crc_ready = false;

static void crc_init(void)
{
    for (uint32_t n = 0; n < 256; n++) {
        uint32_t c = n;
        for (int k = 0; k < 8; k++) {
            c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : (c >> 1);
        }
        crc_table[n] = c;
    }
    crc_ready = true;
}

static uint32_t crc32_buf(const uint8_t *buf, size_t len, uint32_t crc)
{
    if (!crc_ready) crc_init();
    crc ^= 0xFFFFFFFFu;
    for (size_t i = 0; i < len; i++) {
        crc = crc_table[(crc ^ buf[i]) & 0xFF] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFFu;
}

static uint32_t adler32_buf(const uint8_t *buf, size_t len)
{
    uint32_t a = 1, b = 0;
    for (size_t i = 0; i < len; i++) {
        a = (a + buf[i]) % 65521u;
        b = (b + a) % 65521u;
    }
    return (b << 16) | a;
}

/* ---------------------------------------------------------------- chunks */

static void put_be32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v >> 24);
    p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);
    p[3] = (uint8_t)v;
}

static bool write_chunk(FILE *fp, const char *type, const uint8_t *data, size_t len)
{
    uint8_t header[4];
    put_be32(header, (uint32_t)len);
    if (fwrite(header, 1, 4, fp) != 4) return false;
    if (fwrite(type, 1, 4, fp) != 4) return false;
    if (len && fwrite(data, 1, len, fp) != len) return false;

    uint32_t crc = crc32_buf((const uint8_t *)type, 4, 0);
    if (len) crc = crc32_buf(data, len, crc);

    uint8_t trailer[4];
    put_be32(trailer, crc);
    return fwrite(trailer, 1, 4, fp) == 4;
}

/*
 * Wrap raw bytes in a zlib stream built entirely from stored deflate blocks.
 * Each block carries at most 65535 bytes: a header byte (BFINAL in bit 0,
 * BTYPE 00 meaning stored), then LEN and its one's complement, then the bytes.
 */
static uint8_t *zlib_store(const uint8_t *raw, size_t raw_len, size_t *out_len)
{
    const size_t max_block = 65535;
    size_t blocks = (raw_len + max_block - 1) / max_block;
    if (blocks == 0) blocks = 1;

    size_t cap = 2 + blocks * 5 + raw_len + 4;
    uint8_t *out = (uint8_t *)malloc(cap);
    if (!out) return NULL;

    size_t w = 0;
    out[w++] = 0x78;  /* CM = deflate, CINFO = 32K window */
    out[w++] = 0x01;  /* FCHECK so that (0x78<<8 | 0x01) % 31 == 0 */

    size_t pos = 0;
    for (size_t b = 0; b < blocks; b++) {
        size_t n = raw_len - pos;
        if (n > max_block) n = max_block;

        out[w++] = (b + 1 == blocks) ? 0x01 : 0x00;
        out[w++] = (uint8_t)(n & 0xFF);
        out[w++] = (uint8_t)(n >> 8);
        out[w++] = (uint8_t)(~n & 0xFF);
        out[w++] = (uint8_t)((~n >> 8) & 0xFF);

        if (n) memcpy(out + w, raw + pos, n);
        w   += n;
        pos += n;
    }

    put_be32(out + w, adler32_buf(raw, raw_len));
    w += 4;

    *out_len = w;
    return out;
}

/* ----------------------------------------------------------------- write */

static bool write_png(const char *path, const uint8_t *rgb,
                      int w, int h, int scale, bool led_gap)
{
    if (!path || !rgb || w <= 0 || h <= 0) return false;
    if (scale < 1) scale = 1;
    if (led_gap && scale < 3) led_gap = false;

    int ow = w * scale;
    int oh = h * scale;

    /* One filter byte per row, then RGB triples. Filter type 0 (None) keeps
     * the encoder trivial; with stored blocks there is nothing to gain from
     * a smarter filter anyway. */
    size_t stride  = 1 + (size_t)ow * 3;
    size_t raw_len = stride * (size_t)oh;

    uint8_t *raw = (uint8_t *)malloc(raw_len);
    if (!raw) return false;

    for (int y = 0; y < oh; y++) {
        uint8_t *row = raw + (size_t)y * stride;
        row[0] = 0;

        int sy = y / scale;
        bool gap_row = led_gap && (y % scale == scale - 1);

        for (int x = 0; x < ow; x++) {
            int sx = x / scale;
            bool gap_col = led_gap && (x % scale == scale - 1);

            const uint8_t *src = rgb + ((size_t)sy * (size_t)w + (size_t)sx) * 3;
            uint8_t *dst = row + 1 + (size_t)x * 3;

            if (gap_row || gap_col) {
                /* Darken rather than blank, so bright pixels still bloom into
                 * the gap the way a real panel does behind diffusing glass. */
                dst[0] = (uint8_t)(src[0] / 5);
                dst[1] = (uint8_t)(src[1] / 5);
                dst[2] = (uint8_t)(src[2] / 5);
            } else {
                dst[0] = src[0];
                dst[1] = src[1];
                dst[2] = src[2];
            }
        }
    }

    size_t z_len = 0;
    uint8_t *z = zlib_store(raw, raw_len, &z_len);
    free(raw);
    if (!z) return false;

    FILE *fp = fopen(path, "wb");
    if (!fp) { free(z); return false; }

    static const uint8_t sig[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'};
    bool ok = fwrite(sig, 1, 8, fp) == 8;

    uint8_t ihdr[13];
    put_be32(ihdr + 0, (uint32_t)ow);
    put_be32(ihdr + 4, (uint32_t)oh);
    ihdr[8]  = 8;   /* bit depth */
    ihdr[9]  = 2;   /* color type 2 = truecolor RGB */
    ihdr[10] = 0;   /* deflate */
    ihdr[11] = 0;   /* adaptive filtering */
    ihdr[12] = 0;   /* no interlace */

    ok = ok && write_chunk(fp, "IHDR", ihdr, sizeof(ihdr));
    ok = ok && write_chunk(fp, "IDAT", z, z_len);
    ok = ok && write_chunk(fp, "IEND", NULL, 0);

    fclose(fp);
    free(z);
    return ok;
}

bool png_write_rgb(const char *path, const uint8_t *rgb, int w, int h, int scale)
{
    return write_png(path, rgb, w, h, scale, false);
}

bool png_write_rgb_led(const char *path, const uint8_t *rgb, int w, int h, int scale)
{
    return write_png(path, rgb, w, h, scale, true);
}
