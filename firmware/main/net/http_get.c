#include "http_get.h"

#include <stdint.h>
#include <string.h>
#include <strings.h>
#include <sys/time.h>
#include <time.h>

#include "esp_crt_bundle.h"
#include "esp_http_client.h"
#include "esp_log.h"
#include "net/sntp_time.h"

static const char *TAG = "http";

/* RFC 1123 IMF-fixdate is 29 bytes ("Sun, 06 Nov 1994 08:49:37 GMT"). The
 * slack absorbs a server that pads or sends one of the obsolete formats. */
#define DATE_CAP 40

/*
 * esp_http_client exposes no response-header getter - esp_http_client_get_header
 * reads request headers - so the Date header is lifted out as the response
 * streams past. It is the only clock source here that cannot need TLS, which is
 * what matters on a guest network that answers 80/443 and drops UDP 123.
 */
static esp_err_t on_header(esp_http_client_event_t *evt)
{
    if (evt->event_id != HTTP_EVENT_ON_HEADER) return ESP_OK;
    if (evt->user_data == NULL) return ESP_OK;
    if (evt->header_key == NULL || evt->header_value == NULL) return ESP_OK;
    if (strcasecmp(evt->header_key, "Date") != 0) return ESP_OK;

    char *date = evt->user_data;
    /* Truncation is harmless: a value that does not parse is ignored. */
    snprintf(date, DATE_CAP, "%s", evt->header_value);
    return ESP_OK;
}

/*
 * The Date header carries a UTC civil date and strptime has no timezone to
 * apply, while newlib ships no timegm. mktime is the three-line version but
 * reads its argument as local time, which would fold the configured TZ, and its
 * DST state, into a value that is already UTC. So the epoch is built here: whole
 * days from 1970, then the time of day. Called at most once per boot.
 */
static time_t utc_epoch(const struct tm *tm)
{
    static const uint8_t mdays[12] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};

    const int year  = tm->tm_year + 1900;
    const bool leap = (year % 4 == 0) && (year % 100 != 0 || year % 400 == 0);

    int64_t days = 0;
    for (int y = 1970; y < year; y++) {
        days += 365 + ((y % 4 == 0) && (y % 100 != 0 || y % 400 == 0));
    }
    for (int m = 0; m < tm->tm_mon; m++) {
        days += mdays[m] + (m == 1 && leap);
    }
    days += tm->tm_mday - 1;

    return (time_t)(days * 86400 + tm->tm_hour * 3600 + tm->tm_min * 60 + tm->tm_sec);
}

static void bootstrap_clock(const char *date)
{
    struct tm tm = {0};

    /* Anything the format string does not consume is ignored, so "GMT" or a
     * stray zone suffix costs nothing. A value in some other zone is taken at
     * face value: the clock only has to be plausible enough to check a
     * certificate's dates, and a zone offset is hours at worst. */
    if (strptime(date, "%a, %d %b %Y %H:%M:%S", &tm) == NULL) {
        ESP_LOGW(TAG, "unparsable Date header \"%s\"", date);
        return;
    }

    struct timeval tv = { .tv_sec = utc_epoch(&tm), .tv_usec = 0 };
    settimeofday(&tv, NULL);

    if (!sntp_time_is_synced()) {
        /* Still not plausible - a captive portal inventing a date, say. The
         * clock stays unknown and the next fetch goes out cleartext again. */
        ESP_LOGW(TAG, "Date header \"%s\" is not a plausible clock", date);
        return;
    }

    struct tm utc;
    time_t now = time(NULL);
    gmtime_r(&now, &utc);
    char stamp[32];
    strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", &utc);
    ESP_LOGI(TAG, "clock bootstrapped from the response's Date header: %s UTC", stamp);
}

esp_err_t http_get(const char *url, const char *bearer,
                   char *buf, size_t cap, size_t *out_len,
                   int *out_status,
                   int timeout_ms)
{
    if (url == NULL || buf == NULL || cap == 0) return ESP_ERR_INVALID_ARG;

    buf[0] = '\0';
    if (out_len != NULL) *out_len = 0;
    /* 0 until a response arrives, so a caller can tell "the service refused
     * the request" from "the request never reached a service". */
    if (out_status != NULL) *out_status = 0;

    char date[DATE_CAP] = {0};

    esp_http_client_config_t cfg = {
        .url = url,
        .timeout_ms = timeout_ms,
        /* ESP-IDF's bundled root certificates. Beats pinning a certificate per
         * service, which turns every provider's routine cert rotation into a
         * mirror that silently stops updating. */
        .crt_bundle_attach = esp_crt_bundle_attach,
        .keep_alive_enable = false,
        .event_handler = on_header,
        .user_data = date,
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
    if (out_status != NULL && status >= 100) *out_status = status;

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

    /* A 2xx means the transport got this far, and a certificate's dates can
     * only be checked against a plausible clock. This device has no RTC: the
     * clock arrives from SNTP, and guest networks routinely block UDP 123 while
     * leaving 80/443 open, so the first HTTPS request after a reboot cannot
     * succeed. The one thing that can hand us the time is a response already
     * fetched, so the Date header of this one is used. This is a bootstrap, not
     * a sync: it is read only while the clock is unknown, so it can never fight
     * or override a working NTP source, and it is trusted no further than the
     * cleartext response it arrived in. */
    if (!sntp_time_is_synced() && date[0] != '\0') {
        bootstrap_clock(date);
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
