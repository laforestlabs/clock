/*
 * http_get.h - one blocking HTTPS GET into a caller buffer.
 *
 * Providers need exactly this and nothing more, so there is no streaming API
 * and no callback plumbing. Certificate verification uses ESP-IDF's bundled
 * root store, so no per-service certificate has to be pinned or shipped.
 */
#ifndef MIRROR_HTTP_GET_H
#define MIRROR_HTTP_GET_H

#include <stddef.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Fetch url into buf, NUL terminated, and report the body length.
 *
 * bearer may be NULL; when set it is sent as an Authorization header.
 *
 * Returns ESP_ERR_INVALID_RESPONSE for any non-2xx status, ESP_ERR_NO_MEM if
 * the body would not fit, and whatever the transport reported otherwise. Call
 * this only from a task that can afford to block for timeout_ms.
 */
esp_err_t http_get(const char *url, const char *bearer,
                   char *buf, size_t cap, size_t *out_len,
                   int timeout_ms);

#ifdef __cplusplus
}
#endif
#endif /* MIRROR_HTTP_GET_H */
