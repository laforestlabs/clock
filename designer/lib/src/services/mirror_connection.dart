// App-scoped BLE connection to the mirror.
//
// The connection lives here, not in a screen: it is owned by the workspace
// root, survives page navigation (pushing and popping the Mirror screen no
// longer drops the link), and remembers the last device across app launches
// so the app can reconnect to it on startup. Screens listen to it as a
// ChangeNotifier and read [session] / [status].

import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  const BlePermissionGate({required this.granted, this.permanentDenied = false});

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

/// The BLE link with one mirror, remembered across launches.
class MirrorConnection extends ChangeNotifier {
  static const String _lastIdKey = 'last_ble_device_id';
  static const String _lastNameKey = 'last_ble_device_name';
  static const String _lastWidthKey = 'last_panel_width';
  static const String _lastHeightKey = 'last_panel_height';

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

  int? _lastPanelWidth;
  int? _lastPanelHeight;

  /// The last panel size the mirror reported, remembered across launches so
  /// stock layouts stay filtered to the right hardware after a disconnect.
  int? get lastPanelWidth => _lastPanelWidth;
  int? get lastPanelHeight => _lastPanelHeight;

  /// The panel size to target right now: the live mirror when connected,
  /// otherwise the last remembered size. 0 means unknown.
  int get panelWidth {
    final w = _pong?.width ?? 0;
    return w > 0 ? w : (_lastPanelWidth ?? 0);
  }

  int get panelHeight {
    final h = _pong?.height ?? 0;
    return h > 0 ? h : (_lastPanelHeight ?? 0);
  }

  // Watches the link so a dropped connection (mirror rebooted, powered off,
  // walked out of range) is reflected in the UI instead of showing a stale
  // "connected".
  StreamSubscription<BluetoothConnectionState>? _stateSub;

  /// Whether a device was connected before and is remembered for reconnect.
  Future<bool> hasLastDevice() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_lastIdKey);
    return id != null && id.isNotEmpty;
  }

  /// Populates the remembered panel size from prefs, for startup before any
  /// connection exists.
  Future<void> loadLastPanelSize() async {
    final prefs = await SharedPreferences.getInstance();
    _lastPanelWidth = prefs.getInt(_lastWidthKey);
    _lastPanelHeight = prefs.getInt(_lastHeightKey);
  }

  /// Records [width]x[height] as the panel size the mirror last reported.
  Future<void> rememberPanelSize(int width, int height) async {
    if (width <= 0 || height <= 0) return;
    _lastPanelWidth = width;
    _lastPanelHeight = height;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastWidthKey, width);
    await prefs.setInt(_lastHeightKey, height);
  }

  /// Connect to a device found by a scan.
  Future<void> connect(BleScanEntry entry) {
    return connectDevice(id: entry.device.remoteId.str, name: entry.name);
  }

  /// Reconnect to the last remembered device. No-op when nothing is
  /// remembered or a connection already exists. The caller is responsible
  /// for permissions and the adapter being on.
  Future<void> connectLast() async {
    if (_status == MirrorConnectionStatus.connected) return;
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_lastIdKey);
    final name = prefs.getString(_lastNameKey);
    if (id == null || id.isEmpty || name == null || name.isEmpty) return;
    // A short timeout: at launch the mirror may not be in range, and a
    // 35-second hang on the way into the app is worse than a quick failure
    // the user can retry from the Mirror screen.
    await connectDevice(id: id, name: name,
        timeout: const Duration(seconds: 10));
  }

  /// Adopt [name] as the remembered display name after a setup rename.
  /// The device puts the new identity back on air the next time it starts
  /// advertising (a config commit while connected only lands in NVS and
  /// the GAP name; the packet is rebuilt on the following advertise), so
  /// later scans show exactly what the owner typed.
  Future<void> renameDevice(String name) async {
    if (name.isEmpty) return;
    _deviceName = name;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastNameKey, name);
  }

  /// Connect to the mirror and bring up its session. The short [timeout]
  /// only bounds the link establishment; the pong exchange has its own.
  Future<void> connectDevice({
    required String id,
    required String name,
    Duration timeout = const Duration(seconds: 35),
  }) async {
    if (_status == MirrorConnectionStatus.connecting) return;

    _status = MirrorConnectionStatus.connecting;
    _deviceName = name;
    _error = null;
    notifyListeners();

    final device = BluetoothDevice.fromId(id);
    final previous = _stateSub;
    if (previous != null) unawaited(previous.cancel());
    _stateSub = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected &&
          _status == MirrorConnectionStatus.connected) {
        // The link died on its own. Drop the dead session so the UI stops
        // showing a connection that no longer answers.
        final dead = _session;
        _session = null;
        _pong = null;
        _status = MirrorConnectionStatus.disconnected;
        notifyListeners();
        if (dead != null) unawaited(dead.close());
      }
    });

    try {
      final session = await BleSession.connect(device, timeout: timeout);
      final pong = await session.ping();
      _session = session;
      _pong = BlePong.parse(pong);
      await rememberPanelSize(_pong?.width ?? 0, _pong?.height ?? 0);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastIdKey, id);
      await prefs.setString(_lastNameKey, name);
      _status = MirrorConnectionStatus.connected;
      notifyListeners();
    } catch (e) {
      await _stateSub?.cancel();
      _stateSub = null;
      await _session?.close();
      _session = null;
      _pong = null;
      _status = MirrorConnectionStatus.failed;
      _error = e.toString().replaceFirst('Exception: ', '');
      notifyListeners();
    }
  }

  /// Drop the link. The device stays remembered, so the next app launch
  /// reconnects to it (a reboot or a power cycle should not forget the
  /// mirror).
  Future<void> disconnect() async {
    await _stateSub?.cancel();
    _stateSub = null;
    final dead = _session;
    _session = null;
    _pong = null;
    _deviceName = null;
    _error = null;
    _status = MirrorConnectionStatus.disconnected;
    notifyListeners();
    await dead?.close();
  }

  /// Drop a stale `failed` connect and its error so a fresh scan's results can
  /// render. The remembered device is kept, so the next launch still tries to
  /// reconnect to it; only the transient failure banner goes away. No-op
  /// unless the last connect attempt actually failed.
  void clearFailed() {
    if (_status != MirrorConnectionStatus.failed) return;
    _status = MirrorConnectionStatus.disconnected;
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _stateSub = null;
    final dead = _session;
    _session = null;
    if (dead != null) unawaited(dead.close());
    super.dispose();
  }
}
