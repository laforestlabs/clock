// One BLE link to one mirror.
//
// Transport only: the link lives here, not in a screen, so pushing and popping
// the Mirror screen no longer drops it. Nothing is remembered across launches
// any more -- the device registry owns persisted identities -- and a
// connection built for a device record is bound to that device's BLE target,
// so a route holding it cannot write to a different mirror. Screens listen to
// it as a ChangeNotifier and read [session] / [status].

import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'mirror_ble.dart';

/// Where the BLE link with the mirror currently stands.
enum MirrorConnectionStatus {
  /// No session, or the user disconnected. The last device is still
  /// remembered and can be reconnected.
  disconnected,

  /// A connect is in flight.
  connecting,

  /// [MirrorConnection.session] is live and answers commands.
  connected,

  /// The last connect attempt failed; [MirrorConnection.error] explains why.
  failed,
}

/// What the BLE pong line reports: "pong <version> <ip> <layout> <w> <h>".
class BlePong {
  const BlePong(this.version, this.ip, this.layout, this.width, this.height);

  final String version;
  final String ip;
  final String layout;
  final int width;
  final int height;
  static BlePong? parse(String pong) {
    final parts = pong.split(' ');
    if (parts.length < 6 || parts[0] != 'pong') return null;
    return BlePong(
      parts[1],
      parts[2],
      parts[3],
      int.tryParse(parts[4]) ?? 0,
      int.tryParse(parts[5]) ?? 0,
    );
  }
}

/// Outcome of requesting the Android 12+ runtime BLE permissions.
class BlePermissionGate {
  const BlePermissionGate(
      {required this.granted, this.permanentDenied = false});

  final bool granted;

  /// True when [granted] is false and the denial can only be undone in the
  /// system settings.
  final bool permanentDenied;
}

/// Request the runtime BLE permissions Android needs before scanning.
///
/// Android 12+ needs BLUETOOTH_SCAN and BLUETOOTH_CONNECT; Android 11 and
/// below needs a location grant instead (the manifest declares
/// ACCESS_FINE_LOCATION with maxSdkVersion 30, and the plugin has no legacy
/// scan/connect mapping on those builds). Everything else needs no runtime
/// permission.
///
/// The request is one batch call (a single dialog listing every permission)
/// and the outcome is read back with `Permission.status` afterwards:
/// permission_handler's request callback can report denied for a permission
/// the user just granted (a known race on Android 12+), while `status`
/// reads the live OS state.
Future<BlePermissionGate> ensureBlePermissions() async {
  if (!Platform.isAndroid) return const BlePermissionGate(granted: true);

  // Platform.operatingSystemVersion is documented as not parseable and its
  // format changes across Dart versions; the Android SDK int comes from the
  // platform API instead.
  final androidInfo = await DeviceInfoPlugin().androidInfo;
  final sdkInt = androidInfo.version.sdkInt;
  debugPrint('ensureBle: sdk=$sdkInt os=${Platform.operatingSystemVersion}');

  final permissions = <Permission>[
    if (sdkInt >= 31) ...<Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ] else
      Permission.locationWhenInUse,
  ];

  await permissions.request();

  for (final permission in permissions) {
    final status = await permission.status;
    if (status.isGranted) continue;
    return BlePermissionGate(
      granted: false,
      permanentDenied: status.isPermanentlyDenied,
    );
  }
  return const BlePermissionGate(granted: true);
}

/// The BLE link with one mirror.
///
/// Transport only: it owns the physical link, the live session and the panel
/// size the device reports. Identity and persistence belong to the device
/// registry, which owns the lifetime of every connection it hands to a route.
class MirrorConnection extends ChangeNotifier {
  MirrorConnection({
    String? deviceId,
    String? deviceName,
    int panelWidth = 0,
    int panelHeight = 0,
  })  : _deviceId = _nonEmpty(deviceId),
        _deviceName = _nonEmpty(deviceName),
        _panelWidth = panelWidth > 0 ? panelWidth : 0,
        _panelHeight = panelHeight > 0 ? panelHeight : 0;

  static String? _nonEmpty(String? value) =>
      (value == null || value.isEmpty) ? null : value;

  /// The BLE remote id this link is bound to, or null when it was built
  /// without a target (local simulator, test fake). [connectDevice] and
  /// [connect] refuse any other id rather than writing to the wrong mirror; a
  /// connection built without one adopts the target of its first successful
  /// connect.
  String? _deviceId;
  String? get deviceId => _deviceId;

  MirrorConnectionStatus _status = MirrorConnectionStatus.disconnected;
  MirrorConnectionStatus get status => _status;

  BleSession? _session;
  BleSession? get session => _session;

  String? _deviceName;
  String? get deviceName => _deviceName;

  BlePong? _pong;
  BlePong? get pong => _pong;

  String? _error;
  String? get error => _error;

  // The panel size the device last reported. The registry seeds it from the
  // stored record and persists what [updatePanelSize] reports.
  int _panelWidth;
  int _panelHeight;

  /// The panel size to target right now: the live mirror when it answers,
  /// otherwise the last size it reported. 0 means unknown.
  int get panelWidth {
    final w = _pong?.width ?? 0;
    return w > 0 ? w : _panelWidth;
  }

  int get panelHeight {
    final h = _pong?.height ?? 0;
    return h > 0 ? h : _panelHeight;
  }

  // Watches the link so a dropped connection (mirror rebooted, powered off,
  // walked out of range) is reflected in the UI instead of showing a stale
  // "connected".
  StreamSubscription<BluetoothConnectionState>? _stateSub;

  // Bumped when an attempt starts and by everything that abandons one
  // ([disconnect], [dispose]). A link that lands after its attempt was
  // abandoned is closed instead of adopted; see [connectDevice].
  int _attempt = 0;

  /// Record [width]x[height] as the panel size the device reported. Positive
  /// dimensions only, and only a real change notifies: the registry persists
  /// what it is told here.
  void updatePanelSize(int width, int height) {
    if (_setPanelSize(width, height)) notifyListeners();
  }

  /// Stores a positive size and reports whether it changed what is stored.
  bool _setPanelSize(int width, int height) {
    if (width <= 0 || height <= 0) return false;
    if (width == _panelWidth && height == _panelHeight) return false;
    _panelWidth = width;
    _panelHeight = height;
    return true;
  }

  /// Connect to a device found by a scan.
  Future<void> connect(BleScanEntry entry) {
    return connectDevice(id: entry.device.remoteId.str, name: entry.name);
  }

  /// Reconnect the bound target. No-op when this connection has no target (a
  /// local simulator never reaches out on its own), when a session is already
  /// up, or when a connect is already running. The caller is responsible for
  /// permissions and the adapter being on.
  Future<void> reconnect() async {
    final id = _deviceId;
    if (id == null) return;
    if (_status == MirrorConnectionStatus.connected) return;
    // A short timeout: at launch the mirror may not be in range, and a
    // 35-second hang on the way into the app is worse than a quick failure
    // the user can retry.
    await connectDevice(
        id: id, name: _deviceName ?? id, timeout: const Duration(seconds: 10));
  }

  /// Adopt [name] as the display name after a setup rename. Transport only:
  /// listeners (the registry) persist it.
  /// The device puts the new identity back on air the next time it starts
  /// advertising (a config commit while connected only lands in NVS and
  /// the GAP name; the packet is rebuilt on the following advertise), so
  /// later scans show exactly what the owner typed.
  Future<void> renameDevice(String name) async {
    if (name.isEmpty) return;
    _deviceName = name;
    notifyListeners();
  }

  /// Connect to the mirror and bring up its session. The short [timeout]
  /// only bounds the link establishment; the pong exchange has its own.
  ///
  /// A connection built with a `deviceId` only ever connects to that target:
  /// a different id is refused with a [StateError] before anything is sent. A
  /// connection built without one adopts the target of its first successful
  /// connect, so the local simulator can still attach to a mirror by hand (and
  /// a failed attempt binds nothing, so another device can be tried).
  Future<void> connectDevice({
    required String id,
    required String name,
    Duration timeout = const Duration(seconds: 35),
  }) async {
    final bound = _deviceId;
    if (bound != null && bound != id) {
      throw StateError(
          'this connection is bound to $bound; refusing to connect to $id');
    }
    if (_status == MirrorConnectionStatus.connecting) return;

    final attempt = ++_attempt;
    _status = MirrorConnectionStatus.connecting;
    _deviceName = name;
    _error = null;
    notifyListeners();

    BleSession? opened;
    try {
      opened = await openLink(id, timeout);
      if (attempt != _attempt) {
        // The attempt was abandoned while the radio was coming up (the route
        // left, the registry handed the link to another device): close what
        // landed instead of adopting a session nobody owns any more.
        await opened.close();
        return;
      }
      final pong = await opened.ping();
      if (attempt != _attempt) {
        await opened.close();
        return;
      }
      _session = opened;
      _pong = BlePong.parse(pong);
      _deviceId ??= id;
      // Folded into this attempt's notification: a second one for the size
      // would make the registry persist the same record twice.
      _setPanelSize(_pong?.width ?? 0, _pong?.height ?? 0);
      _status = MirrorConnectionStatus.connected;
      notifyListeners();
    } catch (e) {
      if (opened != null) await opened.close();
      // An abandoned attempt reports nothing: the failure belongs to a state
      // that no longer exists.
      if (attempt != _attempt) return;
      await _stateSub?.cancel();
      _stateSub = null;
      _session = null;
      _pong = null;
      _status = MirrorConnectionStatus.failed;
      _error = e.toString().replaceFirst('Exception: ', '');
      notifyListeners();
    }
  }

  /// Bring up the BLE link and watch it while it is live.
  ///
  /// This is the only part of a connect attempt that needs a radio, so it is
  /// the seam a test drives with a fake [BleSession] to exercise the attempt
  /// rules.
  @visibleForTesting
  Future<BleSession> openLink(String remoteId, Duration timeout) async {
    final device = BluetoothDevice.fromId(remoteId);
    final previous = _stateSub;
    if (previous != null) unawaited(previous.cancel());
    late final StreamSubscription<BluetoothConnectionState> sub;
    sub = device.connectionState.listen((state) {
      // Only the watch still installed may act: a drop reported by an
      // abandoned attempt's subscription must not tear down a newer session.
      if (!identical(_stateSub, sub)) return;
      if (state == BluetoothConnectionState.disconnected) linkLost();
    });
    _stateSub = sub;
    try {
      return await BleSession.connect(device, timeout: timeout);
    } catch (_) {
      await sub.cancel();
      if (identical(_stateSub, sub)) _stateSub = null;
      rethrow;
    }
  }

  /// The watched link dropped on its own: drop the dead session so the UI
  /// stops showing a connection that no longer answers. The bound target and
  /// its name stay, so [reconnect] can bring the same mirror back.
  void linkLost() {
    if (_status != MirrorConnectionStatus.connected) return;
    final dead = _session;
    _session = null;
    _pong = null;
    _status = MirrorConnectionStatus.disconnected;
    notifyListeners();
    if (dead != null) unawaited(dead.close());
  }

  /// Drop the link. The bound target and its name stay, so [reconnect] brings
  /// the same mirror back (a reboot or a power cycle should not forget it).
  /// A connect still in flight is abandoned: its link is closed when it lands,
  /// never adopted.
  Future<void> disconnect() async {
    _attempt++;
    await _stateSub?.cancel();
    _stateSub = null;
    final dead = _session;
    _session = null;
    _pong = null;
    _error = null;
    _status = MirrorConnectionStatus.disconnected;
    notifyListeners();
    await dead?.close();
  }

  /// Drop a stale `failed` connect and its error so a fresh scan's results can
  /// render. The bound target is kept, so the next [reconnect] still tries it;
  /// only the transient failure banner goes away. No-op unless the last
  /// connect attempt actually failed.
  void clearFailed() {
    if (_status != MirrorConnectionStatus.failed) return;
    _status = MirrorConnectionStatus.disconnected;
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    // Abandon any attempt still in flight: its session is closed when it
    // lands, and this object is never notified again.
    _attempt++;
    _stateSub?.cancel();
    _stateSub = null;
    final dead = _session;
    _session = null;
    if (dead != null) unawaited(dead.close());
    super.dispose();
  }
}
