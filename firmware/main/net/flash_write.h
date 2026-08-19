/*
 * flash_write.h - run a flash-write callback on a dedicated internal-DRAM task.
 *
 * Flash writes (esp_ota_*, SPIFFS) freeze the flash cache, and ESP-IDF asserts
 * the calling task's stack is in internal DRAM while caches are frozen. The
 * httpd task lives in PSRAM (internal DRAM is the scarce resource), so flash
 * writes reachable from httpd are routed through this module instead.
 */
#ifndef MIRROR_FLASH_WRITE_H
#define MIRROR_FLASH_WRITE_H

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Call once at boot before any flash_write_run(). */
void flash_write_init(void);

/*
 * Run fn(ctx) on the flash-writer task (internal-DRAM stack), blocking until
 * fn returns. Serialized across callers, so it is safe from any task.
 */
esp_err_t flash_write_run(void (*fn)(void *ctx), void *ctx);

#ifdef __cplusplus
}
#endif

#endif /* MIRROR_FLASH_WRITE_H */
