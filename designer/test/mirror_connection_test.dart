// The pong line is how the app learns the mirror's version, WiFi IP, layout
// and panel size over BLE, and the parse feeds both the Mirror screen and
// the persistent connection state. A break in it shows up as "no WiFi IP"
// on the OTA button and a blank status line, so it gets a test.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mirror_designer/src/services/mirror_connection.dart';

void main() {
  group('BlePong.parse', () {
    test('parses a full pong line', () {
      final pong = BlePong.parse('pong 0.2.0 192.168.1.5 mini 64 32');
      expect(pong, isNotNull);
      expect(pong!.version, '0.2.0');
      expect(pong.ip, '192.168.1.5');
      expect(pong.layout, 'mini');
      expect(pong.width, 64);
      expect(pong.height, 32);
    });

    test('returns null for anything that is not a pong', () {
      expect(BlePong.parse('brightness ok 128'), isNull);
      expect(BlePong.parse('pong'), isNull);
      expect(BlePong.parse('pong 0.2.0 192.168.1.5'), isNull);
    });

    test('tolerates non-numeric panel dimensions', () {
      final pong = BlePong.parse('pong 0.2.0 192.168.1.5 mini x y');
      expect(pong, isNotNull);
      expect(pong!.width, 0);
      expect(pong.height, 0);
    });
  });

  group('last panel size', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('rememberPanelSize persists and reloads', () async {
      final conn = MirrorConnection();
      await conn.rememberPanelSize(64, 32);
      expect(conn.panelWidth, 64);
      expect(conn.panelHeight, 32);

      final restored = MirrorConnection();
      await restored.loadLastPanelSize();
      expect(restored.panelWidth, 64);
      expect(restored.panelHeight, 32);
    });

    test('ignores a zero or negative size', () async {
      final conn = MirrorConnection();
      await conn.rememberPanelSize(0, 0);
      expect(conn.panelWidth, 0);
      expect(conn.panelHeight, 0);
    });

    test('panelWidth falls back to the remembered size without a live pong',
        () async {
      final conn = MirrorConnection();
      await conn.rememberPanelSize(128, 64);
      expect(conn.panelWidth, 128);
      expect(conn.panelHeight, 64);
    });
  });
}
