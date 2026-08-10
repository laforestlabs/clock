/*
 * ble.h - NimBLE GATT server for config + layout push from the phone.
 */
#ifndef MIRROR_BLE_H
#define MIRROR_BLE_H

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Bring up the NimBLE controller and host, register the config/layout GATT
 * service and start advertising. Call once at boot, after the LAN API.
 */
esp_err_t ble_init(void);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_BLE_H */
