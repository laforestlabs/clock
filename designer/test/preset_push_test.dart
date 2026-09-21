// Picking a stock layout, from the picker the user actually taps.
//
// A pick is a live preview: with a mirror connected the layout goes to it in
// the same tap, so the panel changes as the user clicks through the layouts
// instead of after a separate trip to the Mirror screen. This drives the real
// workspace - the real chips, the real asset text, the real queue - against a
// session that records what it was handed, so what is asserted is what the
// mirror receives and what the workspace says about it.
//
// One test, run as one flow: no mirror, then a mirror, then a mirror that
// refuses - because the picker's stock list comes from the asset manifest, and
// on this harness that read only lands in the first widget test of a file (a
// later one waits on an asset response the framework no longer delivers, which
// LayoutRepository reports as an empty list and would quietly leave nothing to
// tap). Adding a second widget test here would test an empty picker.
//
// Needs the native core, which is built as part of the app rather than by
// `flutter test`. Build the app once first:
//
//   flutter build linux --debug
//   LD_LIBRARY_PATH=build/linux/x64/debug/bundle/lib flutter test

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mirror_designer/src/engine/engine.dart';
import 'package:mirror_designer/src/services/mirror_ble.dart';
import 'package:mirror_designer/src/services/mirror_connection.dart';
import 'package:mirror_designer/src/ui/app.dart';

/// A session that records every layout it is handed, and can refuse them the
/// way the mirror does.
class _Session extends Fake implements BleSession {
  final List<String> pushed = <String>[];
  Object? refusal;

  @override
  Future<String> pushLayout(String json) async {
    pushed.add(json);
    if (refusal != null) throw refusal!;
    return 'commit ok 3 widgets';
  }
}

/// The workspace's link, with the session the test puts there. Everything the
/// picker needs from a connected mirror is here: the session it pushes over,
/// and the panel size the presets are filtered by.
class _Connection extends MirrorConnection {
  _Session? live;

  @override
  BleSession? get session => live;

  @override
  MirrorConnectionStatus get status => live == null
      ? MirrorConnectionStatus.disconnected
      : MirrorConnectionStatus.connected;

  @override
  String? get deviceName => live == null ? null : 'Dashing Dolphin';

  @override
  BlePong? get pong => null;

  @override
  int get panelWidth => 64;

  @override
  int get panelHeight => 32;

  /// The radio brings the link up, as the workspace hears it.
  void replace(_Session session) {
    live = session;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Pump until [finder] matches. The workspace lays itself out
  /// asynchronously and none of that schedules a frame, so settling is not
  /// the same as ready.
  Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 200 && finder.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(finder, findsWidgets, reason: 'the workspace never showed it');
  }

  /// Let the real event loop turn, for the one step that needs it: loading a
  /// layout decodes a real frame, which only completes outside the fake-async
  /// zone a widget test runs in.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }

  Finder chip(String name) => find.widgetWithText(ChoiceChip, name);

  /// The preset the picker marks as current.
  String currentChip(WidgetTester tester) {
    final selected = tester
        .widgetList<ChoiceChip>(find.byType(ChoiceChip))
        .where((c) => c.selected)
        .toList();
    expect(selected, hasLength(1), reason: 'one pick is current');
    return (selected.single.label as Text).data!;
  }

  testWidgets('every pick opens the layout, and a connected mirror gets it',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final engine = MirrorEngine.open();
    addTearDown(engine.dispose);
    // A surface with room for the picker: the panel is a fraction of the
    // window, and the chips have to be on screen to be tapped.
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final connection = _Connection();
    addTearDown(connection.dispose);
    await tester.pumpWidget(MaterialApp(
      home: WorkspaceScreen(engine: engine, connection: connection),
    ));
    // The stock layouts are read from the asset manifest before the picker
    // has anything in it.
    await pumpUntil(tester, chip('weather'));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    // No mirror: a pick is still a pick, and it says what it did.
    await tester.tap(chip('weather'));
    await settle(tester);

    expect(connection.session, isNull,
        reason: 'nothing to send to, and nothing attempted');
    expect(currentChip(tester), 'weather');
    expect(find.text('Opened weather'), findsOneWidget);

    // A mirror connects. The picker says so, because a tap now changes the
    // panel as well as the preview.
    final session = _Session();
    connection.replace(session);
    await pumpUntil(
        tester, find.text('Pick a layout to preview it on your mirror.'));

    await tester.tap(chip('quad'));
    await pumpUntil(tester, find.text('Pushed quad'));

    final quad = await tester.runAsync(
        () => File('../layouts/quad.json').readAsString());
    expect(jsonDecode(session.pushed.single), jsonDecode(quad!),
        reason: 'the mirror is sent the preset file itself, not a '
            're-serialized document that could differ from it');

    // A mirror that will not take the next one is reported with its own
    // reason, and the layout is still opened here.
    session.refusal =
        BlePushException('layout is 128x64 but this panel is 64x32');
    await tester.tap(chip('mini'));
    await pumpUntil(tester,
        find.text('Not pushed: layout is 128x64 but this panel is 64x32'));

    expect(session.pushed, hasLength(2), reason: 'one push per pick');
    await settle(tester);
    expect(currentChip(tester), 'mini',
        reason: 'the preview follows the pick even when the panel cannot');
  });
}
