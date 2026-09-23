// Which mirror gets offered an update, and the upload that follows it.
//
// The comparison decides whether the app prompts at all, so it is pinned here
// and not only through the prompt: a wrong answer either nags a mirror that is
// already current or silently never offers the update the app was built to
// carry.

import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/services/firmware_update.dart';
import 'package:mirror_designer/src/services/mirror_ble_status.dart';

void main() {
  group('compareFirmwareVersions', () {
    test('orders dotted versions numerically, not as text', () {
      expect(compareFirmwareVersions('0.2.32', '0.2.33'), lessThan(0));
      expect(compareFirmwareVersions('0.2.33', '0.2.32'), greaterThan(0));
      expect(compareFirmwareVersions('0.2.33', '0.2.33'), 0);
      // Text order would put 0.2.9 above 0.2.10.
      expect(compareFirmwareVersions('0.2.9', '0.2.10'), lessThan(0));
      expect(compareFirmwareVersions('0.10.0', '0.9.9'), greaterThan(0));
      expect(compareFirmwareVersions('1.0.0', '0.99.99'), greaterThan(0));
    });

    test('a missing field counts as zero', () {
      expect(compareFirmwareVersions('0.2', '0.2.0'), 0);
      expect(compareFirmwareVersions('0.2', '0.2.1'), lessThan(0));
      expect(compareFirmwareVersions('1', '0.9.9'), greaterThan(0));
    });
  });

  group('firmwareUpdateAvailable', () {
    test('offers the update to a mirror that is behind', () {
      expect(
        firmwareUpdateAvailable(
            deviceVersion: '0.2.32', bundledVersion: '0.2.33'),
        isTrue,
      );
      expect(
        firmwareUpdateAvailable(
            deviceVersion: '0.1.9', bundledVersion: '0.2.33'),
        isTrue,
      );
    });

    test('leaves a current or newer mirror alone', () {
      expect(
        firmwareUpdateAvailable(
            deviceVersion: '0.2.33', bundledVersion: '0.2.33'),
        isFalse,
      );
      expect(
        firmwareUpdateAvailable(
            deviceVersion: '0.3.0', bundledVersion: '0.2.33'),
        isFalse,
      );
    });

    test('refuses a version it cannot read instead of guessing', () {
      // A mirror whose version does not parse is unknown, not old: offering to
      // replace it would be a claim about which build is newer.
      for (final unknown in <String>['', 'dev', '0.2.33-rc1', 'v0.2.33']) {
        expect(
          firmwareUpdateAvailable(
              deviceVersion: unknown, bundledVersion: '0.2.33'),
          isFalse,
          reason: 'device "$unknown"',
        );
        expect(
          firmwareUpdateAvailable(
              deviceVersion: '0.2.0', bundledVersion: unknown),
          isFalse,
          reason: 'bundled "$unknown"',
        );
      }
    });
  });
  group('firmwareResumeOffset', () {
    test('resumes only matching active sessions', () {
      expect(firmwareResumeOffset(null, 1338096), 0);
      expect(
          firmwareResumeOffset(
              const BleOtaStatus(written: 5, total: 10, active: false), 10),
          0);
      expect(
          firmwareResumeOffset(
              const BleOtaStatus(written: 5, total: 9, active: true), 10),
          0);
      expect(
          firmwareResumeOffset(
              const BleOtaStatus(written: 0, total: 10, active: true), 10),
          0);
      expect(
          firmwareResumeOffset(
              const BleOtaStatus(written: 524288, total: 1338096, active: true),
              1338096),
          524288);
      expect(
          firmwareResumeOffset(
              const BleOtaStatus(
                  written: 1338096, total: 1338096, active: true),
              1338096),
          1338096);
    });
  });
}
