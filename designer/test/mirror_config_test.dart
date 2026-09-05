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
    test('accepts a personal device name', () {
      expect(const MirrorConfig(name: 'Kitchen').validate(), isNull);
      expect(MirrorConfig(name: 'X' * 24).validate(), isNull);
    });

    test('rejects an empty or whitespace-only device name', () {
      expect(const MirrorConfig(name: '').validate(), isNotNull);
      expect(const MirrorConfig(name: '   ').validate(),
          contains('must not be empty'));
    });

    test('rejects a device name longer than 24 chars', () {
      expect(MirrorConfig(name: 'X' * 25).validate(), isNotNull);
    });

    test('rejects a device name with non-printable characters', () {
      // The firmware's JSON decoder lands non-ASCII bytes on '?'; the phone
      // refuses the rename rather than advertise a mangled name.
      expect(const MirrorConfig(name: 'Küche').validate(), contains('printable'));
      expect(const MirrorConfig(name: 'a\nb').validate(), contains('printable'));
    });


    test('rejects an empty timezone', () {
      expect(const MirrorConfig(timezone: '').validate(), isNotNull);
    });

    test('rejects a timezone longer than 63 chars', () {
      // EST5 plus a long DST name keeps the 63-char string POSIX-shaped, so
      // only the length is being tested.
      final at63 = 'EST5${'A' * 59}';
      expect(at63.length, 63);
      expect(MirrorConfig(timezone: at63).validate(), isNull);
      expect(MirrorConfig(timezone: 'EST5${'A' * 60}').validate(), isNotNull);
    });

    test('rejects an IANA timezone name', () {
      // newlib only parses POSIX TZ strings; an IANA name would be accepted
      // by the length check and silently degrade the clock to UTC.
      expect(
          const MirrorConfig(timezone: 'America/New_York').validate(),
          contains('POSIX TZ'));
      expect(
          const MirrorConfig(timezone: 'Europe/Berlin').validate(),
          contains('POSIX TZ'));
    });

    test('rejects a timezone with no UTC offset', () {
      expect(const MirrorConfig(timezone: 'UTC').validate(), contains('POSIX'));
      expect(const MirrorConfig(timezone: 'GMT').validate(), contains('POSIX'));
    });

    test('rejects a timezone with junk characters', () {
      expect(const MirrorConfig(timezone: 'UTC0!').validate(), contains('POSIX'));
      expect(
          const MirrorConfig(timezone: 'EST5EDT,M3.2.0@M11.1.0').validate(),
          contains('POSIX'));
    });

    test('accepts POSIX-shaped custom timezones', () {
      expect(const MirrorConfig(timezone: 'UTC0').validate(), isNull);
      expect(const MirrorConfig(timezone: 'MST7').validate(), isNull);
      expect(const MirrorConfig(timezone: 'EST5:30EDT').validate(), isNull);
      expect(
          const MirrorConfig(timezone: 'GMT0BST,M3.5.0/1:30,M10.5.0').validate(),
          isNull);
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

    test('rejects brightness outside [0, 255]', () {
      expect(const MirrorConfig(brightness: -1).validate(), isNotNull);
      expect(const MirrorConfig(brightness: 256).validate(), isNotNull);
      expect(const MirrorConfig(brightness: 0).validate(), isNull);
      expect(const MirrorConfig(brightness: 255).validate(), isNull);
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

    test('fromJson reads a manual brightness', () {
      final cfg = MirrorConfig.fromJson(<String, dynamic>{'brightness': 200});
      expect(cfg, isNotNull);
      expect(cfg!.brightness, 200);
    });

    test('fromJson maps the device auto value (-1) to null', () {
      // A mirror reporting "auto" has no override to push back; sending -1
      // back would be rejected by the firmware, so it reads as absent.
      expect(MirrorConfig.fromJson(<String, dynamic>{'brightness': -1}), isNull);
      final mixed = MirrorConfig.fromJson(<String, dynamic>{
        'timezone': 'UTC0',
        'brightness': -1,
      });
      expect(mixed, isNotNull);
      expect(mixed!.timezone, 'UTC0');
      expect(mixed.brightness, isNull);
    });

    test('fromJson ignores non-integer brightness', () {
      expect(MirrorConfig.fromJson(<String, dynamic>{'brightness': 200.5}),
          isNull);
      expect(MirrorConfig.fromJson(<String, dynamic>{'brightness': '200'}),
          isNull);
    });

    test('toJson omits brightness when null (unchanged on push)', () {
      final json = const MirrorConfig().toJson();
      expect(json.containsKey('brightness'), isFalse);
    });

    test('fromJson round-trips brightness', () {
      const cfg = MirrorConfig(brightness: 100);
      final back = MirrorConfig.fromJson(cfg.toJson());
      expect(back, isNotNull);
      expect(back!.brightness, 100);
    });

    test('toJson writes clock12h and temp_unit for the display settings', () {
      final json = const MirrorConfig(clock12h: true, tempF: true).toJson();
      expect(json, <String, dynamic>{'clock12h': true, 'temp_unit': 'F'});
      expect(const MirrorConfig(clock12h: false, tempF: false).toJson(),
          <String, dynamic>{'clock12h': false, 'temp_unit': 'C'});
    });

    test('toJson omits the display settings when null (unchanged on push)',
        () {
      final json = const MirrorConfig().toJson();
      expect(json.containsKey('clock12h'), isFalse);
      expect(json.containsKey('temp_unit'), isFalse);
    });

    test('fromJson reads the display settings', () {
      final f = MirrorConfig.fromJson(
          <String, dynamic>{'clock12h': true, 'temp_unit': 'F'});
      expect(f, isNotNull);
      expect(f!.clock12h, isTrue);
      expect(f.tempF, isTrue);

      final c = MirrorConfig.fromJson(
          <String, dynamic>{'clock12h': false, 'temp_unit': 'C'});
      expect(c, isNotNull);
      expect(c!.clock12h, isFalse);
      expect(c.tempF, isFalse);
    });

    test('fromJson ignores a non-boolean clock12h and unknown temp units', () {
      final cfg = MirrorConfig.fromJson(<String, dynamic>{
        'clock12h': 'yes',
        'temp_unit': 'K',
      });
      // Neither field is present once the bad values are filtered, so the
      // object itself reads as absent, exactly like the firmware rejecting
      // them on push.
      expect(cfg, isNull);
    });

    test('fromJson round-trips the display settings', () {
      const cfg = MirrorConfig(clock12h: false, tempF: true);
      final back = MirrorConfig.fromJson(cfg.toJson());
      expect(back, isNotNull);
      expect(back!.clock12h, isFalse);
      expect(back.tempF, isTrue);
    });

    test('a display setting alone is a valid config', () {
      expect(const MirrorConfig(clock12h: true).validate(), isNull);
      expect(const MirrorConfig(tempF: false).validate(), isNull);
    });
  });

  group('timezone presets', () {
    test('are all well-formed', () {
      expect(kTimezonePresets, isNotEmpty);
      for (final p in kTimezonePresets) {
        expect(p.label, isNotEmpty);
        expect(p.tz, isNotEmpty);
        // Every preset must survive the POSIX TZ check or the firmware would
        // reject it on push.
        expect(MirrorConfig(timezone: p.tz).validate(), isNull,
            reason: 'preset ${p.label} fails validation');
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

  group('MirrorConfig name JSON', () {
    test('toJson carries the name only when set', () {
      expect(const MirrorConfig().toJson().containsKey('name'), isFalse);
      expect(const MirrorConfig(name: 'Hallway').toJson()['name'], 'Hallway');
    });

    test('fromJson reads a name-only object', () {
      final cfg = MirrorConfig.fromJson(<String, dynamic>{'name': 'Hallway'});
      expect(cfg, isNotNull);
      expect(cfg!.name, 'Hallway');
    });

    test('fromJson round-trips the name with the other fields', () {
      const cfg = MirrorConfig(name: 'Hallway', timezone: 'UTC0');
      final back = MirrorConfig.fromJson(cfg.toJson());
      expect(back, isNotNull);
      expect(back!.name, 'Hallway');
      expect(back.timezone, 'UTC0');
    });

    test('fromJson ignores a non-string name', () {
      expect(MirrorConfig.fromJson(<String, dynamic>{'name': 7}), isNull);
    });
  });
}
