/*
 * netlog.h - compact nonvolatile ring of network/error events.
 *
 * Lives in the existing SPIFFS "storage" partition as a single fixed-size
 * file, so a mirror that crashes or loses power still has the history of
 * "what happened before the reboot" for the developer. It is a diagnostic
 * tool, not a general logger: entries are 8 bytes, event codes only, and the
 * UART console keeps its usual role of carrying the full text logs.
 *
 * Every event is written through the flash-writer task (flash_write_run), so
 * callers may run on PSRAM-backed stacks. The file is a ring: oldest entries
 * are overwritten, the size never grows.
 */
#ifndef MIRROR_NETLOG_H
#define MIRROR_NETLOG_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Event codes, persisted in the log. Append new codes; never renumber. */
typedef enum {
    NETLOG_EVT_BOOT = 0,
    NETLOG_EVT_WIFI_CONNECTING = 1,
    NETLOG_EVT_WIFI_CONNECTED = 2,
    NETLOG_EVT_WIFI_GOT_IP = 3,
    NETLOG_EVT_WIFI_DISCONNECTED = 4,
    NETLOG_EVT_PORTAL_OPENED = 5,
    NETLOG_EVT_PORTAL_CLOSED = 6,
    NETLOG_EVT_WEATHER_FETCH_OK = 7,
    NETLOG_EVT_WEATHER_FETCH_FAIL = 8,
    NETLOG_EVT_WEATHER_STALE = 9,
    NETLOG_EVT_CLOCK_SYNCED = 10,
    NETLOG_EVT_OTA_BEGIN = 11,
    NETLOG_EVT_OTA_OK = 12,
    NETLOG_EVT_COUNT
} netlog_evt_t;

/* Detail classes for NETLOG_EVT_WEATHER_FETCH_FAIL, so the persisted byte is
 * a project enum rather than a raw esp_err that could drift between builds. */
typedef enum {
    NETLOG_ERR_CONNECT = 1,   /* transport/DNS: no route, no answer, timeout */
    NETLOG_ERR_HTTP = 2,      /* service answered non-2xx, or a read error */
    NETLOG_ERR_PARSE = 3,     /* payload did not parse, or a field was absent */
    NETLOG_ERR_NOMEM = 4,     /* response larger than the fetch buffer */
} netlog_err_class_t;

/* On-disk sizes, in bytes. A 16-byte header plus 4096 eight-byte entries. */
#define NETLOG_HEADER_SIZE 16
#define NETLOG_ENTRY_SIZE  8
#define NETLOG_SLOTS       4096
#define NETLOG_FILE_SIZE   (NETLOG_HEADER_SIZE + NETLOG_SLOTS * NETLOG_ENTRY_SIZE)

/*
 * Open the log, record the BOOT entry with the reset reason. Call once at
 * boot, after SPIFFS is mounted (layout_store_init) and flash_write_init().
 */
void netlog_init(void);

/*
 * Append one entry. rssi is dBm or 0 when not applicable; detail is event
 * specific (wifi reason, error class, attempt, reset reason). Blocks until
 * the write completes, so call it from code that can afford a few ms of
 * flash latency, never from the flash-writer task itself.
 */
void netlog_record(netlog_evt_t evt, int rssi, int detail);

/*
 * Record the wall-clock epoch of uptime 0 now that the clock has synced.
 * Lets the dump turn each entry's uptime_s into absolute time, including the
 * pre-sync entries. Idempotent; cheap when the clock has not yet synced.
 */
void netlog_set_boot_epoch(void);

/* Read up to cap bytes of the raw log file starting at byte offset, on the
 * flash-writer task (SPIFFS reads disable the flash cache). buf must be
 * internal DRAM. Returns bytes read; 0 at end of file. Used by GET /api/log. */
size_t netlog_read(char *buf, size_t cap, size_t offset);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_NETLOG_H */
