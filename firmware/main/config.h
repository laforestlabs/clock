/*
 * config.h - owner-set device configuration, stored in NVS.
 *
 * The phone app (Bluetooth) is the only writer. Kconfig values are the
 * factory defaults, seeded into NVS on first boot; everything the phone
 * pushes overrides them and survives reboots.
 */
#ifndef MIRROR_CONFIG_H
#define MIRROR_CONFIG_H

#include <stdbool.h>
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

/* True when clock widgets without an explicit format use a 12-hour face
 * ("03:41 PM"), false for 24-hour ("15:41"). */
bool mirror_config_clock_12h(void);

/* 'F' or 'C': the unit temperatures are shown in. */
char mirror_config_temp_unit(void);

/*
 * The stored brightness override: -1 when the device follows the layout,
 * 0..255 when the owner set a manual override (over BLE). The panel's live
 * brightness is read with panel_get_brightness().
 */
int mirror_config_brightness(void);

/*
 * The brightness the panel should run at: the manual override when one is
 * set, otherwise the value the current layout asks for. Every code path
 * that writes to the panel goes through this, so an override survives a
 * layout push.
 */
uint8_t mirror_config_effective_brightness(uint8_t layout_brightness);

/*
 * Drop the manual override (back to -1, persisted) without touching the
 * panel; the caller re-applies the layout's brightness afterwards. This is
 * the BLE "set brightness auto" path.
 */
void mirror_config_clear_brightness(void);

/*
 * Apply a partial JSON object: {"timezone","latitude","longitude","place",
 * "brightness","clock12h","temp_unit"}. Every present field is validated, and
 * nothing is persisted or applied unless all of them pass; missing fields are
 * left unchanged.
 * "timezone" must be a POSIX TZ string (the only form newlib's tzset
 * parses; IANA names are rejected rather than silently degrading the clock
 * to UTC). "brightness" is a manual override: an integer 0..255, applied to
 * the panel immediately. "clock12h" is a JSON boolean; "temp_unit" is "F" or
 * "C". On success the changed fields are written to NVS and applied:
 * timezone re-points TZ via setenv/tzset, coordinate or place changes kick a
 * provider refresh so the weather relocates promptly.
 *
 * On failure returns ESP_ERR_INVALID_ARG and err holds a human message.
 */
esp_err_t mirror_config_apply_json(const char *json, size_t len,
                                   char *err, size_t errsz);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_CONFIG_H */
