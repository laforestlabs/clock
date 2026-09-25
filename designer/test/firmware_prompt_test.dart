// The firmware prompt, on the device page that owns the device.
//
// A mirror running older firmware than this app ships is offered the update
// once, on its own page, and never from background polling: the prompt names
// the device it will reboot, and after the reboot only that device is
// reconnected.
//
// The registry's LAN transport is a fake here, so the page's own polling is
// deterministic; the *upload* is real HTTP against a fake mirror, because the
// OTA path builds its own client from the endpoint and that contract (explicit
// length, the image this app ships, byte for byte) is what matters.
//
// The versions are read from the bundle rather than written down: the image's
// version changes with every firmware change, and a test that pinned it would
// fail on the next bump for a reason that has nothing to do with the prompt.
// The device version under test is derived from it, so "older" and "current"
// stay true across those bumps.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mirror_designer/src/services/bundled_firmware.dart';
import 'package:mirror_designer/src/services/mirror_ble.dart';
import 'package:mirror_designer/src/services/mirror_devices.dart';
import 'package:mirror_designer/src/services/mirror_display.dart';
import 'package:mirror_designer/src/services/mirror_ble_status.dart';
import 'package:mirror_designer/src/services/mirror_connection.dart';
import 'package:mirror_designer/src/services/mirror_lan.dart';
import 'package:mirror_designer/src/ui/device_screen.dart';
import 'package:mirror_designer/src/ui/device_routes.dart';

const String _firmwareId = 'aaaa00000001';
String _installedVersion = '';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String bundledVersion;
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
    _installedVersion = bundled.version;
  });

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// Pump until [finder] matches. The page lays itself out asynchronously and
  /// none of that schedules a frame, so settling is not the same as ready.
  Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 400 && finder.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(finder, findsWidgets, reason: 'the page never showed it');
  }

  Future<void> boot(
    WidgetTester tester,
    MirrorDevices registry,
    MirrorDevice device,
  ) async {
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: <NavigatorObserver>[appRouteObserver],
      home: DeviceScreen(devices: registry, device: device),
    ));
    await pumpUntil(tester, find.text('Reconnect'));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  }

  testWidgets('an older mirror is offered the update on its own page',
      (tester) async {
    final mirror = _FakeMirror();
    await tester.runAsync(mirror.start);
    addTearDown(mirror.close);

    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    late final MirrorDevice device;
    await tester.runAsync(() async {
      fixture.lanAt('127.0.0.1:${mirror.port}').version = '0.0.1';
      device = await fixture.registry.addLan('127.0.0.1', mirror.port);
    });
    expect(device.status?.version, '0.0.1');

    await boot(tester, fixture.registry, device);
    await pumpUntil(tester, find.text('Firmware update available'));

    expect(find.textContaining('running v0.0.1'), findsOneWidget);
    expect(find.text('Update to v$bundledVersion'), findsOneWidget);

    await tester.tap(find.text('Not now'));
    await tester.pump();
    expect(find.text('Firmware update available'), findsNothing);
    expect(mirror.receivedOta, isEmpty,
        reason: 'declining must not start an upload');
  });

  testWidgets('a mirror on the bundled version is left alone', (tester) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    late final MirrorDevice device;
    await tester.runAsync(() async {
      fixture.lanAt('127.0.0.1:8080').version = bundledVersion;
      device = await fixture.registry.addLan('127.0.0.1', 8080);
    });

    await boot(tester, fixture.registry, device);
    // The check is asynchronous (the bundle is read, then compared), so give
    // it the frames it would need to raise a dialog before asserting silence.
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('Firmware update available'), findsNothing);
  });

  testWidgets('a link that lands while the offer is open enables the update',
      (tester) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    late final MirrorDevice device;
    late final _Connection connection;
    await tester.runAsync(() async {
      fixture.lanAt('127.0.0.1:8080').version = '0.0.1';
      await fixture.registry.addLan('127.0.0.1', 8080);
      // The same mirror, paired over Bluetooth: the version is read over
      // Wi-Fi the moment a page polls it, while the link the image travels
      // over is only opened when that page is pushed. The Bluetooth record
      // folds into the Wi-Fi one, which is the record an update runs through.
      device = await fixture.registry.addBle(fixture.nearby());
      expect(device.bleId, isNotNull, reason: 'an update needs this target');
      connection = device.connection as _Connection;
      await connection.disconnect();
    });

    // The page opens the link when it is pushed; this case holds that open,
    // so the offer is raised while no link is up yet.
    connection.hold = Completer<void>();

    await boot(tester, fixture.registry, device);
    await pumpUntil(tester, find.text('Firmware update available'));

    final action =
        find.widgetWithText(FilledButton, 'Update to v$bundledVersion');
    expect(tester.widget<FilledButton>(action).onPressed, isNull,
        reason: 'the link is still coming up');
    expect(find.textContaining(MirrorDevice.openingBluetooth), findsOneWidget);

    // The link lands while the owner is looking at the offer.
    connection.hold!.complete();
    connection.hold = null;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.textContaining(MirrorDevice.openingBluetooth), findsNothing);
    expect(tester.widget<FilledButton>(action).onPressed, isNotNull,
        reason: 'a live link must offer the update it can now send');
  });
}

/// A live BLE session whose identity the test controls.
class _Session extends Fake implements BleSession {
  _Session(this.firmwareId, this.onPush);
  final String firmwareId;
  final void Function() onPush;

  @override
  Future<MirrorDeviceInfo?> getDeviceInfo() async => MirrorDeviceInfo(
      id: firmwareId,
      displayApi: 1,
      mode: DisplayMode.clock,
      baseMode: DisplayMode.clock,
      pictureReady: false);
  @override
  Future<BleOtaStatus?> getOtaStatus() async => null;
  @override
  Future<void> pushFirmware(
    Uint8List bytes, {
    int offset = 0,
    void Function(int sent, int total)? onProgress,
  }) async {
    onProgress?.call(bytes.length, bytes.length);
    onPush();
  }

  @override
  Future<void> close() async {}
}

/// The Bluetooth link, with a pong that reports the version under test.
class _Connection extends MirrorConnection {
  _Connection({
    super.deviceId,
    super.deviceName,
    super.panelWidth,
    super.panelHeight,
  });

  /// The version the link's pong reports before an update.
  String version = '0.0.1';

  /// The Wi-Fi address the link's pong reports. 0.0.0.0 is what the firmware
  /// sends until its station interface has an address, and what these cases
  /// use unless they are about an address being there.
  String pongIp = '0.0.0.0';

  _Session? live;
  int connects = 0;

  /// Holds the next connect open until the case completes it, so a test can
  /// look at the page while the link is still coming up — which is when the
  /// offer is raised on a version that arrived over Wi-Fi.
  Completer<void>? hold;

  @override
  BleSession? get session => live;

  @override
  MirrorConnectionStatus get status => hold != null
      ? MirrorConnectionStatus.connecting
      : live == null
          ? MirrorConnectionStatus.disconnected
          : MirrorConnectionStatus.connected;

  @override
  BlePong? get pong =>
      live == null ? null : BlePong(version, pongIp, 'mini', 64, 32);

  @override
  String? get deviceName => live == null ? null : 'Twirling Elephant';

  @override
  Future<void> connectDevice({
    required String id,
    required String name,
    Duration timeout = const Duration(seconds: 35),
  }) async {
    connects++;
    final held = hold;
    if (held != null) await held.future;
    live = _Session(_firmwareId, () {
      version = _installedVersion;
      live = null;
      notifyListeners();
    });
    notifyListeners();
  }

  @override
  Future<void> disconnect() async {
    live = null;
    notifyListeners();
  }
}

/// The registry's LAN transport, scripted per endpoint: every request the app
/// makes to a mirror goes through it, the firmware upload included, so a case
/// can see exactly what was asked, and of which address.
class _Lan extends MirrorLan {
  _Lan(this.endpoint) : super(endpoint);

  final String endpoint;

  /// What the mirror reports; the page's firmware prompt reads this.
  String version = '0.0.1';

  /// Whether this endpoint is a real HTTP server. The LAN cases are, and their
  /// requests really travel over it; a Bluetooth record's address is a bare IP
  /// on port 80, where no test server can listen, so those cases are answered
  /// in memory — and record what the app asked the transport to do.
  bool overHttp = true;

  @override
  Future<MirrorStatus> status() async => MirrorStatus(
        version: version,
        core: 'core-1',
        ip: '0.0.0.0',
        online: true,
        rssi: -50,
        uptime_s: 1,
        layout: 'home',
        width: 64,
        height: 32,
        brightness: 128,
        id: _firmwareId,
        name: 'Twirling Elephant',
        mode: DisplayMode.clock,
        baseMode: DisplayMode.clock,
        pictureReady: false,
        flip180: false,
        displayApi: 1,
      );

  /// A plain black frame: the page's polls fetch one, and this keeps them off
  /// the real network (the upload is the only exchange that needs it).
  @override
  Future<MirrorFrame> frame() async => MirrorFrame(
        width: 64,
        height: 32,
        sequence: 1,
        brightness: 128,
        mode: DisplayMode.clock,
        flip180: false,
        rgb: Uint8List(64 * 32 * 3),
      );
}

/// A registry wired to fakes: a scripted LAN and a scripted radio.
class _Fixture {
  _Fixture() {
    dir = Directory.systemTemp.createTempSync('firmware-prompt');
    registry = MirrorDevices(
      connectionFactory: createConnection,
      lanFactory: lan,
      browse: ({Duration timeout = const Duration(seconds: 5)}) async* {},
      scan: ({Duration timeout = const Duration(seconds: 6)}) async =>
          <BleScanEntry>[],
      ensureBleReady: () async {},
      previewDirectory: () async => dir,
    );
  }

  late final Directory dir;
  late final MirrorDevices registry;
  final Map<String, _Lan> lans = <String, _Lan>{};

  MirrorLan lan(String endpoint) =>
      lans.putIfAbsent(endpoint, () => _Lan(endpoint));

  _Lan lanAt(String endpoint) =>
      lans.putIfAbsent(endpoint, () => _Lan(endpoint));

  MirrorConnection createConnection({
    String? deviceId,
    String? deviceName,
    int panelWidth = 0,
    int panelHeight = 0,
  }) =>
      _Connection(
        deviceId: deviceId,
        deviceName: deviceName,
        panelWidth: panelWidth,
        panelHeight: panelHeight,
      );

  BleScanEntry nearby({String remoteId = 'REMOTE-1'}) =>
      BleScanEntry(BluetoothDevice.fromId(remoteId), 'Twirling Elephant', -40);

  Future<MirrorDevice> addLan(String host, int port) =>
      registry.addLan(host, port);

  Future<MirrorDevice> addBle(String remoteId) =>
      registry.addBle(nearby(remoteId: remoteId));

  void dispose() {
    registry.dispose();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}

/// A mirror on the LAN: the image it was sent, and the version it reports
/// after the reboot. The same contract as firmware/main/net/ota.c and
/// api_server.c.
class _FakeMirror {
  late final HttpServer server;
  final List<int> receivedOta = <int>[];
  String version = '9.9.9';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      switch ('${req.method} ${req.uri.path}') {
        case 'POST /api/ota':
          receivedOta.addAll(await req
              .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk)));
          version = nextVersion ?? version;
          req.response.write(jsonEncode(<String, bool>{'ok': true}));
        case 'GET /api/status':
          req.response.headers.contentType = ContentType('application', 'json');
          req.response.write(jsonEncode(<String, dynamic>{
            'version': version,
            'id': _firmwareId,
            'name': 'Twirling Elephant',
            'display_api': 1,
            'mode': 'clock',
            'base_mode': 'clock',
            'picture_ready': false,
            'width': 64,
            'height': 32,
          }));
        default:
          req.response.statusCode = 404;
      }
      await req.response.close();
    });
  }

  /// What the mirror reports after the OTA; null when the test does not care.
  String? nextVersion;

  int get port => server.port;

  Future<void> close() => server.close(force: true);
}
