// Geocoding for the setup wizard: the Open-Meteo search response parsing
// (fixture JSON, no network), the raw-coordinate short-circuit, and the
// IANA-to-POSIX / country-to-unit derivations that prefill the display step.
// The derivations matter because the firmware rejects anything but a POSIX
// TZ string, so every mapped value must also pass MirrorConfig.validate().

import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/services/mirror_config.dart';
import 'package:mirror_designer/src/services/mirror_location.dart';

const String _zipFixture = '''
{"results":[
  {"id":5391959,"name":"San Francisco","latitude":37.77493,"longitude":-122.41942,
   "country_code":"US","admin1":"California","timezone":"America/Los_Angeles",
   "country":"United States"},
  {"id":2978179,"name":"Saint-Maur-des-Fosses","latitude":48.79395,"longitude":2.49323,
   "country_code":"FR","admin1":"Ile-de-France Region","timezone":"Europe/Paris",
   "country":"France"}
]}''';

void main() {
  group('parseCoordinateQuery', () {
    test('accepts a comma-separated pair in range', () {
      final r = parseCoordinateQuery('51.5074, -0.1278');
      expect(r, isNotNull);
      expect(r!.latitude, closeTo(51.5074, 1e-9));
      expect(r.longitude, closeTo(-0.1278, 1e-9));
    });

    test('rejects out-of-range and non-numeric text', () {
      expect(parseCoordinateQuery('91, 0'), isNull);
      expect(parseCoordinateQuery('0, 181'), isNull);
      expect(parseCoordinateQuery('Berlin, Germany'), isNull);
      expect(parseCoordinateQuery('51.5'), isNull);
    });
  });

  group('geocodeSearch', () {
    test('raw coordinates short-circuit the network', () async {
      Future<String> boom(Uri _) async =>
          fail('fetcher must not be called for a coordinate pair');
      final res = await geocodeSearch('48.8584, 2.2945', fetcher: boom);
      expect(res, hasLength(1));
      expect(res.single.latitude, closeTo(48.8584, 1e-9));
    });

    test('an empty query never asks the network', () async {
      Future<String> boom(Uri _) async => fail('must not fetch');
      expect(await geocodeSearch('   ', fetcher: boom), isEmpty);
    });

    test('parses hits best-first with their derivation inputs', () async {
      final res =
          await geocodeSearch('94105', fetcher: (u) async => _zipFixture);
      expect(res, hasLength(2));
      final sf = res.first;
      expect(sf.name, 'San Francisco');
      expect(sf.latitude, closeTo(37.77493, 1e-5));
      expect(sf.countryCode, 'US');
      expect(sf.timezone, 'America/Los_Angeles');
      expect(sf.fullLabel, 'San Francisco, California, United States');
      expect(sf.placeDraft, 'San Francisco');
      expect(res[1].fullLabel,
          'Saint-Maur-des-Fosses, Ile-de-France Region, France');
    });

    test('a response with no results list is simply empty', () async {
      final res = await geocodeSearch('zzzz',
          fetcher: (u) async => '{"generationtime_ms":0.1}');
      expect(res, isEmpty);
      final res2 =
          await geocodeSearch('zzzz', fetcher: (u) async => '{"results":[]}');
      expect(res2, isEmpty);
    });

    test('a malformed hit is dropped, not fatal', () async {
      final res = await geocodeSearch('x',
          fetcher: (u) async =>
              '{"results":[{"name":"NoCoords"},{"id":1,"name":"Good",'
              '"latitude":1.0,"longitude":2.0}]}');
      expect(res, hasLength(1));
      expect(res.single.name, 'Good');
    });

    test('transport failures surface as a human message', () async {
      await expectLater(
        geocodeSearch('Berlin',
            fetcher: (u) async => throw Exception('offline')),
        throwsA(isA<Exception>()
            .having((e) => e.toString(), 'message', contains('offline'))),
      );
    });
  });

  group('posixTzForIana', () {
    test('maps known zones to strings the firmware accepts', () {
      // Representative shapes: exact preset, alias preset, 01:00-UTC
      // transitions, colon offsets, positive (west) offsets, no DST.
      const probes = <String, String>{
        'UTC': 'UTC0',
        'America/Los_Angeles': 'PST8PDT,M3.2.0,M11.1.0',
        'Europe/Paris': 'CET-1CEST,M3.5.0,M10.5.0/3',
        'Europe/Lisbon': 'WET0WEST,M3.5.0/1,M10.5.0/1',
        'Asia/Kolkata': 'IST-5:30',
        'America/Caracas': 'VET4:30',
        'America/Sao_Paulo': 'BRT3',
        'Australia/Adelaide': 'ACST-9:30ACDT,M10.1.0,M4.1.0/3',
      };
      for (final e in probes.entries) {
        expect(posixTzForIana(e.key), e.value, reason: e.key);
        final problem = MirrorConfig(timezone: e.value).validate();
        expect(problem, isNull, reason: '${e.key}: ${e.value} rejected');
      }
    });

    test('unknown and null names return null', () {
      expect(posixTzForIana('Mars/Olympus_Mons'), isNull);
      expect(posixTzForIana(null), isNull);
    });
  });

  group('tempFForCountry', () {
    test('Fahrenheit countries preselect F, everything else C', () {
      expect(tempFForCountry('US'), isTrue);
      expect(tempFForCountry('us'), isTrue); // defensive casing
      expect(tempFForCountry('DE'), isFalse);
      expect(tempFForCountry('ZZ'), isFalse);
      expect(tempFForCountry(null), isNull);
    });
  });
}
