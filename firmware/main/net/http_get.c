#include "http_get.h"

#include <string.h>

#include "esp_crt_bundle.h"
#include "esp_http_client.h"
#include "esp_log.h"

static const char *TAG = "http";

esp_err_t http_get(const char *url, const char *bearer,
                   char *buf, size_t cap, size_t *out_len,
                   int timeout_ms)
{
    if (url == NULL || buf == NULL || cap == 0) return ESP_ERR_INVALID_ARG;

    buf[0] = '\0';
    if (out_len != NULL) *out_len = 0;

    esp_http_client_config_t cfg = {
        .url = url,
        .timeout_ms = timeout_ms,
        /* ESP-IDF's bundled root certificates. Beats pinning a certificate per
         * service, which turns every provider's routine cert rotation into a
         * mirror that silently stops updating. */
        .crt_bundle_attach = esp_crt_bundle_attach,
        .keep_alive_enable = false,
    };

    esp_http_client_handle_t client = esp_http_client_init(&cfg);
    if (client == NULL) return ESP_ERR_NO_MEM;

    esp_err_t err = ESP_OK;

    if (bearer != NULL && bearer[0] != '\0') {
        char header[256];
        snprintf(header, sizeof(header), "Bearer %s", bearer);
        esp_http_client_set_header(client, "Authorization", header);
    }
    esp_http_client_set_header(client, "Accept", "application/json");

    err = esp_http_client_open(client, 0);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "connect failed: %s", esp_err_to_name(err));
        goto done;
    }

    const int64_t content_length = esp_http_client_fetch_headers(client);
    const int status = esp_http_client_get_status_code(client);

    /* No status line at all means the transport gave up before the server
     * answered: a connectivity problem, not a service one. Report it as
     * ESP_ERR_HTTP_CONNECT so the scheduler retries promptly instead of
     * backing off as though the API had rejected us. */
    if (status < 100) {
        ESP_LOGW(TAG, "no HTTP response (status %d)", status);
        err = ESP_ERR_HTTP_CONNECT;
        goto done;
    }

    if (status < 200 || status > 299) {
        /* Worth naming the common ones: guessing at a bare 401 wastes time. */
        const char *hint = (status == 401 || status == 403)
                               ? " (check the API token)"
                           : (status == 429) ? " (rate limited, back off)"
                                             : "";
        ESP_LOGW(TAG, "HTTP %d%s", status, hint);
        err = ESP_ERR_INVALID_RESPONSE;
        goto done;
    }

    if (content_length > 0 && (size_t)content_length >= cap) {
        ESP_LOGW(TAG, "response is %lld bytes, buffer holds %u",
                 (long long)content_length, (unsigned)cap);
        err = ESP_ERR_NO_MEM;
        goto done;
    }

    /* content_length is -1 for chunked responses, so read until the buffer is
     * full or the body ends rather than trusting the header. */
    size_t total = 0;
    while (total + 1 < cap) {
        const int n = esp_http_client_read(client, buf + total, (int)(cap - 1 - total));
        if (n < 0) {
            ESP_LOGW(TAG, "read error after %u bytes", (unsigned)total);
            err = ESP_FAIL;
            goto done;
        }
        if (n == 0) break;
        total += (size_t)n;
    }

    buf[total] = '\0';
    if (out_len != NULL) *out_len = total;

    if (!esp_http_client_is_complete_data_received(client)) {
        /* Truncated bodies parse into plausible nonsense, so treat this as a
         * failure and keep the previous data. */
        ESP_LOGW(TAG, "body truncated at %u bytes", (unsigned)total);
        err = ESP_ERR_NO_MEM;
        goto done;
    }

    ESP_LOGD(TAG, "fetched %u bytes from %s", (unsigned)total, url);

done:
    esp_http_client_close(client);
    esp_http_client_cleanup(client);
    return err;
}
