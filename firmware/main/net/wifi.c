#include "wifi.h"

#include <string.h>

#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "sdkconfig.h"

static const char *TAG = "wifi";

static volatile bool s_connected = false;
static int  s_retries = 0;
static char s_ip[16] = "0.0.0.0";

/*
 * Backoff after repeated failures.
 *
 * Retrying flat out forever is antisocial to the access point and, more to the
 * point here, it starves the render task on a single-core-ish workload during
 * an outage. The panel should keep drawing a clock even when the network is
 * gone for an hour.
 */
static int backoff_ms(int retries)
{
    if (retries < CONFIG_MIRROR_WIFI_MAX_RETRY) return 1000;
    if (retries < CONFIG_MIRROR_WIFI_MAX_RETRY * 2) return 5000;
    return 30000;
}

static void on_wifi_event(void *arg, esp_event_base_t base,
                          int32_t id, void *data)
{
    (void)arg;
    (void)base;

    switch (id) {
    case WIFI_EVENT_STA_START:
        ESP_LOGI(TAG, "connecting to \"%s\"", CONFIG_MIRROR_WIFI_SSID);
        esp_wifi_connect();
        break;

    case WIFI_EVENT_STA_DISCONNECTED: {
        const wifi_event_sta_disconnected_t *ev =
            (const wifi_event_sta_disconnected_t *)data;

        s_connected = false;
        snprintf(s_ip, sizeof(s_ip), "0.0.0.0");
        s_retries++;

        const int wait = backoff_ms(s_retries);
        /* Log the reason code: 15 (4WAY_HANDSHAKE_TIMEOUT) almost always means
         * a wrong password, while 201 (NO_AP_FOUND) means a wrong SSID or the
         * radio cannot see the AP. Guessing between those wastes real time. */
        ESP_LOGW(TAG, "disconnected, reason %d, attempt %d, retrying in %dms",
                 ev != NULL ? ev->reason : -1, s_retries, wait);

        vTaskDelay(pdMS_TO_TICKS(wait));
        esp_wifi_connect();
        break;
    }

    default:
        break;
    }
}

static void on_ip_event(void *arg, esp_event_base_t base,
                        int32_t id, void *data)
{
    (void)arg;
    (void)base;

    if (id != IP_EVENT_STA_GOT_IP) return;

    const ip_event_got_ip_t *ev = (const ip_event_got_ip_t *)data;
    snprintf(s_ip, sizeof(s_ip), IPSTR, IP2STR(&ev->ip_info.ip));

    s_connected = true;
    s_retries = 0;
    ESP_LOGI(TAG, "connected, address %s", s_ip);
}

esp_err_t wifi_start(void)
{
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();

    wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&init));

    ESP_ERROR_CHECK(esp_event_handler_instance_register(
        WIFI_EVENT, ESP_EVENT_ANY_ID, &on_wifi_event, NULL, NULL));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(
        IP_EVENT, IP_EVENT_STA_GOT_IP, &on_ip_event, NULL, NULL));

    wifi_config_t cfg = {0};
    strncpy((char *)cfg.sta.ssid, CONFIG_MIRROR_WIFI_SSID, sizeof(cfg.sta.ssid) - 1);
    strncpy((char *)cfg.sta.password, CONFIG_MIRROR_WIFI_PASSWORD,
            sizeof(cfg.sta.password) - 1);

    /* An empty password means an open network; forcing a WPA2 threshold there
     * would reject it outright. */
    cfg.sta.threshold.authmode =
        (strlen(CONFIG_MIRROR_WIFI_PASSWORD) == 0) ? WIFI_AUTH_OPEN
                                                   : WIFI_AUTH_WPA2_PSK;

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &cfg));

    /* Modem sleep would save power, but it adds latency to every poll and this
     * device is mains powered by necessity: the panel alone draws amps. */
    ESP_ERROR_CHECK(esp_wifi_set_ps(WIFI_PS_NONE));

    ESP_ERROR_CHECK(esp_wifi_start());
    return ESP_OK;
}

bool wifi_is_connected(void)
{
    return s_connected;
}

int wifi_rssi(void)
{
    if (!s_connected) return 0;

    wifi_ap_record_t ap;
    if (esp_wifi_sta_get_ap_info(&ap) != ESP_OK) return 0;
    return ap.rssi;
}

const char *wifi_ip(void)
{
    return s_ip;
}
