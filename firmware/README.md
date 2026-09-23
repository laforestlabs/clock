# Firmware

ESP32-S3 application. Drives the HUB75 panel, joins WiFi, syncs the clock, and
renders the layout.

The render core is not vendored here. `components/mirror_core` is a symlink to
the repository's `core/`, so the firmware and the desktop designer compile
literally the same source files. That is what makes the designer's preview
worth trusting.

## Versioning

**Rule: bump the firmware version on every firmware change.** The version is
`project(smart_mirror VERSION x.y.z)` in `firmware/CMakeLists.txt`; it is baked
into the image and reported by `/api/status` and the BLE `pong`. Every change
under `firmware/` gets a new version. Never reuse a version for a different
build, and never flash or ship two builds under one version: a reused version
makes it impossible to tell what is actually running on the board or over OTA.

That is enforced, not merely stated. `tools/firmware_version.py` records the
sources the image is compiled from - `firmware/`, `core/`, `gamekit/`, `fonts/`
and `layouts/`, since the games and the render core are built into the image
rather than linked from somewhere else - in `firmware/version.lock`, against
the version they were stamped for:

```sh
tools/firmware_version.py check            # the tree against the record
tools/firmware_version.py check --staged   # ...and the image the app bundles
tools/firmware_version.py stamp            # record the sources as this version
```

Three places run `check`, so a change that forgot the bump cannot reach a
board: the firmware's own configure step (no `idf.py build` starts on a stale
stamp), `tools/bundle_firmware.sh` (every Android build stage through it, and
it checks the staged image is the version the tree declares), and
`designer/test/bundled_firmware_test.dart` for the copy the app ships.

So any change the image is built from is three steps:

1. Bump `project(smart_mirror VERSION ...)` in `firmware/CMakeLists.txt`.
2. `tools/firmware_version.py stamp`.
3. Build. The app's firmware bundle and the OTA image restage themselves.

The record is one hash of the sources, so it also answers what a version *was*:
given an image's version, `git log firmware/version.lock` says which sources
were stamped for it.

## ESP-IDF version

**ESP-IDF 5.4 or newer is required.** Not a preference: `esp-hub75` will not
compile on 5.0 through 5.3.

Its GDMA setup sets `isr_cache_safe` and `eof_till_data_popped` behind a
`#if ESP_IDF_VERSION >= 5.0.0` guard, commented "ESP-IDF 5.0 - 5.3". Both
fields were actually introduced in 5.4, so that branch fails to compile. The
project's CI matrix covers 4.4.8, 5.5.2 and 6.0 and skips the whole 5.0 to 5.3
range, which is why it has gone unnoticed upstream.

This project uses 5.5.2, the version upstream tests.

```sh
. $HOME/esp/esp-idf-v5.5/export.sh
```

## Build

```sh
. $HOME/esp/esp-idf-v5.5/export.sh
idf.py -C firmware set-target esp32s3
idf.py -C firmware menuconfig      # Smart Mirror menu: setup portal, timezone, panel
idf.py -C firmware flash monitor
```

This board's USB-C routes through its onboard CH343 to UART0, so flashing and
the serial console need no external adapter. `sdkconfig` is
gitignored and generated from `sdkconfig.defaults`; the defaults are the
source of truth, and after changing one, delete the local `sdkconfig` so it
regenerates. Nothing in it holds anything private: only choices like the
timezone and the shift-register driver.

Everything in the `Smart Mirror` menuconfig section has a working default.
WiFi credentials are deliberately not there: the owner enters them through
the setup portal and they are stored in NVS, so nothing about a home network
ever ends up in the repository. See "WiFi setup" below.

## WiFi setup

There are no WiFi credentials in the firmware. On first boot the mirror
creates its own access point, `Smart Mirror Setup-XXXX` (the suffix is the
last four hex digits of its MAC), and serves a setup page at
`http://192.168.4.1`. Connect your phone to that network and the
captive-portal redirect should open the page by itself. Enter your home WiFi
details; the mirror saves them to NVS and joins.

What happens when the saved network stops working:

| Situation | What happens |
|---|---|
| Nothing saved yet | Setup access point from the first boot |
| Wrong password or SSID | The portal opens as soon as the failure reason is known |
| Network unreachable at boot | The mirror tries for `MIRROR_CONNECT_TIMEOUT_S` (default 30 s), then opens the portal |
| Network comes back while the portal is open | Nothing happens until the owner submits credentials; the station stays idle so the portal's scans stay clean |
| Network drops after a successful join | The mirror retries in the background with backoff; the portal does not reopen. Power-cycle the mirror to force re-provisioning |

The page also offers "Forget saved network", for handing the device over or
moving house.

Points worth knowing before shipping this:

- The station connects with **WPA2-PSK only**. WPA3 SAE is disabled in
  `sdkconfig.defaults`: the driver's SAE negotiation is flaky against
  WPA2/WPA3 transition-mode routers, so transition networks connect over
  their WPA2 half and WPA3-only networks are unsupported.
- The scan tells the owner three things about each network: open, needs a
  password, or **unsupported** (enterprise/802.1X, WPA3-only). The open verdict
  is only believed when the driver reports no cipher at all: ESP-IDF reports
  enterprise APs that mandate PMF as `WIFI_AUTH_OPEN` while still naming CCMP
  ciphers ([IDFGH-9885](https://github.com/espressif/esp-idf/issues/11202)),
  which is what made a password-protected network show no password box. A
  verdict is also a *hint*, never a lock: the portal and the app always accept a
  password, because the only thing that really knows a network's password policy
  is the connect attempt.
- The setup access point is **open by default** (`MIRROR_AP_PASSWORD` empty)
  and the portal is plain HTTP. For a deployed product, set a WPA2 password
  in menuconfig and print it on the device: on an open setup network, anyone
  within radio range could open the page and claim the mirror.
- Credentials sit in NVS in plaintext. That is a property of the platform:
  the ESP32 has no secure key storage without extra hardware, and this is the
  same trade every consumer IoT device at this price point makes.

## Bring-up, in order

Do these in sequence. Each one isolates a different failure, and skipping ahead
turns a five-minute problem into an afternoon.

### 1. Power before anything else

The default single **P2.5-64x32** draws roughly **2A at 5V** worst case, so a 5V
4A supply is comfortable. A 64x64 panel is rated 4A each, and two of them is 8A
worst case, needing a 5V 10A supply. Inject power into each panel's own VH4
socket. Do not daisy-chain power through the HUB75 ribbon, and do not power
panels from the dev board.

### 2. Shift driver

The single most likely bring-up surprise. Waveshare ships these panels with
either an **ICN2038S**, which needs no setup, or an **FM6126A**, which needs an
initialisation sequence and stays completely dark without it. Which one is in
your box is not documented per unit.

If the panel is dark or shows garbage, change
`Smart Mirror > Panel > Shift register driver IC` and reflash before suspecting
your wiring. `GENERIC` covers ICN2038S and most panels; try `FM6126A` next.

### 3. Clock

Once WiFi joins and SNTP replies, the clock changes from `--:--` to the real
time. The log says so:

```
I (5123) time: clock synced: 2026-07-29 14:03:11 BST
I (5124) mirror: clock is valid, the panel now shows the real time
```

Before that the panel deliberately shows placeholders rather than 1970 or a
confident zero. That is the same "cold" state the designer previews, so it is
worth checking it looks acceptable.

SNTP is not the only way in. A network that blocks UDP 123 but allows HTTP still
gets a clock: the first weather fetch reads the `Date` header off the response
and sets it, and the same log line appears. See "Data providers" for why that
one request is cleartext.

## Pins

Defaults are in menuconfig and match `docs/hardware.md`.

| Signal | GPIO | Signal | GPIO |
|---|---|---|---|
| R1 | 4 | A | 17 |
| G1 | 5 | B | 18 |
| B1 | 6 | C | 8 |
| R2 | 7 | D | 9 |
| G2 | 15 | E | 10 (64-row panels only) |
| B2 | 16 | LAT | 11 |
| | | OE | 12 |
| | | CLK | 13 |

The default 64x32 panel is 1/16 scan and does not use E, so `MIRROR_PIN_E` is
`-1` and GPIO10 stays free. Set it to 10 when moving to a 64-row panel, which is
1/32 scan and shows only half its rows, doubled, without it.

**Do not use GPIO 33 to 37.** On an N16R8 they belong to the octal PSRAM. The
pinout in the `esp-hub75` README uses 35, 36 and 37 and will give you a dead
panel or a board that does not boot.

Also avoid GPIO 0, 3, 45 and 46 (strapping), 26 to 32 (flash), and 43/44 (the
console).

## Design notes

**Gamma is applied exactly once.** The core applies a CIE 1931 curve, and the
golden-image tests assert the exact bytes that produces. `esp-hub75` defaults
to applying its own CIE 1931 curve on top, which would double-correct and come
out far too dark, so `sdkconfig.defaults` sets `CONFIG_HUB75_GAMMA_LINEAR=y`.
Keep it that way: one implementation, and the device-versus-host framebuffer
diff in M4 stays meaningful.

**Brightness is done in hardware.** Frames are blitted at full scale and the
driver dims by shortening LED on-time. Scaling colour values instead would
work, but it throws away colour depth, and at the settings a mirror behind
two-way glass actually runs at there is very little to lose. The phone can
set a manual override over Bluetooth; it lives in NVS, so it survives reboots
and layout pushes until it is cleared ("set brightness auto").

**Orientation is a panel transform, not a layout edit.** An upside-down mount is
compensated in `panel_blit_rgb888`, which rotates the frame 180 degrees in place
as the last step before the shift registers, alongside the crossed green/blue
correction. Doing it in the render core would change the bytes the host golden
tests hash, and editing the layout's coordinates would throw away the layout the
owner authored. It is a config field (`flip180`), pushed by the phone and read
back by it, and it applies to every frame — layouts and games alike.

**The panel is initialised before WiFi.** It needs the largest contiguous block
of DMA-capable internal SRAM in the system, and asking for it before the WiFi
stack has fragmented the heap is the difference between working and a confusing
allocation failure.

**Nothing in the render path touches the network.** The render task reads a
snapshot of the model and draws it, so a DNS timeout or a router reboot cannot
stall or tear the display. Worst case the mirror shows stale data.

## Memory and storage

The DMA buffer must live in internal SRAM. PSRAM-backed HUB75 buffers cap the
shift clock near 13MHz and flicker visibly. The canvas and frame buffers do go
in PSRAM, since only the CPU reads them, which keeps internal SRAM free for
DMA.

**Internal SRAM is the scarce pool, and the device reports it.** One line at
boot, and the same figures on the 30-second status line, so the pool can be
watched without a debugger:

```
I (1621) mirror: memory: internal free 28607 (largest 20480), DMA-capable largest 20480, PSRAM free 8301436
I (1631) mirror: nvs: 190 of 756 entries used (4 namespaces)
I (1280) layout: storage: 10793 of 956561 bytes used (1%)
I (30726) mirror: up 30s, wifi up (192.168.0.137, -30 dBm), clock set, weather ok; internal free 28743 (largest 18432), PSRAM free 8291244
```

That first number is the one to watch, and the reason it is logged. The panel's
DMA buffers and descriptor chains, the WiFi driver's static RX/TX buffers and
the BT controller's per-activity state are all internal and cannot move to
PSRAM, while the weather fetch's TLS handshake needs a couple of KB of
contiguous DMA-capable internal RAM mid-handshake — the hardware AES path
bounces PSRAM record buffers through an internal staging buffer
(`esp_aes_dma_core.c`, two buffers of up to 1600 bytes). When the pool runs dry
the handshake fails, and from the provider's side that is indistinguishable from
the network being down.

Measured budget with the shipped `sdkconfig.defaults` (2026-09-19, board on
USB, `0.2.30`):

| Pool | Total | Free | Used |
|---|---|---|---|
| Internal SRAM heap | 237 KB at boot | **28.6 KB**, 18–20 KB of it contiguous | 208 KB — panel 94 KB, WiFi 54 KB, BT/httpd/mDNS/providers 47 KB, app 12 KB |
| PSRAM | 8.0 MB | **7.9 MB (99%)** | 87–98 KB — canvas+frame 12 KB, TLS and LWIP buffers, transient layout/JSON blocks |
| App slot | 4 MB × 2 | **2.88 MB free per slot (69%)** | 1.31 MB image |
| SPIFFS (`storage`) | 956 KB | **946 KB (99%)** | 10.8 KB — stored layout ~0.9 KB, network log ~9.9 KB, ceiling 33 KB |
| NVS (`nvs`) | 756 entries (24 KB) | **566 entries (75%)** | 190 entries — credentials, owner config, station hint, WiFi driver |
| Flash, unpartitioned | 16 MB total | **6.9 MB unallocated** | — |

These measurements predate picture display. It adds a resident picture and one
snapshot buffer in PSRAM (each roughly width × height × 3 bytes), transient upload
buffers, and two SPIFFS slots (each 16 bytes plus the RGB payload). Account for
those separately; the historical 33 KB storage ceiling does not include pictures.

Reading the numbers by pool: internal SRAM is the only pool that is *tight*, and
it is tight by design — the panel's DMA memory cannot be anywhere else, and the
two things that could be moved (mbedTLS buffers, NimBLE host allocations)
already are. A TLS handshake needs roughly 4 KB of contiguous internal RAM
(2 × 1600-byte staging buffers plus descriptors), so the current 18–20 KB block
is about five times what it needs. Connecting the phone over BLE does not move
the figure measurably (28,743 free before and after a live connection: the
controller's buffers are allocated at init, the host's in PSRAM).

The sizing decisions that keep it there are commented in `sdkconfig.defaults`
(WiFi RX/TX buffer counts, BLE activity count, mbedTLS buffers in PSRAM).
Reducing any of them again is safe on paper and not in practice: at the ESP-IDF
defaults this board landed at 5 KB free with a 1.6 KB largest block, and the
first weather fetch after a boot failed its TLS handshake about half the time —
the exact failure that made an OTA look like it had broken the weather. Roughly
14 KB of new *contiguous* internal demand is what the current margin absorbs
before that returns.

Flash, SPIFFS and NVS are nowhere near a limit: two app slots hold two copies of
a 1.31 MB image, the storage partition that holds the pushed layout and the
network log is at 1% of its 956 KB and stabilises below 4% once the log ring
fills, and 6.9 MB of the 16 MB flash is not even partitioned. If a future
feature needs space rather than RAM, it is there.

## Device identity, pictures and actual previews

`GET /api/status` retains the existing status fields and adds the station-MAC
`id` (12 lowercase hex digits), friendly `name`, `display_api`, effective `mode`,
saved `base_mode`, `picture_ready`, and `flip180`. BLE `get device` reports the
same identity and display state without changing `ping` or `get config`.
mDNS advertises `_smartmirror._tcp` at `smart-mirror-<id>.local`, with instance
`Smart Mirror <id>`; renaming does not change identity.

Clock and picture are persistent base displays. A BLE game temporarily overrides
them, including while paused, and Stop/disconnect restores the saved base.
Layout uploads never implicitly switch the base display.

| Request | Contract |
|---|---|
| `PUT /api/mode` | JSON `{"mode":"clock"}` or `{"mode":"picture"}`; picture without a valid saved image returns 409. |
| `POST /api/image` | `application/octet-stream`, explicit Content-Length, decimal `X-Mirror-Width` / `X-Mirror-Height`, exactly panel-width × panel-height × 3 pre-gamma RGB888 bytes. |
| `GET /api/frame` | `application/octet-stream`, `Cache-Control: no-store`; actual presented frame, or 503 if unavailable/busy. |

Mode/image success is acknowledged only after persistence, with JSON `ok`, `mode`,
`base_mode`, and `picture_ready`. Rejections use `{"ok":false,"error":"..."}`.
BLE mode changes use `begin display <len>` / commit with the same mode JSON.
Pictures and snapshots do not travel over BLE. These APIs inherit the trusted-LAN,
unauthenticated transport: do not expose them to the Internet.

Pictures are static raw RGB, not firmware-decoded JPEG/PNG. The maximum is 196608
bytes (256×256 RGB). Larger panels keep clock/games but do not advertise display
API support. Two CRC-checked SPIFFS slots and one committed NVS state byte retain
the previous picture on an incomplete replacement. Boot loads only the committed
slot; corrupt or dimension-mismatched data falls back to clock. Factory reset
clears both picture slots and display state.

Snapshots have a 16-byte `MRF1` header: little-endian u16 width/height at offsets
4/6, u32 frame sequence at 8, brightness at 12, mode at 13 (clock=0, games=1,
picture=2), flip180 at 14, reserved zero at 15. Exactly width × height × 3 RGB
bytes follow. Pixels include gamma, brightness scaling, and physical rotation,
but not electrical channel swapping. Clients render them as-is. Sequence resets
on reboot; it is not a device identity.

## OTA updates

The phone ships the firmware it needs: the app bundles the image, so the
normal update is "rebuild the app, then push the bundled firmware". No USB
cable and no manual file transfer. The bundled copy is
`designer/assets/firmware/smart_mirror.bin`, refreshed from the sources by
every Android build: a gradle task (`designer/tool/firmware_bundle.gradle`)
runs `tools/bundle_firmware.sh`, which incrementally rebuilds the firmware
before Flutter packs the assets into the APK. A stale bundle is therefore
not possible, and a machine without ESP-IDF fails the build loudly rather
than shipping an old image.

The update travels over the Bluetooth link the app already holds. Neither a
WiFi address nor the phone being on the mirror's network matters; the phone
and mirror only need to remain within Bluetooth range. The transfer takes tens
of seconds rather than WiFi's roughly three seconds.

1. Bump `project(smart_mirror VERSION x.y.z)` in `firmware/CMakeLists.txt`.
2. Rebuild and install the app explicitly (see `designer/README.md`); the APK
   bundles the current image.
3. Connect over Bluetooth, tap **Update to latest**, and confirm the update.
   The app streams the image, waits for validation, and reconnects after the
   mirror reboots.

If Bluetooth drops, the mirror keeps the bytes already written to flash and
the app resumes from that offset. A rejected image leaves the running app
untouched: the boot partition is switched only after `esp_ota_end` validates
the complete image. Rollback remains automatic for an image that crashes
before the new app marks itself valid.

WiFi remains the transport for layout/status/pictures and those picture uploads
still require the phone to reach the mirror on the LAN. A VPN can block that
local picture route; it does not affect OTA over Bluetooth.

## Data providers

Weather comes from **Open-Meteo**, fetched directly by the device over HTTPS.
No API key and no signup, which matters more than convenience: the mirror has no
weather credential to expire, leak, or re-provision.

The first fetch after a boot whose clock has not synced yet is the one
exception, and it is forced rather than chosen: there is no RTC, so the clock
starts at 1970, and certificate validation needs a plausible date, which means
an HTTPS request issued that early cannot complete. Waiting for SNTP instead
would mean waiting on UDP 123, the port guest networks most often block. So
while the clock is unknown the fetch goes out in plaintext, and `http_get` takes
the time from the response's `Date` header — the one clock source that cannot
itself require TLS. Every fetch after that is HTTPS with the certificate bundle
attached. The costs are honest ones: one cleartext request (coordinates
included) per boot until a clock exists, and a network that blocks UDP 123 and
plain HTTP both leaves the clock unset, and the clock widgets showing `--:--`,
until one of them answers.

Set your coordinates in `Smart Mirror > Weather`. The default is central
London, so it will show you plausible-looking weather for the wrong place if
you forget.

### Staleness is deliberate

Each provider declares a refresh interval and a grace period. After three
missed intervals its data is marked invalid and the widget falls back to a
placeholder.

That is on purpose. A mirror showing last Tuesday's temperature as though it
were current is worse than one showing `--`, because you cannot tell by looking
that it is wrong, and you dress for the wrong weather. Stale data has to
announce itself.

Failures that reach the service (rate limits, bad payloads, 5xx) back off
exponentially, capped at an hour. Failures where the connection never
established (WiFi down, DNS failure, connect/TLS timeout) retry at the normal
interval instead: they never reached the service, so there is nothing to be
polite to, and the healthy cadence catches recovery fastest. When the WiFi
association drops and returns, the backoff is cleared immediately.

**Failures the mirror causes itself retry in seconds first.** A TLS handshake
that could not allocate internal RAM, a socket that died mid-request, an
`esp-tls` setup failure: none of those say anything about Open-Meteo's health,
and the provider's own interval is fifteen minutes. Those go on a 5s/15s/45s
ladder before the ordinary cadence applies, so a hiccup that clears in a second
costs a second of staleness rather than a quarter of an hour of it — and the
panel's grace period is three intervals, so it never even flips to a
placeholder. The distinction is made in `provider.c` (`is_local_failure`): the
HTTP client's and esp-tls's error families, plus `ESP_ERR_NO_MEM` and
`ESP_ERR_TIMEOUT`, are local; `ESP_ERR_INVALID_RESPONSE` means the service
answered and gets the polite treatment. A failure log carries the internal-RAM
figures with it, because on this board that is the usual cause and nothing else
reports it.

### Threading

The render task never blocks on the network. Providers fetch into their own
buffers and take the model mutex only for the copy, so a stalled TLS handshake
cannot delay a frame. Time and link state are not providers at all; they are
read locally every frame, so the clock keeps ticking regardless.

## Not yet implemented

**Calendar is deferred.** Expanding ICS recurrence rules is impractical on the
device, and the usual fix, a small helper service, needs a machine that is
always on. If it comes back, the route is Google Calendar's
`events.list?singleEvents=true`, which expands recurrences server-side, with
the Flutter app performing the one-time OAuth and handing the device a refresh
token.

**Todos** are not wired up yet; the widget shows its empty state.

Layout push over the LAN and OTA are implemented; see "OTA updates" above.
