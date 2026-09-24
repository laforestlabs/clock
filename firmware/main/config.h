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

/*
 * The commute route and the credential that fetches it. "from" and "to" are
 * "lat,lon" pairs in the form the routing service wants, so the firmware can
 * substitute them straight into the URL; the label is what the traffic widget
 * prints. The key is the owner's TomTom credential and is empty when none has
 * been stored. Never NULL, and valid for the life of the device, like the
 * accessors above.
 */
const char *mirror_config_traffic_key(void);
const char *mirror_config_route_from(void);
const char *mirror_config_route_to(void);
const char *mirror_config_route_label(void);

/* True when both ends of the commute are configured. The traffic provider
 * makes no network call while this is false. */
bool mirror_config_has_route(void);

/* True when clock widgets without an explicit format use a 12-hour face
 * ("3:41"), false for 24-hour ("15:41"). */
bool mirror_config_clock_12h(void);

/* True when the panel is mounted upside down. The panel rotates every frame
 * 180 degrees to compensate; the stored layout is unaffected. */
bool mirror_config_flip180(void);

/* 'F' or 'C': the unit temperatures are shown in. */
char mirror_config_temp_unit(void);

/*
 * The name the device broadcasts over Bluetooth and shows in the app.
 * Without an owner-set override it is generated from the station MAC: a
 * verb and an animal picked out of the tables in config.c, so every
 * device gets its own combo ("Prancing Platypus") and the name survives
 * reboots without being stored anywhere. An owner rename (the "name"
 * config field, kept in NVS) replaces it until a factory reset.
 */
const char *mirror_config_device_name(void);

/*
 * The device's hardware identity: the Wi-Fi station MAC as exactly 12
 * lowercase hexadecimal digits with no separators ("a1b2c3d4e5f6"), cached
 * during mirror_config_init(). It is what /api/status, the BLE "get device"
 * reply and the mDNS hostname all report, so one board keeps one identity
 * across transports and across an owner rename.
 *
 * Deliberately not the friendly name above (renamable, and two boards may
 * share one) and not a BLE remote address (which is per-phone and can be
 * randomised). Never NULL.
 */
const char *mirror_config_device_id(void);

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
 * Factory reset: erase every key in the device's NVS namespace (config
 * fields, saved WiFi credentials, the station hint: everything the owner
 * set) and reload the in-RAM copies from the Kconfig defaults so the live
 * values match what the next boot will load. Callers reboot the chip
 * afterwards; this function does not restart or touch the layout store.
 * Returns ESP_OK when the namespace is gone, or the NVS error.
 */
esp_err_t mirror_config_factory_reset(void);

/*
 * Apply a partial JSON object: {"name","timezone","latitude","longitude",
 * "place","brightness","clock12h","flip180","temp_unit","route_from",
 * "route_to","route_label","traffic_key"}. Every present field is validated,
 * and nothing is persisted or applied unless all of them pass; missing fields
 * are left unchanged.
 * "name" is the new Bluetooth-advertised device name: printable, trimmed,
 * 1..24 characters. "timezone" must be a POSIX TZ string (the only form newlib's tzset
 * parses; IANA names are rejected rather than silently degrading the clock
 * to UTC). "brightness" is a manual override: an integer 0..255, applied to
 * the panel immediately. "clock12h" is a JSON boolean; "flip180" is a JSON
 * boolean that says the panel is mounted upside down, so every frame is
 * rotated 180 degrees on the device, applied immediately; "temp_unit" is "F"
 * or "C". "route_from" and "route_to" are "lat,lon" pairs with the latitude in
 * [-90, 90] and the longitude in [-180, 180]; "route_label" is printable ASCII
 * of at most 15 characters; "traffic_key" is printable ASCII of at most 64,
 * and the empty string clears the stored key. On success the changed fields
 * are written to NVS and applied: timezone re-points TZ via setenv/tzset,
 * coordinate or place changes kick a provider refresh so the weather relocates
 * promptly, a route or key change invalidates the current commute reading
 * before refreshing, and a name change takes effect when the device advertises
 * again.
 *
 * On failure returns ESP_ERR_INVALID_ARG and err holds a human message.
 */
esp_err_t mirror_config_apply_json(const char *json, size_t len,
                                   char *err, size_t errsz);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_CONFIG_H */
