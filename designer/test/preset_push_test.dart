// Picking a stock layout from the workspace, and where the pick goes.
//
// A pick is a live preview: a workspace bound to a device sends the layout to
// that device in the same tap, so the panel changes as the user clicks through
// the presets instead of after a separate trip to the device's own screen.
// What it must never do is write on entry, or write somewhere the user did not
// choose: opening a clock editor reads the mirror's own layout, and the local
// simulator writes nothing at all.
//
// This drives the real workspace - the real chips, the real asset text, the
// real queue - against a registry whose LAN transport records what it was
// handed, so what is asserted is what the mirror receives.
//
// The bound flow is the first widget test in this file on purpose: the picker's
// stock list comes from the asset manifest, and on this harness that read only
// lands in the first widget test of a file (a later one waits on an asset
// response the framework no longer delivers, which LayoutRepository reports as
// an empty list and would quietly leave nothing to tap).
//
// Needs the native core, which is built as part of the app rather than by
// `flutter test`. Build the app once first:
//
//   flutter build linux --debug
//   LD_LIBRARY_PATH=build/linux/x64/debug/bundle/lib flutter test

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mirror_designer/src/engine/engine.dart';
import 'package:mirror_designer/src/services/mirror_ble.dart';
import 'package:mirror_designer/src/services/mirror_devices.dart';
import 'package:mirror_designer/src/services/mirror_discovery.dart';
import 'package:mirror_designer/src/services/mirror_display.dart';
import 'package:mirror_designer/src/services/mirror_lan.dart';
import 'package:mirror_designer/src/ui/app.dart';

/// One endpoint's HTTP, with the answers the test controls.
class _Lan extends MirrorLan {
  _Lan(super.endpoint);

  /// Every request that reached this endpoint, so a test can prove none did.
  int calls = 0;

  /// What `/api/layout` answers, or the failure it raises instead.
  String layout = '{"name":"from-device"}';
  Object? loadError;

  /// The layouts pushed to this endpoint, in order.
  final List<String> puts = <String>[];
  PutLayoutResult putResult = (ok: true, diag: const <String>[], error: null);

  int frameCalls = 0;

  @override
  Future<MirrorStatus> status() async {
    calls++;
    return const MirrorStatus(
      version: '0.2.34',
      core: 'core-1',
      ip: '127.0.0.1',
      online: true,
      rssi: -50,
      uptime_s: 10,
      layout: 'on-the-mirror',
      width: 64,
      height: 32,
      brightness: 128,
      id: 'aaaa00000001',
      name: 'Hall mirror',
      mode: DisplayMode.clock,
      baseMode: DisplayMode.clock,
      pictureReady: false,
      flip180: false,
      displayApi: 1,
    );
  }

  @override
  Future<String> getLayout() async {
    calls++;
    final failure = loadError;
    if (failure != null) throw failure;
    return layout;
  }

  @override
  Future<PutLayoutResult> putLayout(String json) async {
    calls++;
    puts.add(json);
    return putResult;
  }

  @override
  Future<MirrorFrame> frame() async {
    calls++;
    frameCalls++;
    return MirrorFrame(
      width: 64,
      height: 32,
      sequence: frameCalls,
      brightness: 128,
      mode: DisplayMode.clock,
      flip180: false,
      rgb: Uint8List(64 * 32 * 3),
    );
  }
}

/// A registry wired to [_Lan]s and to nothing else: no mDNS, no BLE scan, and
/// a preview cache in a temp directory.
class _Fixture {
  _Fixture() {
    dir = Directory.systemTemp.createTempSync('preset-push');
    registry = MirrorDevices(
      lanFactory: lan,
      browse: _nothingAdvertised,
      scan: _nothingNearby,
      ensureBleReady: () async {},
      previewDirectory: () async => dir,
      now: () => DateTime.utc(2026, 9, 20, 12),
    );
  }

  late final Directory dir;
  late final MirrorDevices registry;
  final Map<String, _Lan> lans = <String, _Lan>{};

  MirrorLan lan(String endpoint) =>
      lans.putIfAbsent(endpoint, () => _Lan(endpoint));

  _Lan lanAt(String endpoint) =>
      lans.putIfAbsent(endpoint, () => _Lan(endpoint));

  void dispose() {
    registry.dispose();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}

Stream<LanDevice> _nothingAdvertised(
    {Duration timeout = const Duration(seconds: 5)}) async* {}

Future<List<BleScanEntry>> _nothingNearby(
        {Duration timeout = const Duration(seconds: 6)}) async =>
    const <BleScanEntry>[];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// Pump until [finder] matches, turning the real event loop as well: the
  /// workspace lays itself out asynchronously - the stock list comes from the
  /// asset bundle - and none of that schedules a frame on its own.
  Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 240 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(finder, findsWidgets, reason: 'the workspace never showed it');
  }

  /// Pump until [finder] stops matching: the workspace's own async work - a
  /// layout read - only lands on the real event loop.
  Future<void> pumpUntilGone(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 240 && finder.evaluate().isNotEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(finder, findsNothing, reason: 'the workspace never got past it');
  }

  /// Let the real event loop turn and the queued work land: loading a layout
  /// decodes a real frame, which only completes outside the fake-async zone a
  /// widget test runs in.
  Future<void> settle(WidgetTester tester) async {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
  }

  /// Pump until the workspace's own state says so. Used for work that leaves
  /// no widget behind, like the preview refresh a push triggers.
  Future<void> pumpUntilTrue(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 240 && !done(); i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(done(), isTrue, reason: 'the workspace never got there');
  }

  Finder chip(String name) => find.widgetWithText(ChoiceChip, name);

  /// The presets the picker marks as current.
  List<String> currentChips(WidgetTester tester) => tester
      .widgetList<ChoiceChip>(find.byType(ChoiceChip))
      .where((c) => c.selected)
      .map((c) => (c.label as Text).data!)
      .toList();

  Future<void> tapChip(WidgetTester tester, String name) async {
    final finder = chip(name);
    await tester.ensureVisible(finder);
    await tester.tap(finder);
  }

  testWidgets(
      'a bound workspace reads the mirror\'s layout and sends it '
      'every pick', (tester) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final engine = MirrorEngine.open();
    addTearDown(engine.dispose);
    // A surface with room for the picker: the panel is a fraction of the
    // window, and the chips have to be on screen to be tapped.
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final device = await fixture.registry.addLan('127.0.0.1', 8080);
    final lan = fixture.lanAt('127.0.0.1:8080');
    expect(device.width, 64, reason: 'the first status reports the panel');

    // The mirror's layout cannot be read: the workspace opens an explicitly
    // labeled draft instead of pretending a preset came from the device.
    lan.loadError = const SocketException('no route to host');
    await tester.pumpWidget(MaterialApp(
      home: WorkspaceScreen(engine: engine, device: device),
    ));
    await pumpUntil(tester, find.textContaining('Local draft'));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    expect(lan.puts, isEmpty,
        reason: 'opening a clock editor never writes to the panel');
    expect(currentChips(tester), hasLength(1),
        reason: 'the draft seeded one preset, and says it is a draft');
    expect(find.text('Retry'), findsOneWidget);

    // The read succeeds on the retry: the draft is replaced by the mirror's
    // own layout, which is no preset, and still nothing was sent.
    lan.loadError = null;
    lan.layout = (await tester
        .runAsync(() => File('../layouts/status.json').readAsString()))!;
    await tester.tap(find.text('Retry'));
    await pumpUntilGone(tester, find.textContaining('Local draft'));

    expect(currentChips(tester), isEmpty,
        reason: 'the document is the mirror\'s own, not a preset pick');
    expect(lan.puts, isEmpty, reason: 'a read is not a write');

    // A pick goes to the device, over that record's own transport, as the
    // preset file itself.
    await tapChip(tester, 'quad');
    await pumpUntil(tester, find.text('Pushed quad'));

    final quad = await tester
        .runAsync(() => File('../layouts/quad.json').readAsString());
    expect(lan.puts, hasLength(1), reason: 'one push per pick');
    expect(jsonDecode(lan.puts.single), jsonDecode(quad!),
        reason: 'the mirror is sent the preset file itself, not a '
            're-serialized document that could differ from it');
    await pumpUntilTrue(tester, () => device.frame != null);
    expect(device.frame, isNotNull,
        reason: 'the device\'s own status and preview are refreshed after a '
            'push, rather than the local render treated as acknowledgement');

    // A mirror that will not take the next one is reported with its own
    // reason, and the layout is still opened here.
    lan.putResult = (
      ok: false,
      diag: const <String>[],
      error: 'layout is 128x64 but this panel is 64x32',
    );
    await tapChip(tester, 'mini');
    await pumpUntil(tester,
        find.text('Not pushed: layout is 128x64 but this panel is 64x32'));

    expect(lan.puts, hasLength(2), reason: 'one push per pick');
    await settle(tester);
    expect(currentChips(tester), <String>['mini'],
        reason: 'the preview follows the pick even when the panel cannot');
  });

  testWidgets('the local simulator never reaches a remembered mirror',
      (tester) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final engine = MirrorEngine.open();
    addTearDown(engine.dispose);

    // A mirror the registry remembers, reachable and identified.
    await fixture.registry.addLan('127.0.0.1', 8080);
    final lan = fixture.lanAt('127.0.0.1:8080');
    final remembered = lan.calls;
    expect(remembered, greaterThan(0),
        reason: 'adding the device did contact it');

    await tester.pumpWidget(MaterialApp(home: WorkspaceScreen(engine: engine)));
    await pumpUntil(tester, find.byTooltip('Settings'));
    await settle(tester);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    expect(find.text('Local simulator'), findsOneWidget,
        reason: 'the workspace says what it is editing');
    expect(lan.calls, remembered,
        reason: 'opening the local designer must not touch a remembered '
            'mirror, not even to read it');
  });
}
