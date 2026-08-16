#include "wifi.h"

#include <string.h>
#include <stdint.h>

#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "nvs.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "sdkconfig.h"

static const char *TAG = "wifi";

static volatile bool s_connected = false;
static int  s_retries = 0;
static char s_ip[16] = "0.0.0.0";
static char s_ssid[33] = "";
static char s_pass[65] = "";
static bool s_fast_connect = false;

static esp_timer_handle_t s_reconnect;
static wifi_observer_t s_observer = NULL;
static bool s_init_done = false;
/* True once esp_wifi_start() has succeeded. This is the only reliable way to
 * know the interfaces are running: esp_wifi_get_mode() reports WIFI_MODE_STA
 * immediately after esp_wifi_init(), so a "mode is NULL" test would silently
 * skip the start and leave the radio silent while every API call returns OK. */
static bool s_started = false;
static bool s_autoreconnect = true;

/* Last-known-good association, persisted in NVS. Used at boot to skip the
 * full-channel scan and go straight to the AP we joined before. */
#define WIFI_NVS_NS       "mirror"
#define WIFI_NVS_KEY_HINT "sta_hint"

typedef struct {
    uint8_t bssid[6];
    uint8_t channel;
    char    ssid[33];
} sta_hint_t;

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

static void sta_hint_save(const sta_hint_t *hint)
{
    nvs_handle_t h;
    if (nvs_open(WIFI_NVS_NS, NVS_READWRITE, &h) != ESP_OK) return;
    nvs_set_blob(h, WIFI_NVS_KEY_HINT, hint, sizeof(*hint));
    nvs_commit(h);
    nvs_close(h);
}

static bool sta_hint_load(sta_hint_t *hint)
{
    nvs_handle_t h;
    if (nvs_open(WIFI_NVS_NS, NVS_READONLY, &h) != ESP_OK) return false;
    size_t len = sizeof(*hint);
    bool ok = (nvs_get_blob(h, WIFI_NVS_KEY_HINT, hint, &len) == ESP_OK &&
               len == sizeof(*hint));
    nvs_close(h);
    return ok;
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

    case WIFI_EVENT_STA_CONNECTED: {
        /* Cache the association so the next boot can skip the full-channel
         * scan and go straight to this AP. */
        const wifi_event_sta_connected_t *ev =
            (const wifi_event_sta_connected_t *)data;
        if (ev != NULL && ev->ssid_len < sizeof(s_ssid)) {
            sta_hint_t hint;
            memcpy(hint.bssid, ev->bssid, sizeof(hint.bssid));
            hint.channel = ev->channel;
            memcpy(hint.ssid, ev->ssid, ev->ssid_len);
            hint.ssid[ev->ssid_len] = '\0';
            sta_hint_save(&hint);
            ESP_LOGI(TAG, "cached AP %02x:%02x:%02x:%02x:%02x:%02x channel %u",
                     hint.bssid[0], hint.bssid[1], hint.bssid[2],
                     hint.bssid[3], hint.bssid[4], hint.bssid[5], hint.channel);
        }
        s_fast_connect = false;
        break;
    }


    case WIFI_EVENT_STA_DISCONNECTED: {
        const wifi_event_sta_disconnected_t *ev =
            (const wifi_event_sta_disconnected_t *)data;
        const int reason = ev != NULL ? ev->reason : -1;

        s_connected = false;
        snprintf(s_ip, sizeof(s_ip), "0.0.0.0");
        s_retries++;

        /* A fast-connect attempt targets one BSSID on one channel. If that AP
         * has moved or vanished, rebuild the config as a full scan once, so
         * the retry below finds whatever is actually on the air instead of
         * the stale hint. */
        if (s_fast_connect) {
            s_fast_connect = false;
            ESP_LOGW(TAG, "fast connect failed (reason %d), full scan", reason);

            wifi_config_t cfg = {0};
            strncpy((char *)cfg.sta.ssid, s_ssid, sizeof(cfg.sta.ssid) - 1);
            strncpy((char *)cfg.sta.password, s_pass, sizeof(cfg.sta.password) - 1);
            cfg.sta.scan_method = WIFI_ALL_CHANNEL_SCAN;
            cfg.sta.sort_method = WIFI_CONNECT_AP_BY_SIGNAL;
            if (esp_wifi_set_config(WIFI_IF_STA, &cfg) != ESP_OK) {
                ESP_LOGW(TAG, "could not apply the full-scan fallback config");
            }
        }


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
        if (s_reconnect != NULL && s_autoreconnect) {
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
    /* Scan every channel and connect to the strongest AP matching the SSID.
     * Fast scan (the default) stops at the first match; with two APs on one
     * SSID that can latch onto the distant, weak one, whose 4-way handshake
     * then times out and reads as a wrong password. Scanning all channels
     * finds both and sorts by RSSI, so the mirror stays on the near AP. */
    cfg.sta.scan_method = WIFI_ALL_CHANNEL_SCAN;
    cfg.sta.sort_method = WIFI_CONNECT_AP_BY_SIGNAL;

    /* Try the AP we joined last boot first. It is usually still on the same
     * channel, so this skips the several-second full scan; if it has moved,
     * the disconnect handler falls back to the full scan above. */
    sta_hint_t hint;
    if (sta_hint_load(&hint) && strcmp(hint.ssid, ssid) == 0) {
        memcpy(cfg.sta.bssid, hint.bssid, sizeof(cfg.sta.bssid));
        cfg.sta.bssid_set = true;
        cfg.sta.channel = hint.channel;
        cfg.sta.scan_method = WIFI_FAST_SCAN;
        s_fast_connect = true;
        ESP_LOGI(TAG, "fast connect to cached AP (channel %u)", hint.channel);
    } else {
        s_fast_connect = false;
    }


    /* No authmode threshold: the default (accept anything) lets the driver
     * negotiate with the password we supplied. The old examples set a
     * WPA2_PSK threshold here, which makes the station report reason 210
     * ("no AP found with compatible security") against WPA3 and WPA2/WPA3
     * transition networks, the norm on modern routers. */

    strncpy(s_ssid, ssid, sizeof(s_ssid) - 1);
    strncpy(s_pass, password, sizeof(s_pass) - 1);
    s_connected = false;
    s_retries = 0;
    snprintf(s_ip, sizeof(s_ip), "0.0.0.0");

    if (s_reconnect != NULL) esp_timer_stop(s_reconnect);   /* no-op when idle */

    if (!s_started) {
        ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
        ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &cfg));

        /* Modem sleep would save power, but it adds latency to every poll and
         * this device is mains powered by necessity: the panel alone draws
         * amps. */
        ESP_ERROR_CHECK(esp_wifi_set_ps(WIFI_PS_NONE));

        ESP_ERROR_CHECK(esp_wifi_start());
        s_started = true;
    } else {
        /* Reconfigure and rejoin. esp_wifi_set_config refuses while the
         * station is mid-association, so settle it first. The reconnect
         * timer can fire a connect between our disconnect and this
         * set_config; back off briefly on ESP_ERR_WIFI_STATE rather than
         * aborting, which would reboot the whole mirror. */
        esp_wifi_disconnect();
        esp_err_t cerr = ESP_ERR_WIFI_STATE;
        for (int i = 0; i < 20 && cerr == ESP_ERR_WIFI_STATE; i++) {
            cerr = esp_wifi_set_config(WIFI_IF_STA, &cfg);
            if (cerr == ESP_ERR_WIFI_STATE) vTaskDelay(pdMS_TO_TICKS(10));
        }
        if (cerr != ESP_OK) return cerr;
        esp_wifi_connect();
    }
    return ESP_OK;
}

esp_err_t wifi_start_ap(const char *ssid, const char *password)
{
    esp_err_t err = wifi_init();
    if (err != ESP_OK) return err;

    wifi_config_t ap = {0};
    strncpy((char *)ap.ap.ssid, ssid, sizeof(ap.ap.ssid) - 1);
    ap.ap.ssid_len = (uint8_t)strnlen(ssid, sizeof(ap.ap.ssid));
    ap.ap.channel = 1;
    ap.ap.max_connection = 4;
    if (password[0] == '\0') {
        ap.ap.authmode = WIFI_AUTH_OPEN;
    } else {
        strncpy((char *)ap.ap.password, password, sizeof(ap.ap.password) - 1);
        ap.ap.authmode = WIFI_AUTH_WPA_WPA2_PSK;
    }

    if (!s_started) {
        ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_APSTA));
        ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_AP, &ap));
        ESP_ERROR_CHECK(esp_wifi_start());
        s_started = true;
    } else {
        /* The station is already running (saved credentials failed or were
         * re-entered). Adding the AP alongside it is a runtime mode change,
         * which the driver supports while running. */
        ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_APSTA));
        ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_AP, &ap));
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

    if (!s_started) return;

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

void wifi_set_autoreconnect(bool enabled)
{
    s_autoreconnect = enabled;
    if (!enabled && s_reconnect != NULL) {
        esp_timer_stop(s_reconnect);   /* drop any pending retry */
    }
}
