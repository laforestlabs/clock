// The Configure dialog's location controls: the setup wizard's own
// LocationPicker, prefilled from the device's stored point, with whatever the
// chosen source can say about the zone riding back out of Save. The dialog is
// the second host of the picker, so these tests are also what keeps the two
// surfaces from drifting apart.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mirror_designer/src/services/mirror_config.dart';
import 'package:mirror_designer/src/ui/mirror_screen.dart';

void main() {
  // Phone-ish surface, like the wizard's own tests: the dialog is opened on a
  // phone, and the picker plus the unit switches have to fit.
  setUp(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.single;
    view.devicePixelRatio = 3;
    view.physicalSize = const Size(420 * 3, 840 * 3);
    addTearDown(view.resetDevicePixelRatio);
    addTearDown(view.resetPhysicalSize);
  });

  /// Open the dialog over a placeholder page; the returned getter reads what
  /// Save handed back, after the caller taps it.
  Future<MirrorConfig? Function()> openDialog(
    WidgetTester tester, {
    required MirrorConfig? initial,
    Future<LatLng> Function()? deviceLocation,
    Future<String?> Function(double latitude, double longitude)?
        timezoneLookup,
  }) async {
    MirrorConfig? saved;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                saved = await showDialog<MirrorConfig>(
                  context: context,
                  builder: (_) => MirrorConfigDialog(
                    initial: initial,
                    geocode: (q) async => fail('the ZIP path is not under test'),
                    timezoneLookup: timezoneLookup ??
                        (lat, lon) async => fail('no lookup expected here'),
                    deviceLocation: deviceLocation ??
                        () async => fail('no position expected here'),
                    pickOnMap: (context, {initial}) async =>
                        fail('the map is not under test'),
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    return () => saved;
  }

  /// The place label as the owner would read it.
  String placeLabel(WidgetTester tester) => tester
      .widget<TextField>(find.ancestor(
          of: find.text('Place name'), matching: find.byType(TextField)))
      .controller!
      .text;

  /// The zone the timezone dropdown currently holds, or null for none.
  String? chosenTimezone(WidgetTester tester) => tester
      .widget<DropdownButton<String?>>(find.byType(DropdownButton<String?>))
      .value;

  testWidgets('prefills the stored point, then saves the GPS fix and its zone',
      (tester) async {
    final asked = <String>[];
    final saved = await openDialog(
      tester,
      initial: const MirrorConfig(
        timezone: 'CET-1CEST,M3.5.0,M10.5.0/3',
        latitude: '52.52000',
        longitude: '13.40500',
        place: 'Berlin',
      ),
      deviceLocation: () async => const LatLng(48.8584, 2.2945),
      timezoneLookup: (lat, lon) async {
        asked.add('$lat,$lon');
        // A zone the stored preset does not already hold, so the assertion
        // below cannot pass on the device's own value.
        return 'America/Los_Angeles';
      },
    );

    // What the device has, ready to be edited.
    expect(find.text('52.52000, 13.40500'), findsOne);
    expect(placeLabel(tester), 'Berlin');
    expect(chosenTimezone(tester), 'CET-1CEST,M3.5.0,M10.5.0/3');

    await tester.tap(find.text('GPS'));
    await tester.pump();
    await tester.tap(find.text('Use my location'));
    await tester.pump();
    await tester.pump();

    expect(asked, <String>['48.8584,2.2945']);
    expect(find.text('48.85840, 2.29450'), findsOne);
    expect(placeLabel(tester), 'Home');
    // The reverse lookup's answer is what the control now holds, and the
    // custom-string field stays away because the zone mapped to a preset.
    expect(chosenTimezone(tester), 'PST8PDT,M3.2.0,M11.1.0');
    expect(find.widgetWithText(TextField, 'POSIX timezone string'), findsNothing);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final cfg = saved()!;
    expect(cfg.latitude, '48.85840');
    expect(cfg.longitude, '2.29450');
    expect(cfg.timezone, 'PST8PDT,M3.2.0,M11.1.0');
    expect(cfg.place, 'Home');
  });

  testWidgets('an untouched dialog pushes no location at all', (tester) async {
    final saved = await openDialog(tester, initial: null);
    expect(find.text('Place name'), findsNothing);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final cfg = saved()!;
    // A partial push: the firmware applies what it is given, so a device with
    // no stored point keeps whatever it had.
    expect(cfg.latitude, isNull);
    expect(cfg.longitude, isNull);
    expect(cfg.place, isNull);
    expect(cfg.timezone, isNull);
  });

  testWidgets('a stored point that is not a point prefills nothing',
      (tester) async {
    final saved = await openDialog(
      tester,
      initial: const MirrorConfig(
        latitude: 'north of here',
        longitude: '13.40500',
        place: 'Berlin',
      ),
    );

    // Half a point is no point: no card, no label to overwrite.
    expect(find.text('Place name'), findsNothing);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final cfg = saved()!;
    expect(cfg.latitude, isNull);
    expect(cfg.longitude, isNull);
    expect(cfg.place, isNull);
  });
}
