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
