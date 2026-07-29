/*
 * wifi.h - station mode with automatic reconnect.
 *
 * Non-blocking by design. A mirror that stops drawing because the router
 * rebooted is worse than one showing slightly stale weather, so nothing here
 * ever blocks the render loop. Callers poll wifi_is_connected() and let the
 * model reflect whatever is true.
 */
#ifndef MIRROR_WIFI_H
#define MIRROR_WIFI_H

#include <stdbool.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Starts the station and returns immediately. Connection happens in the
 * background and retries on its own. */
esp_err_t wifi_start(void);

bool wifi_is_connected(void);

/* Signal strength in dBm, or 0 when not associated. */
int wifi_rssi(void);

/* Dotted-quad address, or "0.0.0.0" before DHCP completes. Never NULL. */
const char *wifi_ip(void);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_WIFI_H */
