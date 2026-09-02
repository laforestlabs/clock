// Parsers for the BLE WiFi status lines from firmware/main/net/ble.c. Kept
// pure so the app's WiFi setup surface is testable without a device.

import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/services/mirror_wifi_status.dart';

void main() {
  group('parseWifiStatus', () {
    test('parses a saved and connected line', () {
      final w = parseWifiStatus(
          'wifi {"saved":true,"ssid":"Home","ip":"192.168.1.5",'
          '"connected":true}');
      expect(w, isNotNull);
      expect(w!.saved, isTrue);
      expect(w.ssid, 'Home');
      expect(w.ip, '192.168.1.5');
      expect(w.connected, isTrue);
    });

    test('parses a fresh device with no credentials', () {
      final w = parseWifiStatus(
          'wifi {"saved":false,"ssid":"","ip":"0.0.0.0","connected":false}');
      expect(w, isNotNull);
      expect(w!.saved, isFalse);
      expect(w.ssid, '');
      expect(w.connected, isFalse);
    });

    test('decodes an escaped SSID', () {
      final w = parseWifiStatus(
          'wifi {"saved":true,"ssid":"A\\"B","ip":"192.168.1.5",'
          '"connected":true}');
      expect(w, isNotNull);
      expect(w!.ssid, 'A"B');
    });

    test('rejects old firmware and malformed lines', () {
      expect(parseWifiStatus('unknown command'), isNull);
      expect(parseWifiStatus('wifi not-json'), isNull);
      expect(parseWifiStatus(''), isNull);
    });
  });

  group('parseWifiNet', () {
    test('parses a secured network', () {
      final n =
          parseWifiNet('wifi-net {"ssid":"Home","rssi":-45,"open":false}');
      expect(n, isNotNull);
      expect(n!.ssid, 'Home');
      expect(n.rssi, -45);
      expect(n.open, isFalse);
    });

    test('parses an open network', () {
      final n = parseWifiNet('wifi-net {"ssid":"Cafe","rssi":-70,"open":true}');
      expect(n, isNotNull);
      expect(n!.open, isTrue);
    });

    test('rejects unrelated lines', () {
      expect(parseWifiNet('wifi {"saved":true}'), isNull);
      expect(parseWifiNet('wifi-scan done 3'), isNull);
      expect(parseWifiNet(''), isNull);
    });
  });

  group('parseWifiScanDone', () {
    test('parses a count', () {
      expect(parseWifiScanDone('wifi-scan done 3'), 3);
      expect(parseWifiScanDone('wifi-scan done 0'), 0);
    });

    test('rejects unrelated lines', () {
      expect(parseWifiScanDone('wifi-scan start'), isNull);
      expect(parseWifiScanDone('wifi-scan error could not start'), isNull);
      expect(parseWifiScanDone(''), isNull);
    });
  });

  group('parseWifiResult', () {
    test('parses a connect success', () {
      final r = parseWifiResult('wifi connect ok 192.168.1.5');
      expect(r, isNotNull);
      expect(r!.connected, isTrue);
      expect(r.detail, '192.168.1.5');
    });

    test('parses a connect failure with a reason', () {
      final r = parseWifiResult('wifi connect error wrong password');
      expect(r, isNotNull);
      expect(r!.connected, isFalse);
      expect(r.detail, 'wrong password');
    });

    test('rejects unrelated lines', () {
      expect(parseWifiResult('wifi-scan done 3'), isNull);
      expect(parseWifiResult('commit ok'), isNull);
      expect(parseWifiResult(''), isNull);
    });
  });
}
