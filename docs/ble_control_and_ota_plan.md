# Plan: Bluetooth panel control and phone-driven OTA

Audience: the agent implementing this. Read this whole document before editing
anything. It describes what already exists (do not rebuild it), the gaps, the
exact contracts to add, and how to verify.

## Goal

1. Configure and **control** the panel from the Flutter app on a phone over
   Bluetooth: brightness control and reboot are the missing control surface
   (configuration itself already works).
2. OTA firmware updates without plugging the board into the PC: the transport
   exists, but the phone flow is not wired end to end and the firmware does not
   report a version that makes an update verifiable.

Phone target is **Android only**. There is no `designer/ios/` directory.

## What already exists (do not rebuild)

Firmware (ESP-IDF 5.5.2, target esp32s3, board Freenove FNK0085 / N16R8):

- `firmware/main/net/ble.c`: NimBLE GATT server, service
  `5f1b3c2a-9e74-4f6d-8a2b-1c3d5e7f9a01`, characteristics `...02` (cmd),
  `...03` (data), `...04` (status, notify + read). ASCII protocol:
  `ping`, `get config`, `begin <layout|config> <len>`, data chunks, `commit`,
  `abort`. Bounds: `MAX_CMD_LEN 63`, `MAX_PAYLOAD 32768`, `MAX_STATUS_LEN 256`.
  One connection, no pairing (deliberate; same trust model as the open setup
  portal). `pong` replies `pong <version> <ip> <layout> <w> <h>`.
- `firmware/main/net/api_server.c`: LAN API on the station interface:
  `GET /api/status`, `GET|PUT /api/layout`, `POST /api/ota`. mDNS advertises
  `_smartmirror._tcp`.
- `firmware/main/net/ota.c`: `POST /api/ota` streams the raw app image into
  the next OTA partition, validates with `esp_ota_end`, switches the boot
  partition, reboots. Rollback: `CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE=y` and
  `ota_mark_valid()` is called in `app_main` once the render task runs, so an
  image that crashes early reverts automatically.
- `firmware/partitions.csv`: `ota_0`/`ota_1`, 4 MB each. Already in place.
- `firmware/main/config.c` / `config.h`: owner config in NVS (timezone,
  latitude, longitude, place, brightness, clock12h, temp_unit), seeded from
  Kconfig, partial-JSON apply with all-or-nothing validation via
  `mirror_config_apply_json()`. This is the pattern to follow for any new
  persisted setting.
- `firmware/main/panel.cpp`: `panel_set_brightness(uint8_t)` and
  `panel_get_brightness()` already exist and work at runtime (hardware dims by
  shortening LED on-time).
- `firmware/main/net/ble.c` is included from `main.c` behind
  `CONFIG_BT_ENABLED`; NimBLE options live in `sdkconfig.defaults`.

Flutter app (`designer/`):

- `lib/src/services/mirror_ble.dart`: `scanForMirrors()`, `BleSession`
  (connect with MTU 512, serialized with-response writes, `ping()`,
  `getConfigRaw()`, `pushLayout()`, `pushConfig()`).
- `lib/src/services/mirror_ble_protocol.dart`: pure-Dart `BlePayloadWriter`
  chunking. Unit tested.
- `lib/src/services/mirror_lan.dart`: `status()`, `getLayout()`,
  `putLayout()`, `uploadFirmware(File, onProgress:)` streaming in 64 KB
  chunks. Unit tested.
- `lib/src/services/mirror_discovery.dart`: mDNS browse.
- `lib/src/services/mirror_config.dart`: `MirrorConfig` with validation that
  deliberately mirrors `config.c` rule for rule. Keep this convention: any new
  field validated on the device is validated identically in Dart.
- `lib/src/ui/mirror_screen.dart`: Mirror screen with two sections.
  Bluetooth: scan, connect, Push layout, Configure dialog. On this network:
  mDNS browse + manual IP, Push layout, **Update firmware** (file picker,
  progress dialog, then polls status for up to 60 s until the mirror answers
  after reboot).
- `designer/android/app/src/main/AndroidManifest.xml`: `BLUETOOTH_SCAN`
  (neverForLocation), `BLUETOOTH_CONNECT`, `ACCESS_FINE_LOCATION`
  (maxSdkVersion 30), `INTERNET`, `CHANGE_WIFI_MULTICAST_STATE`,
  `usesCleartextTraffic`.
- `designer/tool/fake_mirror.dart`: fake LAN mirror for desktop development
  (status/layout/OTA, in-memory).
- Tests in `designer/test/`: protocol, LAN client, config validation.

### Work in progress you must not clobber

There are **uncommitted changes** in `firmware/main/` (`layout_store.c`,
`main.c`, `net/api_server.c`, `net/ble.c`, `net/provision.c`). These are
in-flight stack-size and robustness fixes from the hardware session. Build on
top of them; never revert them. If a hunk conflicts with your edit, keep both
behaviours.

## Gaps, and the work to close them

### Gap 1: no live brightness control, no reboot command

Brightness is currently set once at boot from `CONFIG_MIRROR_BRIGHTNESS` and
re-set from the layout JSON on every layout push
(`layout_store.c` calls `panel_set_brightness(candidate->brightness)`).
`/api/status` reports `layout.brightness`, a static number, not the live
value. The phone cannot dim the panel.

**Firmware changes:**

1. `firmware/main/config.c`: add a `brightness` key to the NVS config. Type:
   signed int, `-1` means "follow the layout" (the default), `0..255` means a
   manual override. Seed from Kconfig default `-1`. Extend
   `mirror_config_apply_json()` to accept an optional `"brightness"` field:
   integer `0..255`, or `null`/absent to leave unchanged. Reuse the existing
   all-or-nothing validation pattern; on success persist and call
   `panel_set_brightness()` when the value is an override. Add accessors:
   `int mirror_config_brightness(void)` (raw, `-1` = auto).
2. One owner for the effective brightness. Add
   `uint8_t mirror_config_effective_brightness(uint8_t layout_brightness)` in
   `config.c`: returns the override when set, else the layout value. Change
   `layout_store.c` (both the boot path in `main.c` and the apply path) to set
   the panel through this helper instead of using the layout's value
   unconditionally, so a manual override survives a layout push.
3. `firmware/main/net/ble.c`: new commands, same ASCII style:
   - `get brightness` → status `brightness <n> <auto|manual>` where `<n>` is
     the live `panel_get_brightness()`.
   - `set brightness <0-255>` → validate, persist as override, apply, status
     `brightness ok <n>`. Out of range or garbage → `brightness error <why>`.
   - `set brightness auto` → clear the override, re-apply the current
     layout's brightness (snapshot via `layout_store_snapshot`), status
     `brightness ok auto`.
   - `reboot` → send `reboot ok`, flush the notification, then
     `esp_restart()` after a short delay (a `vTaskDelay` of a few hundred ms
     on the host task is fine; the phone needs the status line first).
   Command strings must stay within `MAX_CMD_LEN` (63) and status lines within
   `MAX_STATUS_LEN` (256). Note `handle_cmd` currently has an exact-match and
   prefix-match mix; follow it.
4. `firmware/main/net/api_server.c`: `/api/status` should report the live
   `panel_get_brightness()` instead of `layout.brightness`. Keep the JSON key
   `brightness` unchanged so the app's `MirrorStatus` still parses. (The LAN
   API stays read-only for config: the owner's standing decision is that the
   phone writes over BLE only. Do not add a LAN brightness endpoint.)
5. `get config` response gains `"brightness":<-1|0..255>` so the app can
   prefill from one place. The display settings (`clock12h`, `temp_unit`)
   were added the same way; the configure dialog prefills all of them from
   this one line.

### Gap 2: the firmware reports the wrong version, so OTA is not verifiable

`/api/status` and the BLE `pong` report `ML_VERSION_STR`, the version of the
render core library. An OTA that changes only firmware code leaves that string
identical, and the app's "Updated to X" toast is meaningless.

**Firmware changes:**

1. `firmware/CMakeLists.txt`: give the project a version, e.g.
   `project(smart_mirror VERSION 0.2.0)`. ESP-IDF then bakes it into the app
   image descriptor.
2. Report `esp_app_get_description()->version` (`#include "esp_app_desc.h"`)
   as `version` in `handle_get_status` and as the version token in the BLE
   `pong`. Keep `ML_VERSION_STR` available as a separate `core` field in
   `/api/status` (`"core":"%s"`) since it is still useful for debugging
   designer/firmware render drift. The pong format gains no fields (the
   version token just changes meaning), so `_PongInfo.parse` keeps working.
3. Log the app version at boot in `app_main` next to the existing banner.

### Gap 3: the phone flow is not wired end to end

**App changes (`designer/`):**

1. **Runtime BLE permissions.** The manifest declares the permissions but no
   Dart code requests them, and `flutter_blue_plus` does not request them for
   you: on Android 12+ the scan just fails. Add `permission_handler` to
   `pubspec.yaml`. In `mirror_screen.dart` before `_scan()` calls
   `scanForMirrors()`: request `Permission.bluetoothScan` and
   `Permission.bluetoothConnect` (and `Permission.locationWhenInUse` only on
   Android 11 and below, matching the manifest's `maxSdkVersion="30"`). Map
   denied/permanentlyDenied to the existing `_bleUnavailable` string with a
   human message ("Bluetooth permission denied; grant it in Settings" for
   permanentlyDenied, plus `openAppSettings()` as a convenience button or
   snackbar action).
2. **Brightness control in the BLE section.** When connected
   (`_session != null`), query `get brightness` once, then show a
   `Slider` (0..255, divisions 255) with an "Auto" `Switch`. Dragging sends
   `set brightness <n>`; debounce (only send on `onChangeEnd`, not
   `onChanged`, to keep ATT writes serialized and infrequent). Toggling Auto
   sends `set brightness auto`. Add `getBrightness()` /
   `setBrightness(int?)` methods to `BleSession` (null = auto), parsing the
   `brightness ...` status lines. Reuse the existing `_bleBusy` guard.
3. **Reboot button** in the BLE section (`TextButton`, confirm dialog first).
4. **OTA from the BLE section.** The pong already carries the mirror's WiFi
   IP, and the file comment in `mirror_screen.dart` says that is what it is
   for, but no button consumes it. Add "Update firmware" to the connected BLE
   panel, enabled when `_pong.ip` is non-empty and not `0.0.0.0`. Refactor
   `_updateFirmware(int index)` so the file-pick/upload/wait-for-reboot logic
   takes an IP string, and call it from both the LAN tile and the BLE section.
   Guard the edge case: if the phone is not on the same WiFi (BLE-connected
   but no IP route), the upload fails with the existing "could not reach"
   error, which is acceptable; mention the WiFi requirement in the button's
   tooltip.
5. **Getting the image onto the phone: download-from-URL.** The remaining PC
   involvement is building the `.bin`; copying it to the phone by hand is the
   friction to remove. In the OTA flow, offer two sources: "Choose file"
   (current) and "Download from URL" (a dialog with a URL field, defaulting to
   the last used value persisted via `shared_preferences`). Download with
   `dart:io` `HttpClient` into `${getTemporaryDirectory()}/ota.bin`, verify
   the size is non-zero and fits in 4 MB, then feed it to
   `uploadFirmware`. This pairs with a PC-side `python3 -m http.server` (see
   Gap 4). Add `shared_preferences` to `pubspec.yaml`.

### Gap 4: no build/export tooling for the OTA image

1. Add `tools/build_ota.sh`: sources `$HOME/esp/esp-idf-v5.5/export.sh`,
   runs `idf.py -C firmware build`, copies
   `firmware/build/smart_mirror.bin` to `firmware/build/ota/smart_mirror-<version>.bin`
   (version read from the CMake project), prints size and SHA-256, and
   optionally (`--serve [port]`, default 8000) serves that directory with
   `python3 -m http.server` bound to the LAN interface so the phone's
   "Download from URL" flow can fetch it. Print the exact URL to type into
   the app (detect the primary IPv4 with `ip route get 1.1.1.1` or
   `hostname -I`).
2. Document the full loop in `firmware/README.md` under a new "OTA updates"
   section: build with `tools/build_ota.sh --serve`, open the app on the
   phone, connect over BLE, Update firmware, Download from URL, paste the
   printed URL, wait for the reboot poll. Also document the rollback
   behaviour (already implemented) so a bad image is understood to be
   self-healing, and note that the phone and mirror must be on the same LAN
   for the upload leg.

### Gap 5: developer loop and tests

1. `designer/tool/fake_mirror.dart`: track a mutable brightness
   (`panel_get_brightness` equivalent) so `/api/status` reflects it; add a
   `POST`-less no-op for the reboot flow is unnecessary since reboot is
   BLE-only. Keep OTA byte counting as is.
2. `designer/test/`: add unit tests for the new pure-Dart logic:
   - `BleSession` status-line parsing for `brightness <n> <auto|manual>`
     (factor the parse into a testable function or small class in
     `mirror_ble.dart` / a new `mirror_ble_status.dart`).
   - `MirrorConfig` validation for the new `brightness` field (range,
     null-means-unchanged), mirroring the firmware rules.
   - `MirrorStatus.fromJson` with the new `core` field present and absent
     (older firmware has no `core`; parse must tolerate that).
   Firmware has no test harness; its verification is the build plus the
   hardware smoke below.

## Explicitly out of scope

- **OTA over the BLE transport.** A 4 MB image over BLE at real-world
  throughput takes many minutes and the current protocol caps payloads at
  32 KB; the WiFi OTA path covers the actual need (the mirror lives on the
  LAN). Revisit only if WiFi provisioning proves unreliable in practice.
- **LAN write endpoints for config/brightness.** Standing owner decision:
  writes go over BLE from the phone; the LAN API is read-only plus layout/OTA
  push.
- **BLE pairing/bonding.** Same trust model as the open setup portal, by
  decision. Do not add security "while you are in there".
- **iOS.** No `ios/` project exists; do not create one.
- **Automatic update checking / update servers.** The owner builds and pushes
  deliberately.

## Contracts to keep stable

- BLE UUIDs and the begin/chunks/commit framing are unchanged. New surface is
  new command strings only; old apps talking to new firmware and vice versa
  must both keep working (an old firmware answers `error unknown command` to
  the new commands, which the app should surface, not crash on: check what
  `handle_cmd` does for unknown input and mirror that tolerance in Dart).
- Status JSON keys are additive only. `version` changes meaning (app version
  instead of core version); `core` is new and optional on read.
- `pong <version> <ip> <layout> <w> <h>` keeps its field count and order.
- Dart validation mirrors firmware validation exactly (existing convention in
  `mirror_config.dart`).

## Implementation order

1. Firmware version reporting (Gap 2). Small, self-contained, and it makes
   every later OTA test observable.
2. Firmware brightness + reboot (Gap 1). Builds on `config.c`,
   `layout_store.c`, `ble.c`, `api_server.c`.
3. App: permissions, brightness UI, reboot, BLE OTA button, URL download
   (Gap 3). Can be developed against the real device or, for the LAN parts,
   `tool/fake_mirror.dart`.
4. `tools/build_ota.sh` and docs (Gap 4), fake mirror and tests (Gap 5).

Steps 1 and 2 are sequential with each other (same files); step 3 depends on
the firmware contracts but not on the firmware being flashed, since the BLE
surface is specified above. Step 4 is independent.

## Verification

Build and unit checks:

- Firmware builds clean:
  `. $HOME/esp/esp-idf-v5.5/export.sh && idf.py -C firmware build`
- App: `cd designer && flutter test` (all existing tests plus the new ones)
  and `flutter analyze`.

Hardware smoke (requires the board and a phone; if hardware is not available,
say so explicitly and stop after the build/unit checks):

1. Flash the new firmware over USB one last time.
2. Phone app: scan, connect, confirm the pong line shows the new app version.
3. Brightness slider dims the panel live; reboot the mirror by power cycling;
   the override survives (NVS). Auto switch returns to the layout brightness.
4. Configure dialog still round-trips (get config / push config unchanged
   behaviour plus the new field).
5. OTA: `tools/build_ota.sh --serve`, phone downloads from the printed URL,
   upload progress completes, the mirror reboots, the app's reboot poll
   returns and shows the new version. Bump `project(... VERSION ...)`, repeat
   once to prove the version string actually changes across OTA.
6. Negative: upload a truncated `.bin`; the device must reject it at
   `esp_ota_end` and stay on the old image.
7. Regression: layout push over BLE and over LAN both still apply and still
   update brightness only when no override is set.

## References

- Firmware BLE protocol: top comment of `firmware/main/net/ble.c`.
- OTA handler and rollback rationale: top comment of `firmware/main/net/ota.c`.
- Config module pattern: `firmware/main/config.c`, `firmware/main/config.h`.
- App BLE session and protocol: `designer/lib/src/services/mirror_ble.dart`,
  `mirror_ble_protocol.dart`.
- Mirror screen flows to extend: `designer/lib/src/ui/mirror_screen.dart`
  (`_updateFirmware`, `_waitForReboot`, `_ConfigureDialog`).
- Build environment: ESP-IDF v5.5.2 at `$HOME/esp/esp-idf-v5.5` (5.0 to 5.3
  do not compile `esp-hub75`; see `firmware/README.md`).
