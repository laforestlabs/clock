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
idf.py -C firmware menuconfig      # Smart Mirror menu: WiFi, timezone, panel
idf.py -C firmware flash monitor
```

The S3 has native USB, so no serial adapter is needed. `sdkconfig` is
gitignored, so WiFi credentials entered in menuconfig stay out of the
repository.

Everything in the `Smart Mirror` menuconfig section has a working default
except the WiFi credentials.

## Bring-up, in order

Do these in sequence. Each one isolates a different failure, and skipping ahead
turns a five-minute problem into an afternoon.

### 1. Power before anything else

The panels are rated **4A each at 5V**. Two panels is 8A worst case, so use a
5V 10A supply and inject power into each panel's own VH4 socket. Do not
daisy-chain power through the HUB75 ribbon, and do not power panels from the
dev board.

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
| G2 | 15 | E | 10 |
| B2 | 16 | LAT | 11 |
| | | OE | 12 |
| | | CLK | 13 |

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

## Not yet implemented

M2 ends here. Weather, calendar and todo data arrive in M3, layout push over
the LAN in M4, and WiFi provisioning plus OTA in M5. Until then those widgets
render their placeholders.
