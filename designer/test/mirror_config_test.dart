// MirrorConfig: the same validation rules as firmware/main/config.c, so a
// push that passes here is accepted by the device and one that fails here
// would be rejected there.

import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/services/mirror_config.dart';

void main() {
  group('MirrorConfig validation', () {
    test('accepts valid values', () {
      const cfg = MirrorConfig(
        timezone: 'CET-1CEST,M3.5.0,M10.5.0/3',
        latitude: '52.5200',
        longitude: '13.4050',
        place: 'Berlin',
      );
      expect(cfg.validate(), isNull);
    });

    test('rejects an empty timezone', () {
      expect(const MirrorConfig(timezone: '').validate(), isNotNull);
    });

    test('rejects a timezone longer than 63 chars', () {
      expect(MirrorConfig(timezone: 'A' * 64).validate(), isNotNull);
      expect(MirrorConfig(timezone: 'A' * 63).validate(), isNull);
    });

    test('rejects latitudes outside [-90, 90]', () {
      expect(const MirrorConfig(latitude: '91').validate(), isNotNull);
      expect(const MirrorConfig(latitude: '-91').validate(), isNotNull);
      expect(const MirrorConfig(latitude: '90').validate(), isNull);
      expect(const MirrorConfig(latitude: '-90').validate(), isNull);
      expect(const MirrorConfig(latitude: '0').validate(), isNull);
    });

    test('rejects longitudes outside [-180, 180]', () {
      expect(const MirrorConfig(longitude: '181').validate(), isNotNull);
      expect(const MirrorConfig(longitude: '-181').validate(), isNotNull);
      expect(const MirrorConfig(longitude: '180').validate(), isNull);
      expect(const MirrorConfig(longitude: '-180').validate(), isNull);
    });

    test('rejects non-numeric coordinates', () {
      expect(const MirrorConfig(latitude: 'abc').validate(), isNotNull);
      expect(const MirrorConfig(longitude: '12,3').validate(), isNotNull);
    });

    test('rejects a place longer than 23 chars', () {
      expect(MirrorConfig(place: 'X' * 24).validate(), isNotNull);
      expect(MirrorConfig(place: 'X' * 23).validate(), isNull);
    });

    test('only the offending field is reported', () {
      const cfg = MirrorConfig(timezone: 'UTC0', longitude: '999');
      expect(cfg.validate(), contains('Longitude'));
    });
  });

  group('MirrorConfig JSON', () {
    test('toJson drops absent fields', () {
      final json = const MirrorConfig(latitude: '51.5').toJson();
      expect(json, <String, dynamic>{'latitude': '51.5'});
    });

    test('toJson keeps all four when present', () {
      final json = const MirrorConfig(
        timezone: 'UTC0',
        latitude: '1',
        longitude: '2',
        place: 'p',
      ).toJson();
      expect(json.keys, hasLength(4));
    });

    test('fromJson returns null when no known field is present', () {
      expect(MirrorConfig.fromJson(<String, dynamic>{'other': 1}), isNull);
      expect(MirrorConfig.fromJson(const <String, dynamic>{}), isNull);
    });

    test('fromJson round-trips a toJson object', () {
      const cfg = MirrorConfig(
        timezone: 'UTC0',
        latitude: '51.5074',
        longitude: '-0.1278',
        place: 'Home',
      );
      final back = MirrorConfig.fromJson(cfg.toJson());
      expect(back, isNotNull);
      expect(back!.timezone, 'UTC0');
      expect(back.latitude, '51.5074');
      expect(back.longitude, '-0.1278');
      expect(back.place, 'Home');
    });

    test('fromJson ignores non-string values', () {
      final cfg = MirrorConfig.fromJson(<String, dynamic>{
        'timezone': 42,
        'latitude': '51.5',
      });
      expect(cfg, isNotNull);
      expect(cfg!.timezone, isNull);
      expect(cfg.latitude, '51.5');
    });
  });

  group('timezone presets', () {
    test('are all well-formed', () {
      expect(kTimezonePresets, isNotEmpty);
      for (final p in kTimezonePresets) {
        expect(p.label, isNotEmpty);
        expect(p.tz, isNotEmpty);
      }
    });

    test('have unique labels', () {
      final labels = kTimezonePresets.map((p) => p.label).toSet();
      expect(labels, hasLength(kTimezonePresets.length));
    });

    test('cover the firmware Kconfig examples', () {
      final tzs = kTimezonePresets.map((p) => p.tz).toList();
      expect(tzs, contains('UTC0'));
      expect(tzs, contains('GMT0BST,M3.5.0/1,M10.5.0'));
      expect(tzs, contains('EST5EDT,M3.2.0,M11.1.0'));
    });
  });
}
