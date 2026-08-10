/*
 * provision.h - captive-portal WiFi provisioning.
 *
 * The device has no compiled-in credentials. On first boot, or whenever the
 * saved network stops working, it creates its own access point and serves a
 * setup page at http://192.168.4.1 where the owner types their home WiFi
 * details. Those are stored in NVS and used from then on.
 */
#ifndef MIRROR_PROVISION_H
#define MIRROR_PROVISION_H

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Load saved credentials from NVS. Must run after nvs_flash_init(). */
esp_err_t provision_init(void);

/* Boot entry. Either joins the saved network (opening the setup portal if it
 * cannot) or opens the portal directly when nothing is saved. */
esp_err_t provision_start(void);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_PROVISION_H */
