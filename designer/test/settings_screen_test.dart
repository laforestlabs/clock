import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/controller.dart';
import 'package:mirror_designer/src/engine/engine.dart';
import 'package:mirror_designer/src/services/mirror_ble.dart';
import 'package:mirror_designer/src/services/mirror_ble_status.dart';
import 'package:mirror_designer/src/services/mirror_connection.dart';
import 'package:mirror_designer/src/services/mirror_devices.dart';
import 'package:mirror_designer/src/services/mirror_discovery.dart';
import 'package:mirror_designer/src/services/mirror_display.dart';
import 'package:mirror_designer/src/services/mirror_lan.dart';
import 'package:mirror_designer/src/services/mirror_wifi_status.dart';
import 'package:mirror_designer/src/services/user_view.dart';
import 'package:mirror_designer/src/ui/mirror_screen.dart';
import 'package:mirror_designer/src/ui/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

MirrorEngine? _tryOpen() {
  try {
    return MirrorEngine.open();
  } catch (_) {
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  final probe = _tryOpen();
  final skip = probe == null;
  probe?.dispose();

  testWidgets('orientation toggle flips the panel preview', (tester) async {
    final engine = MirrorEngine.open();
    final controller = DesignerController(engine);
    addTearDown(controller.dispose);

    UserView? changed;
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          controller: controller,
          view: UserView.defaultView,
          onViewChanged: (v) => changed = v,
        ),
      ),
    );

    expect(controller.flip180, isFalse);
    await tester.tap(find.text('Upside down'));
    await tester.pumpAndSettle();

    expect(controller.flip180, isTrue);
    expect(changed, isNull, reason: 'orientation does not change the view');
  }, skip: skip);

  testWidgets('developer mode switch changes the view', (tester) async {
    final engine = MirrorEngine.open();
    final controller = DesignerController(engine);
    addTearDown(controller.dispose);

    UserView? changed;
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          controller: controller,
          view: UserView.defaultView,
          onViewChanged: (v) => changed = v,
        ),
      ),
    );

    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pumpAndSettle();

    expect(changed, UserView.developer);
  }, skip: skip);

  // ------------------------------------------------- device-scoped settings

  testWidgets('a bound device with no link cannot be flipped', (tester) async {
    final rig = _Rig();
    addTearDown(rig.dispose);
    final device = await rig.registry.addLan('127.0.0.1', 8080);
    final persisted = <bool>[];
    final controller = _controller(persisted);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_screen(controller, device));

    expect(controller.flip180, isFalse);
    await tester.tap(find.text('Upside down'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(controller.flip180, isFalse,
        reason: 'there is no Bluetooth link to apply it on');
    expect(persisted, isEmpty,
        reason: 'an orientation the panel never acknowledged is not saved');
    expect(
      tester
          .widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>))
          .onSelectionChanged,
      isNull,
      reason: 'the control is shown disabled, not silently ignored',
    );
    expect(find.textContaining('over Bluetooth to change it'), findsOneWidget);
  });

  testWidgets('a bound device with a live link is flipped over its own session',
      (tester) async {
    final rig = _Rig();
    addTearDown(rig.dispose);
    final device = await rig.pair('REMOTE-A');
    final session = rig.sessionOf(device);
    final persisted = <bool>[];
    final controller = _controller(persisted);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_screen(controller, device));

    await tester.tap(find.text('Upside down'));
    await tester.pumpAndSettle();

    expect(controller.flip180, isTrue);
    expect(session.configs, <Map<String, dynamic>>[
      <String, dynamic>{'flip180': true},
    ]);
    expect(persisted, <bool>[true],
        reason: 'the accepted value is recorded on this device');
  });

  testWidgets('a rejected flip keeps the last confirmed orientation',
      (tester) async {
    final rig = _Rig();
    addTearDown(rig.dispose);
    final device = await rig.pair('REMOTE-A');
    final session = rig.sessionOf(device);
    session.pushError = BlePushException('config error bad value');
    final persisted = <bool>[];
    final controller = _controller(persisted);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_screen(controller, device));

    await tester.tap(find.text('Upside down'));
    await tester.pumpAndSettle();

    expect(controller.flip180, isFalse, reason: 'the panel is still normal');
    expect(persisted, isEmpty,
        reason: 'an unacknowledged orientation must never be persisted');
  });

  testWidgets('flipping one device never touches another', (tester) async {
    final rig = _Rig();
    addTearDown(rig.dispose);
    final a = await rig.pair('REMOTE-A');
    final b = await rig.pair('REMOTE-B');
    final persisted = <bool>[];
    final controller = _controller(persisted);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_screen(controller, b));

    await tester.tap(find.text('Upside down'));
    await tester.pumpAndSettle();

    expect(rig.sessionOf(b).configs, hasLength(1));
    expect(rig.sessionOf(a).configs, isEmpty,
        reason: 'the other device\'s link is not this screen\'s to drive');
    expect(a.flip180, isFalse);
  });

  // ------------------------------------------------ the device's own page

  testWidgets('the device page offers no discovery of its own', (tester) async {
    final rig = _Rig();
    addTearDown(rig.dispose);
    final device = await rig.registry.addLan('127.0.0.1', 8080);
    final controller = _controller(<bool>[]);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_mirrorScreen(controller, device));
    await tester.pumpAndSettle();

    expect(find.text('127.0.0.1:8080'), findsOneWidget,
        reason: 'this device\'s own address, port preserved');
    expect(find.textContaining('v0.2.34'), findsOneWidget,
        reason: 'the status read over that address is shown');
    // Finding devices is Add device's job now; a bound page must not be able
    // to retarget anything.
    expect(find.text('Scan'), findsNothing);
    expect(find.text('Browse'), findsNothing);
    expect(find.textContaining('Manual IP'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    // Nothing that mutates a mirror is offered without a link.
    expect(find.text('Push layout'), findsNothing);
    expect(find.text('Configure'), findsNothing);
    expect(find.text('Reboot'), findsNothing);
    expect(find.text('Factory reset'), findsNothing);
    expect(find.text('Disconnect'), findsNothing);
  });

  testWidgets('a paired device with no link offers reconnect only',
      (tester) async {
    final rig = _Rig();
    addTearDown(rig.dispose);
    final device = await rig.pair('REMOTE-A');
    await rig.registry.deactivate(device);
    final controller = _controller(<bool>[]);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_mirrorScreen(controller, device));
    await tester.pumpAndSettle();

    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('Push layout'), findsNothing);
    expect(find.textContaining('No Wi-Fi address is known'), findsOneWidget);
  });

  testWidgets('a live link exposes the device controls', (tester) async {
    final rig = _Rig();
    addTearDown(rig.dispose);
    final device = await rig.pair('REMOTE-A');
    final controller = _controller(<bool>[]);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_mirrorScreen(controller, device));
    await tester.pumpAndSettle();

    expect(find.text('Connected to ${device.name}'), findsOneWidget);
    for (final label in <String>[
      'Push layout',
      'Configure',
      'Reboot',
      'Factory reset',
      'Disconnect',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });
}

Widget _screen(DesignerController controller, MirrorDevice device) =>
    MaterialApp(
      home: SettingsScreen(
        controller: controller,
        view: UserView.defaultView,
        onViewChanged: (_) {},
        device: device,
        connection: device.connection,
      ),
    );

Widget _mirrorScreen(DesignerController controller, MirrorDevice device) =>
    MaterialApp(home: MirrorScreen(controller: controller, device: device));

/// A controller that needs no native library: settings only reads and writes
/// the preview's orientation, and records what it persists.
DesignerController _controller(List<bool> persisted) => DesignerController(
      _FakeEngine(),
      persistFlip180: (flipped) async => persisted.add(flipped),
    );

/// A registry wired to fakes: each `host:port` answers as its own firmware id,
/// and each BLE remote id connects to the mirror that owns it.
class _Rig {
  final _Radio radio = _Radio();
  late final MirrorDevices registry = MirrorDevices(
    connectionFactory: radio.call,
    lanFactory: (endpoint) =>
        _FakeLan(() => _status(radio.idForEndpoint(endpoint))),
    browse: ({Duration timeout = const Duration(seconds: 5)}) =>
        const Stream<LanDevice>.empty(),
    scan: ({Duration timeout = const Duration(seconds: 6)}) async =>
        <BleScanEntry>[],
    ensureBleReady: () async {},
    previewDirectory: () async => _previewDir,
    now: () => DateTime.utc(2026, 9, 20, 12),
  );

  final Directory _previewDir =
      Directory.systemTemp.createTempSync('settings-screen');

  /// A device with a live Bluetooth link to [remoteId], as a scan result
  /// creates it. BLE-only on purpose: the merge path a LAN record takes runs
  /// real file I/O, which a widget test's fake clock never delivers.
  Future<MirrorDevice> pair(String remoteId) async {
    final device = await registry
        .addBle(BleScanEntry(BluetoothDevice.fromId(remoteId), 'Nearby', -40));
    return device.mergedInto ?? device;
  }

  _FakeSession sessionOf(MirrorDevice device) =>
      device.connection.session! as _FakeSession;

  void dispose() {
    registry.dispose();
    if (_previewDir.existsSync()) _previewDir.deleteSync(recursive: true);
  }
}

MirrorStatus _status(String? id) => MirrorStatus(
      version: '0.2.34',
      core: 'core-1',
      ip: '192.168.1.20',
      online: true,
      rssi: -50,
      uptime_s: 12,
      layout: 'home',
      width: 64,
      height: 32,
      brightness: 128,
      id: id,
      mode: DisplayMode.clock,
      baseMode: DisplayMode.clock,
      pictureReady: false,
      flip180: false,
      displayApi: 1,
    );

class _Radio {
  final Map<String, String> byRemoteId = <String, String>{
    'REMOTE-A': 'aaaa00000001',
    'REMOTE-B': 'aaaa00000002',
  };
  final Map<String, String> byEndpoint = <String, String>{
    '127.0.0.1:8080': 'aaaa00000001',
    '127.0.0.1:8081': 'aaaa00000002',
  };

  String? idForEndpoint(String endpoint) => byEndpoint[endpoint];

  MirrorConnection call({
    String? deviceId,
    String? deviceName,
    int panelWidth = 0,
    int panelHeight = 0,
  }) =>
      _FakeConnection(
        radio: this,
        deviceId: deviceId,
        deviceName: deviceName,
        panelWidth: panelWidth,
        panelHeight: panelHeight,
      );
}

class _FakeConnection extends MirrorConnection {
  _FakeConnection({
    required this.radio,
    super.deviceId,
    super.deviceName,
    super.panelWidth,
    super.panelHeight,
  });

  final _Radio radio;
  _FakeSession? live;

  @override
  BleSession? get session => live;

  @override
  MirrorConnectionStatus get status => live == null
      ? MirrorConnectionStatus.disconnected
      : MirrorConnectionStatus.connected;

  @override
  Future<void> connectDevice({
    required String id,
    required String name,
    Duration timeout = const Duration(seconds: 35),
  }) async {
    live = _FakeSession(firmwareId: radio.byRemoteId[id]);
    notifyListeners();
  }

  @override
  Future<void> disconnect() async {
    live = null;
    notifyListeners();
  }
}

class _FakeSession extends Fake implements BleSession {
  _FakeSession({this.firmwareId});

  final String? firmwareId;
  final List<Map<String, dynamic>> configs = <Map<String, dynamic>>[];
  Object? pushError;

  @override
  Future<MirrorDeviceInfo?> getDeviceInfo() async {
    final id = firmwareId;
    if (id == null) return null;
    return MirrorDeviceInfo(
      id: id,
      displayApi: 1,
      mode: DisplayMode.clock,
      baseMode: DisplayMode.clock,
      pictureReady: false,
    );
  }

  @override
  Future<String> pushConfig(Map<String, dynamic> json) async {
    final failure = pushError;
    if (failure != null) throw failure;
    configs.add(json);
    return 'commit ok';
  }

  @override
  Future<String?> getConfigRaw() async => null;

  // The device page reads these once when it opens on a live link; firmware
  // without the commands answers null and the controls stay hidden.
  @override
  Future<BleBrightness?> getBrightness() async => null;

  @override
  Future<BleWifiStatus?> getWifi() async => null;

  @override
  Future<void> close() async {}
}

class _FakeLan extends Fake implements MirrorLan {
  _FakeLan(this.statusBody);

  final MirrorStatus Function() statusBody;

  @override
  Future<MirrorStatus> status() async => statusBody();
}

class _FakeEngine extends Fake implements MirrorEngine {
  @override
  void dispose() {}
}
