#include "netlog.h"

#include <stdio.h>
#include <string.h>
#include <time.h>

#include "esp_log.h"
#include "esp_system.h"
#include "esp_timer.h"

#include "net/flash_write.h"

static const char *TAG = "netlog";

#define NETLOG_PATH "/spiffs/netlog.bin"
#define MAGIC       "NLOG"
#define VERSION     1

/* On-disk layout. Sizes are asserted below so a future field edit that
 * changes the layout fails loudly instead of corrupting the ring. */
typedef struct {
    uint8_t  magic[4];
    uint8_t  version;
    uint8_t  reserved;
    uint16_t head;       /* slot index of the next write */
    uint32_t count;      /* total entries ever written (monotonic) */
    uint32_t boot_epoch; /* epoch at uptime 0; 0 until the clock syncs */
} netlog_header_t;

typedef struct {
    uint32_t uptime_s;
    uint8_t  event;
    int8_t   rssi;
    uint8_t  detail;
    uint8_t  reserved;
} netlog_entry_t;

_Static_assert(sizeof(netlog_header_t) == NETLOG_HEADER_SIZE, "netlog header size");
_Static_assert(sizeof(netlog_entry_t) == NETLOG_ENTRY_SIZE, "netlog entry size");

typedef struct {
    netlog_entry_t entry;
    uint32_t       boot_epoch;
    bool           have_epoch;
} netlog_write_ctx_t;

/* The boot epoch is cached in RAM and mirrored into the header on every
 * write, so there is no separate header write and no tear between the ring
 * index and the timestamp. */
static uint32_t s_boot_epoch;
static bool     s_have_epoch;
static bool     s_ready;

static uint32_t uptime_s(void)
{
    return (uint32_t)(esp_timer_get_time() / 1000000);
}

/*
 * Runs on the flash-writer task (internal-DRAM stack), because SPIFFS writes
 * freeze the flash cache and a PSRAM-backed caller's stack would be
 * unreachable in that window.
 *
 * Ring update order matters: write the entry first, then advance the head. A
 * crash between the two leaves the head pointing at the slot just written,
 * so the next write overwrites that torn entry and the index stays consistent.
 */
static void write_fn(void *arg)
{
    const netlog_write_ctx_t *c = arg;
    netlog_header_t hdr;
    memset(&hdr, 0, sizeof(hdr));
    bool have_hdr = false;

    FILE *f = fopen(NETLOG_PATH, "r+b");
    if (f == NULL) {
        f = fopen(NETLOG_PATH, "w+b");
    } else {
        have_hdr = fread(&hdr, 1, sizeof(hdr), f) == sizeof(hdr) &&
                   memcmp(hdr.magic, MAGIC, 4) == 0 &&
                   hdr.version == VERSION;
        if (!have_hdr) {
            fclose(f);
            f = fopen(NETLOG_PATH, "w+b");
        }
    }

    if (f == NULL) {
        ESP_LOGW(TAG, "could not open %s", NETLOG_PATH);
        return;
    }

    if (!have_hdr) {
        memcpy(hdr.magic, MAGIC, 4);
        hdr.version = VERSION;
        if (fwrite(&hdr, 1, sizeof(hdr), f) != sizeof(hdr)) {
            ESP_LOGW(TAG, "could not write the header");
            fclose(f);
            return;
        }
    }

    /* Slots are written in ascending order, so the file grows naturally from
     * the header up to NETLOG_FILE_SIZE and then stays there. No seek past
     * the current end ever happens, which SPIFFS does not handle. */
    const uint16_t slot = (uint16_t)(hdr.head % NETLOG_SLOTS);
    const long off = (long)(sizeof(hdr) + (size_t)slot * sizeof(netlog_entry_t));

    bool ok = true;
    if (fseek(f, off, SEEK_SET) != 0) ok = false;
    if (ok && fwrite(&c->entry, 1, sizeof(c->entry), f) != sizeof(c->entry)) {
        ok = false;
    }

    hdr.head = (uint16_t)((hdr.head + 1) % NETLOG_SLOTS);
    hdr.count++;
    if (c->have_epoch) hdr.boot_epoch = c->boot_epoch;

    if (ok && fseek(f, 0, SEEK_SET) != 0) ok = false;
    if (ok && fwrite(&hdr, 1, sizeof(hdr), f) != sizeof(hdr)) ok = false;

    fclose(f);
    if (!ok) ESP_LOGW(TAG, "log append failed");
}

void netlog_init(void)
{
    s_ready = true;
    netlog_record(NETLOG_EVT_BOOT, 0, (int)esp_reset_reason());
}

void netlog_record(netlog_evt_t evt, int rssi, int detail)
{
    if (!s_ready) return;

    netlog_write_ctx_t ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.entry.uptime_s = uptime_s();
    ctx.entry.event    = (uint8_t)evt;
    ctx.entry.rssi     = (int8_t)rssi;
    ctx.entry.detail   = (uint8_t)detail;
    ctx.boot_epoch     = s_boot_epoch;
    ctx.have_epoch     = s_have_epoch;

    flash_write_run(write_fn, &ctx);
}

void netlog_set_boot_epoch(void)
{
    const time_t now = time(NULL);
    if (now < 1700000000) return; /* 2023-11-14: not plausibly synced */
    s_boot_epoch = (uint32_t)((uint64_t)now - (uint64_t)uptime_s());
    s_have_epoch = true;
}

typedef struct {
    char  *buf;
    size_t cap;
    size_t offset;
    size_t len;
} netlog_read_ctx_t;

/* Runs on the flash-writer task: SPIFFS reads disable the flash cache too,
 * so they need an internal-DRAM stack exactly like writes do. */
static void read_fn(void *arg)
{
    netlog_read_ctx_t *c = arg;
    FILE *f = fopen(NETLOG_PATH, "rb");
    if (f == NULL) {
        c->len = 0;
        return;
    }
    fseek(f, (long)c->offset, SEEK_SET);
    c->len = fread(c->buf, 1, c->cap, f);
    fclose(f);
}

size_t netlog_read(char *buf, size_t cap, size_t offset)
{
    if (buf == NULL || cap == 0) return 0;

    netlog_read_ctx_t ctx = { .buf = buf, .cap = cap, .offset = offset, .len = 0 };
    if (flash_write_run(read_fn, &ctx) != ESP_OK) return 0;
    return ctx.len;
}
