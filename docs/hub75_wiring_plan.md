# HUB75 Wiring Plan: Freenove ESP32-S3-WROOM + Waveshare RGB-Matrix-P2.5-64x32

Status: final plan (hand-wire / prototype PCB). Decisions locked: direct drive (no level
shifter), camera disconnected, onboard SD slot not reserved, 1/16-scan 64x32 panel.
Pin assignments verified against the firmware defaults (`Smart Mirror > Panel pins` in
menuconfig, which `firmware/main/panel.cpp` reads into `Hub75Config`).

## Hardware

- MCU board: Freenove ESP32-S3-WROOM (FNK0085), ESP32-S3-WROOM-1 N16R8 module
  (16MB flash, 8MB octal PSRAM)
- Panel: Waveshare RGB-Matrix-P2.5-64x32 (SKU 23707), 64x32 px, 2.5mm pitch,
  1/16 scan, dual HUB75 (chainable), 5V / 2.5A max via VH4 power header, <= 12W.
  Ships with 16-pin IDC ribbon and power terminal adapter.

## Signal wiring (direct drive, no shifter)

| IDC pin | Signal | ESP32 GPIO | Notes |
|---|---|---|---|
| 1 | R1 | 4 | |
| 2 | G1 | 5 | |
| 3 | B1 | 6 | |
| 4 | GND | GND | |
| 5 | R2 | 7 | |
| 6 | G2 | 15 | |
| 7 | B2 | 16 | |
| 8 | E | - | Unused at 1/16 scan; leave unwired. GPIO10 when moving to 64-row (1/32 scan) panels |
| 9 | A | 17 | |
| 10 | B | 18 | |
| 11 | C | 8 | |
| 12 | D | 9 | |
| 13 | CLK | 13 | |
| 14 | LAT | 11 | |
| 15 | OE | 12 | 10k pull-up to 3.3V (blank panel during boot) |
| 16 | GND | GND | |

The camera must be unplugged from its FPC connector: it owns GPIO4-13 and 15-18
when attached (Freenove uses the ESP32S3_EYE camera pinout), and every panel
signal except the address lines and OE lives in that range.

## Power

- Panel: 5V/4A supply into the panel's VH4 header via the included terminal adapter.
- ESP32 board: its own USB power, or 5V from the same supply into the board's 5V pin.
- Hard requirement: common GND between panel supply and ESP32. Use both IDC GND
  pins (4 and 16).
- Never feed panel power through the Freenove board.

## Why this pin set is boot-safe

Pins avoided entirely, and why:

| GPIO | Reason |
|---|---|
| 0, 3, 45, 46 | Strapping pins (boot mode, VDD_SPI, ROM log); panel loading can break boot/flashing. GPIO0 is also the onboard BOOT button |
| 19, 20 | Native USB D-/D+ |
| 43, 44 | UART0 to onboard CH343; kept as debug console |
| 26-32 | Internal SPI flash |
| 33-37 | Internal octal PSRAM (N16R8 variant) |
| 48 | Onboard WS2812 status LED (kept free for that use) |

## Free pins remaining

1, 2, 10, 14, 21, 38, 39, 40, 41, 42, 47 (plus 48 for the status LED, and 10 is
reserved as the future E line for 64-row panels). The SD slot is not reserved,
so 38 (CMD), 39 (CLK), 40 (D0) are general purpose.

## Direct-drive caveat

Panel inputs are 5V logic; 3.3V drive is below the typical 0.7 x VDD = 3.5V V_IH.
It works on most panels in practice (Waveshare ships ESP32 demos wired this way),
but if snow/flicker appears at high refresh: lower the DMA clock first
(e.g. 10 MHz), then retrofit a 74AHCT245 level shifter if it persists.

## Firmware

Driver: `esphome/esp-hub75` 0.3.6 (component registry), the same library the
firmware README documents. The mirror's own render core is compiled in as
`components/mirror_core`.

Pins are not hardcoded in source; they are Kconfig defaults under
`Smart Mirror > Panel pins`, read by `firmware/main/panel.cpp` into
`Hub75Config`. The defaults match the table above:

```cpp
Hub75Config cfg{};
cfg.pins.r1  = 4;   cfg.pins.g1 = 5;   cfg.pins.b1 = 6;
cfg.pins.r2  = 7;   cfg.pins.g2 = 15;  cfg.pins.b2 = 16;
cfg.pins.a   = 17;  cfg.pins.b  = 18;  cfg.pins.c  = 8;   cfg.pins.d = 9;
cfg.pins.e   = -1;                    // 64-row panels only; wire GPIO10 and set to 10
cfg.pins.lat = 11;  cfg.pins.oe = 12; cfg.pins.clk = 13;
```

If you ever re-pin, change `menuconfig` rather than the code, and keep out of
33-37 (octal PSRAM on this module).

## Bring-up checklist

1. Camera FPC disconnected.
2. Wire GND pins 4 and 16 first; verify continuity to panel supply GND.
3. Power panel from 5V/4A, ESP32 from USB; confirm common ground.
4. Flash this firmware (`idf.py -C firmware flash monitor`). At boot the panel
   shows a red/green/blue/white test pattern for two seconds before rendering.
5. If the panel is dark or shows garbage, try the other shift register driver
   (`Smart Mirror > Panel > Shift register driver IC`) before suspecting wiring.
   Waveshare ships either ICN2038S (no setup) or FM6126A (needs init).
6. If the panel stays lit during reset, check the OE pull-up.

## Future PCB path

This plan maps directly onto a prototype shield: female headers for the Freenove
board, 2x8 shrouded IDC to the panel, 5V screw terminal passthrough (3A+), OE
pull-up, and an expansion header for the free pins. The KiCraft pipeline can
generate the fab-ready KiCad project from these exact choices on request.
