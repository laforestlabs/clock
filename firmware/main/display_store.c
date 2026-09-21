/*
 * display_store.c - the persistent base display: the clock or one picture.
 *
 * Two SPIFFS slots hold at most one committed picture each; a single NVS byte
 * says which slot is committed, whether a picture exists, and whether the
 * picture is the base display. Everything else is derived: the inactive slot
 * is scratch space that only becomes visible when the state byte names it, so
 * an interrupted upload can only ever be ignored. The picture itself is kept
 * in PSRAM as raw pre-gamma RGB888, which the render task copies into its
 * canvas (see display_store_render_picture).
 *
 * See display_store.h for the contract and the failure principle.
 */
#include "display_store.h"

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_rom_crc.h"
#include "esp_spiffs.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "mirror/json.h"
#include "net/flash_write.h"
#include "nvs.h"
#include "panel.h"

static const char *TAG = "display";

/* One byte here holds the whole display state; the pictures live in SPIFFS. */
#define NVS_NS        "display"
#define NVS_KEY_STATE "state"

#define SPIFFS_PARTITION "storage"
#define SLOT0_FILE       "/spiffs/picture0.rgb"
#define SLOT1_FILE       "/spiffs/picture1.rgb"

/*
 * Slot file layout, little-endian: "MPI1", u16 width, u16 height, u32 payload
 * length, u32 CRC32 of the payload, then exactly width*height*3 bytes of raw
 * RGB888 and nothing else. A slot only counts when every field agrees with
 * the panel, so a half-written or foreign slot is never rendered.
 */
#define SLOT_HEADER_BYTES 16

/*
 * State byte bits: bit 0 selects the committed slot, bit 1 says a picture is
 * stored, bit 2 says the picture is the base display. Any other bit set means
 * the record was not written by this build, so it is ignored rather than
 * guessed at. No record at all means clock with no picture.
 */
#define STATE_SLOT         0x01u
#define STATE_PICTURE      0x02u
#define STATE_PICTURE_BASE 0x04u
#define STATE_KNOWN        0x07u

/* Re-read chunk for slot verification, small enough for the flash-writer
 * task's stack. */
#define VERIFY_CHUNK 512

/* Payload staging chunk for the write path. It must be internal DRAM, which
 * the flash-writer task's static stack is; 1KB matches ota.c's writer. */
#define WRITE_CHUNK 1024

/* Guards the in-RAM picture and the mode/slot the render task reads. */
static SemaphoreHandle_t s_lock;
/* Serializes mutations so two uploads or a mode change cannot interleave. */
static SemaphoreHandle_t s_writer;

static nvs_handle_t s_nvs;
static bool         s_nvs_open;
static bool         s_storage;   /* SPIFFS mounted and usable */

static uint8_t     *s_rgb;       /* PSRAM, panel_width*panel_height RGB888 */
static size_t       s_len;
static bool         s_valid;     /* s_rgb holds a complete verified picture */
static int          s_slot;      /* committed slot, 0 or 1 */
static mirror_display_mode_t s_base = MIRROR_DISPLAY_CLOCK;

static void lock(void)
{
    if (s_lock != NULL) xSemaphoreTake(s_lock, portMAX_DELAY);
}

static void unlock(void)
{
    if (s_lock != NULL) xSemaphoreGive(s_lock);
}

static void fail(char *err, size_t errsz, const char *fmt, ...)
{
    if (err == NULL || errsz == 0) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, errsz, fmt, ap);
    va_end(ap);
}

/*
 * Bytes a picture must carry for this panel, or false when this build has no
 * picture display at all. The multiplication is done in 64 bits: a build with
 * a larger panel must degrade to clock/games, not overflow its way into an
 * undersized allocation. The 16-bit header fields are checked here too, since
 * they are what a slot stores and re-reads its geometry from.
 */
static bool panel_payload(size_t *out)
{
    const int w = panel_width();
    const int h = panel_height();
    if (w <= 0 || h <= 0 || w > 0xFFFF || h > 0xFFFF) return false;

    const int64_t bytes = (int64_t)w * (int64_t)h * 3;
    if (bytes <= 0 || bytes > PANEL_PICTURE_MAX_BYTES) return false;

    *out = (size_t)bytes;
    return true;
}

static const char *slot_path(int slot)
{
    return slot ? SLOT1_FILE : SLOT0_FILE;
}

static uint16_t rd16(const uint8_t *p)
{
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

static uint32_t rd32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void wr16(uint8_t *p, uint16_t v)
{
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
}

static void wr32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

/* esp_rom_crc32_le chains, so CRCing in chunks and CRCing in one call agree.
 * The payload cap (<= 192KB) is well inside its u32 length. */
static uint32_t payload_crc(const uint8_t *rgb, size_t len)
{
    return esp_rom_crc32_le(0, rgb, (uint32_t)len);
}

/*
 * The layout store mounts SPIFFS first; this is the "is it there, and if not
 * can we get it" check for the picture files. Failing here only disables the
 * picture features for this boot, it is not fatal.
 */
static bool ensure_storage(void)
{
    size_t total = 0, used = 0;
    if (esp_spiffs_info(SPIFFS_PARTITION, &total, &used) == ESP_OK) return true;

    esp_vfs_spiffs_conf_t conf = {
        .base_path              = "/spiffs",
        .partition_label        = SPIFFS_PARTITION,
        .max_files              = 4,
        .format_if_mount_failed = true,
    };
    const esp_err_t err = esp_vfs_spiffs_register(&conf);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "picture storage unavailable: %s", esp_err_to_name(err));
        return false;
    }
    return true;
}

/*
 * Read and fully validate the committed slot. Returns a buffer holding
 * exactly len bytes when the file is complete and its CRC matches, else NULL.
 * Nothing partial is ever handed back: the caller only ever sees an adopted
 * picture or none.
 */
static uint8_t *load_slot(int slot, size_t len)
{
    const char *path = slot_path(slot);
    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        ESP_LOGW(TAG, "%s is missing or unreadable", path);
        return NULL;
    }

    uint8_t *buf = NULL;
    uint8_t hdr[SLOT_HEADER_BYTES];
    long size = -1;

    if (fseek(f, 0, SEEK_END) == 0) size = ftell(f);
    if (size < 0 || (size_t)size != SLOT_HEADER_BYTES + len) {
        ESP_LOGW(TAG, "%s is %ld bytes, expected %u", path, size,
                 (unsigned)(SLOT_HEADER_BYTES + len));
        goto done;
    }
    rewind(f);
    if (fread(hdr, 1, sizeof(hdr), f) != sizeof(hdr)) {
        ESP_LOGW(TAG, "%s header is truncated", path);
        goto done;
    }
    if (hdr[0] != 'M' || hdr[1] != 'P' || hdr[2] != 'I' || hdr[3] != '1') {
        ESP_LOGW(TAG, "%s has the wrong magic", path);
        goto done;
    }
    if (rd16(&hdr[4]) != (uint16_t)panel_width() ||
        rd16(&hdr[6]) != (uint16_t)panel_height() ||
        rd32(&hdr[8]) != (uint32_t)len) {
        ESP_LOGW(TAG, "%s header does not match this panel (%dx%d, %u bytes)",
                 path, panel_width(), panel_height(), (unsigned)len);
        goto done;
    }

    buf = heap_caps_malloc(len, MALLOC_CAP_SPIRAM);
    if (buf == NULL) {
        ESP_LOGE(TAG, "out of memory reading %s", path);
        goto done;
    }
    if (fread(buf, 1, len, f) != len) {
        ESP_LOGW(TAG, "%s payload is truncated", path);
        heap_caps_free(buf);
        buf = NULL;
        goto done;
    }
    if (payload_crc(buf, len) != rd32(&hdr[12])) {
        ESP_LOGW(TAG, "%s CRC does not match, ignoring the picture", path);
        heap_caps_free(buf);
        buf = NULL;
    }

done:
    fclose(f);
    return buf;
}

/*
 * Re-read a just-written slot from flash and check it end to end. The NVS
 * commit must never point at a slot that is short or full of the wrong bytes,
 * so this is what makes "the previous picture survives a failed upload" true
 * even when a write half-lands.
 */
static bool verify_slot(int slot, uint32_t len, uint32_t expected_crc)
{
    const char *path = slot_path(slot);
    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        ESP_LOGE(TAG, "%s is unreadable after writing", path);
        return false;
    }

    bool ok = false;
    uint8_t hdr[SLOT_HEADER_BYTES];
    uint8_t chunk[VERIFY_CHUNK];

    if (fread(hdr, 1, sizeof(hdr), f) != sizeof(hdr)) {
        ESP_LOGE(TAG, "%s header is short after writing", path);
        goto out;
    }
    if (hdr[0] != 'M' || hdr[1] != 'P' || hdr[2] != 'I' || hdr[3] != '1' ||
        rd16(&hdr[4]) != (uint16_t)panel_width() ||
        rd16(&hdr[6]) != (uint16_t)panel_height() ||
        rd32(&hdr[8]) != len || rd32(&hdr[12]) != expected_crc) {
        ESP_LOGE(TAG, "%s header does not match what was written", path);
        goto out;
    }

    uint32_t crc = 0;
    uint32_t remaining = len;
    while (remaining > 0) {
        const uint32_t n = remaining < (uint32_t)sizeof(chunk)
                               ? remaining : (uint32_t)sizeof(chunk);
        if (fread(chunk, 1, n, f) != n) {
            ESP_LOGE(TAG, "%s is truncated after writing", path);
            goto out;
        }
        crc = esp_rom_crc32_le(crc, chunk, n);
        remaining -= n;
    }
    if (fgetc(f) != EOF) {
        ESP_LOGE(TAG, "%s has trailing bytes", path);
        goto out;
    }
    if (crc != expected_crc) {
        ESP_LOGE(TAG, "%s CRC mismatch after writing", path);
        goto out;
    }
    ok = true;

out:
    fclose(f);
    return ok;
}

/* ---- the two flash-writer jobs -------------------------------------- */

typedef struct {
    int            slot;
    uint32_t       len;
    uint32_t       crc;
    const uint8_t *rgb;
    esp_err_t      err;    /* out */
} slot_write_t;

/* Runs on the flash-writer task (internal-DRAM stack), because SPIFFS writes
 * and NVS commits both freeze the flash cache and the caller may be the
 * PSRAM-backed httpd or BLE commit task. */
static void slot_write_fn(void *arg)
{
    slot_write_t *w = arg;
    const char *path = slot_path(w->slot);
    uint8_t hdr[SLOT_HEADER_BYTES];

    hdr[0] = 'M'; hdr[1] = 'P'; hdr[2] = 'I'; hdr[3] = '1';
    wr16(&hdr[4], (uint16_t)panel_width());
    wr16(&hdr[6], (uint16_t)panel_height());
    wr32(&hdr[8], w->len);
    wr32(&hdr[12], w->crc);

    /*
     * The payload is streamed through a stack chunk, the same rule and shape
     * as ota.c's writer: the picture buffer lives in PSRAM, and only internal
     * DRAM is readable in the cache-frozen window a flash write opens. The
     * chunk sits on this task's static internal-DRAM stack, so no per-upload
     * heap is needed for it.
     */
    uint8_t chunk[WRITE_CHUNK];
    bool failed = false;

    FILE *f = fopen(path, "wb");
    if (f == NULL) {
        ESP_LOGE(TAG, "could not open %s for writing", path);
        w->err = ESP_FAIL;
        return;
    }
    if (fwrite(hdr, 1, sizeof(hdr), f) != sizeof(hdr)) {
        ESP_LOGE(TAG, "writing %s failed in the header", path);
        failed = true;
    }
    size_t off = 0;
    while (!failed && off < w->len) {
        const size_t n = (w->len - off < sizeof(chunk))
                             ? (size_t)(w->len - off) : sizeof(chunk);
        memcpy(chunk, w->rgb + off, n);
        if (fwrite(chunk, 1, n, f) != n) {
            ESP_LOGE(TAG, "writing %s failed at %u of %u bytes", path,
                     (unsigned)off, (unsigned)w->len);
            failed = true;
        }
        off += n;
    }
    const int flush_err = fflush(f);
    const int close_err = fclose(f);
    if (flush_err != 0 || close_err != 0) {
        ESP_LOGE(TAG, "writing %s did not flush or close cleanly (%d, %d)",
                 path, flush_err, close_err);
        failed = true;
    }
    if (failed) {
        w->err = ESP_FAIL;
        return;
    }

    if (!verify_slot(w->slot, w->len, w->crc)) {
        w->err = ESP_FAIL;
        return;
    }

    /* The single state byte is the commit point: it selects this slot and
     * records the picture as the base display. Until it lands the slot is
     * uncommitted and next boot ignores it. */
    const uint8_t state = (uint8_t)((w->slot ? STATE_SLOT : 0) |
                                    STATE_PICTURE | STATE_PICTURE_BASE);
    esp_err_t err = nvs_set_u8(s_nvs, NVS_KEY_STATE, state);
    if (err == ESP_OK) err = nvs_commit(s_nvs);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "could not commit the display state: %s",
                 esp_err_to_name(err));
        w->err = ESP_FAIL;
        return;
    }

    ESP_LOGI(TAG, "picture persisted to slot %d (%u bytes)", w->slot,
             (unsigned)w->len);
    w->err = ESP_OK;
}

typedef struct {
    uint8_t   state;
    esp_err_t err;    /* out */
} state_write_t;

/* Mode-only change: one state byte, same flash path as an upload. */
static void state_write_fn(void *arg)
{
    state_write_t *w = arg;
    esp_err_t err = nvs_set_u8(s_nvs, NVS_KEY_STATE, w->state);
    if (err == ESP_OK) err = nvs_commit(s_nvs);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "could not save the display state: %s",
                 esp_err_to_name(err));
    }
    w->err = err;
}

typedef struct {
    bool      storage;
    bool      nvs;
    esp_err_t err;    /* out */
} clear_t;

/*
 * Factory reset removes both slot files and then the state record. Any failure
 * is reported to the caller, which must not claim reset completed or reboot.
 */
static void clear_fn(void *arg)
{
    clear_t *c = arg;

    if (c->storage) {
        for (int slot = 0; slot < 2; slot++) {
            const char *path = slot_path(slot);
            if (remove(path) != 0 && errno != ENOENT) {
                ESP_LOGE(TAG, "could not remove %s: errno %d", path, errno);
                c->err = ESP_FAIL;
                return;
            }
        }
    }

    if (c->nvs) {
        esp_err_t err = nvs_erase_key(s_nvs, NVS_KEY_STATE);
        if (err == ESP_ERR_NVS_NOT_FOUND) err = ESP_OK;
        if (err == ESP_OK) err = nvs_commit(s_nvs);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "could not erase the display state: %s",
                     esp_err_to_name(err));
            c->err = ESP_FAIL;
            return;
        }
    } else {
        /* Without NVS this build could never have written a record, but a
         * record this code cannot erase is exactly what would show an old
         * picture after a reset, so report the failure rather than assume. */
        ESP_LOGE(TAG, "display state could not be erased: NVS unavailable");
        c->err = ESP_FAIL;
        return;
    }

    c->err = ESP_OK;
}

/* ---- public API ----------------------------------------------------- */

esp_err_t display_store_init(void)
{
    s_lock = xSemaphoreCreateMutex();
    s_writer = xSemaphoreCreateMutex();
    if (s_lock == NULL || s_writer == NULL) {
        ESP_LOGE(TAG, "could not create the display store mutexes");
        return ESP_ERR_NO_MEM;
    }

    esp_err_t first_err = ESP_OK;

    s_storage = ensure_storage();
    if (!s_storage) {
        /* Not fatal: the clock and the games do not need the picture store.
         * The panel already said so above. */
        ESP_LOGW(TAG, "no picture storage; the clock is the base display");
        first_err = ESP_FAIL;
    }

    s_nvs_open = nvs_open(NVS_NS, NVS_READWRITE, &s_nvs) == ESP_OK;
    if (!s_nvs_open) {
        ESP_LOGE(TAG, "display state storage unavailable");
        if (first_err == ESP_OK) first_err = ESP_FAIL;
    }

    size_t expect = 0;
    if (!panel_payload(&expect)) {
        /* A build whose panel cannot hold a 256x256 frame still draws the
         * clock and the games; it just has no picture display to offer. */
        ESP_LOGW(TAG, "panel %dx%d cannot hold a picture; picture display disabled",
                 panel_width(), panel_height());
        s_base = MIRROR_DISPLAY_CLOCK;
        return first_err;
    }

    if (!s_storage || !s_nvs_open) return first_err;

    uint8_t state = 0;
    esp_err_t err = nvs_get_u8(s_nvs, NVS_KEY_STATE, &state);
    if (err == ESP_ERR_NVS_NOT_FOUND) {
        ESP_LOGI(TAG, "no stored display state; the clock is the base display");
        return first_err;
    }
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "display state unreadable (%s); the clock is the base display",
                 esp_err_to_name(err));
        return first_err;
    }
    if ((state & (uint8_t)~STATE_KNOWN) != 0) {
        ESP_LOGW(TAG, "display state 0x%02x has unknown bits; the clock is the base display",
                 state);
        return first_err;
    }

    s_slot = (state & STATE_SLOT) ? 1 : 0;

    if ((state & STATE_PICTURE) == 0) {
        if ((state & STATE_PICTURE_BASE) != 0) {
            ESP_LOGW(TAG, "display state claims picture mode without a picture; showing the clock");
        }
        return first_err;
    }

    /* Load only the committed slot under a fresh allocation: an uncommitted
     * slot may be anything at all and is deliberately ignored. */
    uint8_t *rgb = load_slot(s_slot, expect);
    if (rgb == NULL) {
        ESP_LOGW(TAG, "the stored picture in slot %d is unusable; the clock is the base display",
                 s_slot);
        return first_err;
    }

    s_rgb = rgb;
    s_len = expect;
    s_valid = true;
    s_base = (state & STATE_PICTURE_BASE) ? MIRROR_DISPLAY_PICTURE
                                          : MIRROR_DISPLAY_CLOCK;
    ESP_LOGI(TAG, "restored the stored picture (%dx%d) as the %s base display",
             panel_width(), panel_height(), display_mode_name(s_base));
    return first_err;
}

mirror_display_mode_t display_store_base_mode(void)
{
    lock();
    const mirror_display_mode_t mode = s_base;
    unlock();
    return mode;
}

bool display_store_picture_ready(void)
{
    lock();
    const bool ready = s_valid && s_rgb != NULL;
    unlock();
    return ready;
}

const char *display_mode_name(mirror_display_mode_t mode)
{
    switch (mode) {
    case MIRROR_DISPLAY_PICTURE:
        return "picture";
    case MIRROR_DISPLAY_GAMES:
        return "games";
    case MIRROR_DISPLAY_CLOCK:
    default:
        return "clock";
    }
}

esp_err_t display_store_set_mode(mirror_display_mode_t mode,
                                 char *err, size_t errsz)
{
    if (mode == MIRROR_DISPLAY_GAMES) {
        fail(err, errsz, "games are started over Bluetooth, not saved");
        return ESP_ERR_INVALID_ARG;
    }
    if (mode != MIRROR_DISPLAY_CLOCK && mode != MIRROR_DISPLAY_PICTURE) {
        fail(err, errsz, "mode must be \"clock\" or \"picture\"");
        return ESP_ERR_INVALID_ARG;
    }
    if (s_writer == NULL) {
        fail(err, errsz, "display store is not initialised");
        return ESP_ERR_INVALID_STATE;
    }
    if (mode == MIRROR_DISPLAY_PICTURE && !display_store_picture_ready()) {
        fail(err, errsz, "picture missing");
        return ESP_ERR_INVALID_STATE;
    }
    if (!s_nvs_open) {
        fail(err, errsz, "display storage unavailable");
        return ESP_FAIL;
    }

    xSemaphoreTake(s_writer, portMAX_DELAY);

    lock();
    const int slot = s_slot;
    const bool has_picture = s_valid;
    unlock();

    state_write_t ctx = {
        .state = (uint8_t)((slot ? STATE_SLOT : 0) |
                           (has_picture ? STATE_PICTURE : 0) |
                           (mode == MIRROR_DISPLAY_PICTURE ? STATE_PICTURE_BASE : 0)),
        .err = ESP_FAIL,
    };
    const esp_err_t run = flash_write_run(state_write_fn, &ctx);
    if (run != ESP_OK || ctx.err != ESP_OK) {
        xSemaphoreGive(s_writer);
        fail(err, errsz, "display state could not be saved");
        return ESP_FAIL;
    }

    /* Only after the state byte landed does the render task see the new base
     * display, so a failure above leaves the old one in force. */
    lock();
    s_base = mode;
    unlock();
    xSemaphoreGive(s_writer);

    ESP_LOGI(TAG, "base display is now the %s", display_mode_name(mode));
    return ESP_OK;
}

esp_err_t display_store_apply_mode_json(const char *json, size_t len,
                                        char *err, size_t errsz)
{
    if (json == NULL || len == 0) {
        fail(err, errsz, "empty mode request");
        return ESP_ERR_INVALID_ARG;
    }

    /* 16 tokens, like mirror_config_apply_json: "mode" is required and
     * strictly validated, other members are ignored. The request is bounded
     * to 64 bytes by the HTTP handler anyway. */
    ml_json_tok toks[16];
    ml_json j;
    const int n = ml_json_parse(&j, json, len, toks, 16);
    if (n < 0 || j.count == 0 || j.toks[0].type != ML_JSON_OBJECT) {
        fail(err, errsz, "expected a JSON object");
        return ESP_ERR_INVALID_ARG;
    }

    const int t = ml_json_member(&j, 0, "mode");
    if (t < 0) {
        fail(err, errsz, "mode is required");
        return ESP_ERR_INVALID_ARG;
    }
    if (ml_json_streq(&j, t, "clock")) {
        return display_store_set_mode(MIRROR_DISPLAY_CLOCK, err, errsz);
    }
    if (ml_json_streq(&j, t, "picture")) {
        return display_store_set_mode(MIRROR_DISPLAY_PICTURE, err, errsz);
    }
    if (ml_json_streq(&j, t, "games")) {
        fail(err, errsz, "games are started over Bluetooth, not saved");
        return ESP_ERR_INVALID_ARG;
    }
    fail(err, errsz, "mode must be \"clock\" or \"picture\"");
    return ESP_ERR_INVALID_ARG;
}

esp_err_t display_store_apply_picture(const uint8_t *rgb, size_t len,
                                      char *err, size_t errsz)
{
    size_t expect = 0;
    if (!panel_payload(&expect)) {
        fail(err, errsz, "this panel cannot hold a picture");
        return ESP_ERR_NOT_SUPPORTED;
    }
    if (rgb == NULL || len == 0) {
        fail(err, errsz, "empty picture");
        return ESP_ERR_INVALID_ARG;
    }
    if (len != expect) {
        fail(err, errsz, "picture is %u bytes, expected %u for %dx%d",
             (unsigned)len, (unsigned)expect, panel_width(), panel_height());
        return ESP_ERR_INVALID_SIZE;
    }
    if (s_writer == NULL) {
        fail(err, errsz, "display store is not initialised");
        return ESP_ERR_INVALID_STATE;
    }
    if (!s_storage || !s_nvs_open) {
        fail(err, errsz, "display storage unavailable");
        return ESP_FAIL;
    }

    /*
     * Copy into a fresh PSRAM buffer first. The live image must not change
     * until the commit succeeds, and failing here leaves the previous picture
     * and mode completely untouched.
     */
    uint8_t *copy = heap_caps_malloc(len, MALLOC_CAP_SPIRAM);
    if (copy == NULL) {
        fail(err, errsz, "out of memory storing the picture");
        return ESP_ERR_NO_MEM;
    }
    memcpy(copy, rgb, len);

    xSemaphoreTake(s_writer, portMAX_DELAY);

    lock();
    const int slot = s_slot ^ 1;    /* never overwrite the committed slot */
    unlock();

    slot_write_t ctx = {
        .slot = slot,
        .len = (uint32_t)len,
        .crc = payload_crc(copy, len),
        .rgb = copy,
        .err = ESP_FAIL,
    };
    const esp_err_t run = flash_write_run(slot_write_fn, &ctx);
    if (run != ESP_OK || ctx.err != ESP_OK) {
        xSemaphoreGive(s_writer);
        heap_caps_free(copy);
        fail(err, errsz, "picture could not be saved");
        return ESP_FAIL;
    }

    /* Committed: adopt the new image, then drop the old one. A writer that
     * arrived meanwhile would have been blocked on s_writer, and the render
     * task either sees the old image or the new one, never a blend. */
    lock();
    uint8_t *old = s_rgb;
    s_rgb = copy;
    s_len = len;
    s_valid = true;
    s_slot = slot;
    s_base = MIRROR_DISPLAY_PICTURE;
    unlock();

    heap_caps_free(old);
    xSemaphoreGive(s_writer);
    return ESP_OK;
}

bool display_store_render_picture(ml_canvas *canvas)
{
    if (canvas == NULL || canvas->px == NULL || canvas->w <= 0 || canvas->h <= 0) {
        return false;
    }

    lock();
    const size_t pixels = (size_t)canvas->w * (size_t)canvas->h;
    const bool ok = s_valid && s_rgb != NULL &&
                    s_base == MIRROR_DISPLAY_PICTURE &&
                    canvas->w == panel_width() && canvas->h == panel_height() &&
                    s_len == pixels * 3;
    if (ok) {
        /* Raw pre-gamma RGB straight into the canvas: ml_canvas_export_rgb888
         * applies the gamma curve once, exactly as it does for a layout, and
         * panel_blit_rgb888 owns the flip180/wiring pass. */
        const uint8_t *src = s_rgb;
        ml_rgb *dst = canvas->px;
        for (size_t i = 0; i < pixels; i++) {
            dst[i].r = src[i * 3];
            dst[i].g = src[i * 3 + 1];
            dst[i].b = src[i * 3 + 2];
        }
    }
    unlock();
    return ok;
}

esp_err_t display_store_clear(void)
{
    if (s_writer == NULL) return ESP_ERR_INVALID_STATE;

    xSemaphoreTake(s_writer, portMAX_DELAY);

    clear_t ctx = { .storage = s_storage, .nvs = s_nvs_open, .err = ESP_FAIL };
    const esp_err_t run = flash_write_run(clear_fn, &ctx);
    if (run != ESP_OK || ctx.err != ESP_OK) {
        xSemaphoreGive(s_writer);
        return ESP_FAIL;
    }

    lock();
    uint8_t *old = s_rgb;
    s_rgb = NULL;
    s_len = 0;
    s_valid = false;
    s_base = MIRROR_DISPLAY_CLOCK;
    unlock();

    heap_caps_free(old);
    xSemaphoreGive(s_writer);
    ESP_LOGI(TAG, "display cleared; the clock is the base display");
    return ESP_OK;
}
