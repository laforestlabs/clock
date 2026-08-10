/*
 * config.h - owner-set device configuration, stored in NVS.
 *
 * The phone app (Bluetooth) is the only writer. Kconfig values are the
 * factory defaults, seeded into NVS on first boot; everything the phone
 * pushes overrides them and survives reboots.
 */
#ifndef MIRROR_CONFIG_H
#define MIRROR_CONFIG_H

#include <stddef.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Load the config from NVS, seeding any absent key from its Kconfig default.
 * Call once at boot, before sntp_time_start() so the very first synced frame
 * already uses the right zone.
 */
esp_err_t mirror_config_init(void);

/* Current values. Never NULL; "unchanged" while init has not run is not
 * possible because init always fills all four. The pointers stay valid for
 * the life of the device. */
const char *mirror_config_timezone(void);
const char *mirror_config_latitude(void);
const char *mirror_config_longitude(void);
const char *mirror_config_place(void);

/*
 * Apply a partial JSON object: {"timezone","latitude","longitude","place"}.
 * Every present field is validated, and nothing is persisted or applied
 * unless all of them pass; missing fields are left unchanged. On success the
 * changed fields are written to NVS and applied: timezone re-points TZ via
 * setenv/tzset, coordinate or place changes kick a provider refresh so the
 * weather relocates promptly.
 *
 * On failure returns ESP_ERR_INVALID_ARG and err holds a human message.
 */
esp_err_t mirror_config_apply_json(const char *json, size_t len,
                                   char *err, size_t errsz);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_CONFIG_H */
