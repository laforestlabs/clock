/*
 * provision.c - captive-portal WiFi provisioning.
 *
 * Lifecycle:
 *
 *   no saved credentials  -> setup access point and portal from the first boot
 *   saved, reachable      -> join the home network, portal never opens
 *   saved, unreachable    -> try for MIRROR_CONNECT_TIMEOUT_S, then open the
 *                            portal; keep retrying the saved network in the
 *                            background so the mirror rejoins by itself when
 *                            the network comes back
 *   new credentials saved -> reconnect immediately; a wrong password or a
 *                            missing network is reported on the page
 *
 * The setup access point doubles as a captive portal. A tiny DNS responder
 * answers every name with the access point's own address, and every other
 * HTTP path redirects to the setup page, so phones and tablets pop the form
 * up by themselves.
 *
 * Security: the portal serves plain HTTP over an access point that is open by
 * default (MIRROR_AP_PASSWORD). Set a password in menuconfig for a deployed
 * product, where anyone within radio range could otherwise claim the device.
 */
#include "provision.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "esp_http_server.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "lwip/ip4_addr.h"
#include "lwip/udp.h"
#include "nvs.h"
#include "sdkconfig.h"

#include "net/wifi.h"

static const char *TAG = "prov";

#define NVS_NS        "mirror"
#define NVS_KEY_SSID  "ssid"
#define NVS_KEY_PASS  "pass"

#define MAX_SSID_LEN  32   /* WPA2 SSID limit */
#define MAX_PASS_LEN  64   /* WPA2 passphrase limit is 63 */
#define MAX_FORM_BODY 256

/* How long the setup page waits after a successful join before taking the
 * access point down, so the phone actually sees the confirmation. */
#define TEARDOWN_DELAY_US (5 * 1000000)

static char s_ssid[MAX_SSID_LEN];
static char s_pass[MAX_PASS_LEN + 1];
static bool s_has_creds = false;
static bool s_portal_active = false;
static bool s_ever_connected = false;
static char s_last_error[64] = "";

static httpd_handle_t s_httpd = NULL;
static struct udp_pcb *s_dns_pcb = NULL;
static esp_timer_handle_t s_watchdog;
static esp_timer_handle_t s_teardown;
static SemaphoreHandle_t s_lock;

static void portal_start(void);
static void dns_stop(void);

/* state */

static void lock_state(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
}

static void unlock_state(void)
{
    xSemaphoreGive(s_lock);
}

static void set_error(const char *msg)
{
    lock_state();
    if (msg == NULL) {
        s_last_error[0] = '\0';
    } else {
        snprintf(s_last_error, sizeof(s_last_error), "%s", msg);
    }
    unlock_state();
}

static bool error_is_set(void)
{
    lock_state();
    const bool set = s_last_error[0] != '\0';
    unlock_state();
    return set;
}

static bool portal_is_active(void)
{
    lock_state();
    const bool active = s_portal_active;
    unlock_state();
    return active;
}

/* nvs */

static void creds_save(const char *ssid, const char *pass)
{
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NS, NVS_READWRITE, &h);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "nvs open failed: %s", esp_err_to_name(err));
        return;
    }

    err = nvs_set_str(h, NVS_KEY_SSID, ssid);
    if (err == ESP_OK) err = nvs_set_str(h, NVS_KEY_PASS, pass);
    if (err == ESP_OK) err = nvs_commit(h);
    nvs_close(h);

    if (err != ESP_OK) {
        ESP_LOGE(TAG, "could not save credentials: %s", esp_err_to_name(err));
        return;
    }

    lock_state();
    snprintf(s_ssid, sizeof(s_ssid), "%s", ssid);
    snprintf(s_pass, sizeof(s_pass), "%s", pass);
    s_has_creds = true;
    unlock_state();
}

static void creds_clear(void)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) == ESP_OK) {
        nvs_erase_key(h, NVS_KEY_SSID);
        nvs_erase_key(h, NVS_KEY_PASS);
        nvs_commit(h);
        nvs_close(h);
    }

    lock_state();
    s_ssid[0] = '\0';
    s_pass[0] = '\0';
    s_has_creds = false;
    unlock_state();
}

/* wifi event logic */

static bool reason_is_terminal(int reason)
{
    switch (reason) {
    case WIFI_REASON_AUTH_FAIL:              /* 202 */
    case WIFI_REASON_4WAY_HANDSHAKE_TIMEOUT: /* 15, almost always wrong pass */
    case WIFI_REASON_NO_AP_FOUND:            /* 201 */
        return true;
    default:
        return false;
    }
}

static const char *reason_string(int reason)
{
    switch (reason) {
    case WIFI_REASON_AUTH_FAIL:
    case WIFI_REASON_4WAY_HANDSHAKE_TIMEOUT:
        return "wrong password";
    case WIFI_REASON_NO_AP_FOUND:
        return "network not found";
    default:
        return "could not connect";
    }
}

static void provision_on_wifi(wifi_obs_evt_t evt, int arg)
{
    if (evt == WIFI_OBS_CONNECTED) {
        s_ever_connected = true;
        set_error(NULL);
        esp_timer_stop(s_watchdog);   /* no-op when not running */

        if (portal_is_active()) {
            ESP_LOGI(TAG, "connected, closing the setup portal in 5 s");
            esp_timer_stop(s_teardown);
            esp_timer_start_once(s_teardown, TEARDOWN_DELAY_US);
        }
        return;
    }

    /* WIFI_OBS_DISCONNECTED */
    lock_state();
    const bool creds = s_has_creds;
    const bool portal = s_portal_active;
    const bool ever = s_ever_connected;
    unlock_state();
    if (!creds) return;

    const char *why = reason_string(arg);
    set_error(why);

    if (portal) return;   /* the page already shows the failure */

    /* A drop after a successful join is the reconnect loop's job. */
    if (ever) return;

    /* Boot phase with saved credentials that do not work. Jump to the portal
     * right away for reasons that will never fix themselves; the watchdog
     * catches the rest (e.g. a DHCP hang). */
    if (reason_is_terminal(arg)) {
        ESP_LOGW(TAG, "saved network failed (%s), opening the setup portal", why);
        portal_start();
    }
}

/* timers */

static void on_watchdog(void *arg)
{
    (void)arg;

    if (wifi_is_connected()) return;

    /* A failure reason already explains itself; do not overwrite it with the
     * generic timeout. This keeps "wrong password" visible when the portal
     * opened because of a terminal reason, while still reporting the timeout
     * that a DHCP hang would otherwise leave as an eternal "connecting". */
    if (!error_is_set()) {
        set_error("could not reach the network in time");
    }
    if (!portal_is_active()) {
        ESP_LOGW(TAG, "no address after %d s, opening the setup portal",
                 CONFIG_MIRROR_CONNECT_TIMEOUT_S);
        portal_start();
    }
}

static void on_teardown(void *arg)
{
    (void)arg;

    if (!portal_is_active()) return;

    dns_stop();
    if (s_httpd != NULL) {
        httpd_stop(s_httpd);
        s_httpd = NULL;
    }
    esp_wifi_set_mode(WIFI_MODE_STA);
    lock_state();
    s_portal_active = false;
    unlock_state();

    ESP_LOGI(TAG, "setup portal closed, running on the home network");
}

/* httpd */

static const char PORTAL_PAGE[] =
    "<!doctype html>"
    "<html><head><meta charset=\"utf-8\">"
    "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
    "<title>Smart Mirror setup</title>"
    "<style>"
    "body{font-family:system-ui,-apple-system,sans-serif;max-width:26rem;"
    "margin:2rem auto;padding:0 1rem;color:#222;line-height:1.5}"
    "h1{font-size:1.4rem}"
    "label{display:block;margin:.75rem 0 .25rem;font-weight:600}"
    "input{width:100%;box-sizing:border-box;padding:.5rem;font-size:1rem;"
    "border:1px solid #999;border-radius:4px}"
    "button{margin-top:1rem;padding:.6rem 1.2rem;font-size:1rem;"
    "background:#1a73e8;color:#fff;border:0;border-radius:4px}"
    "button.secondary{background:#666;margin-left:.5rem}"
    "#status{margin-top:1rem;min-height:1.5rem}"
    "#status.ok{color:#188038}#status.err{color:#c5221f}"
    "</style></head><body>"
    "<h1>Smart Mirror setup</h1>"
    "<p>You are on the mirror's own setup network. Enter your home WiFi "
    "details to finish setup.</p>"
    "<form method=\"post\" action=\"/\">"
    "<label for=\"ssid\">Network name (SSID)</label>"
    "<input id=\"ssid\" name=\"ssid\" maxlength=\"32\" "
    "autocomplete=\"off\" required>"
    "<label for=\"pass\">Password</label>"
    "<input id=\"pass\" name=\"pass\" type=\"password\" maxlength=\"63\" "
    "autocomplete=\"off\">"
    "<button type=\"submit\">Connect</button>"
    "<button type=\"button\" class=\"secondary\" id=\"forget\" hidden>"
    "Forget saved network</button>"
    "</form>"
    "<div id=\"status\"></div>"
    "<script>"
    "var st=document.getElementById('status');"
    "var f=document.getElementById('forget');"
    "var ss=document.getElementById('ssid');"
    "function esc(s){return s.replace(/[<>&\"]/g,function(c){"
    "return{'<':'&lt;','>':'&gt;','&':'&amp;','\"':'&quot;'}[c];});}"
    "function poll(){var x=new XMLHttpRequest();"
    "x.open('GET','/status');"
    "x.onload=function(){var s;"
    "try{s=JSON.parse(x.responseText)}catch(e){return}"
    "if(!ss.value&&s.ssid)ss.value=s.ssid;"
    "f.hidden=!s.saved;"
    "if(s.connected){st.className='ok';"
    "st.textContent='Connected. The mirror has joined '+esc(s.ssid)+'. "
    "You can close this page.';return;}"
    "if(s.error){st.className='err';"
    "st.textContent='Could not connect: '+esc(s.error);return;}"
    "if(s.state==='connecting'){st.className='';"
    "st.textContent='Connecting to '+esc(s.ssid)+'...';return;}"
    "st.className='';"
    "st.textContent='Enter your home WiFi details and press Connect.';};"
    "x.send();}"
    "setInterval(poll,1500);poll();"
    "f.onclick=function(){var x=new XMLHttpRequest();"
    "x.open('POST','/forget');x.send();};"
    "</script></body></html>";

static void json_escape(char *out, size_t outsz, const char *in)
{
    size_t o = 0;
    for (const unsigned char *s = (const unsigned char *)in;
         *s != '\0' && o + 6 < outsz; s++) {
        switch (*s) {
        case '"':  out[o++] = '\\'; out[o++] = '"'; break;
        case '\\': out[o++] = '\\'; out[o++] = '\\'; break;
        case '\n': out[o++] = '\\'; out[o++] = 'n'; break;
        case '\r': out[o++] = '\\'; out[o++] = 'r'; break;
        case '\t': out[o++] = '\\'; out[o++] = 't'; break;
        default:
            out[o++] = (*s < 0x20) ? '?' : (char)*s;
            break;
        }
    }
    out[o] = '\0';
}

static esp_err_t handle_get_root(httpd_req_t *req)
{
    httpd_resp_set_type(req, "text/html");
    return httpd_resp_send(req, PORTAL_PAGE, HTTPD_RESP_USE_STRLEN);
}

static esp_err_t handle_get_status(httpd_req_t *req)
{
    char esc_ssid[96];
    char esc_err[96];
    bool has_creds, has_err;

    lock_state();
    has_creds = s_has_creds;
    json_escape(esc_ssid, sizeof(esc_ssid), s_has_creds ? s_ssid : "");
    json_escape(esc_err, sizeof(esc_err), s_last_error);
    unlock_state();
    has_err = esc_err[0] != '\0';

    const char *state = wifi_is_connected() ? "connected"
                      : has_err ? "failed"
                      : has_creds ? "connecting"
                      : "idle";

    char body[320];
    snprintf(body, sizeof(body),
             "{\"connected\":%s,\"saved\":%s,\"ssid\":\"%s\",\"ip\":\"%s\","
             "\"state\":\"%s\",\"error\":\"%s\"}",
             wifi_is_connected() ? "true" : "false",
             has_creds ? "true" : "false",
             esc_ssid, wifi_ip(), state, esc_err);

    httpd_resp_set_type(req, "application/json");
    return httpd_resp_send(req, body, HTTPD_RESP_USE_STRLEN);
}

static int hex_value(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* Decode an application/x-www-form-urlencoded string in place. Returns the
 * decoded length. */
static size_t url_decode(char *s)
{
    char *dst = s;
    for (char *src = s; *src != '\0'; src++) {
        if (*src == '+') {
            *dst++ = ' ';
        } else if (*src == '%' && src[1] != '\0' && src[2] != '\0') {
            const int hi = hex_value(src[1]);
            const int lo = hex_value(src[2]);
            if (hi >= 0 && lo >= 0) {
                *dst++ = (char)((hi << 4) | lo);
                src += 2;
            } else {
                *dst++ = *src;
            }
        } else {
            *dst++ = *src;
        }
    }
    *dst = '\0';
    return (size_t)(dst - s);
}

/* Find "key=value" in a form body. The body is split on raw '&' characters
 * (the browser percent-encodes any '&' inside a value), and each value is
 * URL-decoded in place afterwards. Returns the decoded length, or -1 when
 * absent. */
static int form_value(const char *body, const char *key, char *out, size_t outsz)
{
    const size_t klen = strlen(key);
    const char *p = body;

    while (*p != '\0') {
        const char *amp = strchr(p, '&');
        const size_t plen = amp != NULL ? (size_t)(amp - p) : strlen(p);

        if (plen > klen && strncmp(p, key, klen) == 0 && p[klen] == '=') {
            const size_t vlen = plen - klen - 1;
            const size_t copy = vlen < outsz - 1 ? vlen : outsz - 1;
            memcpy(out, p + klen + 1, copy);
            out[copy] = '\0';
            return (int)url_decode(out);
        }
        if (amp == NULL) break;
        p = amp + 1;
    }
    return -1;
}

static esp_err_t handle_post_root(httpd_req_t *req)
{
    char body[MAX_FORM_BODY + 1];
    const int total = req->content_len;

    if (total <= 0 || total > MAX_FORM_BODY) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "form too large");
        return ESP_FAIL;
    }

    int received = 0;
    while (received < total) {
        const int r = httpd_req_recv(req, body + received,
                                     (size_t)(total - received));
        if (r <= 0) {
            httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST,
                                "incomplete request");
            return ESP_FAIL;
        }
        received += r;
    }
    body[received] = '\0';

    char ssid[MAX_SSID_LEN] = "";
    char pass[MAX_PASS_LEN + 1] = "";
    const int ssid_len = form_value(body, "ssid", ssid, sizeof(ssid));
    const int pass_len = form_value(body, "pass", pass, sizeof(pass));

    if (ssid_len <= 0) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "SSID is required");
        return ESP_FAIL;
    }
    if (ssid_len > MAX_SSID_LEN - 1 || pass_len > MAX_PASS_LEN - 1) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "value too long");
        return ESP_FAIL;
    }

    creds_save(ssid, pass);
    set_error(NULL);

    /* A fresh submission restarts the whole connect/watch/teardown dance. */
    esp_timer_stop(s_teardown);
    esp_timer_stop(s_watchdog);

    esp_err_t err = wifi_connect(ssid, pass);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "could not start the connection: %s", esp_err_to_name(err));
        set_error("could not start the connection");
    }

    /* Bounded wait: a network that accepts the association but never answers
     * DHCP otherwise leaves the page stuck on "connecting" forever. */
    esp_timer_start_once(s_watchdog,
                         (int64_t)CONFIG_MIRROR_CONNECT_TIMEOUT_S * 1000000);

    ESP_LOGI(TAG, "credentials saved for \"%s\", connecting", ssid);

    /* Serve the same page again; its poller picks up the new state. */
    return handle_get_root(req);
}

static esp_err_t handle_post_forget(httpd_req_t *req)
{
    (void)req;

    creds_clear();
    wifi_forget();
    set_error(NULL);

    /* The portal stays open with nothing saved. Also cancel a pending
     * teardown: the owner asked to stay in setup, not to go online. */
    esp_timer_stop(s_teardown);

    ESP_LOGI(TAG, "saved credentials cleared");
    return handle_get_root(req);
}

static esp_err_t handle_redirect(httpd_req_t *req)
{
    httpd_resp_set_status(req, "302 Found");
    httpd_resp_set_hdr(req, "Location", "/");
    return httpd_resp_send(req, NULL, 0);
}

static void register_handlers(void)
{
    /* Specific routes first; the wildcard catch-all registered last swallows
     * everything else for the captive-portal redirect. */
    static const httpd_uri_t get_root = {
        .uri = "/", .method = HTTP_GET, .handler = handle_get_root,
    };
    static const httpd_uri_t post_root = {
        .uri = "/", .method = HTTP_POST, .handler = handle_post_root,
    };
    static const httpd_uri_t get_status = {
        .uri = "/status", .method = HTTP_GET, .handler = handle_get_status,
    };
    static const httpd_uri_t post_forget = {
        .uri = "/forget", .method = HTTP_POST, .handler = handle_post_forget,
    };
    static const httpd_uri_t any = {
        .uri = "/*", .method = HTTP_GET, .handler = handle_redirect,
    };

    httpd_register_uri_handler(s_httpd, &get_root);
    httpd_register_uri_handler(s_httpd, &post_root);
    httpd_register_uri_handler(s_httpd, &get_status);
    httpd_register_uri_handler(s_httpd, &post_forget);
    httpd_register_uri_handler(s_httpd, &any);
}

static httpd_config_t server_config(void)
{
    httpd_config_t cfg = HTTPD_DEFAULT_CONFIG();
    cfg.stack_size = 8192;
    cfg.lru_purge_enable = true;
    cfg.uri_match_fn = httpd_uri_match_wildcard;
    return cfg;
}

/* captive-portal dns */

static void dns_recv(void *arg, struct udp_pcb *pcb, struct pbuf *p,
                     const ip_addr_t *addr, u16_t port)
{
    (void)arg;

    if (p == NULL || p->len < 12) {
        if (p != NULL) pbuf_free(p);
        return;
    }

    const uint8_t *q = (const uint8_t *)p->payload;
    size_t qlen = 12;
    bool ok = true;

    /* Walk the QNAME labels to their terminator. */
    while (qlen < p->len) {
        const uint8_t l = q[qlen];
        if (l == 0) {
            qlen += 1;
            break;
        }
        if ((l & 0xC0) == 0xC0) {   /* compression pointer, rare in queries */
            qlen += 2;
            break;
        }
        qlen += 1 + l;
    }
    if (qlen + 4 > p->len) ok = false;   /* need QTYPE and QCLASS */
    else qlen += 4;

    if (!ok) {
        pbuf_free(p);
        return;
    }

    const uint16_t qtype = (uint16_t)((q[qlen - 4] << 8) | q[qlen - 3]);
    const bool want_a = (qtype == 1);   /* A record only; AAAA gets an empty
                                         * answer so the client stops waiting */

    const size_t resp_len = qlen + (want_a ? 16 : 0);
    uint8_t *resp = malloc(resp_len);
    if (resp == NULL) {
        pbuf_free(p);
        return;
    }

    memcpy(resp, q, 2);                 /* transaction ID */
    resp[2] = 0x81;                     /* response, RD + RA */
    resp[3] = 0x80;                     /* rcode 0 */
    resp[4] = 0; resp[5] = 1;           /* QDCOUNT */
    resp[6] = 0; resp[7] = want_a ? 1 : 0;
    resp[8] = 0; resp[9] = 0;           /* NSCOUNT */
    resp[10] = 0; resp[11] = 0;         /* ARCOUNT */
    memcpy(resp + 12, q + 12, qlen - 12);   /* echo the question */

    if (want_a) {
        size_t off = qlen;
        resp[off++] = 0xC0; resp[off++] = 0x0C;   /* pointer to QNAME */
        resp[off++] = 0; resp[off++] = 1;         /* type A */
        resp[off++] = 0; resp[off++] = 1;         /* class IN */
        resp[off++] = 0; resp[off++] = 0;
        resp[off++] = 0; resp[off++] = 60;        /* TTL */
        resp[off++] = 0; resp[off++] = 4;         /* rdlength */

        esp_netif_t *ap = esp_netif_get_handle_from_ifkey("WIFI_AP_DEF");
        esp_netif_ip_info_t ip;
        if (ap != NULL && esp_netif_get_ip_info(ap, &ip) == ESP_OK) {
            memcpy(resp + off, &ip.ip.addr, 4);
        } else {
            resp[off] = 192; resp[off + 1] = 168;
            resp[off + 2] = 4; resp[off + 3] = 1;
        }
    }

    struct pbuf *out = pbuf_alloc(PBUF_TRANSPORT, resp_len, PBUF_RAM);
    if (out != NULL) {
        memcpy(out->payload, resp, resp_len);
        udp_sendto(pcb, out, addr, port);
        pbuf_free(out);
    }
    free(resp);
    pbuf_free(p);
}

static void dns_start(void)
{
    esp_netif_t *ap = esp_netif_get_handle_from_ifkey("WIFI_AP_DEF");
    esp_netif_ip_info_t ip;
    memset(&ip, 0, sizeof(ip));
    if (ap != NULL) esp_netif_get_ip_info(ap, &ip);

    s_dns_pcb = udp_new();
    if (s_dns_pcb == NULL) {
        ESP_LOGE(TAG, "could not allocate the DNS responder");
        return;
    }

    /* Bound to the access point's own address, so the responder only sees
     * queries from setup clients and never touches the station's DNS. */
    ip_addr_t bind_ip = IPADDR4_INIT(ip.ip.addr);
    if (udp_bind(s_dns_pcb, &bind_ip, 53) != ERR_OK) {
        ESP_LOGE(TAG, "could not bind port 53");
        udp_remove(s_dns_pcb);
        s_dns_pcb = NULL;
        return;
    }
    udp_recv(s_dns_pcb, dns_recv, NULL);

    ESP_LOGI(TAG, "captive-portal DNS answering on " IPSTR, IP2STR(&ip.ip));
}

static void dns_stop(void)
{
    if (s_dns_pcb != NULL) {
        udp_remove(s_dns_pcb);
        s_dns_pcb = NULL;
    }
}

/* portal */

static void build_ap_ssid(char *out, size_t outsz)
{
    uint8_t mac[6];
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    snprintf(out, outsz, "%s-%02X%02X", CONFIG_MIRROR_AP_SSID, mac[4], mac[5]);
}

static void portal_start(void)
{
    lock_state();
    if (s_portal_active) {
        unlock_state();
        return;
    }

    esp_err_t err = wifi_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "wifi init failed: %s", esp_err_to_name(err));
        unlock_state();
        return;
    }

    wifi_config_t ap = {0};
    build_ap_ssid((char *)ap.ap.ssid, sizeof(ap.ap.ssid));
    ap.ap.ssid_len = (uint8_t)strlen((const char *)ap.ap.ssid);
    ap.ap.channel = 1;
    ap.ap.max_connection = 4;
    if (CONFIG_MIRROR_AP_PASSWORD[0] != '\0') {
        strncpy((char *)ap.ap.password, CONFIG_MIRROR_AP_PASSWORD,
                sizeof(ap.ap.password) - 1);
        ap.ap.authmode = WIFI_AUTH_WPA_WPA2_PSK;
    } else {
        ap.ap.authmode = WIFI_AUTH_OPEN;
    }

    wifi_mode_t mode;
    if (esp_wifi_get_mode(&mode) != ESP_OK) mode = WIFI_MODE_NULL;

    if (mode == WIFI_MODE_NULL) {
        if (esp_wifi_set_mode(WIFI_MODE_APSTA) != ESP_OK ||
            esp_wifi_set_config(WIFI_IF_AP, &ap) != ESP_OK ||
            esp_wifi_start() != ESP_OK) {
            ESP_LOGE(TAG, "could not bring up the setup access point");
            unlock_state();
            return;
        }
    } else {
        /* WiFi is already running as a station whose saved credentials
         * failed. Switching to APSTA adds the access point alongside it; the
         * station keeps retrying the saved network on its own. */
        if (esp_wifi_set_mode(WIFI_MODE_APSTA) != ESP_OK ||
            esp_wifi_set_config(WIFI_IF_AP, &ap) != ESP_OK) {
            ESP_LOGE(TAG, "could not add the setup access point");
            unlock_state();
            return;
        }
    }

    httpd_config_t cfg = server_config();
    if (httpd_start(&s_httpd, &cfg) != ESP_OK) {
        ESP_LOGE(TAG, "setup page server failed to start");
        s_httpd = NULL;
        unlock_state();
        return;
    }
    register_handlers();
    dns_start();

    s_portal_active = true;
    unlock_state();

    ESP_LOGI(TAG, "setup access point \"%s\"%s at http://192.168.4.1",
             (const char *)ap.ap.ssid,
             ap.ap.authmode == WIFI_AUTH_OPEN ? " (open)" : " (password protected)");
}

/* entry */

esp_err_t provision_init(void)
{
    s_lock = xSemaphoreCreateMutex();
    if (s_lock == NULL) return ESP_ERR_NO_MEM;

    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READONLY, &h) == ESP_OK) {
        size_t len = sizeof(s_ssid);
        esp_err_t err = nvs_get_str(h, NVS_KEY_SSID, s_ssid, &len);
        if (err == ESP_OK && s_ssid[0] != '\0') {
            len = sizeof(s_pass);
            err = nvs_get_str(h, NVS_KEY_PASS, s_pass, &len);
            s_has_creds = (err == ESP_OK);
            if (s_has_creds) {
                ESP_LOGI(TAG, "saved credentials for \"%s\"", s_ssid);
            } else {
                s_ssid[0] = '\0';
            }
        }
        nvs_close(h);
    }

    const esp_timer_create_args_t watchdog_args = {
        .callback = on_watchdog,
        .name     = "prov_watchdog",
    };
    ESP_ERROR_CHECK(esp_timer_create(&watchdog_args, &s_watchdog));

    const esp_timer_create_args_t teardown_args = {
        .callback = on_teardown,
        .name     = "prov_teardown",
    };
    ESP_ERROR_CHECK(esp_timer_create(&teardown_args, &s_teardown));

    return ESP_OK;
}

esp_err_t provision_start(void)
{
    wifi_set_observer(provision_on_wifi);

    if (!s_has_creds) {
        ESP_LOGI(TAG, "no saved credentials, opening the setup portal");
        portal_start();
        return ESP_OK;
    }

    ESP_LOGI(TAG, "joining \"%s\", setup portal on failure within %d s",
             s_ssid, CONFIG_MIRROR_CONNECT_TIMEOUT_S);

    esp_err_t err = wifi_connect(s_ssid, s_pass);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "could not start WiFi: %s", esp_err_to_name(err));
        portal_start();
        return ESP_OK;
    }

    esp_timer_start_once(s_watchdog,
                         (int64_t)CONFIG_MIRROR_CONNECT_TIMEOUT_S * 1000000);
    return ESP_OK;
}
