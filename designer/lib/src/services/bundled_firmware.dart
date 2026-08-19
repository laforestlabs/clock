// The firmware image bundled into this app build, used as the normal OTA
// source on a phone: update the app, then push the bundled firmware to the
// mirror.
//
// The image is the ESP-IDF app partition binary (firmware/build/smart_mirror.bin),
// staged into assets/firmware/ by tools/build_ota.sh. Its version is read from
// the image itself, the ESP-IDF app descriptor, rather than a second file, so
// the version the UI reports can never drift from the bytes being uploaded.

import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

/// The ESP32 app image version, read from the `esp_app_desc_t` at the head of
/// the image. Returns null when [bytes] is not a valid app image.
///
/// The descriptor starts with the magic word 0xABCD5432 and stores
/// `char version[32]` 16 bytes later. It is the first item in the image's
/// DROM segment; scanning the head of the file defensively avoids hard-coding
/// the image header size, which has changed across IDF releases.
String? firmwareVersionFromImage(Uint8List bytes) {
  // 0xABCD5432, little-endian.
  const magic = <int>[0x32, 0x54, 0xCD, 0xAB];
  const versionOffset = 16;
  const versionLength = 32;
  final limit = bytes.length < 4096 ? bytes.length : 4096;

  for (var i = 0; i + versionOffset + versionLength <= limit; i++) {
    if (bytes[i] != magic[0] ||
        bytes[i + 1] != magic[1] ||
        bytes[i + 2] != magic[2] ||
        bytes[i + 3] != magic[3]) {
      continue;
    }
    var end = i + versionOffset;
    while (end < i + versionOffset + versionLength && bytes[end] != 0) {
      end++;
    }
    if (end == i + versionOffset) return null; // empty version string
    return String.fromCharCodes(bytes.sublist(i + versionOffset, end));
  }
  return null;
}

/// The firmware image bundled with this app.
class BundledFirmware {
  const BundledFirmware({required this.version, required this.bytes});

  /// App image version, exactly what the device reports after the OTA.
  final String version;

  /// The raw app partition image to upload to POST /api/ota.
  final Uint8List bytes;
}

/// Loads the bundled firmware, or returns null when this build has none (a
/// developer checkout whose assets/firmware was never populated), in which
/// case the UI falls back to the file/URL sources.
Future<BundledFirmware?> loadBundledFirmware() async {
  try {
    final data = await rootBundle.load('assets/firmware/smart_mirror.bin');
    final bytes =
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final version = firmwareVersionFromImage(bytes);
    if (version == null) return null;
    return BundledFirmware(version: version, bytes: bytes);
  } catch (_) {
    return null;
  }
}
