/*
 * api_server.h - the mirror's LAN API (station interface, port 80).
 */
#ifndef MIRROR_API_SERVER_H
#define MIRROR_API_SERVER_H

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Register the WiFi/IP event handlers and start mDNS. The HTTP server itself
 * starts when the station gets an IP and stops when the link drops, so it
 * never collides with the provisioning portal's own server on port 80.
 */
esp_err_t api_server_init(void);

/*
 * Publish the friendly name again after a rename, so a mirror discovered on
 * the LAN is listed under the name it goes by now. No-op when mDNS never came
 * up; the commit that renames the device calls this.
 */
void api_server_mdns_refresh_name(void);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_API_SERVER_H */
