// parseBrightnessStatus: the "brightness <n> <auto|manual>" status lines from
// firmware/main/net/ble.c. Kept pure so the app's new control surface is
// testable without a device.

import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/services/mirror_ble_status.dart';

void main() {
  group('parseBrightnessStatus', () {
    test('parses a manual override line', () {
      final b = parseBrightnessStatus('brightness 128 manual');
      expect(b, isNotNull);
      expect(b!.value, 128);
      expect(b.auto, isFalse);
    });

    test('parses an auto line', () {
      final b = parseBrightnessStatus('brightness 120 auto');
      expect(b, isNotNull);
      expect(b!.value, 120);
      expect(b.auto, isTrue);
    });

    test('parses the extremes of the range', () {
      expect(parseBrightnessStatus('brightness 0 manual')!.value, 0);
      expect(parseBrightnessStatus('brightness 255 manual')!.value, 255);
    });

    test('rejects set-response and error lines', () {
      // These are the answers to "set brightness", not "get brightness".
      expect(parseBrightnessStatus('brightness ok 128'), isNull);
      expect(parseBrightnessStatus('brightness ok auto'), isNull);
      expect(parseBrightnessStatus('brightness error out of range'), isNull);
    });

    test('rejects unrelated status lines (old firmware)', () {
      expect(parseBrightnessStatus('unknown command'), isNull);
      expect(parseBrightnessStatus('pong 0.2.0 192.168.1.5 mini 64 32'),
          isNull);
      expect(parseBrightnessStatus('commit ok 4 widgets'), isNull);
    });

    test('rejects malformed lines', () {
      expect(parseBrightnessStatus('brightness 128'), isNull);
      expect(parseBrightnessStatus('brightness abc manual'), isNull);
      expect(parseBrightnessStatus('brightness 300 manual'), isNull);
      expect(parseBrightnessStatus('brightness 128 automanual'), isNull);
      expect(parseBrightnessStatus(''), isNull);
    });
  });
}
