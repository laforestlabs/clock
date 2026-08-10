/*
 * layout_store.h - the live layout, with SPIFFS persistence.
 *
 * Owns the ml_layout the render task draws. The designer pushes new layouts
 * over the LAN or Bluetooth; they are stored in SPIFFS so a pushed layout
 * survives a reboot, and the embedded layout stays the fallback when nothing
 * was ever pushed or a stored file turns out to be corrupt.
 */
#ifndef MIRROR_LAYOUT_STORE_H
#define MIRROR_LAYOUT_STORE_H

#include <stddef.h>

#include "esp_err.h"
#include "mirror/layout.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Mount SPIFFS (partition "storage") and load the current layout: the stored
 * one when it parses, otherwise the embedded JSON baked into the binary.
 * Also logs the panel-size clip warning for the loaded layout. Call once at
 * boot, after panel_init().
 */
esp_err_t layout_store_init(const char *embedded_json, size_t embedded_len);

/* Copy the current layout out under the store's lock. Safe from any task. */
void layout_store_snapshot(ml_layout *out);

/*
 * Parse and adopt a new layout, applying its brightness to the panel and
 * persisting the pushed JSON to SPIFFS. diag receives the parser warnings.
 * Returns ESP_OK even when parsing only produced warnings; on a hard parse
 * failure returns ESP_ERR_INVALID_ARG and the layout is unchanged (diag has
 * the message).
 */
esp_err_t layout_store_apply(const char *json, size_t len, ml_diag *diag);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_LAYOUT_STORE_H */
