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
 * Create the commit worker and its queue. Call early in app_main, before
 * the panel claims its DMA buffers: the worker needs an 8KB contiguous
 * internal-RAM stack, and by the time ble_init() runs, panel DMA, WiFi and
 * the BT controller have consumed almost all internal SRAM, leaving no block
 * that large. The worker only blocks on the queue until a commit arrives, so
 * starting it early costs nothing. It is independent of the BT stack.
 */
esp_err_t ble_commit_init(void);

/*
 * Bring up the NimBLE controller and host, register the config/layout GATT
 * service and start advertising. Call once at boot, after the LAN API.
 */
esp_err_t ble_init(void);

/*
 * Send one status line from any task (locks internally; no-ops with no
 * connection). The game runner sends its replies through this, from the
 * render task, so it must be safe off the BLE host task.
 */
void ble_send_status_line(const char *line);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_BLE_H */
