// The wizard's map pin page, rendered for real (unlike the wizard tests,
// which stub the picker). flutter_map resolves a single tap through a
// double-tap timeout, so the test advances fake time before asserting.
// Tile network errors are silenced by the provider; the pin logic is what
// this pins down.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mirror_designer/src/ui/place_pin_page.dart';

void main() {
  testWidgets('a tap pins the spot and Use this spot returns it',
      (tester) async {
    LatLng? result;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) {
            return TextButton(
              onPressed: () async {
                result = await showPlacePinPicker(context);
              },
              child: const Text('open'),
            );
          },
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // route transition

    expect(find.textContaining('Tap the map'), findsOne);

    await tester.tapAt(const Offset(400, 300));
    // Past flutter_map's double-tap window so the single tap registers.
    await tester.pump(const Duration(milliseconds: 500));

    final btn = find.widgetWithText(FilledButton, 'Use this spot');
    expect(tester.widget<FilledButton>(btn).onPressed, isNotNull);
    await tester.tap(btn);
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    // The map opened world-wide (zoom 2 centred on 20N, 0): a centre tap is
    // near there, not an arbitrary screen mapping.
    expect(result!.latitude, closeTo(18.0, 5));
    expect(result!.longitude.abs(), lessThan(5));
  });

  testWidgets('cancelling returns nothing', (tester) async {
    LatLng? result = const LatLng(1, 1);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) {
            return TextButton(
              onPressed: () async {
                result = await showPlacePinPicker(context);
              },
              child: const Text('open'),
            );
          },
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}
