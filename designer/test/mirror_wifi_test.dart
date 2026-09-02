// WifiConfig: the same validation rules as firmware/main/net/provision.c's
// apply_creds_and_connect, so a push that passes here is accepted by the
// device and one that fails here would be rejected there.

import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/services/mirror_wifi.dart';

void main() {
  group('WifiConfig validation', () {
    test('accepts a valid SSID and password', () {
      expect(const WifiConfig(ssid: 'Home', pass: 'secret').validate(), isNull);
    });

    test('accepts an open network (empty password)', () {
      expect(const WifiConfig(ssid: 'CoffeeShop').validate(), isNull);
    });

    test('rejects an empty SSID', () {
      expect(const WifiConfig(ssid: '').validate(), 'SSID is required');
    });

    test('rejects an SSID longer than 31 chars', () {
      expect(WifiConfig(ssid: 'X' * 32).validate(), 'SSID too long');
      expect(WifiConfig(ssid: 'X' * 31).validate(), isNull);
    });

    test('rejects a password longer than 63 chars', () {
      expect(WifiConfig(ssid: 'Home', pass: 'p' * 64).validate(),
          'password too long');
      expect(WifiConfig(ssid: 'Home', pass: 'p' * 63).validate(), isNull);
    });
  });

  group('WifiConfig JSON', () {
    test('toJson emits ssid and pass', () {
      expect(const WifiConfig(ssid: 'Home', pass: 'secret').toJson(),
          <String, dynamic>{'ssid': 'Home', 'pass': 'secret'});
    });

    test('toJson emits an empty pass for open networks', () {
      expect(const WifiConfig(ssid: 'Open').toJson(),
          <String, dynamic>{'ssid': 'Open', 'pass': ''});
    });
  });
}
