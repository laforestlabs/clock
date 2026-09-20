// The workspace offers the firmware this app ships to a mirror that connects
// running something older, and says nothing to a mirror that is current.
//
// The versions here are read from the bundle rather than written down: the
// image's version changes with every firmware change, and a test that pinned
// it would fail on the next bump for a reason that has nothing to do with the
// prompt. The device version under test is derived from it, so "older" and
// "current" stay true across those bumps.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mirror_designer/src/engine/engine.dart';
import 'package:mirror_designer/src/services/bundled_firmware.dart';
import 'package:mirror_designer/src/services/mirror_ble.dart';
import 'package:mirror_designer/src/services/mirror_connection.dart';
import 'package:mirror_designer/src/ui/app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String bundledVersion;
  late Uint8List bundledBytes;

  setUpAll(() async {
    // The test binding installs an HttpClient that answers every request with
    // 400 so a test cannot depend on the network. The update path is real
    // HTTP against the mirror's own API, and the fake mirror below is the
    // contract it talks to, so this file lifts that override for itself (the
    // binding documents the override as replaceable).
    HttpOverrides.global = null;

    final bundled = await loadBundledFirmware();
    expect(bundled, isNotNull, reason: 'the app must ship a firmware image');
    bundledVersion = bundled!.version;
    bundledBytes = bundled.bytes;
  });

  /// Pump until [finder] matches. The workspace lays itself out
  /// asynchronously and none of that schedules a frame, so settling is not the
  /// same as ready.
  Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 200 && finder.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(finder, findsWidgets, reason: 'the workspace never showed it');
  }

  Future<void> boot(WidgetTester tester, _Connection connection) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    addTearDown(connection.dispose);
    final engine = MirrorEngine.open();
    addTearDown(engine.dispose);
    await tester.pumpWidget(MaterialApp(
      home: WorkspaceScreen(engine: engine, connection: connection),
    ));
    // The default view's own Settings button: the workspace is up.
    await pumpUntil(tester, find.byTooltip('Settings'));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  }

  testWidgets('an older mirror is offered the update when it connects',
      (tester) async {
    final connection = _Connection(deviceVersion: '0.0.1', ip: '0.0.0.0');
    await boot(tester, connection);
    expect(find.text('Firmware update available'), findsNothing,
        reason: 'nothing is connected yet');

    connection.simulateConnect();
    await pumpUntil(tester, find.text('Firmware update available'));

    expect(find.textContaining('running v0.0.1'), findsOneWidget);
    expect(find.text('Update to v$bundledVersion'), findsOneWidget);

    await tester.tap(find.text('Not now'));
    await tester.pump();
    expect(find.text('Firmware update available'), findsNothing);
    expect(find.text('Updating firmware'), findsNothing,
        reason: 'declining must not start an upload');
  });

  testWidgets('a mirror on the bundled version is left alone', (tester) async {
    final connection =
        _Connection(deviceVersion: bundledVersion, ip: '0.0.0.0');
    await boot(tester, connection);

    connection.simulateConnect();
    // The check is asynchronous (the bundle is read, then compared), so give
    // it the frames it would need to raise a dialog before asserting silence.
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('Firmware update available'), findsNothing);
  });

  testWidgets('accepting installs the image this app ships', (tester) async {
    final mirror = _FakeMirror()..version = bundledVersion;
    await tester.runAsync(mirror.start);
    addTearDown(mirror.close);

    final connection = _Connection(deviceVersion: '0.0.1', ip: mirror.address);
    await boot(tester, connection);

    connection.simulateConnect();
    await pumpUntil(tester, find.text('Firmware update available'));
    await tester.tap(find.text('Update to v$bundledVersion'));
    await tester.pump();

    // The upload is real I/O, and every step of it is awaited: run the real
    // clock so the socket work progresses, then pump so the flow issues its
    // next step, until the mirror reports the new version back.
    final updated = find.text('Updated to $bundledVersion');
    for (var i = 0; i < 300 && updated.evaluate().isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }

    expect(mirror.receivedOta, orderedEquals(bundledBytes),
        reason: 'the whole image, byte for byte');
    expect(updated, findsOneWidget,
        reason: 'the version read back after the reboot is reported');
    expect(find.text('Updating firmware'), findsNothing,
        reason: 'the progress dialog is closed when the update finishes');
    expect(connection.reconnects, greaterThan(0),
        reason: 'the rebooted mirror is reconnected');
  });

  testWidgets('accepting without a WiFi address says so instead of uploading',
      (tester) async {
    final connection = _Connection(deviceVersion: '0.0.1', ip: '0.0.0.0');
    await boot(tester, connection);

    connection.simulateConnect();
    await pumpUntil(tester, find.text('Firmware update available'));
    await tester.tap(find.text('Update to v$bundledVersion'));
    await tester.pump();
    await tester.pump();

    expect(
        find.textContaining('no WiFi IP'), findsOneWidget,
        reason: 'the update is megabytes over WiFi, and the pong had no '
            'address for it');
    expect(find.text('Updating firmware'), findsNothing);
  });
}

/// The workspace's link with a mirror already connected, so a test can drive
/// the connection states the radio would.
class _Connection extends MirrorConnection {
  _Connection({required this.deviceVersion, required this.ip});

  final String deviceVersion;
  final String ip;
  bool connected = false;
  int reconnects = 0;

  @override
  MirrorConnectionStatus get status => connected
      ? MirrorConnectionStatus.connected
      : MirrorConnectionStatus.disconnected;

  @override
  BlePong? get pong =>
      connected ? BlePong(deviceVersion, ip, 'mini', 64, 32) : null;

  @override
  String? get deviceName => connected ? 'Twirling Elephant' : null;

  @override
  BleSession? get session => null;

  @override
  Future<void> connectLast() async => reconnects++;

  /// The radio brings the link up: what the workspace hears as a connect.
  void simulateConnect() {
    connected = true;
    notifyListeners();
  }
}

/// A mirror on the LAN: the endpoints an update uses, and the image it was
/// sent. The same contract as firmware/main/net/ota.c and api_server.c.
class _FakeMirror {
  late final HttpServer server;
  final List<int> receivedOta = <int>[];
  String version = '9.9.9';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      switch ('${req.method} ${req.uri.path}') {
        case 'POST /api/ota':
          receivedOta.addAll(await req.fold<List<int>>(
              <int>[], (all, chunk) => all..addAll(chunk)));
          req.response.write(jsonEncode(<String, bool>{'ok': true}));
        case 'GET /api/status':
          req.response.headers.contentType = ContentType('application', 'json');
          req.response.write(jsonEncode(<String, dynamic>{'version': version}));
        default:
          req.response.statusCode = 404;
      }
      await req.response.close();
    });
  }

  String get address => '127.0.0.1:${server.port}';

  Future<void> close() => server.close(force: true);
}
