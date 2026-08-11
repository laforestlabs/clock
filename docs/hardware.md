# Hardware notes

## Bill of materials

| Item | Choice | Notes |
|---|---|---|
| MCU | ESP32-S3-DevKitC-1 **N16R8** | 16MB flash, 8MB octal PSRAM, native USB-JTAG |
| Panel | Waveshare RGB-Matrix-P2.5-64x32 | 160x80mm, 1/16 scan, HUB75, roughly 5V 2A each |
| Panel count | 1 (64x32 default) | Geometry is a config value, not compiled in |
| PSU | 5V **4A** (20W) | Ample for one 64x32. See the power section before adding panels. |
| Mirror | Two-way acrylic or glass | Passes roughly 10 to 30 percent of light |

Panel geometry is configurable, so 1, 2 or 4 panels all work with the same firmware.
The stock layouts in `layouts/` cover 64x32, 64x64, 128x64 and 128x128.

The default is the single **P2.5-64x32** and `layouts/mini.json`, a clock and the
weather. It is the cheapest way to get a working mirror, and it is the one arrangement
that needs no E line (see the pin map) and no oversized supply.

Going bigger changes three things at once, so change them together: the panel geometry
in `menuconfig`, the E line if the new panel has 64 rows, and the supply.

## The GPIO trap on N16R8

**Do not copy the pinout from the `esp-hub75` README onto this module.** That example
uses GPIO 35, 36 and 37. On an ESP32-S3 with *octal* PSRAM (the R8 in N16R8), GPIO33
through GPIO37 belong to the PSRAM bus. Driving them gives a dead panel, a board that
will not boot, or both.

Quad-PSRAM parts (R2) do not have this conflict, since quad PSRAM shares the flash pins
at GPIO26 to GPIO32 instead. This applies specifically to the octal part chosen here.

Pins to avoid on this module:

| Range | Why |
|---|---|
| GPIO0, 3, 45, 46 | Strapping pins, sampled at reset |
| GPIO26 to 32 | SPI flash |
| GPIO33 to 37 | **Octal PSRAM on R8 parts** |
| GPIO43, 44 | UART0, the serial console |
| GPIO19, 20 | Native USB D-/D+ |

### Verified-safe pin map

Thirteen signals for the default panel, all drawn from the 25 pins that remain free.
E is a fourteenth, needed only by 64-row panels.

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

**The default 64x32 panel does not use the E line.** At 1/16 scan four address lines
(A through D) address all 32 rows, so `MIRROR_PIN_E` is `-1` and GPIO10 stays free.
Older HUB75 pinout diagrams that show ground in the E position are drawn for exactly
this case.

A 64x64 panel is 1/32 scan and **does** need E, wired to GPIO10 and `MIRROR_PIN_E` set
to match. Without it such a panel shows only half its rows, doubled. This is the single
easiest thing to get wrong when moving up from the default.

### Swapped colour channels

If the boot test pattern (red, green, blue, white bars) reads **red, blue, green**, the
panel's green and blue data lines are crossed at the connector or inside the panel.
Rather than rewiring, set `CONFIG_MIRROR_SWAP_GB` (already on in this project's
`sdkconfig.defaults`); `panel_blit_rgb888` then exchanges the green and blue channels
after gamma, before the shift registers, so the render core and the desktop preview
still produce the true colours.

## Power

Waveshare rates the 64x64 panel at **5V 4A, 20W maximum**, for an all-white frame at
full brightness. The 64x32 has half the LEDs, so budget **roughly 2A / 10W** for it.

- The default single 64x32 is **about 2A worst case**. A 5V 4A supply is comfortable.
- Two 64x64 panels instead is **8A / 40W worst case**, which needs a 5V 10A supply.
  Resize the supply whenever the panel count or panel size changes.
- **Inject power into each panel's own VH4 socket.** Do not daisy-chain power through
  the HUB75 ribbon; it is not rated for it and the far panel will show colour shift.
- Do not power the panels from the ESP32 dev board's USB rail.
- Test with an all-white frame before trusting the supply. An undersized PSU browns out
  the S3 and reboots it, which looks like a firmware crash and is not.

A realistic mirror layout at reduced brightness draws far less than the worst case,
often under 1A per panel. Size for the worst case anyway: the panel is what decides how
much current to pull, and a boot loop under load is a miserable thing to debug.

## Shift-register driver IC

Waveshare ships these panels with either an **ICN2038S** (no setup needed) or an
**FM6126A** (requires a specific initialization sequence at power-on, and stays dark
without it). Which one is in the box is not documented per unit.

`esp-hub75` selects this with `Hub75Config::shift_driver`, which also supports FM6124,
MBI5124 and DP3246. Treat it as a bring-up unknown: if the panel is dark or shows
garbage on first power-up, try the other driver before suspecting wiring.

## Brightness behind the mirror

Two-way mirror film transmits roughly 10 to 30 percent of the light hitting it, so the
panel has to run brighter than it would in the open, which drives both current and heat.

Check legibility before cutting glass:

```sh
./core/build/host/mirror-cli layouts/mini.json --mirror 20 -s 8
```

That dims the preview to 20 percent transmission. Dim greys and thin strokes that look
fine at full brightness tend to disappear entirely, which is worth discovering now
rather than after the enclosure is built.

## Physical dimensions

P2.5 is a 2.5mm pitch, so panel area is just the pixel count times 2.5mm. The default
64x32 is 160 x 80 mm, and each 64x64 panel is 160mm square.

| Configuration | Panel area |
|---|---|
| **64x32, one panel (default)** | **160 x 80 mm** |
| 64x64, one panel | 160 x 160 mm |
| 128x64, two panels | 320 x 160 mm |
| 128x128, four panels | 320 x 320 mm |

The mirror needs to be larger than the panel area, with the panel centred behind the
portion you want to light up.
