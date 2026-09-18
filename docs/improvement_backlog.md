# Improvement backlog

**Status: OPEN — a first batch was implemented on 2026-09-14; everything marked `Done`
below is closed, and the rest is untouched.** This is a backlog, not a schedule: items are
ordered by risk, not by plan, and any item can be picked up on its own.

- Scanned 2026-09-14, tree at commit `08d6c03` ("firmware: bump to 0.2.23 and stage the
  bundled image"). Nothing in the repository was modified by the scan.
- Every item carries its own evidence, fix and definition of done, so it can be worked
  without re-reading this whole file.
- **Maintenance:** when an item is closed, set `Status: Done (date)` in the index and leave
  the entry in place. The evidence is what stops the same defect being reintroduced.
- **Re-check before acting:** the file paths and line numbers were true at the commit above.
  Re-run §"Baseline snapshot" and confirm the item is still open before starting.

Legend — Confidence: **V** reproduced or read first-hand during the scan (the evidence line
quotes what settles it); **R** reported by an area review, plausible and specific, not
independently reproduced (re-verify before fixing). Severity: **BLOCKER** remote
crash/corruption or device takeover · **HIGH** field-visible wrong behaviour, data loss,
wedged feature · **MEDIUM** latent defect, undefined behaviour, fragile invariant ·
**LOW** polish.
Effort: **XS** under an hour · **S** about half a day · **M** one to two days · **L** three
days or more, or needs hardware.

### First batch, implemented 2026-09-14

Chosen as the high-value, low-effort tier: each is a small, contained change with a
verification that runs on this machine (no hardware needed).

| Item | Change | Verified by |
|---|---|---|
| B1 *(partial)* | `firmware/main/net/ble.c` rejects a game-input frame longer than the 49-byte buffer **before** copying it, instead of after. The pairing requirement is still open | Firmware builds; the guard is a length check ahead of the only copy |
| B3 | `mirror_lan.dart` declares `contentLength` on the layout PUT | New test asserts no `Transfer-Encoding` and an exact length; the mirror can now read the body |
| H1 | `provision.c` registers the scan-completion handler on first scan rather than only when the setup portal opens | Firmware builds; all three scan entry points go through `scan_start()` |
| H2 | `wifi.c` no longer retries from the disconnect handler when auto-reconnect is off | Firmware builds; the retry only happens on the timer path now |
| H4 | The designer asks before New / Open / stock presets discard unsaved work, offering Save | Analyzer clean; suite green |
| H5 | Name, canvas, background and brightness go through the controller's edit funnel, so they are undoable and mark the document dirty | Analyzer clean; suite green |
| H6 | Duplicating a widget as large as the canvas no longer throws | Two new tests in `layout_doc_test.dart` (no-room and normal cases) |
| H7 | mDNS discovery has its own generation counter, so the first device no longer cancels the search or wedges Browse | Analyzer clean; suite green |
| H8 | `--dump` always writes the full-scale frame the panel receives; `-b` is a preview-only control; the "bytes the panel receives" claims on the golden tests and in the README now describe what those bytes actually are | Dump compared byte-for-byte against a 255 export; `-b` no longer changes the dump while the PNG still follows it; `-b 256` is rejected |
| H9 | `core/Makefile.host` lists the PIC dependency files, so the library the designer loads rebuilds after a header change | `touch layout.h && make` recompiles the PIC objects and relinks; a second run rebuilds nothing |
| M2 | Network-supplied numbers are clamped where they are read: `line_gap`, `max_items`, the countdown deadline, and the integer conversion | New `hostile layout` test group; the `-ftrapv` reproduction that aborted at `render.c:401` now exits cleanly |
| M3 | Rect components are clamped before narrowing to `int16_t`, so a silly rect warns and clips instead of wrapping back inside the canvas | Same test group |
| M8 | The update's rollback is cancelled after the first frame is drawn, not before the render task has started | Firmware builds; `ota_mark_valid()` moved into the render task |
| H14 | Name the reason a phone cannot reach the mirror's LAN API before an upload starts | Three new `reachable()` cases; the Pixel now says "Can't reach the mirror over WiFi" instead of a socket timeout |
| D18 | Re-stage the bundled image and bump the version after the firmware fixes landed without one | Staged and built images are byte-identical at `0.2.24` |
| M10 *(1 of 6)* | `resolved_font_test.dart` asserted stale font names and scales, and had been failing unseen behind the skip | Now asserts agreement with the engine; both tests pass with the native core |
| M13 *(4 of 5)* | Hit-testing skips unknown widget types; `-b` is range-checked; the evening sample's clock and its machine-readable time agree; "All done" is only claimed when the data says so | Two tests in the core suite; the existing render fixtures are unchanged |
| D17 *(partial)* | Empty `designer/mirror_designer/` removed; two unused FFI typedefs and one no-op assertion deleted, taking `dart analyze` from 13 issues to 10 | `dart analyze --fatal-infos`; suite green |

The batch also confirmed what the scan predicted: with the native core made loadable (see I6),
the 36 skipped designer tests **ran for the first time, and two of them failed**. Both were
stale expectations, both are fixed, and the suite now reports 238 passing with nothing
skipped.

---

## Backlog index

| ID | Item | Sev | Effort | Depends on | Status |
|---|---|---|---|---|---|
| **Tier 0 — someone else can damage the device** | | | | | |
| B1 | Bound the BLE game-input copy; require pairing for privileged commands | BLOCKER | S | — | Partly done — copy bounded; pairing open |
| B2 | Give the LAN API a device token and a Host check | BLOCKER | M | B1 | Open |
| **Tier 1 — a shipped feature fails for a normal user today** | | | | | |
| B3 | Send `Content-Length` on the LAN layout PUT | BLOCKER | XS | — | Done 2026-09-14 |
| H1 | Register the WiFi scan handler outside the portal | HIGH | XS | — | Done 2026-09-14 |
| H2 | Stop the STA retry storm when autoreconnect is off | HIGH | XS | — | Done 2026-09-14 |
| H14 | Say why a phone cannot reach the mirror's LAN API instead of failing mid-upload | HIGH | S | — | Done 2026-09-14 |
| H3 | Constrain the clock bootstrap; offer a TCP SNTP path | HIGH | M | — | Open |
| H8 | Make `--dump` byte-identical to what the device receives | HIGH | S | — | Done 2026-09-14 |
| H13 | Fix or drop the Cairo timezone entry | HIGH | XS | — | Open |
| M5a | WiFi SSID/PSK length limits (32-char SSID unreachable) | MEDIUM | XS | — | Open |
| H10 | Bound breakout's brick indexing | HIGH | XS | — | Open |
| H11 | Mask breakout's phantom brick bits (level-clear unreachable) | HIGH | XS | — | Open |
| H12 | Drain controller endpoints in the game transport | HIGH | S | — | Open |
| **Tier 2 — you can lose work, or the app/renderer crashes or shows something wrong** | | | | | |
| H4 | Confirm before New/Open/preset discards unsaved work | HIGH | S | — | Done 2026-09-14 |
| H5 | Route layout properties through the undo/dirty funnel | HIGH | S | — | Done 2026-09-14 |
| H6 | Fix the `Duplicate` clamp throw | HIGH | XS | — | Done 2026-09-14 |
| H7 | Split the mDNS discovery token from per-device status | HIGH | XS | — | Done 2026-09-14 |
| H9 | Add the PIC dep files to `-include` (stale `.so`) | HIGH | XS | — | Done 2026-09-14 |
| M10 | Designer engine robustness (6 sub-items) | MEDIUM | S | — | Partly done — 1 of 6 |
| M11 | Designer UI lifecycle and input defects (10 sub-items) | MEDIUM | M | — | Partly done — 1 of 10 |
| M13 | Render-core edge cases (5 sub-items) | MEDIUM | S | I2 | Partly done — 4 of 5 |
| **Tier 3 — latent, hardening, or needs a decision** | | | | | |
| M1 | Report string truncation instead of returning success | MEDIUM | S | I4 | Open |
| M2 | Clamp network-supplied numbers (reproduced UB) | MEDIUM | S | — | Done 2026-09-14 |
| M3 | Range-check rect components before `int16_t` | MEDIUM | XS | — | Done 2026-09-14 |
| M4 | BLE state: status-line bound, unlocked reads, 32 KB always allocated | MEDIUM | S | I4 | Open |
| M5b | Passphrase in cleartext in NVS (encrypt, or document) | MEDIUM | S | *decision 3* | Open |
| M6 | Pass the known size to `esp_ota_begin` | MEDIUM | XS | B2 | Open |
| M7 | Validate the stored config when loading from NVS | MEDIUM | XS | — | Open |
| M8 | Gate `ota_mark_valid()` on a successfully started render task | MEDIUM | XS | — | Done 2026-09-14 |
| M9 | Fix or remove the MBI5124 driver option | MEDIUM | XS | *decision 4* | Open |
| M12 | Gamekit runtime and host-harness defects | MEDIUM | M | — | Open |
| M14 | The first weather fetch after a boot can fail its TLS handshake | MEDIUM | S | — | Open |
| L1–L15 | Assorted LOW items | LOW | S | — | Open |
| **Tier 4 — test and CI infrastructure (unblocks confident work on Tier 3)** | | | | | |
| I1 | Add CI: core check, firmware build, designer analyze + test | — | S | — | Open |
| I2 | Sanitizer targets (`test-asan`, `test-ubsan`) | — | S | — | Open |
| I3 | Fuzz the network-facing parsers | — | M | I2 | Open |
| I4 | Host test rig for firmware logic | — | L | — | Open |
| I5 | Golden frames for the untested widget types | — | S | I1 | Open |
| I6 | Stop the designer's 36 skipped tests from hiding | — | S | I1 | Open |
| I7 | `gen_gamma.py --check`, wired into `make check` | — | XS | — | Open |
| **Tier 5 — functionality** | | | | | |
| F1 | Calendar and todos via a server-expanded ICS feed | — | L | I4 | Open |
| F2 | Sunrise/sunset and an hourly temperature series | — | M | — | Open |
| F3 | Night dimming schedule | — | M | — | Open |
| F4 | Panel sizes beyond 64x32 | — | L | *decision 5* | Open |
| F5 | Gamekit protocol completion (HELLO/WELCOME, seq, journal hash, axes) | — | M | M12 | Open |
| F6 | Designer UX: unsaved guard, `smooth` control, error surfacing | — | M | H4, H5 | Open |
| **Tier 6 — documentation and housekeeping** | | | | | |
| D1–D15 | Documentation corrections | — | S | — | Open |
| D17 | Housekeeping: empty directory, `dart analyze` warnings | — | XS | — | Partly done — 10 analyzer infos remain |
| D18 | Re-stage the bundled image and bump the version after a firmware change | — | XS | — | Done 2026-09-14 |

---

## Baseline snapshot (2026-09-14, commit `08d6c03`)

Re-run these to see whether the tree has moved since.

| Check | Command | Result |
|---|---|---|
| Core build | `make -C core -f Makefile.host clean && make -f Makefile.host` | Clean, **zero warnings** under `-Wall -Wextra -Wpedantic -Wshadow -Wstrict-prototypes -Wmissing-prototypes -Wpointer-arith -Wwrite-strings` |
| Core tests | `make -C core -f Makefile.host check` | **578 checks, 0 failures**; fontcheck OK; bindcheck 38 bound / 38 exported / 38 declared |
| CLI smoke | `./core/build/host/mirror-cli layouts/mini.json --all -s 8 --led --dump /tmp/mini.dump` | 4 PNGs, `6144`-byte dump (64x32x3) at full scale |
| Firmware build | `source $HOME/esp/esp-idf-v5.5/export.sh && idf.py -C firmware build` | Success, ESP-IDF 5.5.2; image `0x13ee20`, 69% of the 4 MB app partition free |
| Firmware warnings | Re-compile `firmware/main/**/*.c` with the core's warning set | 1 diagnostic: `main.c:200` (`app_main`, an ESP-IDF convention) |
| Designer tests | `cd designer && flutter test` | **202 passed, 36 skipped** (native core not on the library path — see I6) |
| Designer analyse | `cd designer && dart analyze --fatal-infos` | **10 issues**: 10 infos (`library_private_types_in_public_api` in `game_bindings.dart`) |
| CI | `ls .github` | **Does not exist** (see I1) |
| Sanitizers | `gcc -fsanitize=undefined …` | Fails here: `ld: cannot find /usr/lib64/libubsan.so.1.0.0`. `-ftrapv` works and is what this scan used |

Toolchain note: `flutter`/`dart` are on `PATH`; `idf.py` is not — it needs
`source $HOME/esp/esp-idf-v5.5/export.sh`.

### How the scan was run

Eleven concurrent area reviews (render core, JSON/layout parser, host+FFI+tools, BLE,
HTTP/OTA/WiFi, firmware core+providers, gamekit, designer engine, designer transports,
designer UI, docs) over ~57k lines, then a verification pass on every claim that drives a
Tier 0–2 item.

The structural result is worth stating plainly: **the parts of the system that are wrong are
the parts no test can see.** The render core is clean apart from edge cases in the widget
types that appear in no golden frame, while every Tier 1 item above lives in a path that has
no test at all — the WiFi picker, the LAN push, the setup portal, the games, the clock, the
app's file menu. That is why Tier 4 exists as its own tier, and the first batch showed the
prediction was exact rather than rhetorical: two designer tests had been failing for months
behind a skip.

---

## Tier 0 — someone else can damage the device

### B1 — Unauthenticated BLE write smashes the NimBLE host task stack **(V)** · Effort: S · Blocks: B2

**Status: the buffer bound is fixed. The pairing requirement is open.**

`firmware/main/net/ble.c:780-796`

```c
const uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
if (len < 1) return 0;

uint8_t p[1 + 3 * 16];                  /* 49 bytes */
if (len > sizeof(p)) { ...dropped... }  /* added: the check the copy needed */
os_mbuf_copydata(ctxt->om, 0, len, p);
const uint8_t count = p[0];
if (count > 16 || len != 1 + 3 * (uint16_t)count) { ... return 0; }
```

`CONFIG_BT_NIMBLE_ATT_PREFERRED_MTU=512` (`firmware/sdkconfig.defaults:93`), the
characteristic is write-without-response with no length extension, and no service requires
pairing — so before this fix any central in radio range could write up to 509 bytes into a
49-byte stack array before a single byte was checked. In plain terms: any phone or laptop
within a few metres could hand the mirror a message ten times bigger than the box it poured
it into. The two sibling callbacks (`cmd_write_cb:718-722`, `data_write_cb:747-757`) both
bounded the length first; this one was the outlier, and its comment claimed the opposite of
what it did.

**Still to do.** Put the privileged commands behind a pairing policy: layout push, config
push, `factory reset`, `reboot`, `wifi forget`, `begin wifi`. Today every one of those is an
unauthenticated ASCII write from any central in range.

**Done when.** An unpaired central cannot push a layout or reset the device.

### B2 — The LAN API has no authentication at all **(V)** · Effort: M · Depends on: B1 · Gates: M6, F1

`firmware/main/net/api_server.c:250-268`, `firmware/main/net/ota.c:88-170`

Five handlers are registered with exact path and method and no auth callback. In
`ota_handle_upload` there is no token check anywhere: it validates `Content-Length`,
allocates PSRAM, writes the image and reboots. In plain terms: anyone on your WiFi — a
guest's phone, a smart bulb that has been taken over — can replace the mirror's software, and
a web page you visit can do it too, because browsers let a page silently send a form to a
local address. There is no credential to change afterwards. Separately,
`esp_ota_begin(OTA_SIZE_UNKNOWN)` erases the whole 4 MB program area before writing, so any
peer can also stall the device for seconds at a time, repeatably.

**Fix.** A device token established over the (paired) BLE link.
1. `firmware/main/config.c` — NVS key `api_token`, 32 hex chars, generated on first boot;
   `mirror_config_api_token()`.
2. `ble.c` — `get token` / `set token <32 hex>`, behind the same pairing policy as
   `factory reset`; the designer stores it in its settings.
3. `api_server.c` — require `Authorization: Bearer <token>` on `PUT /api/layout`,
   `POST /api/ota`, `GET /api/layout` and `GET /api/log`; leave `GET /api/status` open but
   free of anything sensitive. Add a `Host` allow-list check and never send a wildcard CORS
   header.
4. `mirror_lan.dart` — send the header, and report 401 distinctly from "wrong address".

**Done when.** `curl -X POST --data-binary @firmware/build/smart_mirror.bin http://<ip>/api/ota`
returns 401 and the running app is untouched; the designer's LAN push and OTA still work.

---

## Tier 1 — a shipped feature fails for a normal user today

### B3 — Every LAN layout push failed against real firmware **(V)** · Done 2026-09-14 · Effort: XS

**Was:** `designer/lib/src/services/mirror_lan.dart:149-155` set `contentType` and called
`req.add(...)` without `contentLength`, so the app framed the body as "here comes some data,
length unknown". Measured directly:

```
METHOD=PUT contentLength=-1 transferEncoding=chunked
```

ESP-IDF's httpd does not de-chunk requests: `httpd_parse.c:370` maps a chunked body to
`content_len = 0`, so `handle_put_layout` took the `total <= 0` branch and answered
`400 "empty body"`, reported in the app as unreadable JSON. `uploadFirmwareBytes` set the
length and worked, which is what identified this as a slip rather than a design.

**Fixed:** the encoded bytes are measured and declared before `add`. A test now asserts the
framing (no `Transfer-Encoding`, exact declared length) rather than only the stored bytes,
because the loopback Dart server de-chunks and hid the difference.

### H1 — The app's WiFi picker never filled **(V)** · Done 2026-09-14 · Effort: XS

**Was:** `WIFI_EVENT_SCAN_DONE` was registered inside `portal_start()` only, and
`provision_scan_start()` — what the app's "scan networks" button calls — just started a scan
and never reaped it. On a mirror already joined to a network the results were discarded, the
device then believed a scan was still running, and every later scan was skipped, including
the setup hotspot's own, until a reboot. Exactly the moment you need it: you changed the
router password.

**Fixed:** `ensure_scan_handler()` registers on first use, and `scan_start()` calls it, so all
three scan entry points are covered with no portal involved.

### H2 — The setup hotspot could not scan either **(V)** · Done 2026-09-14 · Effort: XS

**Was:** `wifi.c:174-179`

```c
if (s_reconnect != NULL && s_autoreconnect) { esp_timer_start_once(...); }
else { esp_wifi_connect(); }
```

The setup hotspot switches auto-reconnect off precisely so the radio can scan, and the portal
opens when the saved network has stopped answering — so those attempts failed, the handler
retried instantly with no pause, and the radio was never idle long enough for the scan the
setup page's network list is built from.

**Fixed:** with auto-reconnect off there is no retry from the handler at all; the timer path
(and a fallback when no timer exists) still serves the normal case.

### H14 — The update failed on the phone while the mirror looked connected **(V)** · Done 2026-09-14 · Effort: S

**Was:** tapping *Update firmware → Install v0.2.23* on the Pixel answered with a socket
timeout, and the mirror never saw a request. Bluetooth and WiFi are separate paths, and the
app only ever checked the BLE side: it enabled the button from the pong's IP and then spent
the upload's timeout on the first packet, reporting

```
update: could not reach 192.168.0.165: Connection timed out (OS Error: Connection timed out, errno = 110)
```

which names neither of the two real causes. A full-tunnel VPN on the phone is the common
one: `dumpsys connectivity` shows Proton VPN's `tun0` carrying `192.168.0.0/17 -> tun0`, so
the mirror's subnet goes into the tunnel and its SYN never reaches the AP. Measured from the
app's own UID on the device (`adb shell run-as com.example.mirror_designer`, the APK is
debuggable): `nc 192.168.0.165 80` times out and `nc 1.1.1.1 443` answers, and the phone's
ARP table has no entry for the mirror afterwards — the packets did not leave `wlan0`. The
mirror's own persisted log settled the device side: in ~4 days of entries, the only
`OTA_BEGIN`/`OTA_OK` pair is the probe upload sent from the PC.

**Fixed:** `MirrorLan.reachable()` — a 4 s TCP connect probe — gates every flow that sends
bytes over WiFi (both OTA entry points, bundled and source-dialog, and the LAN layout push).
When it fails the app says which address is unreachable, that Bluetooth being up does not
mean the WiFi path is, and the two causes: a VPN routing local traffic (with the setting to
look for) and a phone on another network. Retry re-probes in place, so enabling the VPN's
LAN access and tapping Retry finishes the update. Three cases in `mirror_lan_test.dart`
(answer, refused port, packets that go nowhere).

### H3 — Anyone who answers one request can set the mirror's clock **(V)** · Effort: M

`firmware/main/net/http_get.c:104-119`, `providers/openmeteo.c:103`

The mirror has no clock battery, so it uses the date printed on the first weather reply to
set the time — and the check that the date is sensible runs *after* the clock is already set.
An unencrypted first request is unavoidable here (the mirror cannot check a certificate
without knowing the date), so a fake hotspot or anything on the path can answer with a
plausible wrong date, say 2027. The mirror then treats the clock as good, and every later
secure request fails because the real site's certificate looks "not valid yet". The panel
shows a confidently wrong time and the weather silently stops updating, with no widget
falling back to a placeholder.

**Fix, in value order.** (a) Accept the date only inside a sane window (build date … +1 year)
and record where the clock came from; (b) make the window tight enough that a hostile value
cannot satisfy the condition for going encrypted, and retry the cleartext path otherwise;
(c) offer time over TCP/443 so a network that blocks the standard time port is not forced
into cleartext at all; (d) expose "the clock is unverified" through the model so a layout can
show it.

**Done when.** A fake weather server returning `Date: Fri, 01 Jan 2027 00:00:00 GMT` and a
valid body does not move the clock, and weather keeps updating.

### H8 — `--dump` did not produce the bytes the device sends **(V)** · Done 2026-09-14 · Effort: S

**Was:** `core/host/mirror_cli.c` exported the dump at `layout->brightness` (200 in all ten
stock layouts) and then applied the mirror simulation, while the firmware
(`firmware/main/main.c`) exports at 255 and dims in the driver by shortening LED on-time. So
every device-versus-host comparison showed a uniform false mismatch of about 78%, and anyone
debugging chased a difference that was not there.

**Fixed:** the dump is always the full-scale frame the panel receives, and `-b` is now
preview-only (documented in the usage text and enforced: `-b 256` is rejected rather than
wrapping to 0). The claims about "the exact bytes the panel receives" in the golden test
comments, the digest header and the README were wrong in the other direction and now describe
what those bytes actually are.

**Verified:** the dump compares byte-for-byte equal to a 255 export and unequal to a 200 one;
`-b` changes the PNG but not the dump.

### H13 — The app's own Egypt timezone is wrong half the year **(R)** · Effort: XS

`designer/lib/src/services/mirror_location.dart:228-233`

`'Africa/Cairo': 'EET-2'` says "always two hours ahead of UTC", but Egypt brought daylight
saving back in 2023 and it is in force. The wizard preselects this for any geocoded Egyptian
place, so those mirrors run an hour out from late April to late October, and the owner has to
notice and correct it. The table's own contract admits a zone only "when its DST rules are
current", which is why Buenos Aires and Santiago were left out.

**Done when.** Confirmed against IANA and either given the real DST rule or removed from the
table, with a unit test asserting the offset inside and outside the DST window.

### M5a — A 32-character WiFi name can never be joined **(V)** · Effort: XS · See also M5b

`firmware/main/net/provision.c:55-57`, `:619-631`, `wifi.c:246-247/151-152/278-279`

`MAX_SSID_LEN 32` / `MAX_PASS_LEN 64` are used as both buffer limit and validation bound:
`ssid_len > MAX_SSID_LEN - 1` rejects a legal 32-byte SSID, and `strncpy(..., sizeof-1)`
caps the SSID at 31 bytes and a 64-character hex PSK at 63 — so a full-length SSID or hex
PSK can never be joined, and the failure reads as "network not found" (R for the
user-visible symptom, V for the limits).

**Fix (lengths):** size each buffer one byte above the protocol limit and validate against the
limit, not the buffer — `char ssid[33]` with `ssid_len > 32` rejected, `char pass[65]` with
`pass_len > 63`, then `strncpy(dst, src, sizeof(dst) - 1)` terminates correctly. Note that a
32-byte SSID leaves no room for a terminator in `wifi_config_t`'s own field, so this needs a
device to confirm rather than a host test alone.

**Done when.** A test joins a network with a 32-character name, and a rejected name produces
a message that says so.

### H10 — Breakout writes outside its own memory on a wide panel **(V)** · Effort: XS

`gamekit/examples/breakout/game_breakout.c:68-78`

The brick wall is stored as four 32-bit words per row (128 bits), but the code picks the word
from the *panel width* and only checks `x < panel_w`. Run the game on a panel wider than 128
pixels — the command-line tool accepts arbitrary sizes, and the designer can open any size —
and it writes past the end of the memory it borrowed.

**Done when.** `game-cli breakout --panel 256x64` under a memory checker reports no overflow;
a host test covers the helper directly.

### H11 — Breakout can never be finished **(V)** · Effort: XS

`gamekit/examples/breakout/game_breakout.c:62-66`, `:177-181`

The wall is built with all 128 bits lit, but the hit test refuses anything at or beyond the
panel edge and the clear function is only reached through it. On a 64-pixel panel the top 64
bits of every row can never be cleared, so "are any bricks left?" is always yes: the level
never completes, the clearing bonus never fires and the wall never refills. Past level 1 the
game is unwinnable.

**Fix.** Mask each word to the live panel width when filling the wall.

**Done when.** A host test clears every reachable cell and "any bricks left" becomes false,
or the level counter increments on hardware after a full clear.

### H12 — Controller messages pile up on the device **(R)** · Effort: S

`gamekit/src/net_loopback.c:107`

In the two-device setup the phone is the controller; the mirror broadcasts every frame to it
and nothing on the device ever empties the incoming pile. About 66 KB of stale frames sits
there for the whole match, and each later send allocates and frees 1 KB. It works, but it is
unbounded growth on the same small memory the renderer uses, and it makes the local transport
unrepresentative of a real network link.

**Fix.** A bounded per-endpoint queue (keep the newest two — all a controller needs) reclaimed
on close.

**Done when.** A host test sends 200 broadcasts to a created controller endpoint and the queue
depth and memory delta stay flat.

---

## Tier 2 — you can lose work, or the app/renderer crashes or shows something wrong

### H4 — New, Open and stock presets discarded unsaved work silently **(V)** · Done 2026-09-14 · Effort: S

**Was:** `_c.dirty` was read in exactly one place — the title's `*`. `newLayout()`, `_open()`
and the stock-layout menu items replaced the document unconditionally; an afternoon of
arranging widgets disappeared on one click.

**Fixed:** one confirmation funnel (`_confirmDiscard()`) used by New, Open and the stock
presets, offering Cancel / Discard / Save, where choosing Save only proceeds if the save
actually completed rather than being cancelled at the file picker.

### H5 — Four layout properties could not be undone **(V)** · Done 2026-09-14 · Effort: S

**Was:** the controller has one correct edit funnel (record undo, mutate, mark dirty, redraw)
and `_LayoutProperties` bypassed it for Name, Canvas presets, Background and Brightness,
calling `controller.refresh()` — render and notify only. Those four could not be undone, and
the app did not consider them unsaved.

**Fixed:** a `updateDocument()` funnel on the controller, used by all four fields.

**Known gap (not fixed):** the brightness slider still records one undo entry per tick, which
is the existing convention for every slider in the inspector, including widget properties.
Coalescing slider drags into one undo step is a separate improvement.

### H6 — `Duplicate` threw on a widget as wide as the panel **(V)** · Done 2026-09-14 · Effort: XS

**Was:**

```dart
(r.left + 2).clamp(0.0, (width - r.width).toDouble())
```

A widget at least as wide as the panel is explicitly allowed — the drag clamp deliberately
leaves size alone, and the grow commands have no upper bound. Duplicate then asked "keep the
copy between 0 and panel-width-minus-widget-width", a backwards range, and the language
refused; the copy was not made and the undo entry had already been recorded.

**Fixed:** the offset clamps into a range that cannot be empty (the copy lands on the
original when there is no room, and the next drag separates them).

### H7 — Discovery found one mirror and then jammed the button **(V)** · Done 2026-09-14 · Effort: XS

**Was:** the search and the per-device status check shared one "still current?" counter.
Finding the first mirror triggered a status check, which bumped that counter and made the
search think it had been cancelled — so only one mirror was ever listed, and the Browse button
stayed in its searching state.

**Fixed:** a separate counter for the discovery stream, so status refreshes cannot cancel it.

### H9 — The preview library went stale after a header change **(V)** · Done 2026-09-14 · Effort: XS

**Was:** `core/Makefile.host`'s `-include` list omitted `$(CORE_PIC:.o=.d)`. Change a header
and the build reported success but left the library the designer loads untouched — the exact
failure the comment three lines above described.

**Fixed and verified:** `touch core/include/mirror/layout.h && make -f Makefile.host` now
recompiles the PIC objects and relinks the library, and a second run rebuilds nothing.

### M10 — Designer engine robustness (6 sub-items) **(V for the first, R for the rest)** · Effort: S

| Where | Defect | In plain terms | Status |
|---|---|---|---|
| `test/resolved_font_test.dart:111` | Pinned values that predate a change, while sibling tests assert the new ones | The tests failed if they ever ran — and they were skipping (see I6) | **Fixed 2026-09-14**: asserts agreement with the engine instead of pinned names and scales |
| `model/layout.dart:99` | The filtered widget list drops non-object entries while the accessors and the renderer index the raw list | One stray element and tapping a widget in the list selects — or deletes — a different one on the canvas | Open |
| `controller.dart:314` | Reordering tracks the selection only when it is the moved widget | Drag a widget past another selected one and the inspector jumps to the neighbour | Open |
| `controller.dart:480` | The redraw path resumes after the controller is disposed | Redraws after closing the document notify a dead object and dispose the same image twice | Open |
| `services/layout_repository.dart:105` | Opening a file lets the read error escape, and treats a real read failure as "no plugin" | A failed open silently reopens the file picker instead of saying what went wrong | Open |
| `services/mirror_location.dart:114` | The comment promises a two-numbers-separated-by-a-space form the parser rejects | Pasting `51.5074 -0.1278` searches for a place with that name instead of using the coordinates | Open |

**Done when.** Each open row has a unit test that fails before the change and passes after.

### M11 — Designer UI lifecycle and input defects (10 sub-items) **(R)** · Effort: M

`game_screen.dart:1036-1042`, `:492-497`, `:486-490`, `:243-251`, `color_field.dart:71-75`,
`datetime_field.dart:44-50`, `onboarding_screen.dart:271-273`, `place_pin_page.dart:34-38`,
`app.dart:166-172`, `:771-780`

- Touch coordinates are compared against panel half-sizes, so a letterboxed steering axis
  turns the wrong way.
- A per-frame image is never released, unlike the controller's.
- The game keeps stepping and decoding behind the "Game Over" screen.
- A slow game list leaves "Loading games…" forever with no message.
- An unvalidated colour code reaches the document and the device.
- The time picker opens at the current time and silently rewrites a stored countdown.
- Re-picking a WiFi network in the wizard leaves it un-pushed, because the "WiFi ok" flag
  goes stale. **Fixed 2026-09-14:** there is no flag left to go stale — a confirmed join
  advances by itself, a new draft or "Choose another network" clears the note, and the
  confirmed-join path is what the button does (`onboarding_wizard_test.dart` re-picks a second
  network after a rejected one and asserts the new credentials are pushed).
- The map controller is never released.
- Saving swallows errors, so a failed save looks like a successful one.
- The simple view commits text only on Enter, so typed text is dropped when focus moves.

**Done when.** Each row is fixed and the affected flow is exercised by hand; failures are
visible to the user rather than silent.

### M13 — Render-core edge cases (5 sub-items) **(V for the mechanism, R for the rest)** · Effort: S

| Where | Defect | In plain terms | Status |
|---|---|---|---|
| `core/ffi/mirror_ffi.c:173-177` | The designer's "what did I click?" test skipped only hidden widgets, while the renderer also skips unknown types | A mistyped widget drew nothing but still swallowed clicks | **Fixed 2026-09-14** |
| `core/host/mirror_cli.c:111-113` | The brightness flag was cast, not validated | `-b 256` became 0: asking for maximum brightness gave a black picture | **Fixed 2026-09-14** |
| `core/src/mock.c:113-115` | The evening sample set 22:07 on the clock but left the machine-readable "now" at 09:41 | The preview's clock and countdown disagreed by twelve and a half hours in one frame | **Fixed 2026-09-14** |
| `core/src/render.c:1119-1121` | "All done" was shown whenever no row was drawn, including "the box is too small for even one row" | A 2-pixel-tall todo box announced that the owner's list was finished | **Fixed 2026-09-14**: the claim now comes from the data |
| `core/src/render.c` weather block | Clipped rows measure width from the box rather than the pen | A right-aligned ellipsis can land outside the box | Open — needs a golden frame (I5) first |

---

## Tier 3 — latent, hardening, or needs a decision

### M1 — Long values are quietly chopped and reported as success **(V + R)** · Effort: S · Depends on: I4

`core/src/json.c:322,360` — the string reader copies what fits and returns "fine" either way.
Three verified consequences:

| Site | Effect |
|---|---|
| `firmware/main/config.c:625-629` (`char unit[2]`) | `{"temp_unit":"FF"}` is accepted as `"F"` |
| `firmware/main/config.c:512-521`, `:547`, `:588` | The length checks for device name, timezone and place are unreachable — the buffers equal the limits, so an over-long value is truncated and accepted. A 70-character timezone string is cut at 63, still passes the "looks like a timezone" test, and is saved with its daylight-saving rules chopped off |
| `core/src/layout_json.c` (`text`, `format`, `bind`, `font`, `icon_set`) | A label longer than 23 characters renders cut, with no diagnostic, and a round trip through the device saves the cut version |

**Fix.** A string reader that reports whether the value fitted; give the config buffers one
byte of headroom over each limit so the existing checks fire; warn through the diagnostic
channel when a layout field is cut.

**Done when.** `{"temp_unit":"FF"}` is rejected with a message; a 30-character name and a
70-character timezone are rejected rather than truncated; an over-long label produces a
diagnostic.

### M2 — Numbers from the network were unchecked (reproduced undefined behaviour) **(V)** · Done 2026-09-14 · Effort: S

**Was:** row spacing was not checked at all and the row cap was checked only from below,
while the scale in the same function was checked both ways. The row-pitch calculation then
overflowed. Reproduced exactly:

```
$ gcc -ftrapv … && gdb -batch -ex run -ex bt
Program received signal SIGABRT
#3 __mulvsi3 ()
#4 choose_list_font (w=…, scale_out=…) at src/render.c:401
#5 draw_agenda_w (w=…, m=…, c=…) at src/render.c:1024
```

Input was `{"line_gap":2147483647}`, accepted with no diagnostic. The visible result was
nearly normal, which is what made it unpleasant — it surfaces later as "the mirror randomly
reboots" rather than as a layout problem.

**Fixed.** The parser clamps `line_gap` and `max_items` to the ranges the designer declares
(`ML_MAX_LINE_GAP`, `ML_MAX_ITEMS`), the countdown deadline to a sane epoch window, and the
integer reader range-checks before converting. The renderer clamps the same two fields again
via `row_gap()`/`list_rows()`, so a widget built by any path that bypasses the parser is safe
too.

**Verified.** A new `hostile layout` test group covers each bound; the `-ftrapv`
reproduction above now exits cleanly; the existing render fixtures are byte-identical.

### M3 — Rectangles wrapped instead of being clamped **(R)** · Done 2026-09-14 · Effort: XS

**Was:** rectangle values were narrowed to 16-bit integers with no range check, so a huge
value wrapped back *inside* the panel: `[131072,0,65537,10]` became a 1-pixel sliver at the
origin, past both sanity checks, with no warning — while `[65536,…]` wrapped to zero and was
rejected with the misleading message "rect has zero area". The layout header promises
out-of-range rectangles are a warning, and the scale field two hundred lines below was already
clamped rather than rejected.

**Fixed:** components are clamped before narrowing, in both the array and object forms.

### M4 — Bluetooth state: unbounded reply, unlocked reads, 32 KB on request **(R)** · Effort: S · Depends on: I4

`firmware/main/net/ble.c:272`, `:184/755`, `:175-180`, `:1021/1031`

- The `config {...}` reply is built with no size limit; a long name plus long timezone plus
  long place overflows it and permanently breaks the "read back my settings" command for that
  stored config. The game commands already check their room — apply the same.
- The last status message is written under a lock but read without it, and the connection
  handle is read unlocked while the Bluetooth stack recycles it on reconnect — so a status
  reply can be delivered to the *next* phone that connects.
- A 32 KB buffer is allocated on request regardless of the declared size, on an
  unauthenticated command.
- The lock is used without a null check and the worker-task creation result is ignored; after
  either failure every upload answers "busy" forever.

### M5b — The WiFi password is stored in plain text in flash **(R)** · Effort: S · Needs decision 3

`firmware/sdkconfig:2430` (`# CONFIG_NVS_ENCRYPTION is not set`; `sdkconfig.defaults` does not
mention it), and `firmware/partitions.csv` has no `nvs_keys` partition — so a flash dump yields
the home PSK. Enabling NVS encryption needs a partition-table change
(`nvs_keys, data, nvs_keys, , 0x1000, encrypted` + `CONFIG_NVS_ENCRYPTION=y` +
`nvs_flash_secure_init`), which is a one-time USB reflash for a mirror already in a wall;
decide between that cost and documenting the exposure in `docs/hardware.md`.

### M6 — Update erased the whole program area for a known-size image **(V)** · Effort: XS · Depends on: B2

`firmware/main/net/ota.c:54`, `:113-142`. The size is known before the erase starts, but the
whole 4 MB area is cleared anyway, which is the difference between a brief pause and a
multi-second stall — repeatable by any peer while B2 is open. Pass the known size instead.

### M7 — Stored settings are trusted on load **(R)** · Effort: XS

`firmware/main/config.c:280`, `:288`, `:337`. The timezone is copied out of flash without the
validation the push path applies. Older software accepted `Europe/Berlin`-style names that the
clock library silently ignores, leaving the mirror on UTC — and a mirror updated over the air
keeps that value forever, showing a confidently wrong clock while the log claims the zone was
applied. Brightness has the same gap and is later narrowed to a byte. Validate on load and
reseed from the build defaults when a stored value fails.

### M8 — A failed start still cancelled the update rollback **(R)** · Done 2026-09-14 · Effort: XS

**Was:** `firmware/main/main.c` discarded the result of starting the render task and called
`ota_mark_valid()` a few lines later regardless. If memory was too tight to start the task,
the mirror marked a broken image as good and rebooted into it forever — the rollback safety
net disabled by the very condition it exists for.

**Fixed:** the render task marks the image valid after its first frame reaches the panel, so
the predicate is "this image boots and draws", not "a line of app_main was reached".

### M9 — The MBI5124 driver option cannot work **(R)** · Effort: XS · Needs decision 4

`firmware/main/panel.cpp:44` with `firmware/main/Kconfig.projbuild:216`: the driver can be
selected but its clock-phase setting is never applied, so the option is a trap. Set it or
remove the choice.

### M12 — Gamekit runtime and host-harness defects **(R)** · Effort: M

| Where | Defect |
|---|---|
| `runtime.c:288` | Snapshots are refused above 1020 bytes while the buffer allows 1024 and the largest game produces 1018 — three more bytes and every snapshot silently stops working |
| `runtime.c:378` | The in-game event type is generated but nothing consumes it — no handler, no default, no callback |
| `runtime.c:264` | Controller input carries an unvalidated player and control code, and the sequence number documented as the replay guard is never read |
| `host/game_cli.c:311` | `--replay` compares nothing (the journal carries no hash) and silently truncates past 4096 events |
| `host/game_cli.c:226` | `--peer` always runs the rally game, so a replay of any other game renders rally into a file named for the other game |
| `ffi/game_ffi.h:50` | Only control labels are exposed — no codes, types or axes — so the designer's simulation cannot drive the tilt controls the probe game declares. **Partly fixed 2026-09-17:** `ml_game_control_type` exposes each control's declared type and `ml_game_input` resolves it (replacing `ml_game_button`, which hardcoded BUTTON), so the app's own simulation now drives the tilt axes and no longer guesses them from labels. Control *codes* are still not exposed: the app assumes code == catalogue index, which every shipped game satisfies and which the Bluetooth frame's writer assumes too |
| `gamenet.h:30` | The handshake messages are declared but never sent, and a peer's random seed is zero — a fixed point of the generator |

### M14 — The first weather fetch after a boot can fail its TLS handshake **(V)** · Effort: S

Observed on the UART console of the board at `192.168.0.165`, on the boot after an OTA —
where the fetch is triggered the moment the link comes up, seconds after the BLE stack and
httpd have claimed their banks:

```
I (3604) provider: link is back, refreshing everything now
E (3729) esp-aes: Failed to allocate memory
E (3730) esp-tls-mbedtls: mbedtls_ctr_drbg_seed returned -0x0001
E (3732) esp-tls: create_ssl_handle failed
E (3737) transport_base: Failed to open a new connection
W (3748) http: connect failed: ESP_ERR_HTTP_CONNECT
W (3758) provider: weather: failed (ESP_ERR_HTTP_CONNECT), attempt 1, retry in 900s
```

The same firmware fetched fine on the previous boot (`openmeteo: 16.2C (feels 14.4) ... updated
in 1555ms`), so this is an allocation race, not a configuration error — and the cost is
fifteen minutes of `weather stale` on the panel, on the boot the owner is most likely to be
watching (right after an update). The 30 s status line kept reporting `weather stale` for at
least ten minutes afterwards.

**Fix (candidate):** fail fast and retry in seconds rather than the provider's 900 s cadence,
and/or take the TLS buffers (AES context, CTR_DRBG) from a reserved pool at init, the way the
panel already claims its DMA block before WiFi fragments the heap.

**Done when.** A fresh boot's first fetch either succeeds or retries within ~10 s, with the
allocation failure logged once.

### L1–L15 — Assorted LOW items

Unknown widget types are rewritten as `"unknown"` on a device round trip, so a newer layout
pushed through older firmware loses its type names (R). Twelve parser failure paths and five
of ten stock layouts are unasserted (R). The app's tri-state smoothing control is dead code,
so a supported engine feature cannot be set from the UI, and the "Auto font" switch its README
documents is deliberately absent from the schema (R). The app's declared SDK floors are below
what its lock file resolves (R). Gamekit: a null lookup dereference, a per-frame allocation in
the FFI render path, a dead library variable and missing dependency includes in its Makefile, a
connection slot never reclaimed, a "stretch" fit mode that does not stretch, a flag that
prints nothing, and a comment that says five games where six are listed (R). Firmware: no cap
on response headers and no overall request deadline in the HTTP client, a busy-wait when
stopping the server that can leave the setup page permanently broken, a failed flash-writer
startup that blocks its callers forever, and a failed setup-page start that is never retried
(R). See the area reports for the individual citations (they were produced during the scan and
are not committed).

---

## Tier 4 — test and CI infrastructure

Do this tier before working broadly on Tier 3: it is what turns "read carefully and hope" into
"run it".

| ID | Item | Effort | Detail |
|---|---|---|---|
| I1 | CI pipeline | S | A workflow that runs the core checks on the host, builds the firmware in the ESP-IDF container, and runs `flutter analyze` + `flutter test`. Nothing runs today: `make -C core -f Makefile.host check` (578 checks + fontcheck + bindcheck) exists and passes, and no push ever runs it |
| I2 | Sanitizer targets | S | `make -C core -f Makefile.host test-asan` / `test-ubsan`, documented with the note that this machine lacks the UBSan runtime (`ld: cannot find /usr/lib64/libubsan.so.1.0.0`; `-ftrapv` works). M2 was found in minutes with `-ftrapv` and would have been caught by this |
| I3 | Fuzz the parsers | M | A host-only libFuzzer target over the layout parser, the JSON reader and the config-apply path, seeded with `layouts/*.json`. These take input from the network and have no fuzz coverage at all |
| I4 | Host test rig for firmware logic | L | Compile the setting-apply, Bluetooth command, DNS-responder and weather-parsing modules against small stubs so they can be tested on a PC. **No firmware logic is host-runnable today**, which is why every Tier 1–3 firmware item was found by reading rather than running. Add a test for B1's bound here |
| I5 | Golden frames for the untested widgets | S | Digests cover five layouts × four samples (20 frames) and include no `weather`, `date`, `line` or `todo` widget — exactly where M13's remaining defect lives |
| I6 | Stop the skipped tests hiding | S | 36 designer tests skip when the preview library is absent, and two of them were failing unseen. **Cheap interim fix, used by the first batch:** `cp core/build/host/libmirrorcore.so /tmp/ffilib/libmirror_core_ffi.so` then `LD_LIBRARY_PATH=/tmp/ffilib flutter test` — the suite then runs 238 tests with nothing skipped. Proper fix: build the plugin in CI and fail on a skip |
| I7 | Gamma table check | XS | `tools/gen_gamma.py` has no `--check` mode, unlike the font generator, so a hand-edited table cannot be detected. Add one and wire it into `make check` |

---

## Tier 5 — functionality

Ranked by value per unit of new code; all grounded in what already exists.

### F1 — Calendar and todos: the biggest functional hole · Effort: L · Depends on: I4

The agenda and todo widgets are fully implemented in the renderer, the model carries twelve
events and twelve todos, and the bindings exist — but **nothing on the device ever fills
them**. A search for event and todo counts across the firmware finds only a comment saying
they "arrive in M3". Every mirror today shows "No events" forever.

The README already names the route: let the server expand recurrences. One new provider
covers both:

- Fetch a single URL (calendar feed or JSON) every 15 minutes with the existing backoff;
  read events (start, summary, all-day) and tasks (due date, summary, completed), map them
  into the model's events and todos with the existing validity and day-offset fields, and
  **never expand repeat rules** — the server does that (`singleEvents=true` on Google, or a
  time-window query against a self-hosted feed). Repeated-line unfolding and text unescaping
  is roughly 150 lines.
- Config: one new saved setting for the feed URL, pushed over Bluetooth exactly like the
  timezone and place, with an app settings field beside them.
- The renderer needs no change.

**Done when.** A mirror pointed at a real calendar feed shows today's agenda rows on the
panel, and a completed task disappears when "hide done" is on.

### F2 — Sunrise/sunset and an hourly temperature series · Effort: M

The weather request already asks for today's high, low and rain chance plus twelve hours of
rain probability. Adding sunrise, sunset and the hourly temperature is a parameter change
plus model fields, binding paths and either new bindings for existing widgets or a general
"plot" widget the rain chart already demonstrates end to end. Value: a morning/evening layout
that is currently impossible, and a temperature trend.

### F3 — Night dimming schedule · Effort: M

Brightness is either the layout's value or a manual override. A schedule (start, end, level)
applied in the single function that already computes the effective brightness needs no
renderer change, plus the saved settings, the Bluetooth field and an app control. Value: the
reason people turn these mirrors off at night.

### F4 — Panel sizes beyond 64x32 · Effort: L · Needs decision 5

The panel geometry is already derived from build configuration (width, height, panel count,
row count, five driver options are all exposed), and the app already filters presets by the
panel size it learns from the device. So the remaining work is layouts, presets and docs —
not plumbing. The README's claim that larger panels ship as size-suffixed presets is false
today (ten files, all 64x32) while the hardware notes correctly say the presets were removed.
Taller panels also need the extra address line their scan mode requires, which is a hardware
and build-config question.

### F5 — Gamekit protocol completion · Effort: M · Depends on: M12

Fix the tier-1 game items first; then the features the code already declares: send the
handshake messages and seed the peer's generator from them (it is currently zero, a fixed
point), validate the player and control codes on input and use the sequence number as the
replay guard it is documented to be, hash the journal so `--replay` is a real check, and
expose control codes, types and axes so the app can drive the tilt game (types
and axis delivery landed 2026-09-17; see M12).

### F6 — Designer UX · Effort: M · Depends on: H4, H5

Coalesced undo for slider drags, a real smoothing control, text that commits when focus moves,
and save errors the user can see. (The unsaved-changes guard landed with H4.)

---

## Tier 6 — documentation and housekeeping

### D1–D15 — Documentation corrections

Every row was checked against the code during the scan.

| Claim | Reality | Correction |
|---|---|---|
| `README.md:65` "208 checks" | The suite prints **578 checks** today (**V**) | State 578, or point at the printed count |
| `README.md:25`, `core/Makefile.host:64` "PySide6 designer" | The designer is Flutter over the C library (**V**) | Fix both; the diagram's library name is also out of date |
| `README.md:406` "golden tests hash the exact bytes the panel would receive" / "three layouts" | **Done 2026-09-14**: five layouts, hashed at the layout brightness, with the device's full-scale form described separately | — |
| `README.md:370` "larger panels ship as size-suffixed presets" | Ten files, all 64x32; the hardware notes say the presets were removed | Delete the claim |
| `README.md:30-31` "A test diffs the device's real framebuffer against a host render" | No such test exists; the real guard is the library-versus-direct equality check. `--dump` now writes the right bytes (H8), so this is closer to true than it was | Reword to describe the equality check |
| `README.md:122-123` rain-probability list as a binding | Not a bindable path; the rain chart reads it directly | Say so |
| `README.md:75-83` flag table | Omits `-o` and `-b`, and the `--dump` row should mention full scale | Add |
| `README.md:370-374` repository layout | Omits the gamekit directory | Add |
| `designer/README.md:222-226` font families | The picker only offers the two display families every stock layout uses | Rewrite |
| `designer/README.md:257-263` "Auto font" switch | Deliberately absent from the schema | Remove or explain |
| `docs/games.md:13-14, 311-313, 385-388` "firmware integration is a later phase" | Shipped: the games are compiled into the firmware and reachable over Bluetooth | Rewrite as shipped |
| `docs/games.md:351` `--check <hash>` | The flag is `--hash` | Fix |
| `docs/games.md:329, :127` `gamekit/src/shapes.c`, `ml_rand_seed` | Do not exist | Fix |
| `docs/ble_control_and_ota_plan.md` ("Audience: the agent implementing this") | Everything in it has shipped | Mark as delivered, keep as history |
| `firmware/main/main.c:5` "Weather, calendar and todos arrive in M3" | Calendar and todos never arrived | Correct, or update when F1 lands |

### D18 — The bundled image and the version drifted apart **(V)** · Done 2026-09-14 · Effort: XS

**Was:** the tree carried two different builds of `0.2.23` — the staged one
(`designer/assets/firmware/smart_mirror.bin`, 1305568 bytes, app descriptor built 13:39) and
`firmware/build/smart_mirror.bin` (1306144 bytes, built 20:21 from the sources, including the
firmware fixes in `5d362e5`). `5d362e5` changed `firmware/main/**` without bumping
`project(smart_mirror VERSION ...)` or re-staging, so the rule at the top of
`firmware/CMakeLists.txt` ("bump this version on every firmware change ... two builds that
share a version are indistinguishable on the board and over OTA") was broken by exactly one
commit. `firmware/README.md` promises the opposite: "a stale bundle is therefore not
possible". The APK built at 21:28 carries the newer build (its asset hashes to `7dab2d2e…`,
the build directory's image), so the bundled copy and the staged copy disagreed at the same
version — an update could not be shown to have happened.

**Fixed:** version bumped to `0.2.24` and `tools/bundle_firmware.sh` re-run, so the staged
image is byte-identical to the sources' build and the next update is verifiable: the app's
"Install v0.2.24" and the mirror's `/api/status` now have to agree.

### D17 — Housekeeping · Partly done 2026-09-14 · Effort: XS

Done: the empty `designer/mirror_designer/` directory is gone, and two unused FFI typedefs
plus one no-op assertion were removed — `dart analyze` is down from 13 issues to 10.

Remaining: ten `library_private_types_in_public_api` infos in
`designer/lib/src/engine/game_bindings.dart`, where the public API returns private typedef
types. Fixing them means renaming types in the FFI facade, which is a slightly riskier change
than the rest of this tier. Once Tier 1–2 land, also revisit the README's milestone table: M4
is more true than it was now that B3 is fixed, but the LAN push is still unauthenticated.

---

## Decisions this backlog is waiting on

1. **LAN access model** — device token over Bluetooth (B2 as written) versus leaving the API
   open and documenting the risk. Everything in Tier 5 assumes authenticated-but-unencrypted
   LAN access is acceptable. Gates: B2, M6, and any desktop-only workflow.
2. **Calendar and todo source** — Google's expanded feed, a self-hosted calendar feed, or
   both. Decides whether F1 needs a setting per provider.
3. **WiFi credentials in flash** — accept the one-time USB reflash that NVS encryption needs,
   or document the exposure. Gates: M5b.
4. **Gamekit's role** — ship as a novelty or invest in the network game. The breakout and
   memory items are worth fixing either way; the handshake and journal work only matters if
   two-player is real. Gates: M9, M12, F5.
5. **Panel sizes** — stay 64x32-only (then delete the README claim and close F4), or support
   64x64 / 128x64 (then F4 becomes a layouts-and-docs task).

## Explicit non-goals

- Rewriting the renderer or the designer's engine boundary. The one-renderer design holds up:
  the scan found no memory-safety defect in the render core (every canvas write is clipped and
  bounds-checked), and the gamma table is reported byte-exact against its generator (R —
  unverified, because there is no check mode; see I7).
- Replacing the layout JSON schema, the font pipeline, or the model struct as the seam.
- Any authentication infrastructure beyond the device token (no cloud account, no companion
  service), consistent with the existing no-key, no-helper design.
- A machine-that-is-always-on for calendar. The feed approach keeps the mirror standalone.
