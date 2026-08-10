/*
 * provision.c - captive-portal WiFi provisioning.
 *
 * Lifecycle:
 *
 *   no saved credentials  -> setup access point and portal from the first boot
 *   saved, reachable      -> join the home network, portal never opens
 *   saved, unreachable    -> try for MIRROR_CONNECT_TIMEOUT_S, then open the
 *                            portal; the station stays idle until the owner
 *                            submits credentials, so the portal's scans are
 *                            never fought by a background connect attempt
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
#include "esp_heap_caps.h"
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
/* Starts the portal's httpd a beat after the portal opens. See
 * portal_httpd_start: the API server also listens on port 80 and stops on
 * the same disconnect event, but after the provisioning code runs, so the
 * httpd must not bind synchronously inside the event handler. */
static esp_timer_handle_t s_portal_httpd;
static SemaphoreHandle_t s_lock;

/* Networks seen by the last scan, strongest first. Guarded by s_lock. */
#define MAX_SCAN_RESULTS 24
typedef struct {
    char   ssid[33];
    int8_t rssi;
    bool   open;
} scan_entry_t;
static scan_entry_t s_scan_results[MAX_SCAN_RESULTS];
static int  s_scan_count = 0;
static bool s_scanning = false;
static bool s_scan_handler_registered = false;

static void portal_start(void);
static void dns_stop(void);
static void scan_start(void);

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
    case WIFI_REASON_NO_AP_FOUND_W_COMPATIBLE_SECURITY: /* 210 */
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
    case WIFI_REASON_NO_AP_FOUND_W_COMPATIBLE_SECURITY:
        return "incompatible network security";
    default: {
        static char buf[40];
        snprintf(buf, sizeof(buf), "could not connect (reason %d)", reason);
        return buf;
    }
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

    if (wifi_is_connected()) {
        /* Connected at the moment; the connect handler stopped the timer. It
         * is one-shot, so re-arm it: a later permanent drop must still open
         * the portal instead of leaving the mirror retrying silently. */
        esp_timer_start_once(s_watchdog,
                             (int64_t)CONFIG_MIRROR_CONNECT_TIMEOUT_S * 1000000);
        return;
    }

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
        /* If the portal failed to come up, try again on the next beat rather
         * than leaving the device unreachable. */
        esp_timer_start_once(s_watchdog,
                             (int64_t)CONFIG_MIRROR_CONNECT_TIMEOUT_S * 1000000);
    }
}

static void on_teardown(void *arg)
{
    (void)arg;

    if (!portal_is_active()) return;

    /* A deferred httpd start may still be pending; drop it. */
    esp_timer_stop(s_portal_httpd);

    dns_stop();
    if (s_httpd != NULL) {
        httpd_stop(s_httpd);
        s_httpd = NULL;
    }
    esp_wifi_set_mode(WIFI_MODE_STA);
    wifi_set_autoreconnect(true);   /* normal operation: reconnect on drops */
    lock_state();
    s_portal_active = false;
    unlock_state();

    ESP_LOGI(TAG, "setup portal closed, running on the home network");
}

/* httpd */

static const char PORTAL_PAGE[] =
    "<!doctype html>"
    "<html lang=\"en\"><head><meta charset=\"utf-8\">"
    "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
    "<title>Smart Mirror setup</title>"
    "<style>"
    ":root{color-scheme:dark}"
    "*{box-sizing:border-box}"
    "body{margin:0;min-height:100vh;display:flex;align-items:center;"
    "justify-content:center;font-family:system-ui,-apple-system,'Segoe UI',sans-serif;"
    "color:#fff;background:#000 radial-gradient(120% 120% at 50% 0%,#10151c 0%,#000 60%)}"
    ".card{width:92vw;max-width:26rem;background:#0a0d12;border:1px solid #1c232e;"
    "border-radius:18px;padding:2rem;box-shadow:0 20px 60px rgba(0,229,255,.06)}"
    ".brand{display:flex;align-items:center;gap:.9rem}"
    "h1{font-size:1.3rem;margin:0;letter-spacing:.02em}"
    ".tagline{color:#8899aa;font-size:.85rem;margin:.2rem 0 1.6rem}"
    "label{display:block;font-size:.75rem;font-weight:700;letter-spacing:.08em;"
    "text-transform:uppercase;color:#8899aa;margin:1.1rem 0 .4rem}"
    "select,input{width:100%;padding:.65rem .8rem;font-size:1rem;color:#fff;"
    "background:#11161d;border:1px solid #232c38;border-radius:10px;outline:none}"
    "select:focus,input:focus{border-color:#00e5ff}"
    "input::placeholder{color:#55606e}"
    ".pw{position:relative}"
    ".pw input{padding-right:4.2rem}"
    "#showpw{position:absolute;right:.5rem;top:50%;transform:translateY(-50%);"
    "background:none;border:0;color:#00e5ff;font-size:.85rem;cursor:pointer}"
    "#go{width:100%;padding:.75rem;font-size:1rem;font-weight:700;color:#001014;"
    "background:#00e5ff;border:0;border-radius:10px;margin-top:1.4rem;cursor:pointer}"
    "#go:disabled{background:#1a2430;color:#55606e;cursor:default}"
    ".secondary{background:#11161d;border:1px solid #232c38;color:#b6c2d1;"
    "border-radius:10px;padding:.5rem .9rem;font-size:.85rem;"
    "margin-top:.8rem;margin-right:.5rem;cursor:pointer}"
    "#scanstate{color:#8899aa;font-size:.9rem;padding:.2rem 0}"
    ".hint{color:#8899aa;font-size:.8rem;margin-top:.4rem}"
    "#status{margin-top:1.1rem;min-height:1.4rem;font-size:.95rem}"
    "#status.ok{color:#7ee2a8}#status.err{color:#ff5c5c}"
    "</style></head><body>"
    "<div class=\"card\">"
    "<div class=\"brand\">"
    "<svg width=\"44\" height=\"44\" viewBox=\"0 0 44 44\" fill=\"none\">"
    "<rect x=\"6\" y=\"4\" width=\"32\" height=\"36\" rx=\"8\" stroke=\"#00E5FF\" stroke-width=\"2.5\"/>"
    "<circle cx=\"22\" cy=\"19\" r=\"9\" stroke=\"#FFFFFF\" stroke-width=\"2\"/>"
    "<path d=\"M22 12.5V19l4.5 3\" stroke=\"#00E5FF\" stroke-width=\"2\" stroke-linecap=\"round\"/>"
    "<path d=\"M13 32h18\" stroke=\"#8899AA\" stroke-width=\"2\" stroke-linecap=\"round\"/>"
    "</svg>"
    "<div><h1>Smart Mirror</h1>"
    "<p class=\"tagline\">Connect your mirror to your home network</p></div>"
    "</div>"
    "<form method=\"post\" action=\"/\" id=\"f\" autocomplete=\"off\">"
    "<label for=\"net\">WiFi network</label>"
    "<div id=\"scanstate\">Scanning for networks...</div>"
    "<select id=\"net\" hidden></select>"
    "<div id=\"manual\" hidden>"
    "<input id=\"manualssid\" maxlength=\"32\" placeholder=\"Network name\">"
    "</div>"
    "<div class=\"hint\" id=\"netinfo\" hidden></div>"
    "<label for=\"pass\">Password</label>"
    "<div class=\"pw\">"
    "<input id=\"pass\" name=\"pass\" type=\"password\" maxlength=\"63\" "
    "autocomplete=\"off\">"
    "<button type=\"button\" id=\"showpw\">Show</button>"
    "</div>"
    "<div class=\"hint\" id=\"passhint\" hidden>Open network, no password needed.</div>"
    "<button type=\"submit\" id=\"go\" disabled>Connect</button>"
    "<div>"
    "<button type=\"button\" class=\"secondary\" id=\"rescan\" hidden>Rescan</button>"
    "<button type=\"button\" class=\"secondary\" id=\"forget\" hidden>Forget saved network</button>"
    "</div>"
    "<input type=\"hidden\" name=\"ssid\" id=\"ssid\">"
    "</form>"
    "<div id=\"status\"></div>"
    "</div>"
    "<script>"
    "var form=document.getElementById('f'),sel=document.getElementById('net');"
    "var scanstate=document.getElementById('scanstate');"
    "var manual=document.getElementById('manual'),mssid=document.getElementById('manualssid');"
    "var pass=document.getElementById('pass'),passhint=document.getElementById('passhint');"
    "var showpw=document.getElementById('showpw'),go=document.getElementById('go');"
    "var rescan=document.getElementById('rescan'),forget=document.getElementById('forget');"
    "var st=document.getElementById('status'),hssid=document.getElementById('ssid');"
    "var netinfo=document.getElementById('netinfo');"
    "var OTHER='__other__',nets=[],saved='',scanTimer=null,retries=0;"
    "function fill(list){nets=list;sel.innerHTML='';"
    "var ph=document.createElement('option');ph.value='';"
    "ph.textContent='Select a network';sel.appendChild(ph);"
    "list.forEach(function(n){var o=document.createElement('option');"
    "o.value=n.ssid;o.textContent=n.ssid+(n.open?'  (open)':'');"
    "sel.appendChild(o);});"
    "var oth=document.createElement('option');oth.value=OTHER;"
    "oth.textContent='Other (type the name)';sel.appendChild(oth);"
    "sel.hidden=false;selectSaved();update();}"
    "function selectSaved(){if(!saved)return;"
    "for(var i=0;i<sel.options.length;i++){"
    "if(sel.options[i].value===saved){sel.selectedIndex=i;update();return;}}"
    "sel.value=OTHER;manual.hidden=false;mssid.value=saved;update();}"
    "function update(){var v=sel.value,n=null;"
    "for(var i=0;i<nets.length;i++){if(nets[i].ssid===v)n=nets[i];}"
    "var open=n?n.open:false;"
    "manual.hidden=(v!==OTHER);passhint.hidden=!open;pass.disabled=open;"
    "if(open)pass.value='';"
    "if(n){netinfo.hidden=false;"
    "netinfo.textContent='Signal '+n.rssi+' dBm'+(n.open?', open network':'');}"
    "else{netinfo.hidden=true;}"
    "go.disabled=(v===''||(v===OTHER&&mssid.value==='')||"
    "(n&&!n.open&&pass.value===''));}"
    "sel.onchange=update;mssid.oninput=update;pass.oninput=update;"
    "var kick=false;"
    "function startScan(k){rescan.hidden=true;sel.hidden=true;manual.hidden=true;"
    "scanstate.hidden=false;scanstate.textContent='Scanning for networks...';"
    "go.disabled=true;if(scanTimer)clearInterval(scanTimer);kick=k;"
    "scanTimer=setInterval(function(){var x=new XMLHttpRequest();"
    "x.open('GET','/scan'+(kick?'?rescan=1':''));kick=false;"
    "x.onload=function(){var s;try{s=JSON.parse(x.responseText)}catch(e){return}"
    "if(s.scanning)return;clearInterval(scanTimer);scanTimer=null;"
    "if(s.networks&&s.networks.length){scanstate.hidden=true;fill(s.networks);}"
    "else if(retries<2){retries++;startScan(true);return;}"
    "else{scanstate.textContent='No networks found. Rescan to try again.';}"
    "rescan.hidden=false;};x.send();},1500);}"
    "startScan(false);rescan.onclick=function(){retries=0;startScan(true);};"
    "function poll(){var x=new XMLHttpRequest();x.open('GET','/status');"
    "x.onload=function(){var s;try{s=JSON.parse(x.responseText)}catch(e){return}"
    "if(s.saved&&!saved)saved=s.ssid;"
    "forget.hidden=!s.saved;"
    "if(s.connected){st.className='ok';"
    "st.textContent='Connected. The mirror has joined '+s.ssid+'. "
    "You can close this page.';return;}"
    "if(s.error){st.className='err';"
    "st.textContent='Could not connect: '+s.error;return;}"
    "if(s.state==='connecting'){st.className='';"
    "st.textContent='Connecting to '+s.ssid+'...';return;}"
    "st.className='';st.textContent='';};x.send();}"
    "setInterval(poll,1500);poll();"
    "form.onsubmit=function(){"
    "if(sel.value===OTHER){hssid.value=mssid.value;}else{hssid.value=sel.value;}"
    "if(pass.disabled)pass.value='';};"
    "showpw.onclick=function(){var t=pass.type;"
    "pass.type=(t==='password')?'text':'password';"
    "this.textContent=(t==='password')?'Hide':'Show';};"
    "forget.onclick=function(){forget.hidden=true;"
    "var x=new XMLHttpRequest();x.open('POST','/forget');x.send();};"
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

static esp_err_t handle_get_scan(httpd_req_t *req)
{
    /* A ?rescan=1 query kicks off a fresh scan; plain calls only report the
     * current state. Polling must never restart the scan, or a poll cadence
     * faster than the scan duration would keep wiping the results and the
     * page would never see a completed scan. */
    char qbuf[16];
    if (httpd_req_get_url_query_str(req, qbuf, sizeof(qbuf)) == ESP_OK &&
        strstr(qbuf, "rescan") != NULL) {
        scan_start();
    }

    scan_entry_t snapshot[MAX_SCAN_RESULTS];
    bool scanning;
    int count;

    lock_state();
    scanning = s_scanning;
    count = s_scan_count;
    memcpy(snapshot, s_scan_results, sizeof(snapshot));
    unlock_state();

    const size_t cap = 256 + (size_t)count * 160;
    char *body = malloc(cap);
    if (body == NULL) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR,
                            "out of memory");
        return ESP_FAIL;
    }

    size_t off = (size_t)snprintf(body, cap, "{\"scanning\":%s,\"networks\":[",
                                  scanning ? "true" : "false");
    for (int i = 0; i < count && off < cap; i++) {
        char esc[96];
        json_escape(esc, sizeof(esc), snapshot[i].ssid);
        off += (size_t)snprintf(body + off, cap - off,
                                "%s{\"ssid\":\"%s\",\"rssi\":%d,\"open\":%s}",
                                i > 0 ? "," : "", esc, snapshot[i].rssi,
                                snapshot[i].open ? "true" : "false");
    }
    if (off + 2 < cap) {
        body[off++] = ']';
        body[off++] = '}';
        body[off] = '\0';
    }

    httpd_resp_set_type(req, "application/json");
    const esp_err_t ret = httpd_resp_send(req, body, HTTPD_RESP_USE_STRLEN);
    free(body);
    return ret;
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
    static const httpd_uri_t get_scan = {
        .uri = "/scan", .method = HTTP_GET, .handler = handle_get_scan,
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
    httpd_register_uri_handler(s_httpd, &get_scan);
    httpd_register_uri_handler(s_httpd, &post_forget);
    httpd_register_uri_handler(s_httpd, &any);
}

static httpd_config_t server_config(void)
{
    httpd_config_t cfg = HTTPD_DEFAULT_CONFIG();
    cfg.stack_size = 8192;
    cfg.lru_purge_enable = true;
    cfg.uri_match_fn = httpd_uri_match_wildcard;
    /* Task stack on PSRAM: internal SRAM is scarce (panel DMA, WiFi and the
     * BT controller all live there), and this server only serves the small
     * setup page and its JSON pollers. */
    cfg.task_caps = MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT;
    return cfg;
}

/* ------------------------------------------------------- wifi scanning */

/* Start a background scan if none is running. The result arrives on
 * WIFI_EVENT_SCAN_DONE and is copied into s_scan_results. */
static void scan_start(void)
{
    lock_state();
    if (s_scanning) {
        unlock_state();
        return;
    }
    s_scanning = true;
    s_scan_count = 0;
    unlock_state();

    wifi_scan_config_t cfg = {0};
    cfg.scan_type = WIFI_SCAN_TYPE_ACTIVE;
    cfg.show_hidden = false;

    const esp_err_t err = esp_wifi_scan_start(&cfg, false);
    if (err != ESP_OK) {
        /* Busy or not ready; whatever scan is running will clear the flag on
         * SCAN_DONE. */
        ESP_LOGW(TAG, "scan start failed: %s", esp_err_to_name(err));
        lock_state();
        s_scanning = false;
        unlock_state();
    }
}

static void on_scan_done(void *arg, esp_event_base_t base,
                         int32_t id, void *data)
{
    (void)arg; (void)base; (void)id; (void)data;

    uint16_t num = 0;
    esp_wifi_scan_get_ap_num(&num);

    wifi_ap_record_t *recs = NULL;
    uint16_t got = 0;
    if (num > 0) {
        recs = malloc((size_t)num * sizeof(wifi_ap_record_t));
        if (recs != NULL) {
            got = num;
            if (esp_wifi_scan_get_ap_records(&got, recs) != ESP_OK) got = 0;
        }
    }

    lock_state();
    s_scan_count = 0;
    for (uint16_t i = 0; i < got && s_scan_count < MAX_SCAN_RESULTS; i++) {
        if (recs[i].ssid[0] == '\0') continue;

        /* One entry per SSID, keeping the strongest signal of its BSSIDs. */
        bool dup = false;
        for (int j = 0; j < s_scan_count; j++) {
            if (memcmp(s_scan_results[j].ssid, recs[i].ssid, 32) == 0) {
                if (recs[i].rssi > s_scan_results[j].rssi) {
                    s_scan_results[j].rssi = recs[i].rssi;
                }
                dup = true;
                break;
            }
        }
        if (dup) continue;

        memcpy(s_scan_results[s_scan_count].ssid, recs[i].ssid, 32);
        s_scan_results[s_scan_count].ssid[32] = '\0';
        s_scan_results[s_scan_count].rssi = recs[i].rssi;
        s_scan_results[s_scan_count].open =
            (recs[i].authmode == WIFI_AUTH_OPEN);
        s_scan_count++;
    }

    /* Strongest first. */
    for (int i = 1; i < s_scan_count; i++) {
        const scan_entry_t key = s_scan_results[i];
        int j = i - 1;
        while (j >= 0 && s_scan_results[j].rssi < key.rssi) {
            s_scan_results[j + 1] = s_scan_results[j];
            j--;
        }
        s_scan_results[j + 1] = key;
    }

    s_scanning = false;
    unlock_state();

    /* Raw records, before dedup: the exact SSID bytes and the advertised
     * authmode are what decide whether a connect attempt is even allowed. */
    ESP_LOGI(TAG, "scan found %d networks", s_scan_count);
    for (uint16_t i = 0; i < got; i++) {
        char hex[65];
        for (int b = 0; b < 32; b++) {
            snprintf(hex + b * 2, 3, "%02x", recs[i].ssid[b]);
        }
        ESP_LOGI(TAG, "  \"%.32s\" rssi %d auth %d hex %s",
                 recs[i].ssid, recs[i].rssi, recs[i].authmode, hex);
    }

    if (recs != NULL) free(recs);
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

/* Short enough that the current event dispatch (including the API server's
 * stop handler, which releases port 80) has long finished. */
#define PORTAL_HTTPD_DELAY_US (200 * 1000)

static void portal_httpd_start(void *arg)
{
    (void)arg;

    lock_state();
    if (!s_portal_active || s_httpd != NULL) {
        unlock_state();
        return;
    }

    httpd_config_t cfg = server_config();
    const esp_err_t httpd_err = httpd_start(&s_httpd, &cfg);
    if (httpd_err != ESP_OK) {
        /* The API server's stop handler runs in the same event dispatch that
         * opened the portal, so port 80 is free by the time this fires. A
         * failure here is a real resource problem, not the old race. */
        ESP_LOGE(TAG, "setup page server failed to start: %s",
                 esp_err_to_name(httpd_err));
        s_httpd = NULL;
        unlock_state();
        return;
    }
    register_handlers();
    dns_start();
    unlock_state();

    ESP_LOGI(TAG, "setup portal serving at http://192.168.4.1");

    /* Kick off the first scan so the dropdown is already populated when the
     * owner's phone opens the page. */
    scan_start();
}

static void portal_start(void)
{
    lock_state();
    if (s_portal_active) {
        unlock_state();
        return;
    }

    char ap_ssid[32];
    build_ap_ssid(ap_ssid, sizeof(ap_ssid));

    /* wifi_start_ap brings the radio up whether or not the station is already
     * running, so this works both on first boot and as a fallback after
     * failed credentials. */
    esp_err_t err = wifi_start_ap(ap_ssid, CONFIG_MIRROR_AP_PASSWORD);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "could not bring up the setup access point");
        unlock_state();
        return;
    }

    /* Stop the station's background reconnect loop. While the portal is open
     * the station only connects when the owner submits credentials; a
     * retrying station would fight the portal's scans, which come back empty
     * while an association attempt is in flight. */
    wifi_set_autoreconnect(false);

    if (!s_scan_handler_registered) {
        const esp_err_t err = esp_event_handler_instance_register(
            WIFI_EVENT, WIFI_EVENT_SCAN_DONE, &on_scan_done, NULL, NULL);
        if (err != ESP_OK) {
            ESP_LOGW(TAG, "could not register the scan handler: %s",
                     esp_err_to_name(err));
        } else {
            s_scan_handler_registered = true;
        }
    }

    s_portal_active = true;
    unlock_state();

    ESP_LOGI(TAG, "setup access point \"%s\"%s, portal at http://192.168.4.1",
             ap_ssid,
             CONFIG_MIRROR_AP_PASSWORD[0] != '\0' ? " (password protected)"
                                                  : " (open)");

    /* The httpd starts on a timer, not here: this runs inside the
     * WIFI_EVENT_STA_DISCONNECTED dispatch, and the LAN API server's own
     * disconnect handler (which releases port 80) only runs after this
     * function returns. Binding synchronously would race it. */
    esp_timer_stop(s_portal_httpd);
    esp_timer_start_once(s_portal_httpd, PORTAL_HTTPD_DELAY_US);
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
                ESP_LOGI(TAG, "saved credentials for \"%s\" (%d-char password)",
                         s_ssid, (int)strlen(s_pass));
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

    const esp_timer_create_args_t portal_httpd_args = {
        .callback = portal_httpd_start,
        .name     = "prov_httpd",
    };
    ESP_ERROR_CHECK(esp_timer_create(&portal_httpd_args, &s_portal_httpd));

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
