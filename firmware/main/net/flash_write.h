/*
 * flash_write.h - run flash-write callbacks on a dedicated internal-DRAM task.
 *
 * Flash writes (esp_ota_*, SPIFFS) freeze the flash cache, and ESP-IDF asserts
 * the calling task's stack is in internal DRAM while caches are frozen. The
 * writer runs either a short batched job (NVS, SPIFFS, a layout commit) or the
 * whole OTA stream; callers are serialized by this module.
 */
#ifndef MIRROR_FLASH_WRITE_H
#define MIRROR_FLASH_WRITE_H

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Call once at boot before any flash_write_run() or flash_write_submit(). */
void flash_write_init(void);

/*
 * Run fn(ctx) on the flash-writer task (internal-DRAM stack), blocking until
 * fn returns. Serialized across callers, so it is safe from any task.
 */
esp_err_t flash_write_run(void (*fn)(void *ctx), void *ctx);

/*
 * Queue a job and return without waiting for it. The writer task releases the
 * mutex and its "done" credit when the job returns, so the next sync or async
 * caller starts only after this one has finished. Use for a job that runs
 * longer than the caller can block for (the OTA stream).
 */
esp_err_t flash_write_submit(void (*fn)(void *ctx), void *ctx);
#ifdef __cplusplus
}
#endif

#endif /* MIRROR_FLASH_WRITE_H */
