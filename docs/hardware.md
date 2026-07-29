# Hardware notes

## Bill of materials

| Item | Choice | Notes |
|---|---|---|
| MCU | ESP32-S3-DevKitC-1 **N16R8** | 16MB flash, 8MB octal PSRAM, native USB-JTAG |
| Panel | Waveshare RGB-Matrix-P2.5-64x64 | 160x160mm, 1/32 scan, HUB75, 5V 4A each |
| Panel count | 2 (128x64 default) | Geometry is a config value, not compiled in |
| PSU | 5V **10A** (50W) | See the power section. Do not undersize this. |
| Mirror | Two-way acrylic or glass | Passes roughly 10 to 30 percent of light |

Panel geometry is configurable, so 1, 2 or 4 panels all work with the same firmware.
The stock layouts in `layouts/` cover 64x64, 128x64 and 128x128.

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

Fourteen signals, all drawn from the 25 pins that remain free.

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

The **E line is required**. A 64x64 panel at 1/32 scan needs five address lines
(A through E). Some older HUB75 pinout diagrams show ground in the E position, which is
correct for 1/16 scan 64x32 panels and wrong here.

## Power

Waveshare rates each panel at **5V 4A, 20W maximum**. That figure is for an all-white
frame at full brightness.

- Two panels is **8A / 40W worst case**. Specify a 5V 10A supply.
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
./core/build/host/mirror-cli layouts/dual.json --mirror 20 -s 8
```

That dims the preview to 20 percent transmission. Dim greys and thin strokes that look
fine at full brightness tend to disappear entirely, which is worth discovering now
rather than after the enclosure is built.

## Physical dimensions

At P2.5 pitch each 64x64 panel is 160mm square.

| Configuration | Panel area |
|---|---|
| 64x64, one panel | 160 x 160 mm |
| 128x64, two panels | 320 x 160 mm |
| 128x128, four panels | 320 x 320 mm |

The mirror needs to be larger than the panel area, with the panel centred behind the
portion you want to light up.
