/*
 * ota.h - firmware update over the LAN API (POST /api/ota).
 */
#ifndef MIRROR_OTA_H
#define MIRROR_OTA_H

#include "esp_err.h"
#include "esp_http_server.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Handle POST /api/ota: stream the request body (the app-partition image,
 * build/smart_mirror.bin) into the inactive OTA partition, point the boot
 * loader at it and restart. Responds 200 {"ok":true} just before the
 * restart; any failure responds a JSON error and leaves the running app
 * untouched.
 */
esp_err_t ota_handle_upload(httpd_req_t *req);

/*
 * Mark the running app valid so the boot loader does not roll it back. Call
 * once the render task is running: reaching that point is the definition of
 * "the new app booted far enough to be good". A crash before this returns
 * the device to the previous app automatically.
 */
void ota_mark_valid(void);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_OTA_H */
