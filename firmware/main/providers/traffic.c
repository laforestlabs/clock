#include "traffic.h"

#include <stdio.h>
#include <string.h>

#include "config.h"
#include "esp_heap_caps.h"
#include "esp_http_client.h"
#include "esp_log.h"
#include "mirror/json.h"
#include "model_store.h"
#include "net/http_get.h"
#include "netlog.h"
#include "net/wifi.h"
#include "sdkconfig.h"

static const char *TAG = "traffic";

/*
 * routeRepresentation=none keeps the route geometry and its thousands of
 * legs out of the response, so the summary this reads is a few hundred bytes.
 * 4KB is generous for it and still a single PSRAM block.
 */
#define RESPONSE_CAP 4096
#define TOKEN_CAP    320

static char        *s_body;
static ml_json_tok *s_tokens;

esp_err_t traffic_init(void)
{
    s_body = heap_caps_malloc(RESPONSE_CAP, MALLOC_CAP_SPIRAM);
    if (s_body == NULL) s_body = heap_caps_malloc(RESPONSE_CAP, MALLOC_CAP_INTERNAL);

    s_tokens = heap_caps_malloc(TOKEN_CAP * sizeof(ml_json_tok), MALLOC_CAP_SPIRAM);
    if (s_tokens == NULL) {
        s_tokens = heap_caps_malloc(TOKEN_CAP * sizeof(ml_json_tok), MALLOC_CAP_INTERNAL);
    }

    if (s_body == NULL || s_tokens == NULL) {
        ESP_LOGE(TAG, "could not allocate the fetch buffers");
        heap_caps_free(s_body);
        heap_caps_free(s_tokens);
        s_body   = NULL;
        s_tokens = NULL;
        return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
}

void traffic_invalidate(void)
{
    model_store_lock();
    model_store_locked()->traffic.valid = false;
    model_store_unlock();
}

/* The provider's own staleness path, which also records why the display went
 * blank. Kept separate from traffic_invalidate() so a config change does not
 * look like a failed fetch in the log. */
static void traffic_go_stale(void)
{
    traffic_invalidate();
    netlog_record(NETLOG_EVT_TRAFFIC_STALE, wifi_rssi(), 0);
}

static esp_err_t traffic_refresh(void)
{
    /*
     * Unconfigured is not a failure. The owner may never set a commute up, and
     * a mirror that logs an error every five minutes about a route it was
     * never given would bury the failures that matter. The model simply stays
     * invalid and the widget draws its placeholder.
     */
    if (!mirror_config_has_route() || mirror_config_traffic_key()[0] == '\0') {
        return ESP_OK;
    }

    char url[512];
    /*
     * computeTravelTimeFor=all is what makes the response carry
     * noTrafficTravelTimeInSeconds alongside the live one, which is the
     * difference between "18 minutes" and "6 minutes of that is traffic".
     */
    snprintf(url, sizeof(url),
             "https://api.tomtom.com/routing/1/calculateRoute/%s:%s/json"
             "?key=%s&traffic=true&computeTravelTimeFor=all"
             "&routeRepresentation=none",
             mirror_config_route_from(), mirror_config_route_to(),
             mirror_config_traffic_key());

    int status = 0;
    size_t len = 0;
    esp_err_t err = http_get(url, NULL, s_body, RESPONSE_CAP, &len, &status, 10000);
    if (err != ESP_OK) {
        int cls = NETLOG_ERR_CONNECT;
        if (err == ESP_ERR_NO_MEM)      cls = NETLOG_ERR_NOMEM;
        else if (status == 401 || status == 403) cls = NETLOG_ERR_AUTH;
        else if (err == ESP_ERR_INVALID_RESPONSE) cls = NETLOG_ERR_HTTP;
        else if (err != ESP_ERR_HTTP_CONNECT)     cls = NETLOG_ERR_HTTP;
        ESP_LOGW(TAG, "fetch failed (HTTP %d)", status);
        netlog_record(NETLOG_EVT_TRAFFIC_FETCH_FAIL, wifi_rssi(), cls);
        return err;
    }

    ml_json j;
    const int tokens = ml_json_parse(&j, s_body, len, s_tokens, TOKEN_CAP);
    if (tokens < 0) {
        ESP_LOGW(TAG, "response did not parse (code %d, %u bytes)", tokens, (unsigned)len);
        netlog_record(NETLOG_EVT_TRAFFIC_FETCH_FAIL, wifi_rssi(), NETLOG_ERR_PARSE);
        return ESP_ERR_INVALID_RESPONSE;
    }

    ml_traffic t;
    memset(&t, 0, sizeof(t));
    snprintf(t.label, sizeof(t.label), "%s", mirror_config_route_label());

    const int routes = ml_json_member(&j, 0, "routes");
    const int first  = routes >= 0 ? ml_json_array_at(&j, routes, 0) : -1;
    const int summary = first >= 0 ? ml_json_member(&j, first, "summary") : -1;
    if (summary < 0) {
        /* A rejected key or a route the service cannot compute both land here
         * as a body with no usable summary. */
        ESP_LOGW(TAG, "no route summary in the response");
        netlog_record(NETLOG_EVT_TRAFFIC_FETCH_FAIL, wifi_rssi(), NETLOG_ERR_PARSE);
        return ESP_ERR_INVALID_RESPONSE;
    }

    int travel = 0;
    if (!ml_json_get_int(&j, summary, "travelTimeInSeconds", &travel)) {
        ESP_LOGW(TAG, "summary has no travel time");
        netlog_record(NETLOG_EVT_TRAFFIC_FETCH_FAIL, wifi_rssi(), NETLOG_ERR_PARSE);
        return ESP_ERR_INVALID_RESPONSE;
    }
    t.travel_s = travel;

    int delay = 0;
    if (ml_json_get_int(&j, summary, "trafficDelayInSeconds", &delay)) t.delay_s = delay;

    int free_flow = 0;
    if (ml_json_get_int(&j, summary, "noTrafficTravelTimeInSeconds", &free_flow)) {
        t.free_flow_s = free_flow;
    } else {
        t.free_flow_s = travel - delay;
        if (t.free_flow_s < 0) t.free_flow_s = 0;
    }

    t.valid = true;

    /* Lock held only for the copy, never across the fetch above. */
    model_store_lock();
    model_store_locked()->traffic = t;
    model_store_unlock();

    ESP_LOGI(TAG, "%s: %d min (%+d s), free flow %d min",
             t.label[0] ? t.label : "route", (t.travel_s + 30) / 60, t.delay_s,
             (t.free_flow_s + 30) / 60);

    netlog_record(NETLOG_EVT_TRAFFIC_FETCH_OK, wifi_rssi(), 0);
    return ESP_OK;
}

static const ml_provider s_provider = {
    .name = "traffic",
    .interval_s = CONFIG_MIRROR_TRAFFIC_INTERVAL_S,
    /* Three missed polls before the display admits it does not know. */
    .grace_s = CONFIG_MIRROR_TRAFFIC_INTERVAL_S * 3,
    .refresh = traffic_refresh,
    .invalidate = traffic_go_stale,
};

const ml_provider *traffic_provider(void)
{
    return &s_provider;
}
