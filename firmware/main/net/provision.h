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

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Load saved credentials from NVS. Must run after nvs_flash_init(). */
esp_err_t provision_init(void);

/* Boot entry. Either joins the saved network (opening the setup portal if it
 * cannot) or opens the portal directly when nothing is saved. */
esp_err_t provision_start(void);
/* One network found by the last scan, strongest first. */
typedef struct {
    char   ssid[33];
    int8_t rssi;
    bool   open;
} provision_scan_result_t;

/* Called on the event-loop task when a scan completes. */
typedef void (*provision_scan_done_cb_t)(void);

/* Called when a credential apply's connect attempt reaches an outcome:
 * connected with the station IP, or failed with a human reason. */
typedef void (*provision_wifi_result_cb_t)(bool connected, const char *arg);

/* True when WiFi credentials are saved in NVS. */
bool provision_has_creds(void);

/* The saved SSID, or "" when none. Static storage; copy it, do not keep the
 * pointer. */
const char *provision_saved_ssid(void);

/*
 * Parse {"ssid":"...","pass":"..."} and apply it: validate, persist, and
 * start the connect (same path as the portal's POST handler). The outcome
 * arrives asynchronously through the wifi-result callback. Returns
 * ESP_ERR_INVALID_ARG with a message in err on bad input, ESP_OK otherwise.
 */
esp_err_t provision_apply_json(const char *json, size_t len,
                               char *err, size_t errsz);

/* Clear saved credentials, forget the station config, and reopen the setup
 * portal (the portal's "forget network" path). */
esp_err_t provision_forget(void);

/* Kick off a background scan if none is running. Results arrive on the
 * scan-done callback; read them with provision_scan_results(). */
esp_err_t provision_scan_start(void);

/* Copy up to max of the last scan's results (strongest first) into out and
 * return the count copied. */
int provision_scan_results(provision_scan_result_t *out, int max);

/* Install (or clear, with NULL) the scan-done and wifi-result callbacks. */
void provision_set_scan_done_cb(provision_scan_done_cb_t cb);
void provision_set_wifi_result_cb(provision_wifi_result_cb_t cb);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_PROVISION_H */
