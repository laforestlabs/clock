/*
 * ota.h - streaming firmware updates over the existing Bluetooth transport.
 */
#ifndef MIRROR_OTA_H
#define MIRROR_OTA_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

esp_err_t ota_init(void);

/*
 * Start (offset 0) or resume (offset > 0) a session. Returns:
 *   ESP_OK                accepted; data writes may follow
 *   ESP_ERR_INVALID_ARG   size 0 or larger than the target slot, or a resume
 *                         that does not match the retained session
 *   ESP_ERR_NOT_FOUND     no alternative OTA app slot in the partition table
 *   ESP_ERR_INVALID_STATE the flash writer was busy; the same begin will work
 *   ESP_ERR_NO_MEM        no contiguous OTA_RING_BYTES for the receive ring
 * These are the codes ble.c turns into "begin error <reason>" and into the
 * netlog's OTA_FAIL detail, so they are part of the protocol, not internals.
 */
esp_err_t ota_session_begin(size_t total, size_t offset);
esp_err_t ota_session_append(const uint8_t *data, size_t len);
esp_err_t ota_session_finish(void);
void ota_session_abort(void);
size_t ota_session_written(void);
size_t ota_session_total(void);
bool ota_session_active(void);

/* Mark the running app valid so the boot loader does not roll it back. */
void ota_mark_valid(void);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_OTA_H */
