import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/services/bundled_firmware.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('firmwareVersionFromImage', () {
    test('reads the version from the app descriptor magic word', () {
      final bytes = Uint8List(128);
      // esp_app_desc_t at offset 32: magic 0xABCD5432, then version[32] 16
      // bytes later, null-padded.
      bytes.setRange(32, 36, const <int>[0x32, 0x54, 0xCD, 0xAB]);
      const version = '0.2.0';
      for (var i = 0; i < version.length; i++) {
        bytes[48 + i] = version.codeUnitAt(i);
      }

      expect(firmwareVersionFromImage(bytes), version);
    });

    test('returns null for a short or garbage image', () {
      expect(firmwareVersionFromImage(Uint8List(10)), isNull);
      expect(firmwareVersionFromImage(Uint8List(256)), isNull);
    });
  });

  group('loadBundledFirmware', () {
    test('loads the bundled image and reports a self-consistent version',
        () async {
      final bundled = await loadBundledFirmware();

      expect(bundled, isNotNull, reason: 'the app must ship a firmware image');
      expect(bundled!.version, isNotEmpty);
      expect(bundled.bytes, isNotEmpty);
      // The reported version must reparse from the bytes it was loaded with,
      // proving the bundle cannot drift.
      expect(firmwareVersionFromImage(bundled.bytes), bundled.version);
    });

    test('bundles the firmware the tree declares', () async {
      final bundled = await loadBundledFirmware();
      expect(bundled, isNotNull);

      // One version per image: an APK that bundles a firmware other than the
      // one firmware/CMakeLists.txt names is shipping an image nobody can
      // identify. tools/firmware_version.py enforces the same thing from the
      // build side; this is the half the app itself can check.
      final cmake = File('../firmware/CMakeLists.txt').readAsStringSync();
      final declared = RegExp(r'^project\(smart_mirror VERSION ([^)\s]+)\)',
              multiLine: true)
          .firstMatch(cmake)
          ?.group(1);
      expect(declared, isNotNull,
          reason: 'firmware/CMakeLists.txt declares a version');
      expect(bundled!.version, declared,
          reason: 'the app bundles ${bundled.version} while the firmware tree '
              'declares $declared: restage with tools/bundle_firmware.sh');
    });
  });
}
