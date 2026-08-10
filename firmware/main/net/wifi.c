#include "wifi.h"

#include <string.h>

#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "sdkconfig.h"

static const char *TAG = "wifi";

static volatile bool s_connected = false;
static int  s_retries = 0;
static char s_ip[16] = "0.0.0.0";
static char s_ssid[33] = "";

static esp_timer_handle_t s_reconnect;
static wifi_observer_t s_observer = NULL;
static bool s_init_done = false;

/*
 * Backoff after repeated failures.
 *
 * Retrying flat out forever is antisocial to the access point, and on a device
 * that is expected to ride out a router reboot without the clock stuttering it
 * buys nothing.
 */
static int backoff_ms(int retries)
{
    if (retries < CONFIG_MIRROR_WIFI_MAX_RETRY) return 1000;
    if (retries < CONFIG_MIRROR_WIFI_MAX_RETRY * 2) return 5000;
    return 30000;
}

static void reconnect_cb(void *arg)
{
    (void)arg;
    esp_wifi_connect();
}

static void notify(wifi_obs_evt_t evt, int arg)
{
    if (s_observer != NULL) s_observer(evt, arg);
}

static void on_wifi_event(void *arg, esp_event_base_t base,
                          int32_t id, void *data)
{
    (void)arg;
    (void)base;

    switch (id) {
    case WIFI_EVENT_STA_START:
        /* No credentials configured (setup-portal mode): stay quiet instead
         * of trying to join a blank SSID on a timer. */
        if (s_ssid[0] == '\0') break;

        ESP_LOGI(TAG, "connecting to \"%s\"", s_ssid);
        esp_wifi_connect();
        break;

    case WIFI_EVENT_STA_DISCONNECTED: {
        const wifi_event_sta_disconnected_t *ev =
            (const wifi_event_sta_disconnected_t *)data;
        const int reason = ev != NULL ? ev->reason : -1;

        s_connected = false;
        snprintf(s_ip, sizeof(s_ip), "0.0.0.0");
        s_retries++;

        const int wait = backoff_ms(s_retries);
        /* Log the reason code: 15 (4WAY_HANDSHAKE_TIMEOUT) almost always means
         * a wrong password, while 201 (NO_AP_FOUND) means a wrong SSID or the
         * radio cannot see the AP. Guessing between those wastes real time. */
        ESP_LOGW(TAG, "disconnected, reason %d, attempt %d, retrying in %dms",
                 reason, s_retries, wait);

        /*
         * Armed on a timer rather than slept through here. Handlers run on the
         * shared default event loop task, so blocking for the 30 seconds this
         * backs off to would hold up dispatch of every other event in the
         * system, GOT_IP among them, and can back the event queue up behind us.
         */
        if (s_reconnect != NULL) {
            esp_timer_stop(s_reconnect);   /* no-op when it is not running */
            esp_timer_start_once(s_reconnect, (int64_t)wait * 1000);
        } else {
            esp_wifi_connect();
        }

        notify(WIFI_OBS_DISCONNECTED, reason);
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

    notify(WIFI_OBS_CONNECTED, 0);
}

esp_err_t wifi_init(void)
{
    if (s_init_done) return ESP_OK;

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();
    /* Created up front even though the setup access point is only used when
     * provisioning: attaching a netif mid-flight is the kind of ordering
     * subtlety that shows up as a DHCP failure on a customer's kitchen table. */
    esp_netif_create_default_wifi_ap();

    wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&init));

    ESP_ERROR_CHECK(esp_event_handler_instance_register(
        WIFI_EVENT, ESP_EVENT_ANY_ID, &on_wifi_event, NULL, NULL));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(
        IP_EVENT, IP_EVENT_STA_GOT_IP, &on_ip_event, NULL, NULL));

    const esp_timer_create_args_t reconnect_args = {
        .callback = reconnect_cb,
        .name     = "wifi_reconnect",
    };
    ESP_ERROR_CHECK(esp_timer_create(&reconnect_args, &s_reconnect));

    s_init_done = true;
    return ESP_OK;
}

esp_err_t wifi_connect(const char *ssid, const char *password)
{
    esp_err_t err = wifi_init();
    if (err != ESP_OK) return err;

    wifi_config_t cfg = {0};
    strncpy((char *)cfg.sta.ssid, ssid, sizeof(cfg.sta.ssid) - 1);
    strncpy((char *)cfg.sta.password, password, sizeof(cfg.sta.password) - 1);

    /* An empty password means an open network; forcing a WPA2 threshold there
     * would reject it outright. */
    cfg.sta.threshold.authmode =
        (password[0] == '\0') ? WIFI_AUTH_OPEN
                              : WIFI_AUTH_WPA2_PSK;

    strncpy(s_ssid, ssid, sizeof(s_ssid) - 1);
    s_connected = false;
    s_retries = 0;
    snprintf(s_ip, sizeof(s_ip), "0.0.0.0");

    if (s_reconnect != NULL) esp_timer_stop(s_reconnect);   /* no-op when idle */

    wifi_mode_t mode;
    ESP_ERROR_CHECK(esp_wifi_get_mode(&mode));

    if (mode == WIFI_MODE_NULL) {
        ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
        ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &cfg));

        /* Modem sleep would save power, but it adds latency to every poll and
         * this device is mains powered by necessity: the panel alone draws
         * amps. */
        ESP_ERROR_CHECK(esp_wifi_set_ps(WIFI_PS_NONE));

        ESP_ERROR_CHECK(esp_wifi_start());
    } else {
        /* Reconfigure and rejoin. esp_wifi_set_config refuses while the
         * station is mid-association, so settle it first; the error is
         * expected when the link is already down. */
        esp_wifi_disconnect();
        ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &cfg));
        esp_wifi_connect();
    }
    return ESP_OK;
}

void wifi_forget(void)
{
    if (s_reconnect != NULL) esp_timer_stop(s_reconnect);

    s_ssid[0] = '\0';
    s_connected = false;
    s_retries = 0;
    snprintf(s_ip, sizeof(s_ip), "0.0.0.0");

    wifi_mode_t mode;
    if (esp_wifi_get_mode(&mode) != ESP_OK || mode == WIFI_MODE_NULL) return;

    wifi_config_t blank = {0};
    esp_wifi_disconnect();
    esp_wifi_set_config(WIFI_IF_STA, &blank);
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

void wifi_set_observer(wifi_observer_t obs)
{
    s_observer = obs;
}
