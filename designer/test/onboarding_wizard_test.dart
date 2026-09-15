// The guided setup walkthrough, driven end to end with fake device seams:
// the Name step (keep the generated identity, rename, reject junk), the WiFi
// step (a confirmed join continues by itself; a rejection or an unanswered
// push stays on the step and offers the list again), the three location
// sources (ZIP → candidate list, GPS, map pin, raw coordinates) and the
// display step's prefills (timezone from whatever the source said about the
// zone, Fahrenheit from the country). No BLE, no network and no device
// position in any of it, which is the whole point of the injected seams on
// MirrorOnboardingPage.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mirror_designer/src/services/device_location.dart';
import 'package:mirror_designer/src/services/mirror_location.dart';
import 'package:mirror_designer/src/services/mirror_wifi.dart';
import 'package:mirror_designer/src/services/mirror_wifi_status.dart';
import 'package:mirror_designer/src/ui/onboarding_screen.dart';

const String _zipJson = '''
{"results":[
  {"name":"San Francisco","latitude":37.77493,"longitude":-122.41942,
   "country_code":"US","admin1":"California","timezone":"America/Los_Angeles",
   "country":"United States"},
  {"name":"Saint-Maur-des-Fosses","latitude":48.79395,"longitude":2.49323,
   "country_code":"FR","admin1":"Ile-de-France Region",
   "timezone":"Europe/Paris","country":"France"}
]}''';

void main() {
  // Phone-ish surface so the test catches what an owner on a phone would
  // see, including any bottom-bar overflow.
  setUp(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.single;
    view.devicePixelRatio = 3;
    view.physicalSize = const Size(420 * 3, 840 * 3);
    addTearDown(view.resetDevicePixelRatio);
    addTearDown(view.resetPhysicalSize);
  });

  /// Pushes the wizard over a placeholder route so its final pop behaves like
  /// the real screen's Navigator.pop over the Mirror page.
  Future<void> open(WidgetTester tester, MirrorOnboardingPage page) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              Navigator.of(context)
                  .push(MaterialPageRoute<void>(builder: (_) => page));
            });
            return const SizedBox.shrink();
          },
        ),
      ),
    ));
    await tester.pumpAndSettle(); // push animation
  }

  /// The wizard's primary button (Connect / Continue / Finish setup).
  Finder primary(String label) => find.widgetWithText(FilledButton, label);

  Finder queryField() => find.widgetWithText(TextField, 'ZIP or city name');

  Finder nameField() => find.widgetWithText(TextField, 'Mirror name');

  /// The picker's place label, as the owner would read it.
  String placeLabel(WidgetTester tester) => tester
      .widget<TextField>(find.ancestor(
          of: find.text('Place name'), matching: find.byType(TextField)))
      .controller!
      .text;

  /// Leave the Name step: the one decision every walkthrough starts with.
  Future<void> passName(WidgetTester tester) async {
    await tester.tap(primary('Continue'));
    await tester.pump();
    await tester.pump();
  }

  /// Pick a scanned network and type a password, leaving the draft with the
  /// wizard.
  Future<void> pickNetwork(WidgetTester tester, String ssid) async {
    await tester.tap(find.widgetWithText(ListTile, ssid));
    await tester.pump();
    await tester.enterText(
      find.ancestor(of: find.text('Password'), matching: find.byType(TextField)),
      'hunter2',
    );
    await tester.pump();
  }

  testWidgets('full walkthrough: WiFi, ZIP search, derived display step',
      (tester) async {
    WifiConfig? pushedWifi;
    Map<String, dynamic>? pushedConfig;

    await open(
      tester,
      MirrorOnboardingPage(
        includeWifi: true,
        wifiScan: () async => const <BleWifiNetwork>[
          BleWifiNetwork(
              ssid: 'CafeNet', rssi: -50, security: WifiSecurity.secured),
        ],
        wifiPush: (w) async {
          pushedWifi = w;
          return 'wifi ok';
        },
        wifiAwait: () async =>
            const BleWifiResult(connected: true, detail: '192.168.1.9'),
        geocode: (q) async => _parse(_zipJson),
        // The geocoder's hit carries its own zone; asking again would be a
        // second provider round trip for nothing.
        timezoneLookup: (lat, lon) async =>
            fail('the ZIP hit already knows its timezone'),
        configPush: (json) async {
          pushedConfig = json;
          return 'config ok';
        },
      ),
    );

    // Step 1: name the mirror, replacing the generated identity that is
    // pushed with the rest of the config at the end.
    await tester.enterText(nameField(), 'Kitchen');
    await tester.pump();
    await passName(tester);

    // Step 2: pick the scanned network, type the password, connect.
    expect(find.text('Scanning for networks...'), findsNothing);
    await pickNetwork(tester, 'CafeNet');
    await tester.tap(primary('Connect'));
    await tester.pump();
    await tester.pump();
    expect(pushedWifi, isNotNull);
    expect(pushedWifi!.ssid, 'CafeNet');
    // A confirmed join continues by itself: no second tap, and no note the
    // owner has nothing to do about.
    expect(find.textContaining('Weather is fetched for a point'), findsOne);

    // Step 3: the ZIP resolves to a candidate list; pick the first hit.
    await tester.enterText(queryField(), '94105');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Find'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Did you mean:'), findsOne);
    await tester.tap(find.text('San Francisco, California, United States'));
    await tester.pump();
    // The card shows what will be pushed; the place label prefills from the
    // selection.
    expect(find.text('37.77493, -122.41942'), findsOne);
    expect(placeLabel(tester), 'San Francisco');
    await tester.tap(primary('Continue'));
    await tester.pump();
    await tester.pump();

    // Step 4: timezone prefilled from America/Los_Angeles, Fahrenheit
    // prefilled from the US; the owner switches to a 24-hour clock.
    expect(find.text('Los Angeles'), findsOne);
    await tester.tap(find.text('24-hour clock'));
    await tester.pump();
    await tester.tap(primary('Finish setup'));
    await tester.pumpAndSettle();

    expect(pushedConfig, isNotNull);
    expect(pushedConfig!['name'], 'Kitchen');
    expect(pushedConfig!['timezone'], 'PST8PDT,M3.2.0,M11.1.0');
    expect(pushedConfig!['latitude'], '37.77493');
    expect(pushedConfig!['longitude'], '-122.41942');
    expect(pushedConfig!['place'], 'San Francisco');
    expect(pushedConfig!['clock12h'], isFalse);
    expect(pushedConfig!['temp_unit'], 'F');
    expect(find.text('Set up your mirror'), findsNothing); // popped
  });

  testWidgets('a map pin carries coordinates, the default label and a zone',
      (tester) async {
    Map<String, dynamic>? pushedConfig;
    await open(
      tester,
      MirrorOnboardingPage(
        includeWifi: false,
        geocode: (q) async => fail('search must not run when pinning'),
        timezoneLookup: (lat, lon) async {
          // The pin is the only thing the reverse lookup can be asked about.
          expect(lat, closeTo(52.52437, 1e-9));
          expect(lon, closeTo(13.41053, 1e-9));
          return 'Europe/Berlin';
        },
        pickOnMap: (context, {initial}) async =>
            const LatLng(52.52437, 13.41053),
        configPush: (json) async {
          pushedConfig = json;
          return 'config ok';
        },
      ),
    );
    await passName(tester);

    await tester.tap(find.text('Map'));
    await tester.pump();
    await tester.tap(find.text('Pin it on a map'));
    await tester.pump();
    await tester.pump();
    expect(find.text('52.52437, 13.41053'), findsOne);
    expect(placeLabel(tester), 'Home');
    await tester.tap(primary('Continue'));
    await tester.pump();
    await tester.pump();

    // A pin says nothing about its own zone, so the lookup's answer is what
    // prefills the display step.
    expect(find.text('Berlin'), findsOne);
    await tester.tap(primary('Finish setup'));
    await tester.pumpAndSettle();
    expect(pushedConfig!['latitude'], '52.52437');
    expect(pushedConfig!['longitude'], '13.41053');
    expect(pushedConfig!['place'], 'Home');
    expect(pushedConfig!['timezone'], 'CET-1CEST,M3.5.0,M10.5.0/3');
    expect(pushedConfig!['temp_unit'], 'F');
  });

  testWidgets('GPS fills the coordinates and the default label',
      (tester) async {
    Map<String, dynamic>? pushedConfig;
    await open(
      tester,
      MirrorOnboardingPage(
        includeWifi: false,
        geocode: (q) async => fail('search must not run for GPS'),
        deviceLocation: () async => const LatLng(48.8584, 2.2945),
        timezoneLookup: (lat, lon) async => 'Europe/Paris',
        configPush: (json) async {
          pushedConfig = json;
          return 'config ok';
        },
      ),
    );
    await passName(tester);

    await tester.tap(find.text('GPS'));
    await tester.pump();
    await tester.tap(find.text('Use my location'));
    await tester.pump();
    await tester.pump();

    expect(find.text('48.85840, 2.29450'), findsOne);
    expect(placeLabel(tester), 'Home');
    // Nothing pages on its own here: the owner leaves when they are ready.
    expect(find.textContaining('Weather is fetched for a point'), findsOne);

    await tester.tap(primary('Continue'));
    await tester.pump();
    await tester.pump();
    await tester.tap(primary('Finish setup'));
    await tester.pumpAndSettle();
    expect(pushedConfig!['latitude'], '48.85840');
    expect(pushedConfig!['longitude'], '2.29450');
    expect(pushedConfig!['place'], 'Home');
    expect(pushedConfig!['timezone'], 'CET-1CEST,M3.5.0,M10.5.0/3');
  });

  testWidgets('a refused position is reported and blocks the step',
      (tester) async {
    await open(
      tester,
      MirrorOnboardingPage(
        includeWifi: false,
        geocode: (q) async => fail('search must not run for GPS'),
        deviceLocation: () async => throw const DeviceLocationException(
            'Location services are turned off on this device.'),
        timezoneLookup: (lat, lon) async => fail('no fix, no lookup'),
        configPush: (json) async => 'unused',
      ),
    );
    await passName(tester);

    await tester.tap(find.text('GPS'));
    await tester.pump();
    await tester.tap(find.text('Use my location'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Location services are turned off on this device.'),
        findsOne);
    expect(tester.widget<FilledButton>(primary('Continue')).onPressed, isNull);
  });

  testWidgets('an unmappable zone is reported on the display step',
      (tester) async {
    Map<String, dynamic>? pushedConfig;
    await open(
      tester,
      MirrorOnboardingPage(
        includeWifi: false,
        geocode: (q) async => fail('search must not run for GPS'),
        deviceLocation: () async => const LatLng(48.8584, 2.2945),
        timezoneLookup: (lat, lon) async => null,
        configPush: (json) async {
          pushedConfig = json;
          return 'config ok';
        },
      ),
    );
    await passName(tester);

    await tester.tap(find.text('GPS'));
    await tester.pump();
    await tester.tap(find.text('Use my location'));
    await tester.pump();
    await tester.pump();

    expect(
      find.textContaining("Could not determine this spot's timezone"),
      findsOne,
    );
    await tester.tap(primary('Continue'));
    await tester.pump();
    await tester.pump();

    // The display step says the same thing where the choice is actually made,
    // instead of leaving the owner with a silent UTC clock.
    expect(
      find.textContaining('Could not set the timezone from this location'),
      findsOne,
    );
    await tester.tap(primary('Finish setup'));
    await tester.pumpAndSettle();
    expect(pushedConfig!.containsKey('timezone'), isFalse);
    expect(pushedConfig!['latitude'], '48.85840');
  });

  testWidgets('raw coordinates are accepted without the geocoder',
      (tester) async {
    Map<String, dynamic>? pushedConfig;
    await open(
      tester,
      MirrorOnboardingPage(
        includeWifi: false,
        geocode: (q) async => fail('a coordinate pair must not search'),
        timezoneLookup: (lat, lon) async => null,
        configPush: (json) async {
          pushedConfig = json;
          return 'config ok';
        },
      ),
    );
    await passName(tester);

    await tester.enterText(queryField(), '48.8584, 2.2945');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Find'));
    await tester.pump();
    await tester.pump();
    // The pair selects itself (no candidate list) and labels like a pin:
    // there is no place name to be had from two numbers.
    expect(find.text('48.85840, 2.29450'), findsOne);
    expect(placeLabel(tester), 'Pinned location');
    await tester.tap(primary('Continue'));
    await tester.pump();
    await tester.pump();
    await tester.tap(primary('Finish setup'));
    await tester.pumpAndSettle();
    expect(pushedConfig!['latitude'], '48.85840');
    expect(pushedConfig!['longitude'], '2.29450');
  });

  testWidgets('no hits leaves Continue disabled and says so', (tester) async {
    await open(
      tester,
      MirrorOnboardingPage(
        includeWifi: false,
        geocode: (q) async => const <GeocodeResult>[],
        timezoneLookup: (lat, lon) async => fail('no location chosen'),
        configPush: (json) async => 'unused',
      ),
    );
    await passName(tester);

    await tester.enterText(queryField(), 'Atlantis');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Find'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Nothing found for "Atlantis".'), findsOne);
    expect(tester.widget<FilledButton>(primary('Continue')).onPressed, isNull);
  });

  testWidgets('skipping location pushes only the display choices',
      (tester) async {
    Map<String, dynamic>? pushedConfig;
    await open(
      tester,
      MirrorOnboardingPage(
        includeWifi: false,
        geocode: (q) async => const <GeocodeResult>[],
        timezoneLookup: (lat, lon) async => fail('no location chosen'),
        configPush: (json) async {
          pushedConfig = json;
          return 'config ok';
        },
      ),
    );
    await passName(tester);

    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Celsius'));
    await tester.pump();
    await tester.tap(primary('Finish setup'));
    await tester.pumpAndSettle();
    expect(pushedConfig, {
      'clock12h': true,
      'temp_unit': 'C',
    });
  });
  testWidgets('the prefilled name, kept as-is, pushes no rename',
      (tester) async {
    Map<String, dynamic>? pushedConfig;
    await open(
      tester,
      MirrorOnboardingPage(
        includeWifi: false,
        currentName: 'Dashing Dolphin',
        geocode: (q) async => fail('search must not run here'),
        timezoneLookup: (lat, lon) async => null,
        configPush: (json) async {
          pushedConfig = json;
          return 'config ok';
        },
      ),
    );

    // The field starts at the identity the device advertised. Leaving it
    // untouched must not send a name at all: "unchanged" in the config
    // JSON, not a rename to the same string.
    expect(
      tester.widget<TextField>(nameField()).controller!.text,
      'Dashing Dolphin',
    );
    await passName(tester);
    await tester.enterText(queryField(), '48.8584, 2.2945');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Find'));
    await tester.pump();
    await tester.pump();
    await tester.tap(primary('Continue'));
    await tester.pump();
    await tester.pump();
    await tester.tap(primary('Finish setup'));
    await tester.pumpAndSettle();
    expect(pushedConfig, isNotNull);
    expect(pushedConfig!.containsKey('name'), isFalse);
  });

  testWidgets('a typed rename rides the config push and the callback',
      (tester) async {
    Map<String, dynamic>? pushedConfig;
    String? renamed;
    await open(
      tester,
      MirrorOnboardingPage(
        includeWifi: false,
        currentName: 'Dashing Dolphin',
        nameApplied: (n) => renamed = n,
        geocode: (q) async => fail('search must not run here'),
        timezoneLookup: (lat, lon) async => null,
        configPush: (json) async {
          pushedConfig = json;
          return 'config ok';
        },
      ),
    );

    await tester.enterText(nameField(), 'Hallway');
    await tester.pump();
    await passName(tester);
    await tester.enterText(queryField(), '48.8584, 2.2945');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Find'));
    await tester.pump();
    await tester.pump();
    await tester.tap(primary('Continue'));
    await tester.pump();
    await tester.pump();
    await tester.tap(primary('Finish setup'));
    await tester.pumpAndSettle();
    expect(pushedConfig!['name'], 'Hallway');
    expect(renamed, 'Hallway');
  });

  testWidgets('a name with non-printable characters stops at the step',
      (tester) async {
    await open(
      tester,
      MirrorOnboardingPage(
        includeWifi: false,
        geocode: (q) async => fail('search must not run here'),
        timezoneLookup: (lat, lon) async => fail('no location chosen'),
        configPush: (json) async => 'never',
      ),
    );

    await tester.enterText(nameField(), 'Küche');
    await tester.pump();
    await tester.tap(primary('Continue'));
    await tester.pump();
    expect(find.text('Name can only contain printable characters'), findsOne);
    // Still on the name step: the wizard did not page.
    expect(nameField(), findsOne);
  });

  testWidgets('a rejected join stays on WiFi and offers the list again',
      (tester) async {
    final pushed = <WifiConfig>[];
    final results = <BleWifiResult>[
      const BleWifiResult(connected: false, detail: 'no such SSID'),
      const BleWifiResult(connected: true, detail: '192.168.1.9'),
    ];
    await open(
      tester,
      MirrorOnboardingPage(
        includeWifi: true,
        wifiScan: () async => const <BleWifiNetwork>[
          BleWifiNetwork(
              ssid: 'CafeNet', rssi: -50, security: WifiSecurity.secured),
          BleWifiNetwork(
              ssid: 'Home WiFi', rssi: -40, security: WifiSecurity.secured),
        ],
        wifiPush: (w) async {
          pushed.add(w);
          return 'wifi ok';
        },
        wifiAwait: () async => results.removeAt(0),
        geocode: (q) async => fail('the walkthrough stops on WiFi'),
        timezoneLookup: (lat, lon) async => fail('no location yet'),
        configPush: (json) async => 'unused',
      ),
    );
    await passName(tester);

    await pickNetwork(tester, 'CafeNet');
    await tester.tap(primary('Connect'));
    await tester.pump();
    await tester.pump();

    expect(
        find.textContaining('Could not join CafeNet: no such SSID'), findsOne);
    // Still on the WiFi step, with the list in front of the owner.
    expect(find.widgetWithText(ListTile, 'Home WiFi'), findsOne);
    expect(find.widgetWithText(FilledButton, 'Connect'), findsOne);

    await tester.tap(find.text('Choose another network'));
    await tester.pump();
    // No draft: the primary waits for a network to be picked again.
    expect(
      tester.widget<FilledButton>(primary('Connect')).onPressed,
      isNull,
    );

    await pickNetwork(tester, 'Home WiFi');
    await tester.tap(primary('Connect'));
    await tester.pump();
    await tester.pump();
    expect(pushed.map((w) => w.ssid).toList(), <String>['CafeNet', 'Home WiFi']);
    // The second join was confirmed, so the walkthrough moved on by itself.
    expect(find.textContaining('Weather is fetched for a point'), findsOne);
  });

  testWidgets('an unanswered push asks the device, then gives up honestly',
      (tester) async {
    await open(
      tester,
      MirrorOnboardingPage(
        includeWifi: true,
        wifiScan: () async => const <BleWifiNetwork>[
          BleWifiNetwork(
              ssid: 'CafeNet', rssi: -50, security: WifiSecurity.secured),
        ],
        wifiPush: (w) async => 'wifi ok',
        wifiAwait: () async => null,
        geocode: (q) async => fail('the walkthrough stops on WiFi'),
        timezoneLookup: (lat, lon) async => fail('no location yet'),
        configPush: (json) async => 'unused',
      ),
    );
    await passName(tester);

    await pickNetwork(tester, 'CafeNet');
    await tester.tap(primary('Connect'));
    await tester.pump();
    await tester.pump();

    // A push that gets no outcome is not a success: the old flow walked on
    // and left a mirror that never joined.
    expect(
      find.textContaining('No answer from CafeNet within 40 seconds'),
      findsOne,
    );
    expect(
      tester.widget<FilledButton>(primary('Connect')).onPressed,
      isNotNull,
    );
  });

  testWidgets('a device on a different network is not a confirmed join',
      (tester) async {
    await open(
      tester,
      MirrorOnboardingPage(
        includeWifi: true,
        wifiScan: () async => const <BleWifiNetwork>[
          BleWifiNetwork(
              ssid: 'CafeNet', rssi: -50, security: WifiSecurity.secured),
        ],
        wifiPush: (w) async => 'wifi ok',
        wifiAwait: () async => null,
        wifiStatus: () async => const BleWifiStatus(
            saved: true,
            ssid: 'OldNet',
            ip: '192.168.1.4',
            connected: true),
        geocode: (q) async => fail('the walkthrough stops on WiFi'),
        timezoneLookup: (lat, lon) async => fail('no location yet'),
        configPush: (json) async => 'unused',
      ),
    );
    await passName(tester);

    await pickNetwork(tester, 'CafeNet');
    await tester.tap(primary('Connect'));
    await tester.pump();
    await tester.pump();

    expect(
      find.textContaining('No answer from CafeNet within 40 seconds'),
      findsOne,
    );
  });

  testWidgets('an unanswered push the device confirms is a success',
      (tester) async {
    await open(
      tester,
      MirrorOnboardingPage(
        includeWifi: true,
        wifiScan: () async => const <BleWifiNetwork>[
          BleWifiNetwork(
              ssid: 'CafeNet', rssi: -50, security: WifiSecurity.secured),
        ],
        wifiPush: (w) async => 'wifi ok',
        wifiAwait: () async => null,
        wifiStatus: () async => const BleWifiStatus(
            saved: true,
            ssid: 'CafeNet',
            ip: '192.168.1.9',
            connected: true),
        geocode: (q) async => fail('the walkthrough stops after WiFi'),
        timezoneLookup: (lat, lon) async => fail('no location yet'),
        configPush: (json) async => 'unused',
      ),
    );
    await passName(tester);

    await pickNetwork(tester, 'CafeNet');
    await tester.tap(primary('Connect'));
    await tester.pump();
    await tester.pump();

    // The device says it is on the network that was asked for: that is the
    // confirmation the async outcome never delivered.
    expect(find.textContaining('Weather is fetched for a point'), findsOne);
  });
}

/// Parse a fixture through the same model the service uses, so the test
/// cannot drift from the field names the API actually ships.
List<GeocodeResult> _parse(String json) {
  final decoded = jsonDecode(json) as Map<String, dynamic>;
  final results = decoded['results'];
  if (results is! List) return const <GeocodeResult>[];
  return results
      .whereType<Map<String, dynamic>>()
      .map(GeocodeResult.fromJson)
      .whereType<GeocodeResult>()
      .toList();
}
