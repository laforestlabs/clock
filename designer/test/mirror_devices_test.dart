// What the device registry guarantees.
//
// The dashboard is only as trustworthy as the registry under it, and the
// failures worth pinning are the ones that silently write to the wrong panel:
// two mirrors with the same name collapsing into one tile, an address that
// belongs to another mirror by the time a mutation goes out, a global
// connection that follows the wrong record, or a preview whose timestamp
// describes a poll that failed. The rest of the file checks the bookkeeping
// the dashboard reads: remembered offline devices, preserved ports, the
// throttled preview cache and the two-refresh concurrency limit.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mirror_designer/src/services/mirror_ble.dart';
import 'package:mirror_designer/src/services/mirror_connection.dart';
import 'package:mirror_designer/src/services/mirror_devices.dart';
import 'package:mirror_designer/src/services/mirror_display.dart';
import 'package:mirror_designer/src/services/mirror_discovery.dart';
import 'package:mirror_designer/src/services/mirror_lan.dart';

/// Temp directories to remove after each test.
final List<Directory> _temps = <Directory>[];

MirrorStatus mirrorStatus({
  String? id,
  String? name,
  int width = 64,
  int height = 32,
  DisplayMode? mode = DisplayMode.clock,
  DisplayMode? baseMode = DisplayMode.clock,
  bool? pictureReady = false,
  bool? flip180 = false,
  int displayApi = 1,
  String ip = '',
}) =>
    MirrorStatus(
      version: '0.2.34',
      core: 'core-1',
      ip: ip,
      online: true,
      rssi: -50,
      uptime_s: 12,
      layout: 'home',
      width: width,
      height: height,
      brightness: 128,
      id: id,
      name: name,
      mode: mode,
      baseMode: baseMode,
      pictureReady: pictureReady,
      flip180: flip180,
      displayApi: displayApi,
    );

Uint8List pattern([int salt = 0]) => Uint8List.fromList(
      List<int>.generate(64 * 32 * 3, (i) => (i * 7 + salt) % 251),
    );

MirrorFrame mirrorFrame({
  int sequence = 1,
  bool flip180 = false,
  DisplayMode mode = DisplayMode.clock,
  Uint8List? rgb,
}) =>
    MirrorFrame(
      width: 64,
      height: 32,
      sequence: sequence,
      brightness: 128,
      mode: mode,
      flip180: flip180,
      rgb: rgb ?? pattern(),
    );

/// A live BLE session whose replies the test controls.
class _Session extends Fake implements BleSession {
  _Session({this.firmwareId = 'aaaa00000001'});

  /// The identity the mirror reports, null for firmware without `get device`.
  String? firmwareId;
  int displayApi = 1;
  DisplayMode? mode = DisplayMode.clock;
  DisplayMode? baseMode = DisplayMode.clock;
  bool pictureReady = false;

  Object? infoError;
  Object? modeError;
  final List<DisplayMode> modes = <DisplayMode>[];
  final List<String> layouts = <String>[];
  bool closed = false;

  /// What `get config` answers with, as the mirror's own name; null is
  /// firmware that does not answer the command at all.
  String? configName;
  Object? configError;

  @override
  Future<String?> getConfigRaw() async {
    final failure = configError;
    if (failure != null) throw failure;
    final name = configName;
    if (name == null) return null;
    return 'config {"name":"$name","timezone":"UTC0"}';
  }

  @override
  Future<MirrorDeviceInfo?> getDeviceInfo() async {
    final failure = infoError;
    if (failure != null) throw failure;
    final id = firmwareId;
    if (id == null) return null;
    return MirrorDeviceInfo(
      id: id,
      displayApi: displayApi,
      mode: mode,
      baseMode: baseMode,
      pictureReady: pictureReady,
    );
  }

  @override
  Future<String> setDisplayMode(DisplayMode mode) async {
    final failure = modeError;
    if (failure != null) throw failure;
    modes.add(mode);
    return 'commit ok';
  }

  @override
  Future<String> pushLayout(String json) async {
    layouts.add(json);
    return 'commit ok';
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// The BLE link, with the connect behavior a test needs to state.
class _Connection extends MirrorConnection {
  _Connection({
    super.deviceId,
    super.deviceName,
    super.panelWidth,
    super.panelHeight,
  });

  _Session? live;

  /// What a connect to this link reports; null means firmware that predates
  /// `get device`.
  String? firmwareId;
  int displayApi = 1;
  Object? connectError;
  final List<String> connects = <String>[];

  /// The name the mirror answers `get config` with, on every link it opens:
  /// it is stored on the device, so it survives a reconnect.
  String? configName;

  /// The pong the link reports once a session is up; null means nothing has
  /// answered yet, which is what the rest of this file's cases assume.
  BlePong? pongOverride;

  @override
  BlePong? get pong => live == null ? null : pongOverride;
  int disconnects = 0;
  bool disposed = false;

  /// Puts a session on the link without a connect, for tests that start with
  /// an already-live Bluetooth link.
  void adopt(_Session session) {
    live = session;
    notifyListeners();
  }

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
    connects.add(id);
    final failure = connectError;
    if (failure != null) throw failure;
    live = _Session(firmwareId: firmwareId)
      ..displayApi = displayApi
      ..configName = configName;
    notifyListeners();
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
    live = null;
    notifyListeners();
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

/// The connection factory, keyed so each BLE remote id can report its own
/// firmware identity.
class _Radio {
  final Map<String, String?> byRemoteId = <String, String?>{};

  /// What an unbound connection (a LAN record's own link) reports.
  String? unbound = 'aaaa00000001';
  final List<_Connection> created = <_Connection>[];

  MirrorConnection call({
    String? deviceId,
    String? deviceName,
    int panelWidth = 0,
    int panelHeight = 0,
  }) {
    final connection = _Connection(
      deviceId: deviceId,
      deviceName: deviceName,
      panelWidth: panelWidth,
      panelHeight: panelHeight,
    );
    connection.firmwareId = deviceId == null ? unbound : byRemoteId[deviceId];
    created.add(connection);
    return connection;
  }
}

class _Counters {
  int inFlight = 0;
  int peak = 0;
}

/// The LAN client, with per-endpoint scripted answers.
class _Lan extends MirrorLan {
  _Lan(this.endpoint, this.counters) : super(endpoint);

  final String endpoint;
  final _Counters counters;

  MirrorStatus Function()? statusBody;
  Object? statusError;
  MirrorFrame? frameBody;
  Object? frameError;
  DisplayResult? modeResult;
  Object? modeError;
  DisplayResult? uploadResult;
  Object? uploadError;
  PutLayoutResult? putResult;
  String layout = '{"name":"home"}';

  int statusCalls = 0;
  int frameCalls = 0;
  int modeCalls = 0;
  int uploadCalls = 0;
  int putCalls = 0;
  DisplayMode? lastMode;
  Uint8List? uploaded;
  int? uploadedWidth;
  int? uploadedHeight;

  Completer<void>? statusGate;
  Completer<void>? uploadGate;

  @override
  Future<MirrorStatus> status() async {
    statusCalls++;
    counters.inFlight++;
    if (counters.inFlight > counters.peak) counters.peak = counters.inFlight;
    try {
      final gate = statusGate;
      if (gate != null) await gate.future;
      final failure = statusError;
      if (failure != null) throw failure;
      return statusBody?.call() ?? mirrorStatus();
    } finally {
      counters.inFlight--;
    }
  }

  @override
  Future<MirrorFrame> frame() async {
    frameCalls++;
    final failure = frameError;
    if (failure != null) throw failure;
    return frameBody ?? mirrorFrame();
  }

  @override
  Future<DisplayResult> setDisplayMode(DisplayMode mode) async {
    modeCalls++;
    lastMode = mode;
    final failure = modeError;
    if (failure != null) throw failure;
    return modeResult ??
        const DisplayResult(
          mode: DisplayMode.clock,
          baseMode: DisplayMode.clock,
          pictureReady: false,
        );
  }

  @override
  Future<DisplayResult> uploadPicture(
    Uint8List rgb, {
    required int width,
    required int height,
  }) async {
    uploadCalls++;
    uploaded = rgb;
    uploadedWidth = width;
    uploadedHeight = height;
    final gate = uploadGate;
    if (gate != null) await gate.future;
    final failure = uploadError;
    if (failure != null) throw failure;
    return uploadResult ??
        const DisplayResult(
          mode: DisplayMode.picture,
          baseMode: DisplayMode.picture,
          pictureReady: true,
        );
  }

  @override
  Future<String> getLayout() async => layout;

  @override
  Future<PutLayoutResult> putLayout(String json) async {
    putCalls++;
    return putResult ?? (ok: true, diag: const <String>[], error: null);
  }

  @override
  Future<bool> reachable({
    Duration timeout = const Duration(seconds: 4),
  }) async =>
      true;
}

/// A registry wired to fakes, plus a fake clock.
class _Fixture {
  _Fixture({Directory? directory, DateTime? start})
      : clock = start ?? DateTime.utc(2026, 9, 20, 12) {
    dir = directory ?? Directory.systemTemp.createTempSync('mirror-devices');
    if (directory == null) _temps.add(dir);
    registry = MirrorDevices(
      connectionFactory: radio.call,
      lanFactory: lan,
      browse: browse,
      scan: scan,
      ensureBleReady: () async {},
      previewDirectory: () async => dir,
      now: () => clock,
    );
  }

  late final Directory dir;
  late final MirrorDevices registry;
  final _Radio radio = _Radio();
  final _Counters counters = _Counters();
  final List<LanDevice> advertised = <LanDevice>[];
  final List<String> endpoints = <String>[];
  final Map<String, _Lan> lans = <String, _Lan>{};
  List<BleScanEntry> scanResults = <BleScanEntry>[];
  Object? browseError;
  int browseRuns = 0;
  DateTime clock;

  /// A further registry over the same prefs and preview directory: the
  /// relaunch case.
  _Fixture reload() => _Fixture(directory: dir, start: clock);

  MirrorLan lan(String endpoint) {
    endpoints.add(endpoint);
    return lans.putIfAbsent(endpoint, () => _Lan(endpoint, counters));
  }

  _Lan lanAt(String endpoint) => lans.putIfAbsent(
        endpoint,
        () => _Lan(endpoint, counters),
      );

  Stream<LanDevice> browse(
      {Duration timeout = const Duration(seconds: 5)}) async* {
    browseRuns++;
    final failure = browseError;
    if (failure != null) throw failure;
    for (final device in advertised) {
      yield device;
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<List<BleScanEntry>> scan({
    Duration timeout = const Duration(seconds: 6),
  }) async =>
      scanResults;

  BleScanEntry entry(String remoteId, {String name = 'Nearby mirror'}) =>
      BleScanEntry(BluetoothDevice.fromId(remoteId), name, -40);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));
  tearDown(() {
    for (final dir in _temps) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
    _temps.clear();
  });

  test('an empty registry loads empty, without a warning, once', () async {
    final fixture = _Fixture();
    await fixture.registry.load();
    await fixture.registry.load();

    expect(fixture.registry.devices, isEmpty);
    expect(fixture.registry.warning, isNull);
    expect(fixture.registry.active, isNull);
    expect(fixture.radio.created, isEmpty, reason: 'nothing to connect to');
    fixture.registry.dispose();
  });

  test('the single-device keys migrate into one remembered device', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'last_ble_device_id': 'REMOTE-1',
      'last_ble_device_name': 'Hall mirror',
      'last_panel_width': 64,
      'last_panel_height': 32,
    });
    final fixture = _Fixture();
    await fixture.registry.load();

    final device = fixture.registry.devices.single;
    expect(device.key, 'ble:REMOTE-1');
    expect(device.bleId, 'REMOTE-1');
    expect(device.name, 'Hall mirror');
    expect(device.width, 64);
    expect(device.height, 32);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(MirrorDevices.storeKey), isNotNull,
        reason: 'the new document is written before the old keys go');
    for (final key in <String>[
      'last_ble_device_id',
      'last_ble_device_name',
      'last_panel_width',
      'last_panel_height',
    ]) {
      expect(prefs.containsKey(key), isFalse, reason: '$key is imported once');
    }

    final relaunch = fixture.reload();
    await relaunch.registry.load();
    expect(relaunch.registry.devices.single.key, 'ble:REMOTE-1');
    expect(relaunch.registry.devices.single.name, 'Hall mirror');
    relaunch.registry.dispose();
    fixture.registry.dispose();
  });

  test('a remembered panel size with no device id invents nothing', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'last_panel_width': 64,
      'last_panel_height': 32,
    });
    final fixture = _Fixture();
    await fixture.registry.load();

    expect(fixture.registry.devices, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('last_panel_width'), 64);
    fixture.registry.dispose();
  });

  test('a corrupt document starts empty and warns', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      MirrorDevices.storeKey: 'not json at all',
    });
    final fixture = _Fixture();
    await fixture.registry.load();

    expect(fixture.registry.devices, isEmpty);
    expect(fixture.registry.warning, isNotNull);
    fixture.registry.dispose();
  });

  test('one corrupt record does not take the others with it', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      MirrorDevices.storeKey: jsonEncode(<String, Object>{
        'version': 1,
        'devices': <Object?>[
          <String, Object?>{
            'key': 'lan:10.0.0.1:80',
            'name': 'Kitchen',
            'host': '10.0.0.1',
            'port': 80,
            'width': 64,
            'height': 32,
            'flip180': false,
          },
          'a string where a record should be',
          <String, Object?>{'name': 'no key at all'},
        ],
      }),
    });
    final fixture = _Fixture();
    await fixture.registry.load();

    expect(fixture.registry.devices.single.key, 'lan:10.0.0.1:80');
    expect(fixture.registry.devices.single.port, 80);
    expect(fixture.registry.warning, isNotNull);
    fixture.registry.dispose();
  });

  test('an offline device keeps its last actual frame and its timestamp',
      () async {
    final fixture = _Fixture();
    await fixture.registry.load();
    final lan = fixture.lanAt('127.0.0.1:8080');
    lan.statusBody = () => mirrorStatus(id: 'aaaa00000001', name: 'Hall');
    lan.frameBody = mirrorFrame(sequence: 41, rgb: pattern(3));

    final device = await fixture.registry.addLan('127.0.0.1', 8080);
    await fixture.registry.refresh(device, includeFrame: true);
    await pumpEventQueue();
    await fixture.registry.saveMetadata(device);

    expect(device.frame, isNotNull);
    expect(device.frameAt, fixture.clock);
    expect(device.lastSeen, fixture.clock);

    final relaunch = fixture.reload();
    await relaunch.registry.load();
    final restored = relaunch.registry.devices.single;
    expect(restored.key, 'lan:127.0.0.1:8080');
    expect(restored.port, 8080);
    expect(restored.name, 'Hall');
    expect(restored.id, 'aaaa00000001');
    expect(restored.width, 64);
    expect(restored.height, 32);
    expect(restored.frame, isNotNull, reason: 'the preview survives a restart');
    expect(restored.frame!.sequence, 41);
    expect(restored.frame!.rgb, pattern(3));
    expect(restored.frameAt, fixture.clock);
    expect(restored.lastSeen, fixture.clock);
    expect(restored.lanReachable, isFalse,
        reason: 'nothing has been contacted yet');
    relaunch.registry.dispose();
    fixture.registry.dispose();
  });

  test('two mirrors with the same name stay separate and isolated', () async {
    final fixture = _Fixture();
    await fixture.registry.load();
    fixture.lanAt('10.0.0.1:80').statusBody =
        () => mirrorStatus(id: 'aaaa00000001', name: 'Hall mirror');
    fixture.lanAt('10.0.0.2:80').statusBody =
        () => mirrorStatus(id: 'bbbb00000002', name: 'Hall mirror');

    final first = await fixture.registry.addLan('10.0.0.1', 80);
    final second = await fixture.registry.addLan('10.0.0.2', 80);

    expect(fixture.registry.devices.length, 2,
        reason: 'a name is not an identity');
    expect(first.id, 'aaaa00000001');
    expect(second.id, 'bbbb00000002');
    expect(first.key, isNot(second.key));

    await fixture.registry.setMode(second, DisplayMode.picture);
    expect(fixture.lanAt('10.0.0.2:80').lastMode, DisplayMode.picture);
    expect(fixture.lanAt('10.0.0.1:80').modeCalls, 0,
        reason: 'only the tile that was tapped changed');
    fixture.registry.dispose();
  });

  test('a LAN record and the Bluetooth side of the same mirror merge',
      () async {
    final fixture = _Fixture();
    await fixture.registry.load();
    fixture.lanAt('127.0.0.1:8080').statusBody =
        () => mirrorStatus(id: 'aaaa00000001', name: 'Hall');
    final lanRecord = await fixture.registry.addLan('127.0.0.1', 8080);
    expect(fixture.registry.devices.length, 1);
    final candidateIndex = fixture.radio.created.length;

    fixture.radio.byRemoteId['REMOTE-1'] = 'aaaa00000001';
    final merged = await fixture.registry.addBle(fixture.entry('REMOTE-1'));

    expect(identical(merged, lanRecord), isTrue,
        reason: 'the earlier record is the one that survives');
    expect(fixture.registry.devices.length, 1,
        reason: 'the confirmed firmware id is one device, not two');
    expect(merged.key, 'lan:127.0.0.1:8080',
        reason: 'the earlier record keeps its key and its tile');
    expect(merged.bleId, 'REMOTE-1');
    expect(merged.endpoint, '127.0.0.1:8080');
    expect(merged.port, 8080);

    final candidate = fixture.radio.created[candidateIndex];
    expect(candidate.disposed, isTrue,
        reason: 'the throwaway connection that read the identity is closed');
    final lanConnection = fixture.radio.created.first;
    expect(lanConnection.connects, <String>['REMOTE-1'],
        reason: 'the retained record reopens the link itself');
    expect(merged.bleConnected, isTrue);
    fixture.registry.dispose();
  });

  test('a Bluetooth record absorbs the LAN address discovered later', () async {
    final fixture = _Fixture();
    await fixture.registry.load();
    fixture.radio.byRemoteId['REMOTE-1'] = 'aaaa00000001';
    final bleRecord = await fixture.registry.addBle(fixture.entry('REMOTE-1'));
    expect(bleRecord.key, 'ble:REMOTE-1');
    expect(bleRecord.endpoint, isNull);

    fixture.lanAt('10.0.0.7:80').statusBody =
        () => mirrorStatus(id: 'aaaa00000001', name: 'Hall');
    final survivor = await fixture.registry.addLan('10.0.0.7', 80);

    expect(fixture.registry.devices.length, 1);
    expect(identical(survivor, bleRecord), isTrue,
        reason: 'the earlier record wins, so a held reference still works');
    expect(survivor.key, 'ble:REMOTE-1');
    expect(survivor.endpoint, '10.0.0.7:80');
    expect(survivor.bleConnected, isTrue,
        reason: 'the live Bluetooth link was not disturbed by the merge');
    fixture.registry.dispose();
  });

  test('an address reused by another mirror can never be written to', () async {
    final fixture = _Fixture();
    await fixture.registry.load();
    final lan = fixture.lanAt('10.0.0.1:80');
    lan.statusBody = () => mirrorStatus(id: 'aaaa00000001', name: 'Hall');
    final device = await fixture.registry.addLan('10.0.0.1', 80);
    expect(device.lanReachable, isTrue);

    // The address answers as different hardware now (DHCP handed it on).
    lan.statusBody = () => mirrorStatus(id: 'cccc00000003', name: 'Study');

    await expectLater(
      fixture.registry.setMode(device, DisplayMode.picture),
      throwsA(isA<MirrorRegistryException>()),
    );
    expect(lan.modeCalls, 0, reason: 'no mode change reached the replacement');
    expect(device.host, isNull, reason: 'the endpoint is invalidated');
    expect(device.endpoint, isNull);
    expect(device.lanReachable, isFalse);
    expect(device.error, isNotNull);
    expect(fixture.registry.devices.single.key, 'lan:10.0.0.1:80',
        reason: 'the record survives with its history and preview');
    fixture.registry.dispose();
  });

  test('a Bluetooth link to another mirror is refused before any command',
      () async {
    final fixture = _Fixture();
    await fixture.registry.load();
    fixture.lanAt('10.0.0.1:80').statusBody =
        () => mirrorStatus(id: 'aaaa00000001', name: 'Hall');
    final device = await fixture.registry.addLan('10.0.0.1', 80);
    fixture.radio.unbound = 'cccc00000003'; // the wrong hardware answers
    final session = _Session(firmwareId: 'cccc00000003');
    fixture.radio.created.first.adopt(session);

    await expectLater(
      fixture.registry.setMode(device, DisplayMode.picture),
      throwsA(isA<MirrorRegistryException>()),
    );
    expect(session.modes, isEmpty, reason: 'nothing was sent to it');
    expect(device.bleConnected, isFalse, reason: 'the wrong link is dropped');
    fixture.registry.dispose();
  });

  test('Wi-Fi reachability and the Bluetooth link are independent', () async {
    final fixture = _Fixture();
    await fixture.registry.load();
    final lan = fixture.lanAt('10.0.0.1:80');
    lan.statusBody = () => mirrorStatus(id: 'aaaa00000001', name: 'Hall');
    final device = await fixture.registry.addLan('10.0.0.1', 80);
    expect(device.lanReachable, isTrue);

    // Wi-Fi goes away; the Bluetooth link is still live.
    fixture.radio.created.first.adopt(_Session());
    lan.statusError = MirrorApiException('could not reach 10.0.0.1');
    await fixture.registry.refresh(device);
    expect(device.lanReachable, isFalse);
    expect(device.bleConnected, isTrue,
        reason: 'a Wi-Fi failure says nothing about Bluetooth');

    // Wi-Fi answers again; the Bluetooth link drops.
    lan.statusError = null;
    await fixture.registry.refresh(device);
    expect(device.lanReachable, isTrue);
    await fixture.radio.created.first.disconnect();
    expect(device.bleConnected, isFalse);
    expect(device.lanReachable, isTrue,
        reason: 'a Bluetooth failure says nothing about Wi-Fi');
    fixture.registry.dispose();
  });

  test('a failed frame fetch leaves the last actual frame alone', () async {
    final fixture = _Fixture();
    await fixture.registry.load();
    final lan = fixture.lanAt('10.0.0.1:80');
    lan.statusBody = () => mirrorStatus(id: 'aaaa00000001');
    lan.frameBody = mirrorFrame(sequence: 7, rgb: pattern(1));
    final device = await fixture.registry.addLan('10.0.0.1', 80);
    await fixture.registry.refresh(device, includeFrame: true);
    final at = device.frameAt;
    expect(device.frame!.sequence, 7);
    expect(device.frameFresh, isTrue);

    fixture.clock = fixture.clock.add(const Duration(seconds: 5));
    lan.frameError =
        MirrorApiException('snapshot unavailable', statusCode: 503);
    await fixture.registry.refresh(device, includeFrame: true);

    expect(device.frame!.sequence, 7, reason: 'the old image is still real');
    expect(device.frame!.rgb, pattern(1));
    expect(device.frameAt, at,
        reason: 'the timestamp still describes the saved bytes');
    expect(device.lanReachable, isTrue,
        reason: 'a busy snapshot endpoint is not an offline device');
    expect(device.frameFresh, isFalse,
        reason: 'reachable status must not present a stale snapshot as live');
    lan.frameError = null;
    await fixture.registry.refresh(device, includeFrame: true);
    expect(device.frameFresh, isTrue);
    lan.statusError = MirrorApiException('connection lost');
    await fixture.registry.refresh(device);
    lan.statusError = null;
    await fixture.registry.refresh(device);
    expect(device.lanReachable, isTrue);
    expect(device.frameFresh, isFalse,
        reason: 'status recovery alone cannot refresh an offline snapshot');
    fixture.registry.dispose();
  });

  test('firmware without the display API is never asked for a frame', () async {
    final fixture = _Fixture();
    await fixture.registry.load();
    final lan = fixture.lanAt('10.0.0.1:80');
    lan.statusBody = () => mirrorStatus(id: 'aaaa00000001', displayApi: 0);
    final device = await fixture.registry.addLan('10.0.0.1', 80);
    await fixture.registry.refresh(device, includeFrame: true);

    expect(device.supportsDisplay, isFalse);
    expect(lan.frameCalls, 0, reason: '/api/frame does not exist there');
    expect(device.frame, isNull);
    fixture.registry.dispose();
  });

  test('the port from the address is what gets used', () async {
    final fixture = _Fixture();
    await fixture.registry.load();
    final lan = fixture.lanAt('127.0.0.1:8081');
    lan.statusBody = () => mirrorStatus(id: 'aaaa00000001', ip: '10.0.0.9');

    final device = await fixture.registry.addLan('127.0.0.1', 8081);

    expect(device.id, 'aaaa00000001',
        reason: 'the client built for 127.0.0.1:8081 answered');
    expect(device.endpoint, '127.0.0.1:8081');
    expect(device.port, 8081);
    expect(device.status!.ip, '10.0.0.9',
        reason: 'the reported address is recorded, not adopted');
    fixture.registry.dispose();
  });

  test('discovery adds only addresses that identify as mirrors', () async {
    final fixture = _Fixture();
    await fixture.registry.load();
    fixture.advertised.addAll(<LanDevice>[
      LanDevice('10.0.0.1', 80),
      LanDevice('10.0.0.2', 80),
    ]);
    fixture.lanAt('10.0.0.1:80').statusBody =
        () => mirrorStatus(id: 'aaaa00000001', name: 'Kitchen');
    fixture.lanAt('10.0.0.2:80').statusError =
        MirrorApiException('could not reach 10.0.0.2');

    await Future.wait(<Future<void>>[
      fixture.registry.refreshDiscovery(),
      fixture.registry.refreshDiscovery(),
    ]);

    expect(fixture.browseRuns, 1, reason: 'no overlapping discovery runs');
    expect(fixture.registry.devices.map((d) => d.key),
        <String>['lan:10.0.0.1:80']);
    expect(fixture.registry.devices.single.name, 'Kitchen');
    expect(fixture.registry.discoveryError, isNull);

    final second = fixture.reload();
    second.browseError = Exception('no multicast interface');
    await second.registry.refreshDiscovery();
    expect(second.registry.discoveryError, isNotNull);
    second.registry.dispose();
    fixture.registry.dispose();
  });

  test('a mirror that reports no name is not named after its address',
      () async {
    final fixture = _Fixture();
    await fixture.registry.load();
    fixture.advertised.add(LanDevice('10.0.0.9', 80));
    // Firmware from before the identity fields: /api/status describes a panel
    // but carries no id and no name.
    fixture.lanAt('10.0.0.9:80').statusBody = () => mirrorStatus();

    await fixture.registry.refreshDiscovery();

    final device = fixture.registry.devices.single;
    expect(device.endpoint, '10.0.0.9:80');
    expect(device.name, isEmpty,
        reason: 'a device that has not said what it is called has no name');
    expect(device.displayName, MirrorDevice.unnamedLabel,
        reason: 'a tile must not label a mirror with the address it answers '
            'on, nor with the mDNS name it was discovered under');
    fixture.registry.dispose();
  });

  test('the name a mirror reports replaces a placeholder an older build saved',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      MirrorDevices.storeKey: jsonEncode(<String, Object>{
        'version': 1,
        'devices': <Object?>[
          <String, Object?>{
            'key': 'lan:127.0.0.1:80',
            'name': '192.168.4.1',
            'host': '127.0.0.1',
            'port': 80,
          },
          <String, Object?>{
            'key': 'ble:REMOTE-2',
            'ble_id': 'REMOTE-2',
            'name': 'Smart Mirror._smartmirror._tcp.local',
          },
        ],
      }),
    });
    final fixture = _Fixture();
    await fixture.registry.load();

    // Records written before the registry waited for a name listed a mirror
    // under an address or an mDNS key. Neither is a name, so neither survives
    // the launch: the tiles say the mirrors are unnamed until one names itself.
    for (final device in fixture.registry.devices) {
      expect(device.name, isEmpty, reason: device.key);
      expect(device.displayName, MirrorDevice.unnamedLabel, reason: device.key);
    }

    fixture.lanAt('127.0.0.1:80').statusBody =
        () => mirrorStatus(id: 'aaaa00000001', name: 'Twirling Elephant');
    await fixture.registry.refresh(fixture.registry.devices.first);

    expect(fixture.registry.devices.first.name, 'Twirling Elephant',
        reason: 'the mirror names itself on the next contact');
    fixture.registry.dispose();
  });

  test('pairing names a record from the mirror’s own advertisement', () async {
    final fixture = _Fixture();
    await fixture.registry.load();
    // Firmware that answers a status without a name: nothing to list the
    // record under until the mirror says what it is called.
    fixture.lanAt('10.0.0.1:80').statusBody =
        () => mirrorStatus(id: 'aaaa00000001');
    final device = await fixture.registry.addLan('10.0.0.1', 80);
    expect(device.name, isEmpty);

    fixture.radio.byRemoteId['REMOTE-1'] = 'aaaa00000001';
    await fixture.registry
        .attachBle(device, fixture.entry('REMOTE-1', name: 'Dashing Dolphin'));

    expect(device.name, 'Dashing Dolphin',
        reason: 'the advertised name is the mirror’s own, not an address');
    expect(device.displayName, 'Dashing Dolphin');
    fixture.registry.dispose();
  });

  test('a Bluetooth link names a record its advertisement left unnamed',
      () async {
    final fixture = _Fixture();
    await fixture.registry.load();
    fixture.radio.byRemoteId['REMOTE-1'] = 'aaaa00000001';
    final device =
        await fixture.registry.addBle(fixture.entry('REMOTE-1', name: ''));

    expect(device.name, isEmpty, reason: 'the advertisement carried no name');
    expect(device.displayName, MirrorDevice.unnamedLabel);

    // The name lives in the mirror's config, not in the `device` reply, so a
    // record reached only over Bluetooth asks for it on the next connect.
    fixture.radio.created.last.configName = 'Twirling Elephant';
    await fixture.registry.connect(device);

    expect(device.name, 'Twirling Elephant',
        reason: 'the mirror named itself over Bluetooth');
    fixture.registry.dispose();
  });

  test('discovery names and rehomes a record that knew the mirror already',
      () async {
    // The record was made when the mirror was in setup mode, at the address
    // its access point answers on: an address nothing reaches now, and no
    // name, because that firmware never reported one.
    SharedPreferences.setMockInitialValues(<String, Object>{
      MirrorDevices.storeKey: jsonEncode(<String, Object>{
        'version': 1,
        'devices': <Object?>[
          <String, Object?>{
            'key': 'lan:192.168.4.1:80',
            'id': 'aaaa00000001',
            'ble_id': 'REMOTE-1',
            'name': '192.168.4.1',
            'host': '192.168.4.1',
            'port': 80,
          },
        ],
      }),
    });
    final fixture = _Fixture();
    await fixture.registry.load();
    fixture.advertised.add(LanDevice('10.0.0.9', 80));
    fixture.lanAt('10.0.0.9:80').statusBody =
        () => mirrorStatus(id: 'aaaa00000001', name: 'Twirling Elephant');

    await fixture.registry.refreshDiscovery();

    final device = fixture.registry.devices.single;
    expect(device.key, 'lan:192.168.4.1:80',
        reason: 'the record that already knew the hardware is the one kept');
    expect(device.endpoint, '10.0.0.9:80',
        reason: 'the merge moves the record onto the address that answered');
    expect(device.name, 'Twirling Elephant',
        reason: 'the name travels with the merge, or the tile stays unnamed');
    fixture.registry.dispose();
  });

  test('a mirror says which Bluetooth record is its own, and the two fold',
      () async {
    // The Bluetooth record a scan made, before its identity was confirmed: no
    // firmware id, so nothing else in the registry can match it to the mirror
    // discovered later on the LAN — except the mirror saying which Bluetooth
    // address is behind its Wi-Fi identity.
    SharedPreferences.setMockInitialValues(<String, Object>{
      MirrorDevices.storeKey: jsonEncode(<String, Object>{
        'version': 1,
        'devices': <Object?>[
          <String, Object?>{
            'key': 'ble:30:30:F9:18:36:56',
            'ble_id': '30:30:F9:18:36:56',
            'name': 'Twirling Elephant',
            'width': 64,
            'height': 32,
          },
        ],
      }),
    });
    final fixture = _Fixture();
    await fixture.registry.load();
    fixture.advertised.add(LanDevice('10.0.0.9', 80,
        name: 'Twirling Elephant', bleAddress: '30:30:F9:18:36:56'));
    fixture.lanAt('10.0.0.9:80').statusBody =
        () => mirrorStatus(id: '3030f9183654', name: 'Twirling Elephant');

    await fixture.registry.refreshDiscovery();

    final device = fixture.registry.devices.single;
    expect(device.key, 'ble:30:30:F9:18:36:56',
        reason: 'the earlier record carries the identity now');
    expect(device.id, '3030f9183654');
    expect(device.endpoint, '10.0.0.9:80',
        reason: 'the record moves onto the address the mirror answered on');
    expect(device.name, 'Twirling Elephant');
    fixture.registry.dispose();
  });

  test('an advertisement does not fuse two mirrors that both have an identity',
      () async {
    // Every advertisement is unauthenticated. A mirror claiming a Bluetooth
    // address another record already owns, while both carry a confirmed
    // identity of their own, is a contradiction: a duplicate tile is cheaper
    // than one record standing for two mirrors.
    SharedPreferences.setMockInitialValues(<String, Object>{
      MirrorDevices.storeKey: jsonEncode(<String, Object>{
        'version': 1,
        'devices': <Object?>[
          <String, Object?>{
            'key': 'ble:30:30:F9:18:36:56',
            'id': 'aaaaaaaaaaaa',
            'ble_id': '30:30:F9:18:36:56',
            'name': 'Hall mirror',
          },
        ],
      }),
    });
    final fixture = _Fixture();
    await fixture.registry.load();
    fixture.advertised.add(LanDevice('10.0.0.9', 80,
        name: 'Kitchen mirror', bleAddress: '30:30:F9:18:36:56'));
    fixture.lanAt('10.0.0.9:80').statusBody =
        () => mirrorStatus(id: 'bbbbbbbbbbbb', name: 'Kitchen mirror');

    await fixture.registry.refreshDiscovery();

    expect(fixture.registry.devices, hasLength(2));
    expect(fixture.registry.devices.map((d) => d.name),
        containsAll(<String>['Hall mirror', 'Kitchen mirror']));
    fixture.registry.dispose();
  });

  test('loading a remembered device connects nothing', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      MirrorDevices.storeKey: jsonEncode(<String, Object>{
        'version': 1,
        'devices': <Object?>[
          <String, Object?>{
            'key': 'ble:REMOTE-1',
            'ble_id': 'REMOTE-1',
            'name': 'Hall',
            'port': 80,
            'width': 64,
            'height': 32,
            'flip180': false,
          },
        ],
      }),
    });
    final fixture = _Fixture();
    await fixture.registry.load();

    expect(fixture.registry.devices.single.width, 64);
    expect(fixture.radio.created.single.connects, isEmpty,
        reason: 'the radio stays shut until the user asks for a device');
    expect(fixture.registry.devices.single.bleConnected, isFalse);
    fixture.registry.dispose();
  });

  test('no more than two device refreshes run at once', () async {
    final fixture = _Fixture();
    await fixture.registry.load();
    final gate = Completer<void>();
    final devices = <MirrorDevice>[];
    for (var i = 0; i < 4; i++) {
      final lan = fixture.lanAt('10.0.0.$i:80');
      lan.statusBody = () => mirrorStatus(id: 'aaaa0000000$i');
      devices.add(await fixture.registry.addLan('10.0.0.$i', 80));
    }
    // Only now: the adds above refresh, and a closed gate would hold them.
    for (var i = 0; i < 4; i++) {
      fixture.lanAt('10.0.0.$i:80').statusGate = gate;
    }
    fixture.counters.peak = 0;

    final refreshes = <Future<void>>[
      for (final device in devices) fixture.registry.refresh(device),
    ];
    await pumpEventQueue();
    expect(fixture.counters.peak, 2,
        reason: 'a screenful of tiles must not open every socket at once');
    expect(fixture.counters.inFlight, 2);

    gate.complete();
    await Future.wait(refreshes);
    expect(devices.map((d) => d.lanReachable), everyElement(isTrue));
    fixture.registry.dispose();
  });

  test(
      'a second refresh joins the first, and a frame request gets its own pass',
      () async {
    final fixture = _Fixture();
    await fixture.registry.load();
    final lan = fixture.lanAt('10.0.0.1:80');
    lan.statusBody = () => mirrorStatus(id: 'aaaa00000001');
    final device = await fixture.registry.addLan('10.0.0.1', 80);
    final gate = Completer<void>();
    lan.statusGate = gate;
    final callsBefore = lan.statusCalls;

    final first = fixture.registry.refresh(device);
    await pumpEventQueue();
    final second = fixture.registry.refresh(device);
    final withFrame = fixture.registry.refresh(device, includeFrame: true);
    await pumpEventQueue();
    expect(lan.statusCalls - callsBefore, 1,
        reason: 'one refresh per record at a time');

    gate.complete();
    await Future.wait(<Future<void>>[first, second, withFrame]);
    expect(lan.statusCalls - callsBefore, 2,
        reason: 'the frame request ran a second status pass');
    expect(lan.frameCalls, 1);
    fixture.registry.dispose();
  });

  test(
      'activate connects only the chosen device, deactivate protects a newer '
      'route', () async {
    final fixture = _Fixture();
    await fixture.registry.load();
    fixture.radio.byRemoteId['REMOTE-1'] = 'aaaa00000001';
    fixture.radio.byRemoteId['REMOTE-2'] = 'bbbb00000002';
    final first = await fixture.registry.addBle(fixture.entry('REMOTE-1'));
    final second = await fixture.registry.addBle(fixture.entry('REMOTE-2'));
    // Adding a scanned device necessarily connects it to read its identity;
    // start from a clean slate so what is measured is the handover.
    for (final connection in fixture.radio.created) {
      await connection.disconnect();
      connection.connects.clear();
    }

    await fixture.registry.activate(first);
    expect(identical(fixture.registry.active, first), isTrue);
    expect(first.bleConnected, isTrue);
    expect(second.bleConnected, isFalse, reason: 'only the chosen device');
    expect(fixture.radio.created[1].connects, isEmpty,
        reason: 'the other device was not connected for being remembered');

    await fixture.registry.activate(second);
    expect(second.bleConnected, isTrue);
    expect(first.bleConnected, isTrue,
        reason: 'its route has not exited, so its link is left alone');

    await fixture.registry.deactivate(first);
    expect(first.bleConnected, isFalse);
    expect(second.bleConnected, isTrue,
        reason: 'the route that exited cannot drop a newer link');
    expect(identical(fixture.registry.active, second), isTrue);

    await fixture.registry.deactivate(second);
    expect(second.bleConnected, isFalse);
    expect(fixture.registry.active, isNull);
    fixture.registry.dispose();
  });

  test('the armed dashboard links the mirror used most recently', () async {
    final fixture = _Fixture();
    await fixture.registry.load();
    fixture.radio.byRemoteId['REMOTE-1'] = 'aaaa00000001';
    fixture.radio.byRemoteId['REMOTE-2'] = 'bbbb00000002';
    final older = await fixture.registry.addBle(fixture.entry('REMOTE-1'));
    fixture.clock = fixture.clock.add(const Duration(minutes: 5));
    final newer = await fixture.registry.addBle(fixture.entry('REMOTE-2'));
    // Adding a scanned device necessarily connects it to read its identity;
    // start from links that are closed so what is measured is the policy.
    for (final connection in fixture.radio.created) {
      await connection.disconnect();
      connection.connects.clear();
    }

    await fixture.registry.setAutoConnect(true);

    expect(identical(fixture.registry.autoConnected, newer), isTrue,
        reason: 'the dashboard follows the mirror last worked with');
    expect(newer.bleConnected, isTrue);
    expect(older.bleConnected, isFalse,
        reason: 'one link, not one per remembered device');
    expect(fixture.radio.created[1].connects, <String>['REMOTE-2']);
    expect(fixture.radio.created[0].connects, isEmpty);
    fixture.registry.dispose();
  });

  test('disarming closes the dashboard link but never an open page’s',
      () async {
    final fixture = _Fixture();
    await fixture.registry.load();
    fixture.radio.byRemoteId['REMOTE-1'] = 'aaaa00000001';
    final device = await fixture.registry.addBle(fixture.entry('REMOTE-1'));
    for (final connection in fixture.radio.created) {
      await connection.disconnect();
      connection.connects.clear();
    }

    await fixture.registry.setAutoConnect(true);
    expect(device.bleConnected, isTrue);
    await fixture.registry.setAutoConnect(false);
    expect(device.bleConnected, isFalse,
        reason: 'leaving the app stops holding a radio for nobody');
    expect(fixture.registry.autoConnected, isNull);

    await fixture.registry.setAutoConnect(true);
    await fixture.registry.activate(device);
    expect(device.bleConnected, isTrue);
    await fixture.registry.setAutoConnect(false);
    expect(device.bleConnected, isTrue,
        reason: 'the route that opened it still owns it');
    fixture.registry.dispose();
  });

  test('closing an armed device page hands the link back, not away',
      () async {
    final fixture = _Fixture();
    await fixture.registry.load();
    fixture.radio.byRemoteId['REMOTE-1'] = 'aaaa00000001';
    final device = await fixture.registry.addBle(fixture.entry('REMOTE-1'));
    for (final connection in fixture.radio.created) {
      await connection.disconnect();
      connection.connects.clear();
    }

    await fixture.registry.setAutoConnect(true);
    await fixture.registry.activate(device);
    await fixture.registry.deactivate(device);

    expect(device.bleConnected, isTrue,
        reason: 'the tile still reads Bluetooth when the page closes');
    expect(identical(fixture.registry.autoConnected, device), isTrue);
    expect(fixture.radio.created.single.connects, <String>['REMOTE-1'],
        reason: 'the handover did not close and reopen the link');

    await fixture.registry.setAutoConnect(false);
    expect(device.bleConnected, isFalse);
    fixture.registry.dispose();
  });

  test('an absent mirror is retried on a cadence, not on every poll',
      () async {
    final fixture = _Fixture();
    await fixture.registry.load();
    fixture.radio.byRemoteId['REMOTE-1'] = 'aaaa00000001';
    final device = await fixture.registry.addBle(fixture.entry('REMOTE-1'));
    final link = fixture.radio.created.single;
    await link.disconnect();
    link.connects.clear();
    link.connectError = BleUnavailableException('there is no radio');

    await fixture.registry.setAutoConnect(true);
    expect(link.connects, hasLength(1));
    expect(device.bleConnected, isFalse);
    expect(fixture.registry.autoConnected, isNull);

    await fixture.registry.retryAutoConnect();
    await fixture.registry.retryAutoConnect();
    expect(link.connects, hasLength(1),
        reason: 'the tile poll is seconds apart; the retry is not');

    fixture.clock = fixture.clock.add(MirrorDevices.autoConnectRetry);
    link.connectError = null;
    await fixture.registry.retryAutoConnect();
    expect(link.connects, hasLength(2),
        reason: 'the mirror may have been switched on since');
    expect(device.bleConnected, isTrue,
        reason: 'powering it on brings the tile up without a tap');
    fixture.registry.dispose();
  });

  test('pairing a scandalous Bluetooth device to a LAN record is refused',
      () async {
    final fixture = _Fixture();
    await fixture.registry.load();
    final lan = fixture.lanAt('10.0.0.1:80');
    lan.statusBody = () => mirrorStatus(id: 'aaaa00000001', name: 'Hall');
    final device = await fixture.registry.addLan('10.0.0.1', 80);

    fixture.radio.byRemoteId['REMOTE-9'] = 'cccc00000003'; // a different mirror
    await expectLater(
      fixture.registry.attachBle(device, fixture.entry('REMOTE-9')),
      throwsA(isA<MirrorRegistryException>()),
    );

    expect(device.bleId, isNull, reason: 'the alias was not attached');
    expect(device.bleConnected, isFalse);
    expect(device.error, isNotNull);
    expect(lan.modeCalls, 0, reason: 'no mutation before the identity check');
    fixture.registry.dispose();
  });

  test('upload sends the prepared bytes and records what the mirror stored',
      () async {
    final fixture = _Fixture();
    await fixture.registry.load();
    final lan = fixture.lanAt('10.0.0.1:80');
    lan.statusBody = () => mirrorStatus(
          id: 'aaaa00000001',
          mode: lan.uploadCalls > 0 ? DisplayMode.picture : DisplayMode.clock,
          baseMode:
              lan.uploadCalls > 0 ? DisplayMode.picture : DisplayMode.clock,
          pictureReady: lan.uploadCalls > 0,
        );
    final device = await fixture.registry.addLan('10.0.0.1', 80);
    final rgb = pattern(9);

    final result = await fixture.registry.uploadPicture(
      device,
      rgb,
      width: 64,
      height: 32,
    );

    expect(lan.uploaded, rgb);
    expect(lan.uploadedWidth, 64);
    expect(lan.uploadedHeight, 32);
    expect(result.mode, DisplayMode.picture);
    expect(device.mode, DisplayMode.picture);
    expect(device.baseMode, DisplayMode.picture);
    expect(device.pictureReady, isTrue);
    expect(device.uploading, isFalse);
    expect(lan.frameCalls, greaterThan(0),
        reason: 'the tile is refreshed from the device, not from the upload');
    fixture.registry.dispose();
  });

  test('upload refuses a panel that changed shape before sending', () async {
    final fixture = _Fixture();
    await fixture.registry.load();
    final lan = fixture.lanAt('10.0.0.1:80');
    lan.statusBody = () => mirrorStatus(id: 'aaaa00000001');
    final device = await fixture.registry.addLan('10.0.0.1', 80);

    await expectLater(
      fixture.registry.uploadPicture(device, pattern(), width: 80, height: 40),
      throwsA(isA<MirrorRegistryException>()),
    );
    expect(lan.uploadCalls, 0, reason: 'no blind crop was sent');
    fixture.registry.dispose();
  });

  test('upload without a Wi-Fi address asks for one', () async {
    final fixture = _Fixture();
    await fixture.registry.load();
    fixture.radio.byRemoteId['REMOTE-1'] = 'aaaa00000001';
    final device = await fixture.registry.addBle(fixture.entry('REMOTE-1'));

    await expectLater(
      fixture.registry.uploadPicture(device, pattern(), width: 64, height: 32),
      throwsA(
        isA<MirrorRegistryException>().having(
          (e) => e.message,
          'message',
          MirrorDevices.uploadNeedsWifiMessage,
        ),
      ),
    );
    fixture.registry.dispose();
  });

  test('a refused upload surfaces the device reason with its status code',
      () async {
    final fixture = _Fixture();
    await fixture.registry.load();
    final lan = fixture.lanAt('10.0.0.1:80');
    lan.statusBody = () => mirrorStatus(id: 'aaaa00000001');
    final device = await fixture.registry.addLan('10.0.0.1', 80);
    lan.uploadError =
        MirrorApiException('panel dimensions changed', statusCode: 409);

    await expectLater(
      fixture.registry.uploadPicture(device, pattern(), width: 64, height: 32),
      throwsA(
        isA<MirrorRegistryException>()
            .having((e) => e.statusCode, 'statusCode', 409)
            .having(
                (e) => e.message, 'message', contains('dimensions changed')),
      ),
    );
    expect(device.uploading, isFalse,
        reason: 'a failed upload must be retryable');
    expect(device.lanReachable, isTrue,
        reason: 'the device answered; it is not offline');
    expect(device.error, contains('dimensions changed'));
    fixture.registry.dispose();
  });

  test('the preview cache is written at most once every 30 seconds', () async {
    final fixture = _Fixture();
    await fixture.registry.load();
    final lan = fixture.lanAt('10.0.0.1:80');
    lan.statusBody = () => mirrorStatus(id: 'aaaa00000001');
    final device = await fixture.registry.addLan('10.0.0.1', 80);

    /// The timestamp the document claims for the cached bytes.
    Future<DateTime?> savedFrameAt() async {
      final prefs = await SharedPreferences.getInstance();
      final document = jsonDecode(prefs.getString(MirrorDevices.storeKey)!)
          as Map<String, dynamic>;
      final record =
          (document['devices'] as List<dynamic>).single as Map<String, dynamic>;
      final at = record['frame_at'];
      return at is String ? DateTime.parse(at) : null;
    }

    final start = fixture.clock;
    lan.frameBody = mirrorFrame(sequence: 1, rgb: pattern(1));
    await fixture.registry.refresh(device, includeFrame: true);
    await pumpEventQueue();
    expect(await savedFrameAt(), start);

    fixture.clock = start.add(const Duration(seconds: 5));
    lan.frameBody = mirrorFrame(sequence: 2, rgb: pattern(2));
    await fixture.registry.refresh(device, includeFrame: true);
    await pumpEventQueue();
    expect(device.frame!.sequence, 2,
        reason: 'the tile shows the newest frame');
    expect(device.frameAt, fixture.clock);
    expect(await savedFrameAt(), start,
        reason: 'inside the window the cached file is left alone');

    fixture.clock = start.add(const Duration(seconds: 35));
    lan.frameBody = mirrorFrame(sequence: 3, rgb: pattern(3));
    await fixture.registry.refresh(device, includeFrame: true);
    await pumpEventQueue();
    expect(await savedFrameAt(), fixture.clock);

    final reloaded = fixture.reload();
    await reloaded.registry.load();
    final restored = reloaded.registry.devices.single;
    expect(restored.frame!.sequence, 3);
    expect(restored.frame!.rgb, pattern(3));
    expect(restored.frameAt, fixture.clock,
        reason: 'the timestamp and the bytes describe the same frame');
    reloaded.registry.dispose();
    fixture.registry.dispose();
  });

  test('forgetting a device removes its record and its cached preview',
      () async {
    final fixture = _Fixture();
    await fixture.registry.load();
    final lan = fixture.lanAt('10.0.0.1:80');
    lan.statusBody = () => mirrorStatus(id: 'aaaa00000001');
    final device = await fixture.registry.addLan('10.0.0.1', 80);
    await fixture.registry.refresh(device, includeFrame: true);
    await pumpEventQueue();
    await fixture.registry.saveMetadata(device);
    final previews =
        Directory(fixture.dir.path).listSync().whereType<File>().toList();
    expect(previews, isNotEmpty, reason: 'the preview was cached');

    await fixture.registry.remove(device);
    expect(fixture.registry.devices, isEmpty);
    expect(fixture.radio.created.first.disposed, isTrue);
    expect(fixture.dir.listSync().whereType<File>(), isEmpty);

    await expectLater(
      fixture.registry.refresh(device),
      completes,
      reason: 'the caller may still hold it',
    );
    await expectLater(
      fixture.registry.setMode(device, DisplayMode.clock),
      throwsA(isA<MirrorRegistryException>()),
    );
    fixture.registry.dispose();
  });

  test('two saved records for one mirror heal into one on load', () async {
    const key = 'ble:REMOTE-1';
    final name = base64Url.encode(utf8.encode(key)).replaceAll('=', '');
    // The Bluetooth record is the one carrying a preview; the LAN record was
    // written when the identity was confirmed on the network.
    final blePreview = encodeMirrorFrame(
      MirrorFrame(
        width: 64,
        height: 32,
        sequence: 5,
        brightness: 96,
        mode: DisplayMode.clock,
        flip180: true,
        rgb: pattern(6),
      ),
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      MirrorDevices.storeKey: jsonEncode(<String, Object>{
        'version': 1,
        'devices': <Object?>[
          <String, Object?>{
            'key': 'lan:10.0.0.1:80',
            'id': 'aaaa00000001',
            'name': 'Hall',
            'host': '10.0.0.1',
            'port': 80,
            'width': 0,
            'height': 0,
            'flip180': false,
          },
          <String, Object?>{
            'key': key,
            'id': 'aaaa00000001',
            'name': 'Hall mirror',
            'ble_id': 'REMOTE-1',
            'port': 80,
            'width': 64,
            'height': 32,
            'flip180': true,
            'frame_at': '2026-09-20T11:00:00.000Z',
          },
        ],
      }),
    });
    final fixture = _Fixture();
    await File('${fixture.dir.path}/$name.frame').writeAsBytes(blePreview);
    await fixture.registry.load();

    final device = fixture.registry.devices.single;
    expect(device.key, 'lan:10.0.0.1:80',
        reason: 'the earlier record is the one that survives');
    expect(device.id, 'aaaa00000001');
    expect(device.bleId, 'REMOTE-1', reason: 'the Bluetooth alias transfers');
    expect(device.endpoint, '10.0.0.1:80');
    expect(device.width, 64, reason: 'the known geometry transfers');
    expect(device.flip180, isTrue);
    expect(device.frame!.sequence, 5);
    expect(device.frameAt, DateTime.utc(2026, 9, 20, 11));

    final keptName =
        base64Url.encode(utf8.encode('lan:10.0.0.1:80')).replaceAll('=', '');
    final files = fixture.dir.listSync().whereType<File>().toList();
    expect(
        files.map((f) => f.uri.pathSegments.last), <String>['$keptName.frame'],
        reason: 'the preview moved onto the surviving record');
    fixture.registry.dispose();
  });

  test('a merged-away record is dropped, not refreshed or driven', () async {
    final fixture = _Fixture();
    await fixture.registry.load();
    fixture.radio.byRemoteId['REMOTE-1'] = 'aaaa00000001';
    final bleRecord = await fixture.registry.addBle(fixture.entry('REMOTE-1'));
    final lan = fixture.lanAt('10.0.0.1:80');
    lan.statusBody = () => mirrorStatus(name: 'Hall'); // identity not known yet
    final lanRecord = await fixture.registry.addLan('10.0.0.1', 80);
    expect(fixture.registry.devices.length, 2,
        reason: 'without an identity these are two records, not one device');

    // The address now identifies as the mirror already known over Bluetooth;
    // the refresh that discovers it must abandon the record it was started
    // for, not keep polling it and not give it a tile.
    lan.statusBody = () => mirrorStatus(id: 'aaaa00000001', name: 'Hall');
    await fixture.registry.refresh(lanRecord, includeFrame: true);

    expect(fixture.registry.devices.length, 1);
    expect(identical(fixture.registry.devices.single, bleRecord), isTrue);
    expect(identical(lanRecord.mergedInto, bleRecord), isTrue);
    expect(bleRecord.endpoint, '10.0.0.1:80',
        reason: 'the address moves to the record that survived');
    expect(lan.frameCalls, 0,
        reason: 'a dropped record is not asked for a preview');
    await expectLater(fixture.registry.refresh(lanRecord), completes);
    await expectLater(
      fixture.registry.setMode(lanRecord, DisplayMode.picture),
      throwsA(isA<MirrorRegistryException>()),
    );
    expect(lan.modeCalls, 0);
    fixture.registry.dispose();
  });

  test('a late read cannot revive a removed record or overwrite another tile',
      () async {
    final f = _Fixture();
    await f.registry.load();
    final a = f.lanAt('10.0.0.1:80')
      ..statusBody = () => mirrorStatus(id: 'aaaaaaaaaaaa', name: 'A');
    final b = f.lanAt('10.0.0.2:80')
      ..statusBody = () => mirrorStatus(id: 'bbbbbbbbbbbb', name: 'B');
    final recordA = await f.registry.addLan('10.0.0.1', 80);
    final recordB = await f.registry.addLan('10.0.0.2', 80);
    a.statusGate = Completer<void>();
    final read = f.registry.refresh(recordA, includeFrame: true);
    await Future<void>.delayed(Duration.zero);
    await f.registry.remove(recordA);
    await f.registry.activate(recordB);
    a.statusBody = () => mirrorStatus(
        id: 'aaaaaaaaaaaa', name: 'Late A', mode: DisplayMode.picture);
    a.statusGate!.complete();
    await read;
    expect(f.registry.devices, [recordB]);
    expect(recordB.name, 'B');
    expect(recordB.mode, DisplayMode.clock);
    expect(b.uploadCalls, 0);
    f.registry.dispose();
  });

  test('an in-flight upload remains pinned while the active route changes',
      () async {
    final f = _Fixture();
    await f.registry.load();
    final a = f.lanAt('10.0.0.1:80')
      ..statusBody = () => mirrorStatus(id: 'aaaaaaaaaaaa', name: 'A');
    final b = f.lanAt('10.0.0.2:80')
      ..statusBody = () => mirrorStatus(id: 'bbbbbbbbbbbb', name: 'B');
    final recordA = await f.registry.addLan('10.0.0.1', 80);
    final recordB = await f.registry.addLan('10.0.0.2', 80);
    await f.registry.activate(recordA);
    a.uploadGate = Completer<void>();
    final upload =
        f.registry.uploadPicture(recordA, pattern(9), width: 64, height: 32);
    while (a.uploadCalls == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    await f.registry.deactivate(recordA);
    await f.registry.activate(recordB);
    a.uploadGate!.complete();
    await upload;
    expect(a.uploaded, orderedEquals(pattern(9)));
    expect(b.uploaded, isNull);
    expect(recordB.mode, DisplayMode.clock);
    expect(f.registry.active, same(recordB));
    f.registry.dispose();
  });

  test('a known address replaced by legacy firmware cannot receive a mutation',
      () async {
    final f = _Fixture();
    await f.registry.load();
    final lan = f.lanAt('10.0.0.1:80')
      ..statusBody = () => mirrorStatus(id: 'aaaaaaaaaaaa');
    final device = await f.registry.addLan('10.0.0.1', 80);
    lan.statusBody = () => mirrorStatus(displayApi: 0);
    await expectLater(f.registry.sendLayout(device, '{}'),
        throwsA(isA<MirrorRegistryException>()));
    expect(lan.putCalls, 0);
    expect(device.endpoint, isNull);
    f.registry.dispose();
  });

  test('removal during identity verification cancels the unsent mutation',
      () async {
    final f = _Fixture();
    await f.registry.load();
    final lan = f.lanAt('10.0.0.1:80')
      ..statusBody = () => mirrorStatus(id: 'aaaaaaaaaaaa');
    final device = await f.registry.addLan('10.0.0.1', 80);
    lan.statusGate = Completer<void>();
    final send = f.registry.sendLayout(device, '{}');
    final checked = expectLater(send, throwsA(isA<MirrorRegistryException>()));
    await Future<void>.delayed(Duration.zero);
    await f.registry.remove(device);
    lan.statusGate!.complete();
    await checked;
    expect(lan.putCalls, 0);
    f.registry.dispose();
  });

  test('firmware update is unavailable without a live session', () async {
    final f = _Fixture();
    await f.registry.load();
    final device = await f.registry.addLan('10.0.0.7', 80);
    expect(device.canUpdateFirmware, isFalse);
    f.registry.dispose();
  });

  test('firmware update is available with a live session', () async {
    final f = _Fixture();
    await f.registry.load();
    final device = await f.registry.addBle(f.entry('REMOTE-1'));
    f.radio.created.last.adopt(_Session());
    expect(device.canUpdateFirmware, isTrue);
    f.registry.dispose();
  });
}
