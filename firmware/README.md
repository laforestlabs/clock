# Firmware

ESP32-S3 application. Drives the HUB75 panel, joins WiFi, syncs the clock, and
renders the layout.

The render core is not vendored here. `components/mirror_core` is a symlink to
the repository's `core/`, so the firmware and the desktop designer compile
literally the same source files. That is what makes the designer's preview
worth trusting.

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
gitignored; the only things it holds are choices like the timezone and the
shift-register driver.

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

Two things worth knowing before shipping this:

- The station connects with **WPA2-PSK only**. WPA3 SAE is disabled in
  `sdkconfig.defaults`: the driver's SAE negotiation is flaky against
  WPA2/WPA3 transition-mode routers, so transition networks connect over
  their WPA2 half and WPA3-only networks are unsupported.
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

### 2. Test pattern

Enabled by default (`MIRROR_TEST_PATTERN`). At boot the panel shows red,
green, blue and white bars for two seconds.

| What you see | What it means |
|---|---|
| Correct bars, left to right | Wiring and colour order are right |
| Colours in the wrong order | Data pins swapped: check R1/G1/B1 and R2/G2/B2 |
| Top half right, bottom half wrong | The R2/G2/B2 group is miswired |
| Nothing at all | See the shift driver section below |
| Board resets during the white bar | The 5V supply cannot hold up. This looks exactly like a firmware crash and is not one. |

### 3. Shift driver

The single most likely bring-up surprise. Waveshare ships these panels with
either an **ICN2038S**, which needs no setup, or an **FM6126A**, which needs an
initialisation sequence and stays completely dark without it. Which one is in
your box is not documented per unit.

If the panel is dark or shows garbage, change
`Smart Mirror > Panel > Shift register driver IC` and reflash before suspecting
your wiring. `GENERIC` covers ICN2038S and most panels; try `FM6126A` next.

### 4. Clock

Once WiFi joins and SNTP replies, the clock changes from `--:--` to the real
time. The log says so:

```
I (5123) time: clock synced: 2026-07-29 14:03:11 BST
I (5124) mirror: clock is valid, the panel now shows the real time
```

Before that the panel deliberately shows placeholders rather than 1970 or a
confident zero. That is the same "cold" state the designer previews, so it is
worth checking it looks acceptable.

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
two-way glass actually runs at there is very little to lose.

**The panel is initialised before WiFi.** It needs the largest contiguous block
of DMA-capable internal SRAM in the system, and asking for it before the WiFi
stack has fragmented the heap is the difference between working and a confusing
allocation failure.

**Nothing in the render path touches the network.** The render task reads a
snapshot of the model and draws it, so a DNS timeout or a router reboot cannot
stall or tear the display. Worst case the mirror shows stale data.

## Memory

The DMA buffer must live in internal SRAM. PSRAM-backed HUB75 buffers cap the
shift clock near 13MHz and flicker visibly. The canvas and frame buffers do go
in PSRAM, since only the CPU reads them, which keeps internal SRAM free for
DMA. The log reports which pool each allocation landed in at boot.

## Data providers

Weather comes from **Open-Meteo**, fetched directly by the device over HTTPS.
No API key and no signup, which matters more than convenience: the mirror has
no weather credential to expire, leak, or re-provision.

Set your coordinates in `Smart Mirror > Weather`. The default is central
London, so it will show you plausible-looking weather for the wrong place if
you forget.

Certificate verification uses ESP-IDF's bundled root store rather than a pinned
certificate. Pinning would turn a provider's routine cert rotation into a
mirror that silently stops updating.

### Staleness is deliberate

Each provider declares a refresh interval and a grace period. After three
missed intervals its data is marked invalid and the widget falls back to a
placeholder.

That is on purpose. A mirror showing last Tuesday's temperature as though it
were current is worse than one showing `--`, because you cannot tell by looking
that it is wrong, and you dress for the wrong weather. Stale data has to
announce itself.

Failures back off exponentially, capped at an hour. When the link returns the
backoff is cleared immediately, since an outage's failures are the network's
fault and the penalty should not outlive it.

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

Layout push over the LAN arrives in M4, OTA in M5.
