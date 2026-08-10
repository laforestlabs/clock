/*
 * wifi.h - station mode with automatic reconnect.
 *
 * Non-blocking by design. A mirror that stops drawing because the router
 * rebooted is worse than one showing slightly stale weather, so nothing here
 * ever blocks the render loop. Callers poll wifi_is_connected() and let the
 * model reflect whatever is true.
 *
 * Credentials are supplied at runtime by the provisioning module, which owns
 * their persistence in NVS. Nothing is compiled into the firmware.
 */
#ifndef MIRROR_WIFI_H
#define MIRROR_WIFI_H

#include <stdbool.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/* One-time initialisation of the netif, event loop and WiFi driver. Safe to
 * call more than once; required before any other call here. */
esp_err_t wifi_init(void);

/* Configure the station with the given credentials and connect. Returns
 * immediately; association and DHCP happen in the background and retry on
 * their own. When the station is already running this reconfigures and
 * rejoins. */
esp_err_t wifi_connect(const char *ssid, const char *password);

/* Drop the link, forget the station configuration and stop the retry timer,
 * so nothing reconnects until wifi_connect is called again. Used by the setup
 * portal's "forget network" action. */
void wifi_forget(void);

bool wifi_is_connected(void);

/* Signal strength in dBm, or 0 when not associated. */
int wifi_rssi(void);

/* Dotted-quad address, or "0.0.0.0" before DHCP completes. Never NULL. */
const char *wifi_ip(void);

/* Events the provisioning module watches to decide whether saved credentials
 * have failed and the setup portal should open. */
typedef enum {
    WIFI_OBS_CONNECTED,     /* station got an IP; arg is unused */
    WIFI_OBS_DISCONNECTED,  /* association lost; arg is the WiFi reason code */
} wifi_obs_evt_t;

typedef void (*wifi_observer_t)(wifi_obs_evt_t evt, int arg);

/* Install the observer. It runs on the default event loop task, so keep it
 * short and non-blocking. Pass NULL to uninstall. */
void wifi_set_observer(wifi_observer_t obs);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_WIFI_H */
