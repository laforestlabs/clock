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
  });
}
