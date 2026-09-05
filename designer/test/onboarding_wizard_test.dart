// The guided setup walkthrough, driven end to end with fake device seams:
// WiFi connect, imprecise location (ZIP → candidate list, raw coordinates,
// map pin), and the display step's prefills (timezone from the chosen zone,
// Fahrenheit from the country). No BLE and no network in any of it, which is
// the whole point of the injected seams on MirrorOnboardingPage.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
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

  testWidgets('full walkthrough: WiFi, ZIP search, derived display step',
      (tester) async {
    WifiConfig? pushedWifi;
    Map<String, dynamic>? pushedConfig;

    await open(
      tester,
      MirrorOnboardingPage(
        includeWifi: true,
        wifiScan: () async => const <BleWifiNetwork>[
          BleWifiNetwork(ssid: 'CafeNet', rssi: -50, open: false),
        ],
        wifiPush: (w) async {
          pushedWifi = w;
          return 'wifi ok';
        },
        wifiAwait: () async =>
            const BleWifiResult(connected: true, detail: '192.168.1.9'),
        geocode: (q) async => _parse(_zipJson),
        configPush: (json) async {
          pushedConfig = json;
          return 'config ok';
        },
      ),
    );

    // Step 1: pick the scanned network, type the password, connect.
    expect(find.text('Scanning for networks...'), findsNothing);
    await tester.tap(find.text('CafeNet'));
    await tester.pump();
    await tester.enterText(
      find.ancestor(
          of: find.text('Password'), matching: find.byType(TextField)),
      'hunter2',
    );
    await tester.pump();
    await tester.tap(primary('Connect'));
    await tester.pump();
    await tester.pump();
    expect(pushedWifi, isNotNull);
    expect(pushedWifi!.ssid, 'CafeNet');
    expect(find.text('Connected to CafeNet'), findsOne);
    // The button flipped to Continue; the wizard does not auto-page.
    await tester.tap(primary('Continue'));
    await tester.pump();
    await tester.pump();

    // Step 2: the ZIP resolves to a candidate list; pick the first hit.
    expect(find.textContaining('Weather is fetched for a point'), findsOne);
    await tester.enterText(queryField(), '94105');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Find'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Did you mean:'), findsOne);
    await tester.tap(find.text('San Francisco, California, United States'));
    await tester.pump();
    // The place label prefills from the selection.
    expect(
      tester
          .widget<TextField>(find.ancestor(
              of: find.text('Place name'), matching: find.byType(TextField)))
          .controller!
          .text,
      'San Francisco',
    );
    await tester.tap(primary('Continue'));
    await tester.pump();
    await tester.pump();

    // Step 3: timezone prefilled from America/Los_Angeles, Fahrenheit
    // prefilled from the US; the owner switches to a 24-hour clock.
    expect(find.text('Los Angeles'), findsOne);
    await tester.tap(find.text('24-hour clock'));
    await tester.pump();
    await tester.tap(primary('Finish setup'));
    await tester.pumpAndSettle();

    expect(pushedConfig, isNotNull);
    expect(pushedConfig!['timezone'], 'PST8PDT,M3.2.0,M11.1.0');
    expect(pushedConfig!['latitude'], '37.77493');
    expect(pushedConfig!['longitude'], '-122.41942');
    expect(pushedConfig!['place'], 'San Francisco');
    expect(pushedConfig!['clock12h'], isFalse);
    expect(pushedConfig!['temp_unit'], 'F');
    expect(find.text('Set up your mirror'), findsNothing); // popped
  });

  testWidgets('map pin sets coordinates and the default label', (tester) async {
    Map<String, dynamic>? pushedConfig;
    await open(
      tester,
      MirrorOnboardingPage(
        includeWifi: false,
        geocode: (q) async => fail('search must not run when pinning'),
        pickOnMap: (context, {initial}) async =>
            const LatLng(52.52437, 13.41053),
        configPush: (json) async {
          pushedConfig = json;
          return 'config ok';
        },
      ),
    );

    await tester.tap(find.text('Pick on a map instead'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Pinned location'), findsOne);
    await tester.tap(primary('Continue'));
    await tester.pump();
    await tester.pump();

    await tester.tap(primary('Finish setup'));
    await tester.pumpAndSettle();
    expect(pushedConfig!['latitude'], '52.52437');
    expect(pushedConfig!['longitude'], '13.41053');
    expect(pushedConfig!['place'], 'Home');
    // An unlocatable pin derives no timezone and keeps the factory unit.
    expect(pushedConfig!.containsKey('timezone'), isFalse);
    expect(pushedConfig!['temp_unit'], 'F');
  });

  testWidgets('raw coordinates are accepted without the geocoder',
      (tester) async {
    Map<String, dynamic>? pushedConfig;
    await open(
      tester,
      MirrorOnboardingPage(
        includeWifi: false,
        geocode: (q) async => fail('a coordinate pair must not search'),
        configPush: (json) async {
          pushedConfig = json;
          return 'config ok';
        },
      ),
    );

    await tester.enterText(queryField(), '48.8584, 2.2945');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Find'));
    await tester.pump();
    await tester.pump();
    // The single hit selects itself (card title and place label share the
    // name here); Continue is now enabled.
    expect(find.text('Pinned location'), findsWidgets);
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
        configPush: (json) async => 'unused',
      ),
    );
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
        configPush: (json) async {
          pushedConfig = json;
          return 'config ok';
        },
      ),
    );
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
