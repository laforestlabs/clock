// The device registry: what the app remembers about every mirror it has met.
//
// The dashboard is a list of devices, not one selected connection, so the
// state that used to live in a single `MirrorConnection` (the remembered
// device, the panel size, the last screenshot) lives here instead. One
// [MirrorDevice] stands for one physical mirror: a local `key` that never
// changes, one [MirrorConnection] for its Bluetooth link, one mutable LAN
// endpoint, and the last actual frame the mirror sent.
//
// Two rules shape the rest of the file. The first is that identity is the
// firmware ID derived from the Wi-Fi MAC, reported identically over LAN and
// BLE — names, RSSI and assumed MAC arithmetic are not identity, and merging
// two records that describe different hardware (or splitting one that was
// renamed) is worse than keeping a duplicate. The second is that a mutation
// is pinned to the device it was dispatched to: the endpoint and BLE session
// are captured before the first await, stable identity is rechecked against
// the record before writing, and an address that now answers as a *different*
// mirror is invalidated rather than written to.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mirror_ble.dart';
import 'mirror_connection.dart';
import 'mirror_display.dart';
import 'mirror_discovery.dart';
import 'mirror_lan.dart';

/// Creates the BLE link for a record. The real implementation binds the seed
/// fields into a [MirrorConnection]; tests replace it with a fake so the
/// registry can be exercised without a radio.
typedef MirrorConnectionFactory = MirrorConnection Function({
  String? deviceId,
  String? deviceName,
  int panelWidth,
  int panelHeight,
});

/// Creates the HTTP client for one `host:port` endpoint. The endpoint string
/// is used verbatim, so a non-default mDNS or manual port survives.
typedef LanFactory = MirrorLan Function(String endpoint);

/// Browses mDNS for mirrors. Defaults to [browseMdns].
typedef LanBrowser = Stream<LanDevice> Function({Duration timeout});

/// Scans for nearby BLE mirrors. Defaults to [scanForMirrors].
typedef BleScanner = Future<List<BleScanEntry>> Function({Duration timeout});

/// Requests BLE permissions before a scan. Defaults to [ensureBlePermissions].
typedef BleReadyProbe = Future<void> Function();

/// Where the preview cache lives. Defaults to
/// `<application support>/device-previews`.
typedef PreviewDirectory = Future<Directory> Function();

/// A registry operation that could not be carried out, with a sentence the UI
/// can show as-is.
///
/// Transport failures arrive here too, so a caller catches one type: the
/// firmware's own status code rides along, because 409 and 503 are things the
/// UI says differently ("frame the picture again", "no picture saved yet").
class MirrorRegistryException implements Exception {
  MirrorRegistryException(this.message, {this.statusCode});

  final String message;

  /// The HTTP status the device answered with, null when the failure never
  /// reached the device (no address, refused identity, socket failure).
  final int? statusCode;

  @override
  String toString() => message;
}

/// One mirror the app has met.
///
/// A record outlives the connection and the route: it is what makes an offline
/// device still worth showing, with its last actual frame and the time it was
/// captured, instead of inventing a live preview.
class MirrorDevice extends ChangeNotifier {
  MirrorDevice._(
    this._registry,
    this._connection, {
    required this.key,
    String? id,
    required String name,
    String? bleId,
    String? host,
    int port = 80,
    int width = 0,
    int height = 0,
    bool flip180 = false,
    DateTime? lastSeen,
    DateTime? frameAt,
    MirrorFrame? frame,
    MirrorStatus? status,
    DisplayMode? mode,
    DisplayMode? baseMode,
    bool pictureReady = false,
    int displayApi = 0,
    bool lanReachable = false,
  })  : _id = id,
        _name = name,
        _bleId = bleId,
        _host = host,
        _port = port,
        _width = width,
        _height = height,
        _flip180 = flip180,
        _lastSeen = lastSeen,
        _frameAt = frameAt,
        _frame = frame,
        _status = status,
        _mode = mode,
        _baseMode = baseMode,
        _pictureReady = pictureReady,
        _displayApi = displayApi,
        _lanReachable = lanReachable;

  final MirrorDevices _registry;

  /// Registry that owns this record and its target-safe operations.
  MirrorDevices get owner => _registry;

  /// The local identity of this record. `ble:<remote id>` or
  /// `lan:<host>:<port>` when it was first seen, and stable from then on: it
  /// names the record, the preview cache file and the open route, so it must
  /// survive learning the firmware ID or gaining a transport.
  final String key;

  final MirrorConnection _connection;

  /// The device's own BLE link. Registry-owned metadata is persisted by the
  /// registry, not by the connection.
  MirrorConnection get connection => _connection;

  String? _id;
  String _name;
  String? _bleId;
  String? _host;
  int _port;
  int _width;
  int _height;
  bool _flip180;
  DateTime? _lastSeen;
  DateTime? _frameAt;
  MirrorFrame? _frame;
  bool _frameFresh = false;
  MirrorStatus? _status;
  DisplayMode? _mode;
  DisplayMode? _baseMode;
  bool _pictureReady;
  int _displayApi;
  bool _lanReachable;
  bool _uploading = false;
  String? _error;
  bool _removed = false;
  MirrorDevice? _mergedInto;

  /// The LAN transport for the current endpoint, and the endpoint it was
  /// built for. Rebuilt when the address changes, which also invalidates the
  /// identity check that went with the old one.
  MirrorLan? _lan;
  String? _lanEndpoint;

  /// Bumped whenever the endpoint changes or is invalidated. A mutation only
  /// trusts a captured endpoint while this is unchanged.
  int _lanGeneration = 0;

  /// The generation whose stable identity has already been confirmed, so the
  /// pre-flight check costs one request per endpoint, not one per mutation.
  int? _verifiedLanGeneration;

  /// The BLE session whose identity has already been confirmed.
  BleSession? _verifiedSession;

  /// Serializes BLE connects for this record: a handover must not race a
  /// second connect, and a late success must not be adopted.
  int _bleAttempt = 0;

  /// When the bytes currently on disk were captured. The persisted
  /// `frame_at` is this value, never the held frame's, so the document and
  /// the cached file always describe the same image.
  DateTime? _savedFrameAt;

  /// When this record's volatile fields were last written to prefs.
  DateTime? _persistedAt;

  /// The firmware identity: 12 lowercase hex digits from the Wi-Fi station
  /// MAC, null until a transport reports it.
  String? get id => _id;

  /// The owner's name for the mirror: the firmware's friendly name once a
  /// transport reports it, otherwise what discovery or setup supplied.
  String get name => _name;

  /// The BLE remote id this record is bound to over Bluetooth, null for a
  /// LAN-only record that has not been paired yet.
  String? get bleId => _bleId;

  /// The LAN host, null when the record has no usable address.
  String? get host => _host;

  /// The LAN port. Preserved from discovery or manual entry; the firmware's
  /// reported `ip` never replaces it.
  int get port => _port;

  /// Panel geometry in pixels, 0 while unknown.
  int get width => _width;
  int get height => _height;

  /// Whether the panel is rotated 180 degrees as the mirror last reported.
  bool get flip180 => _flip180;

  /// The last time the mirror was reached on either transport.
  DateTime? get lastSeen => _lastSeen;

  /// When the frame in [frame] was captured on the mirror. It describes those
  /// bytes, never a later poll that failed.
  DateTime? get frameAt => _frameAt;

  /// The last actual frame from the mirror's framebuffer. Only bytes the
  /// device sent appear here; a local framing preview never does.
  MirrorFrame? get frame => _frame;

  /// Whether the latest snapshot request succeeded on the current LAN link.
  bool get frameFresh => _frameFresh && lanReachable;

  /// The last `/api/status` body, or null before the first contact.
  MirrorStatus? get status => _status;

  /// Whether the last HTTP call to this device succeeded. The Bluetooth link
  /// and this are independent: a phone can hold a session to a mirror it
  /// cannot reach over Wi-Fi.
  bool get lanReachable => _lanReachable;

  /// A live BLE session proves Bluetooth connectivity.
  bool get bleConnected => _connection.session != null;

  /// Whether a BLE connect is in flight.
  bool get bleConnecting =>
      _connection.status == MirrorConnectionStatus.connecting;

  /// The effective display: `games` while a game overrides the base.
  DisplayMode? get mode => _mode;

  /// The saved base display (clock or picture), never `games`.
  DisplayMode? get baseMode => _baseMode;

  /// Whether the mirror reports a stored picture matching its panel.
  bool get pictureReady => _pictureReady;

  /// The firmware's display API version, 0 when it never advertised one.
  int get displayApi => _displayApi;

  /// Whether this firmware supports picture upload and framebuffer previews.
  bool get supportsDisplay => _displayApi >= 1;

  /// Whether a game is overriding the saved display right now.
  bool get gamesRunning => _mode == DisplayMode.games;

  /// Whether this record is the one an open route is bound to.
  bool get isActive => _registry._activeKey == key;

  /// Whether a picture upload is in flight; the tile stops polling previews
  /// while it is, because the device serves one transfer at a time.
  bool get uploading => _uploading;

  /// Whether this record still belongs to the registry. A merged or forgotten
  /// device is dropped, and late results for it must not resurrect it.
  bool get removed => _removed;

  /// When this record turned out to name the same hardware as one already
  /// known, the record that survived the merge; null while it stands alone.
  /// A caller holding the record it asked for follows this to a live record.
  MirrorDevice? get mergedInto => _mergedInto;

  /// The last failure worth showing, from the registry or the BLE link.
  String? get error => _error ?? _connection.error;

  /// `host:port` for the LAN transport, null when there is no address.
  String? get endpoint => _host == null ? null : '$_host:$_port';

  /// Whether a firmware update can be sent over a live Bluetooth link.
  bool get canUpdateFirmware => _connection.session != null;

  /// Shown when [canUpdateFirmware] is false.
  static const String needsBluetooth =
      'A firmware update is sent over Bluetooth, so this mirror needs a live '
      'Bluetooth connection. Connect to it and try again.';

  @override
  String toString() => '$name ($key)';

  void _startListening() => _connection.addListener(_onConnectionChanged);
  void _stopListening() => _connection.removeListener(_onConnectionChanged);

  void _onConnectionChanged() {
    if (_removed) return;
    _registry._connectionChanged(this);
  }

  void _notify() {
    if (!_removed) notifyListeners();
  }

  void _touch({bool structural = false}) {
    if (_removed) return;
    _registry._noteChanged(this, structural: structural);
  }
}

/// The dashboard's registry: the list of known mirrors, their persistence and
/// every operation that touches a device's transports.
///
/// The registry owns the records and their connections (it disposes them); a
/// screen owns the widget lifecycle. Nothing here connects to a device on its
/// own: at startup the remembered list is read from prefs and shown, and only
/// an explicit [activate] or [addBle]/[connect] opens a radio.
class MirrorDevices extends ChangeNotifier {
  MirrorDevices({
    MirrorConnectionFactory connectionFactory = _defaultConnectionFactory,
    LanFactory lanFactory = MirrorLan.new,
    LanBrowser browse = browseMdns,
    BleScanner scan = scanForMirrors,
    BleReadyProbe ensureBleReady = _defaultBleReady,
    PreviewDirectory? previewDirectory,
    DateTime Function() now = DateTime.now,
  })  : _connectionFactory = connectionFactory,
        _lanFactory = lanFactory,
        _browse = browse,
        _scan = scan,
        _ensureBleReady = ensureBleReady,
        _previewDirectoryOf = previewDirectory ?? _defaultPreviewDirectory,
        _now = now;

  /// The prefs key holding the registry document.
  static const String storeKey = 'mirror_devices_v1';

  /// Shown when a picture cannot be uploaded because only Bluetooth is
  /// available. The LAN path is what carries image bytes.
  static const String uploadNeedsWifiMessage =
      'Connect phone and device to the same Wi-Fi to upload pictures';

  /// The four prefs keys the single-device build wrote, imported once.
  static const List<String> _legacyKeys = <String>[
    'last_ble_device_id',
    'last_ble_device_name',
    'last_panel_width',
    'last_panel_height',
  ];

  /// Previews are written at most this often per device: a 5-second poll
  /// would otherwise rewrite a 6 KB file (and prefs) twelve times a minute.
  static const Duration _previewInterval = Duration(seconds: 30);

  /// Volatile fields (last seen, reachability, frame time) follow the same
  /// throttle; structural changes are written at once.
  static const Duration _volatileInterval = Duration(seconds: 30);

  /// How long a user-initiated BLE connect may take before it is reported as
  /// failed. Short on purpose: a launch-time hang is worse than a retry.
  static const Duration _bleConnectTimeout = Duration(seconds: 20);

  /// How many device refreshes may be in flight at once. A screenful of
  /// tiles must not open every socket at the same moment.
  static const int _refreshLimit = 2;

  final MirrorConnectionFactory _connectionFactory;
  final LanFactory _lanFactory;
  final LanBrowser _browse;
  final BleScanner _scan;
  final BleReadyProbe _ensureBleReady;
  final PreviewDirectory _previewDirectoryOf;
  final DateTime Function() _now;

  /// The LAN transport every request to a mirror goes through. Exposed so the
  /// firmware upload - the one caller that sends bytes without a record-level
  /// mutation to hang off - uses the same transport as everything else, and so
  /// a test can answer it instead of the network.
  LanFactory get lanFactory => _lanFactory;

  final List<MirrorDevice> _devices = <MirrorDevice>[];
  final _RefreshGate _refreshGate = _RefreshGate(_refreshLimit);

  /// One refresh in flight per record; a second call joins it.
  final Map<String, _RefreshRun> _refreshes = <String, _RefreshRun>{};

  Future<void>? _discovery;
  String? _discoveryError;
  String? _warning;
  String? _activeKey;
  bool _loaded = false;
  bool _disposed = false;
  Directory? _previewDir;

  Future<void> _persistTail = Future<void>.value();
  bool _persistDirty = false;
  Future<void>? _persistPending;
  Future<void> _handoverTail = Future<void>.value();

  /// The known devices, in the order they were persisted.
  List<MirrorDevice> get devices => List<MirrorDevice>.unmodifiable(_devices);

  /// The record an open route is bound to, if any.
  MirrorDevice? get active {
    final key = _activeKey;
    if (key == null) return null;
    for (final device in _devices) {
      if (device.key == key) return device;
    }
    return null;
  }

  /// A restore problem worth showing once: unreadable saved data, or a
  /// preview cache that could not be read or written. Null when all is well.
  String? get warning => _warning;

  /// Why the last discovery run failed, for the retryable inline message.
  String? get discoveryError => _discoveryError;

  /// Whether the persisted list has been read.
  bool get loaded => _loaded;

  // ---------------------------------------------------------------- loading

  /// Reads the persisted registry, importing the single-device build's keys
  /// and the preview cache. Shows the remembered devices immediately; no
  /// radio is opened and no device is contacted.
  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(storeKey);

    if (raw == null) {
      await _migrateLegacy(prefs);
    } else {
      final parsed = _parseStore(raw);
      _devices.addAll(parsed.devices);
      if (parsed.warning != null) _setWarning(parsed.warning!);
    }
    for (final device in _devices) {
      device._startListening();
    }
    _loaded = true;
    await _loadPreviews();
    await _healDuplicates();
    notifyListeners();
  }

  /// Folds records that share a confirmed identity.
  ///
  /// Reaching the merge path is normally enough, but a crash between reading a
  /// status that confirms the identity and writing the merged document leaves
  /// both the old and the provisional record behind — two tiles for one
  /// mirror. The earlier record is the one that survives, as in [_merge].
  Future<void> _healDuplicates() async {
    final seenIds = <String, MirrorDevice>{};
    final seenBleIds = <String, MirrorDevice>{};
    for (final device in List<MirrorDevice>.of(_devices)) {
      final id = device._id;
      if (id != null) {
        final twin = seenIds[id];
        if (twin != null) {
          await _merge(twin, device);
          continue;
        }
        seenIds[id] = device;
      }
      final bleId = device._bleId;
      if (bleId != null) {
        final twin = seenBleIds[bleId];
        if (twin != null) {
          await _merge(twin, device);
          continue;
        }
        seenBleIds[bleId] = device;
      }
    }
  }

  /// Imports `last_ble_device_id` and friends once, when no registry exists.
  ///
  /// A size with no device id is not a device: only a remembered BLE id makes
  /// a provisional record, and the old keys are dropped only after the new
  /// document has been written successfully.
  Future<void> _migrateLegacy(SharedPreferences prefs) async {
    final remoteId = prefs.getString(_legacyKeys[0]);
    if (remoteId == null || remoteId.isEmpty) return;
    final name = prefs.getString(_legacyKeys[1]);
    final width = prefs.getInt(_legacyKeys[2]) ?? 0;
    final height = prefs.getInt(_legacyKeys[3]) ?? 0;
    final device = _create(
      key: 'ble:$remoteId',
      bleId: remoteId,
      name: (name == null || name.isEmpty) ? remoteId : name,
      width: math.max(0, width),
      height: math.max(0, height),
    );
    _devices.add(device);
    final saved = await _persist();
    if (!saved) return;
    for (final key in _legacyKeys) {
      await prefs.remove(key);
    }
  }

  /// Reads the document. A corrupt record is skipped without taking the rest
  /// of the list with it; a corrupt document leaves an empty registry and a
  /// visible warning rather than pretending the devices were never there.
  ({List<MirrorDevice> devices, String? warning}) _parseStore(String raw) {
    final devices = <MirrorDevice>[];
    String? warning;
    Object? root;
    try {
      root = jsonDecode(raw);
    } on FormatException {
      return (
        devices: devices,
        warning: 'The saved device list could not be read; starting empty.',
      );
    }
    if (root is! Map<String, dynamic> ||
        (root['version'] is int && root['version'] != 1) ||
        root['devices'] is! List) {
      return (
        devices: devices,
        warning: 'The saved device list could not be read; starting empty.',
      );
    }
    final keys = <String>{};
    for (final entry in (root['devices'] as List).cast<Object?>()) {
      if (entry is! Map<String, dynamic>) {
        warning ??= 'One saved device was unreadable and was skipped.';
        continue;
      }
      final device = _recordFromJson(entry);
      if (device == null || !keys.add(device.key)) {
        warning ??= 'One saved device was unreadable and was skipped.';
        continue;
      }
      devices.add(device);
    }
    return (devices: devices, warning: warning);
  }

  MirrorDevice? _recordFromJson(Map<String, dynamic> json) {
    final key = json['key'];
    if (key is! String || key.isEmpty) return null;
    String? text(Object? value) =>
        value is String && value.isNotEmpty ? value : null;
    int count(Object? value, int fallback) =>
        value is num && value.toInt() >= 0 ? value.toInt() : fallback;
    final host = text(json['host']);
    final bleId = text(json['ble_id']);
    if (host == null && bleId == null) return null;
    final port = json['port'];
    return _create(
      key: key,
      id: text(json['id']),
      name: text(json['name']) ?? host ?? bleId!,
      bleId: bleId,
      host: host,
      port: port is int && port > 0 ? port : 80,
      width: count(json['width'], 0),
      height: count(json['height'], 0),
      flip180: json['flip180'] == true,
      lastSeen: _parseTime(json['last_seen']),
      frameAt: _parseTime(json['frame_at']),
    );
  }

  static DateTime? _parseTime(Object? value) {
    if (value is! String) return null;
    final parsed = DateTime.tryParse(value);
    return parsed?.toUtc();
  }

  /// Loads each record's saved frame. The bytes are validated by decoding
  /// them: a truncated or foreign file drops the preview and its timestamp
  /// rather than showing an image no mirror ever sent.
  Future<void> _loadPreviews() async {
    var dropped = false;
    for (final device in _devices) {
      final at = device._frameAt;
      if (at == null) continue;
      try {
        final file = await _previewFile(device.key);
        final bytes = await file.readAsBytes();
        device._frame = decodeMirrorFrame(bytes);
        device._frameAt = at;
        device._savedFrameAt = at;
      } catch (_) {
        device._frame = null;
        device._frameAt = null;
        device._savedFrameAt = null;
        dropped = true;
      }
    }
    if (dropped) await _persist();
  }

  // ------------------------------------------------------------ persistence

  String _encodeStore() => jsonEncode(<String, Object?>{
        'version': 1,
        'devices': <Object?>[
          for (final device in _devices)
            <String, Object?>{
              'key': device.key,
              'id': device._id,
              'name': device._name,
              'ble_id': device._bleId,
              'host': device._host,
              'port': device._port,
              'width': device._width,
              'height': device._height,
              'flip180': device._flip180,
              'last_seen': device._lastSeen?.toUtc().toIso8601String(),
              'frame_at': device._savedFrameAt?.toUtc().toIso8601String(),
            },
        ],
      });

  /// Writes the document and resolves once the write that includes this
  /// call's changes has finished. Concurrent writers coalesce: a burst of
  /// record changes costs one document write.
  Future<bool> _persist() {
    // After disposal the record list is empty; writing would erase the
    // document on the way out.
    if (_disposed) return Future<bool>.value(false);
    _persistDirty = true;
    final pending = _persistPending;
    if (pending != null) return pending.then((_) => _lastPersistOk);
    final completer = Completer<void>();
    _persistPending = completer.future;
    _persistTail = _persistTail.then((_) async {
      try {
        while (_persistDirty) {
          _persistDirty = false;
          try {
            final prefs = await SharedPreferences.getInstance();
            _lastPersistOk = await prefs.setString(storeKey, _encodeStore());
          } catch (e) {
            _lastPersistOk = false;
            _setWarning('Could not save the device list: $e');
          }
        }
      } finally {
        _persistPending = null;
        completer.complete();
      }
    });
    return completer.future.then((_) => _lastPersistOk);
  }

  bool _lastPersistOk = true;

  /// Writes this record's metadata now, including a preview held back by the
  /// 30-second throttle. The UI calls this when it leaves the foreground or
  /// marks a device offline, so the last actual frame is not the one from
  /// before the app went away.
  Future<void> saveMetadata(MirrorDevice device) async {
    if (_disposed || device._removed) return;
    if (device._frame != null && device._savedFrameAt != device._frameAt) {
      await _saveFrame(device);
    }
    await _persist();
  }

  /// Records a change: notifies listeners, and persists at once for
  /// structural changes or on the 30-second throttle for volatile ones.
  void _noteChanged(MirrorDevice device, {bool structural = false}) {
    if (_disposed || device._removed) return;
    device._notify();
    if (structural) {
      device._persistedAt = _now();
      unawaited(_persist());
      notifyListeners();
      return;
    }
    final at = _now();
    final last = device._persistedAt;
    if (last == null || at.difference(last) >= _volatileInterval) {
      device._persistedAt = at;
      unawaited(_persist());
    }
    notifyListeners();
  }

  void _setWarning(String message) {
    if (_disposed) return;
    _warning = message;
    if (_loaded) notifyListeners();
  }

  /// Clears the restore warning once the user has seen it.
  void clearWarning() {
    if (_warning == null) return;
    _warning = null;
    notifyListeners();
  }

  Future<Directory> _previewDirectory() async {
    final cached = _previewDir;
    if (cached != null) return cached;
    final dir = await _previewDirectoryOf();
    await dir.create(recursive: true);
    return _previewDir = dir;
  }

  Future<File> _previewFile(String key) async {
    final dir = await _previewDirectory();
    final name = base64Url.encode(utf8.encode(key)).replaceAll('=', '');
    return File('${dir.path}/$name.frame');
  }

  /// Writes the held frame, then the timestamp that describes it. The bytes
  /// and `frame_at` are written together so a reload never claims an age for
  /// an image it does not have.
  Future<void> _saveFrame(MirrorDevice device) async {
    final frame = device._frame;
    final at = device._frameAt;
    if (frame == null || at == null || device._removed || _disposed) return;
    try {
      final file = await _previewFile(device.key);
      await file.writeAsBytes(encodeMirrorFrame(frame), flush: true);
      device._savedFrameAt = at;
      await _persist();
    } catch (e) {
      _setWarning('Could not save the device preview: $e');
    }
  }

  static MirrorConnection _defaultConnectionFactory({
    String? deviceId,
    String? deviceName,
    int panelWidth = 0,
    int panelHeight = 0,
  }) =>
      MirrorConnection(
        deviceId: deviceId,
        deviceName: deviceName,
        panelWidth: panelWidth,
        panelHeight: panelHeight,
      );

  static Future<Directory> _defaultPreviewDirectory() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/device-previews');
  }

  static Future<void> _defaultBleReady() async {
    final gate = await ensureBlePermissions();
    if (gate.granted) return;
    throw MirrorRegistryException(
      gate.permanentDenied
          ? 'Bluetooth permission is off. Enable it in system settings, then '
              'scan again.'
          : 'Bluetooth permission is needed to find mirrors nearby.',
    );
  }

  MirrorDevice _create({
    required String key,
    String? id,
    required String name,
    String? bleId,
    String? host,
    int port = 80,
    int width = 0,
    int height = 0,
    bool flip180 = false,
    DateTime? lastSeen,
    DateTime? frameAt,
    MirrorStatus? status,
    DisplayMode? mode,
    DisplayMode? baseMode,
    bool pictureReady = false,
    int displayApi = 0,
    bool lanReachable = false,
  }) {
    // The connection is bound to the BLE remote id, never to the firmware id:
    // the link is what gets addressed, and the firmware id only says which
    // hardware that link should turn out to be.
    final connection = _connectionFactory(
      deviceId: bleId,
      deviceName: name,
      panelWidth: width,
      panelHeight: height,
    );
    return MirrorDevice._(
      this,
      connection,
      key: key,
      id: id,
      name: name,
      bleId: bleId,
      host: host,
      port: port,
      width: width,
      height: height,
      flip180: flip180,
      lastSeen: lastSeen,
      frameAt: frameAt,
      status: status,
      mode: mode,
      baseMode: baseMode,
      pictureReady: pictureReady,
      displayApi: displayApi,
      lanReachable: lanReachable,
    );
  }

  MirrorDevice? _byKey(String key) {
    for (final device in _devices) {
      if (device.key == key) return device;
    }
    return null;
  }

  /// The record for a confirmed firmware identity, if one is known.
  MirrorDevice? deviceForId(String id) {
    for (final device in _devices) {
      if (device.id == id) return device;
    }
    return null;
  }

  /// The record bound to a BLE remote id, if one is known.
  MirrorDevice? deviceForBleId(String bleId) {
    for (final device in _devices) {
      if (device.bleId == bleId) return device;
    }
    return null;
  }

  void _require(MirrorDevice device) {
    _checkAlive();
    if (device._removed || !_devices.contains(device)) {
      throw MirrorRegistryException('This device is no longer in the list.');
    }
  }

  void _checkAlive() {
    if (_disposed) {
      throw MirrorRegistryException('The device list has been closed.');
    }
  }

  // -------------------------------------------------------------- discovery

  /// Browses mDNS and adds mirrors it can confirm. Runs at most one browse at
  /// a time; a second call joins the run in flight.
  Future<void> refreshDiscovery() {
    if (_disposed) return Future<void>.value();
    final running = _discovery;
    if (running != null) return running;
    final run = _runDiscovery();
    _discovery = run;
    return run.whenComplete(() {
      _discovery = null;
    });
  }

  Future<void> _runDiscovery() async {
    if (_disposed) return;
    if (_discoveryError != null) {
      _discoveryError = null;
      notifyListeners();
    }
    try {
      await for (final found in _browse(timeout: const Duration(seconds: 5))) {
        await _consider(found);
      }
    } catch (e) {
      _discoveryError = 'Could not search the network: ${_message(e)}';
      notifyListeners();
    }
  }

  /// A device found by mDNS is only added once its `/api/status` identifies a
  /// mirror: multicast advertises the service, not the hardware, and adding
  /// an unconfirmed address would put a tile on the dashboard that is not a
  /// mirror at all.
  Future<void> _consider(LanDevice found) async {
    if (_disposed || found.ip.isEmpty) return;
    final port = found.port > 0 ? found.port : 80;
    if (_byKey('lan:${found.ip}:$port') != null) return;
    for (final device in _devices) {
      if (device._host == found.ip && device._port == port) return;
    }
    final lan = _lanFactory('${found.ip}:$port');
    final MirrorStatus status;
    try {
      status = await lan.status();
    } catch (_) {
      return; // unreachable or not our device; nothing to show yet
    }
    if (_disposed) return;
    if (status.id == null && (status.width <= 0 || status.height <= 0)) return;
    final key = 'lan:${found.ip}:$port';
    if (_byKey(key) != null) return;
    final device = _create(
      key: key,
      name: found.name.isEmpty ? found.ip : found.name,
      host: found.ip,
      port: port,
    );
    device._lan = lan;
    device._lanEndpoint = '${found.ip}:$port';
    _devices.add(device);
    device._startListening();
    await _applyStatus(device, status);
    await _persist();
    _noteChanged(device, structural: true);
  }

  // --------------------------------------------------------------- add/remove

  /// Adds (or returns) a device at a manually entered address.
  ///
  /// An address the user typed is kept even when it does not answer: an
  /// offline tile the user can retry is more useful than a silent rejection.
  Future<MirrorDevice> addLan(String host, int port) async {
    _checkAlive();
    final trimmed = host.trim();
    if (trimmed.isEmpty) {
      throw MirrorRegistryException('Enter the mirror\'s address.');
    }
    final wanted = port > 0 ? port : 80;
    final key = 'lan:$trimmed:$wanted';
    final existing = _byKey(key);
    if (existing != null) {
      await refresh(existing);
      return existing._mergedInto ?? existing;
    }
    final device =
        _create(key: key, name: trimmed, host: trimmed, port: wanted);
    _devices.add(device);
    device._startListening();
    _noteChanged(device, structural: true);
    await refresh(device);
    // The first status can identify a mirror already known over Bluetooth;
    // the caller gets the record that survived, not the one folded into it.
    return device._mergedInto ?? device;
  }

  /// Adds (or returns) a mirror found by a BLE scan, and connects to it to
  /// read its identity. The identity decides whether this is a new device or
  /// the Bluetooth side of one already known over LAN.
  Future<MirrorDevice> addBle(BleScanEntry entry) async {
    _checkAlive();
    final remoteId = entry.device.remoteId.str;
    if (remoteId.isEmpty) {
      throw MirrorRegistryException('That Bluetooth device has no address.');
    }
    final known = deviceForBleId(remoteId);
    if (known != null) {
      await connect(known);
      return known._mergedInto ?? known;
    }
    var device = _byKey('ble:$remoteId');
    if (device == null) {
      device = _create(
        key: 'ble:$remoteId',
        bleId: remoteId,
        name: entry.name.isEmpty ? remoteId : entry.name,
      );
      _devices.add(device);
      device._startListening();
      // Not persisted yet: if this turns out to be the Bluetooth side of a
      // mirror already known over LAN, the record is folded into that one and
      // the candidate must never reach the document.
      notifyListeners();
    }
    final survivor = await _connectDevice(device);
    await _persist();
    return device._mergedInto ?? survivor ?? device;
  }

  /// Forgets a device: drops its record, closes its BLE link and removes its
  /// cached preview.
  Future<void> remove(MirrorDevice device) async {
    if (device._removed) return;
    _devices.remove(device);
    if (_activeKey == device.key) _activeKey = null;
    device._removed = true;
    device._stopListening();
    try {
      await device._connection.disconnect();
    } catch (_) {
      // A link that will not close must not keep the record alive.
    }
    device._connection.dispose();
    device.dispose();
    try {
      final file = await _previewFile(device.key);
      if (file.existsSync()) await file.delete();
    } catch (_) {
      // The preview cache is best effort.
    }
    await _persist();
    notifyListeners();
  }

  // -------------------------------------------------------------- activation

  /// Binds the open route to [device] and connects its Bluetooth link when
  /// the identity is known. Devices are never connected just because they are
  /// remembered: only the chosen one.
  Future<void> activate(MirrorDevice device) async {
    _require(device);
    await _serializeHandover(() async {
      if (_disposed || device._removed) return;
      _activeKey = device.key;
      notifyListeners();
      if (device._bleId == null) return;
      if (device._connection.session != null) return;
      await _connectDevice(device);
    });
  }

  /// Releases a route. The BLE link the route owned is closed here, which is
  /// why handover goes through this and not through a blind disconnect: a
  /// route that has already exited cannot drop the link a newer route opened.
  Future<void> deactivate(MirrorDevice device) async {
    if (device._removed) return;
    await _serializeHandover(() async {
      if (_disposed || device._removed) return;
      if (_activeKey == device.key) _activeKey = null;
      device._bleAttempt++; // a connect landing after this is not adopted
      await device._connection.disconnect();
      await saveMetadata(device);
      if (!_disposed) notifyListeners();
    });
  }

  /// Runs handovers one at a time, in call order.
  Future<void> _serializeHandover(Future<void> Function() op) {
    final next = _handoverTail.then((_) => op());
    _handoverTail = next.catchError((Object _) {});
    return next;
  }

  // ----------------------------------------------------------------- reading

  /// Refreshes one record: LAN status, identity, and optionally the actual
  /// frame. At most two records are refreshed at once, and a record has at
  /// most one refresh in flight — a second call joins the first.
  Future<void> refresh(MirrorDevice device, {bool includeFrame = false}) {
    if (device._removed) return Future<void>.value();
    var run = _refreshes[device.key];
    if (run != null) {
      if (includeFrame) run.wantsFrame = true;
      return run.done;
    }
    run = _RefreshRun();
    _refreshes[device.key] = run;
    run.done = _refreshLoop(device, run, includeFrame);
    return run.done;
  }

  Future<void> _refreshLoop(
    MirrorDevice device,
    _RefreshRun run,
    bool includeFrame,
  ) async {
    try {
      var wantFrame = includeFrame;
      while (true) {
        await _refreshOnce(device, includeFrame: wantFrame);
        run.servedFrame = run.servedFrame || wantFrame;
        if (!run.wantsFrame || run.servedFrame) break;
        wantFrame = true; // a caller asked for a frame while we were polling
        if (device._removed) break;
      }
    } finally {
      _refreshes.remove(device.key);
    }
  }

  Future<void> _refreshOnce(MirrorDevice device,
      {required bool includeFrame}) async {
    if (device._removed || device._uploading) return;
    final lan = _lanFor(device);
    if (lan == null) {
      // A Bluetooth-only record still learns its geometry from the link.
      _connectionChanged(device);
      return;
    }
    final release = await _refreshGate.acquire();
    try {
      if (device._removed || device._uploading) return;
      final MirrorStatus status;
      try {
        status = await lan.status();
      } catch (e) {
        if (identical(device._lan, lan)) _markLanFailure(device, e);
        return;
      }
      if (device._removed || !identical(device._lan, lan)) return;
      _markLanSuccess(device);
      await _applyStatus(device, status);
      if (device._removed || !identical(device._lan, lan)) return;
      if (!includeFrame || !device.supportsDisplay) return;
      try {
        final frame = await lan.frame();
        if (device._removed || !identical(device._lan, lan)) return;
        _storeFrame(device, frame, _now());
      } catch (_) {
        // A busy or missing snapshot is a preview problem, not an offline
        // device: the last actual frame and its timestamp stay as they were.
        if (!device._removed && identical(device._lan, lan)) {
          device._frameFresh = false;
          _noteChanged(device);
        }
      }
    } finally {
      release();
    }
  }

  /// The LAN client for the record's current endpoint, rebuilt when the
  /// address changes. A new endpoint invalidates the identity check that
  /// belonged to the old one.
  MirrorLan? _lanFor(MirrorDevice device) {
    final endpoint = device.endpoint;
    if (endpoint == null) return null;
    if (device._lan == null || device._lanEndpoint != endpoint) {
      device._lan = _lanFactory(endpoint);
      device._lanEndpoint = endpoint;
      device._lanGeneration++;
      device._verifiedLanGeneration = null;
      device._frameFresh = false;
    }
    return device._lan;
  }

  /// A successful HTTP response is what proves the LAN path works. The
  /// firmware's `online` flag describes its Wi-Fi state, not our reachability.
  void _markLanSuccess(MirrorDevice device) {
    device._lanReachable = true;
    device._lastSeen = _now();
    if (device._error != null) device._error = null;
  }

  void _markLanFailure(MirrorDevice device, Object error) {
    device._lanReachable = false;
    device._frameFresh = false;
    device._error = _message(error);
    device._touch();
  }

  /// Folds a `/api/status` body into the record: identity first (it can merge
  /// two records into one), then the display, geometry and name.
  Future<void> _applyStatus(MirrorDevice device, MirrorStatus status) async {
    var structural = false;
    if (device._id != null && status.id != device._id) {
      _invalidateEndpoint(
          device, 'That address no longer confirms this mirror’s identity.');
      return;
    }
    device._status = status;

    final id = status.id;
    if (id != null && device._id == null) {
      await _adoptIdentity(device, id);
      if (device._removed) return;
      structural = true;
    }

    if (device._mode != status.mode ||
        device._baseMode != status.baseMode ||
        device._pictureReady != (status.pictureReady ?? false) ||
        device._displayApi != status.displayApi) {
      device._mode = status.mode;
      device._baseMode = status.baseMode;
      device._pictureReady = status.pictureReady ?? false;
      device._displayApi = status.displayApi;
      structural = true;
    }
    if (status.width > 0 &&
        status.height > 0 &&
        (status.width != device._width || status.height != device._height)) {
      device._width = status.width;
      device._height = status.height;
      structural = true;
    }
    if (status.flip180 != null && status.flip180 != device._flip180) {
      device._flip180 = status.flip180!;
      structural = true;
    }
    if (status.name != null && status.name != device._name) {
      device._name = status.name!;
      structural = true;
    }
    // Note: a routine status read does not mark the endpoint as verified for
    // writes — see [_verifyLanIdentity]. An address can be handed to another
    // mirror between a poll and a mutation.
    _noteChanged(device, structural: structural);
  }

  /// Replaces the record's endpoint because it no longer answers as this
  /// device. The record stays (its history and preview are still its own) but
  /// it has no address until discovery finds it again.
  void _invalidateEndpoint(MirrorDevice device, String reason) {
    device._host = null;
    device._lan = null;
    device._lanEndpoint = null;
    device._lanGeneration++;
    device._verifiedLanGeneration = null;
    device._lanReachable = false;
    device._frameFresh = false;
    device._error = reason;
    unawaited(_persist());
    device._touch(structural: false);
    unawaited(refreshDiscovery());
  }

  /// Stores an actual frame from the mirror. The bytes are the device's own
  /// screenshot; the local framing preview is never written here.
  void _storeFrame(MirrorDevice device, MirrorFrame frame, DateTime at) {
    device._frame = frame;
    device._frameAt = at;
    device._frameFresh = true;
    final saved = device._savedFrameAt;
    if (saved == null || at.difference(saved) >= _previewInterval) {
      unawaited(_saveFrame(device));
    }
    _noteChanged(device);
  }

  /// Pulls geometry, the friendly name and reachability out of the BLE link.
  void _connectionChanged(MirrorDevice device) {
    if (device._removed) return;
    var structural = false;
    final connection = device._connection;
    final width = connection.panelWidth;
    final height = connection.panelHeight;
    if (width > 0 &&
        height > 0 &&
        (width != device._width || height != device._height)) {
      device._width = width;
      device._height = height;
      structural = true;
    }
    final name = connection.deviceName;
    if (name != null && name.isNotEmpty && name != device._name) {
      device._name = name;
      structural = true;
    }
    if (connection.session != null) device._lastSeen = _now();
    _noteChanged(device, structural: structural);
  }

  /// The download a clock workspace starts from. LAN only: there is no BLE
  /// layout-download command, which is why a Bluetooth-only workspace is a
  /// local draft until a preset is sent.
  Future<String> loadLayout(MirrorDevice device) async {
    _require(device);
    final lan = _lanFor(device);
    if (lan == null) {
      throw MirrorRegistryException(
        'This device has no Wi-Fi address, so its layout cannot be read.',
      );
    }
    await _verifyLanIdentity(device, lan, forWrite: false);
    try {
      final json = await lan.getLayout();
      _markLanSuccess(device);
      return json;
    } catch (e) {
      _noteFailure(device, e);
      throw _wrapped(e);
    }
  }

  // --------------------------------------------------------------- identity

  /// Makes this record's identity the confirmed firmware ID [id], merging
  /// with an existing record for the same hardware when there is one.
  Future<void> _adoptIdentity(MirrorDevice device, String id) async {
    if (device._id == id) return;
    final twin = deviceForId(id);
    if (twin != null && twin.key != device.key) {
      final keep = _preferred(twin, device);
      final drop = identical(keep, twin) ? device : twin;
      await _merge(keep, drop);
      return;
    }
    device._id = id;
  }

  /// Which record survives a merge: the one an open route is bound to, else
  /// the earlier one, so the key a caller already holds keeps working.
  MirrorDevice _preferred(MirrorDevice a, MirrorDevice b) {
    final aActive = a.key == _activeKey;
    final bActive = b.key == _activeKey;
    if (aActive != bActive) return aActive ? a : b;
    return _devices.indexOf(a) <= _devices.indexOf(b) ? a : b;
  }

  /// Folds [drop] into [keep]: two records that turn out to be the same
  /// hardware become one, with the kept record's key and connection intact.
  /// The dropped connection is closed instead of transplanted — a live
  /// session's physical target never changes under it.
  Future<void> _merge(MirrorDevice keep, MirrorDevice drop) async {
    if (identical(keep, drop) || drop._removed) return;
    keep._id ??= drop._id;
    keep._bleId ??= drop._bleId;
    if (keep._host == null && drop._host != null) {
      keep._host = drop._host;
      keep._port = drop._port;
      keep._lanGeneration++;
      keep._verifiedLanGeneration = null;
    } else if (!keep._lanReachable &&
        drop._lanReachable &&
        drop._host != null) {
      // The address we just reached is the one that answered.
      keep._host = drop._host;
      keep._port = drop._port;
      keep._lanGeneration++;
      keep._verifiedLanGeneration = null;
    }
    if (keep._name.isEmpty) keep._name = drop._name;
    if (keep._width <= 0 && drop._width > 0) {
      keep._width = drop._width;
      keep._height = drop._height;
    }
    keep._displayApi = math.max(keep._displayApi, drop._displayApi);
    if (keep._status == null && drop._status != null) {
      keep._status = drop._status;
      keep._mode = drop._mode;
      keep._baseMode = drop._baseMode;
      keep._pictureReady = drop._pictureReady;
      if (drop._status!.flip180 != null) keep._flip180 = drop._flip180;
    }
    // A record that has never had a status report has no orientation of its
    // own to keep, so the other record's is the only thing known.
    if (keep._status == null && drop._flip180) keep._flip180 = true;
    if (keep._frame == null && drop._frame != null) {
      keep._frame = drop._frame;
      keep._frameAt = drop._frameAt;
      // The dropped record's cache file is about to be deleted, so the kept
      // record has nothing on disk until its own write lands.
      keep._savedFrameAt = null;
    }
    final lastSeen = drop._lastSeen;
    if (lastSeen != null &&
        (keep._lastSeen == null || lastSeen.isAfter(keep._lastSeen!))) {
      keep._lastSeen = lastSeen;
    }

    _devices.remove(drop);
    drop._removed = true;
    drop._mergedInto = keep;
    drop._stopListening();
    final wasLive = drop._connection.session != null;
    try {
      await drop._connection.disconnect();
    } catch (_) {
      // Closing a candidate link is best effort; the record goes either way.
    }
    drop._connection.dispose();
    drop.dispose();
    try {
      final file = await _previewFile(drop.key);
      if (file.existsSync()) await file.delete();
    } catch (_) {
      // Preview cache only.
    }

    await _persist();
    // The kept record now holds an image that was cached under the dropped
    // key; write it under its own name so a restart keeps the preview.
    if (keep._frame != null && keep._savedFrameAt != keep._frameAt) {
      await _saveFrame(keep);
    }
    _noteChanged(keep, structural: true);
    // The link the dropped record held was the confirmed one; the retained
    // record reopens it under its own connection rather than inheriting a
    // session that was addressed to another record.
    if (wasLive && keep._bleId != null && keep._connection.session == null) {
      await _connectDevice(keep);
    }
  }

  /// Confirms that the endpoint still answers as this device before the first
  /// write of an endpoint generation. A mismatch invalidates the address and
  /// never reaches the replacement device.
  Future<void> _verifyLanIdentity(
    MirrorDevice device,
    MirrorLan lan, {
    bool forWrite = true,
  }) async {
    if (device._verifiedLanGeneration == device._lanGeneration) return;
    final generation = device._lanGeneration;
    final MirrorStatus status;
    try {
      status = await lan.status();
    } catch (e) {
      if (forWrite) _noteFailure(device, e);
      rethrow;
    }
    _require(device);
    if (generation != device._lanGeneration) {
      throw MirrorRegistryException(
          'The device address changed; refresh before retrying.');
    }
    _markLanSuccess(device);
    await _applyStatus(device, status);
    _require(device);
    if (device._host == null) {
      // _applyStatus dropped the endpoint: it answers as other hardware now.
      throw MirrorRegistryException(
        device._error ?? 'That address does not answer as this device.',
      );
    }
    device._verifiedLanGeneration = device._lanGeneration;
  }

  /// Confirms that the live BLE session belongs to this record, once per
  /// session. A session that reports a different firmware ID is dropped
  /// before any command is sent.
  Future<void> _verifyBleIdentity(
      MirrorDevice device, BleSession session) async {
    if (identical(device._verifiedSession, session)) return;
    final info = await session.getDeviceInfo();
    _require(device);
    if (!identical(device._connection.session, session)) {
      throw MirrorRegistryException(
          'The Bluetooth connection changed; reconnect before retrying.');
    }
    if (device._id != null && info?.id != device._id) {
      await device._connection.disconnect();
      throw MirrorRegistryException(
        'Bluetooth is connected to a different mirror.',
      );
    }
    if (info != null && device._id == null) {
      await _adoptIdentity(device, info.id);
      _require(device);
    }
    device._verifiedSession = session;
  }

  // -------------------------------------------------------------- BLE links

  /// The nearby mirrors a scan found, after BLE permissions are granted. The
  /// adapter prompt and the picker belong to the Add device screen.
  Future<List<BleScanEntry>> scanBle({
    Duration timeout = const Duration(seconds: 6),
  }) async {
    _checkAlive();
    await _ensureBleReady();
    return _scan(timeout: timeout);
  }

  /// Reconnects a known Bluetooth device. Does nothing useful without a known
  /// BLE remote id: use [attachBle] with a scan result for the first pairing.
  Future<void> connect(MirrorDevice device) async {
    _require(device);
    if (device._bleId == null) {
      throw MirrorRegistryException(
        'This device has no Bluetooth address yet. Add it from a scan.',
      );
    }
    await _serializeHandover(() => _connectDevice(device));
  }

  /// Pairs a scanned mirror with a record that has no Bluetooth alias yet,
  /// after confirming they are the same hardware. A different firmware ID is
  /// refused and disconnected before any mutation reaches it.
  Future<void> attachBle(MirrorDevice device, BleScanEntry entry) async {
    _require(device);
    final remoteId = entry.device.remoteId.str;
    final owner = deviceForBleId(remoteId);
    if (owner != null && owner.key != device.key) {
      throw MirrorRegistryException(
        'That Bluetooth device is already paired with ${owner.name}.',
      );
    }
    final connection = _connectionFactory(
      deviceId: remoteId,
      deviceName: entry.name.isEmpty ? device._name : entry.name,
      panelWidth: device._width,
      panelHeight: device._height,
    );
    MirrorDeviceInfo? info;
    try {
      await connection.connectDevice(
        id: remoteId,
        name: entry.name.isEmpty ? device._name : entry.name,
        timeout: _bleConnectTimeout,
      );
      info = await connection.session?.getDeviceInfo();
    } catch (e) {
      await _closeQuietly(connection);
      device._error = _message(e);
      device._touch();
      throw _wrapped(e);
    }
    if (info == null || (device._id != null && info.id != device._id)) {
      await _closeQuietly(connection);
      device._error = info == null
          ? 'Update firmware before pairing: this mirror’s identity could not be confirmed.'
          : 'That Bluetooth device is a different mirror.';
      device._touch();
      throw MirrorRegistryException(device._error!);
    }
    // The candidate was only ever a way to read an identity; the record keeps
    // its own connection, now bound to the confirmed remote id.
    await _closeQuietly(connection);
    _require(device);
    device._bleId = remoteId;
    if (device._id == null) await _adoptIdentity(device, info.id);
    if (device._removed) return;
    _applyInfo(device, info);
    device._error = null;
    await _persist();
    _noteChanged(device, structural: true);
    // The record's own link, now addressing the confirmed remote id.
    await _serializeHandover(() => _connectDevice(device));
  }

  /// Opens this record's own BLE link and confirms its identity. Returns the
  /// surviving record: an identity match can merge the candidate into the
  /// record that already knew the hardware.
  Future<MirrorDevice?> _connectDevice(MirrorDevice device) async {
    final bleId = device._bleId;
    if (bleId == null) return null;
    final attempt = ++device._bleAttempt;
    try {
      await device._connection.connectDevice(
        id: bleId,
        name: device._name,
        timeout: _bleConnectTimeout,
      );
    } catch (e) {
      if (attempt != device._bleAttempt || device._removed) return null;
      device._error = _message(e);
      device._touch();
      return null;
    }
    if (attempt != device._bleAttempt || device._removed) return null;
    final session = device._connection.session;
    if (session == null) {
      device._error = 'The mirror did not answer over Bluetooth.';
      device._touch();
      return null;
    }
    MirrorDeviceInfo? info;
    try {
      info = await session.getDeviceInfo();
    } catch (_) {
      info = null; // firmware that predates the command, or a dropped link
    }
    if (attempt != device._bleAttempt || device._removed) return null;
    if (device._id != null && info?.id != device._id) {
      await device._connection.disconnect();
      device._error = 'That Bluetooth device is a different mirror.';
      device._touch();
      return null;
    }
    if (info != null) {
      device._verifiedSession = session;
      if (device._id == null) {
        await _adoptIdentity(device, info.id);
        if (device._removed) return device._mergedInto ?? deviceForId(info.id);
      }
      _applyInfo(device, info);
    }
    device._error = null;
    device._lastSeen = _now();
    await _persist();
    _noteChanged(device, structural: true);
    return device;
  }

  Future<void> _closeQuietly(MirrorConnection connection) async {
    try {
      await connection.disconnect();
    } catch (_) {
      // A candidate link that will not close is still dropped.
    }
    connection.dispose();
  }

  void _applyInfo(MirrorDevice device, MirrorDeviceInfo info) {
    if (device._displayApi != info.displayApi) {
      device._displayApi = info.displayApi;
    }
    device._mode = info.mode;
    device._baseMode = info.baseMode;
    device._pictureReady = info.pictureReady;
  }

  // -------------------------------------------------------------- mutations

  /// Sets the saved base display, over the live BLE session when there is one
  /// and over LAN otherwise. The device's answer is what gets recorded.
  Future<void> setMode(MirrorDevice device, DisplayMode mode) async {
    _require(device);
    if (mode == DisplayMode.games) {
      throw MirrorRegistryException(
        'Games are started from the Games screen, not saved as a display mode.',
      );
    }
    final session = device._connection.session;
    final lan = session == null ? _lanFor(device) : null;
    if (session == null && lan == null) {
      throw MirrorRegistryException(
        'This device has no reachable transport for a display change.',
      );
    }
    try {
      if (session != null) {
        await _verifyBleIdentity(device, session);
        await session.setDisplayMode(mode);
        if (device._removed) return;
        final info = await session.getDeviceInfo();
        if (info != null && !device._removed) _applyInfo(device, info);
      } else {
        await _verifyLanIdentity(device, lan!, forWrite: false);
        final result = await lan.setDisplayMode(mode);
        _markLanSuccess(device);
        if (device._removed) return;
        _applyDisplayResult(device, result);
      }
      device._error = null;
      await _persist();
      _noteChanged(device, structural: true);
    } catch (e) {
      _noteFailure(device, e);
      throw _wrapped(e);
    }
    // The panel changed: read the real state and a fresh frame rather than
    // trusting the request we just sent.
    if (!device._removed) await refresh(device, includeFrame: true);
  }

  /// Uploads one prepared picture. The bytes are the app's own pre-gamma
  /// RGB888; a picture never travels over Bluetooth in this version.
  Future<DisplayResult> uploadPicture(
    MirrorDevice device,
    Uint8List rgb, {
    required int width,
    required int height,
  }) async {
    _require(device);
    if (device._uploading) {
      throw MirrorRegistryException('A picture upload is already in progress.');
    }
    final lan = _lanFor(device);
    if (lan == null) {
      throw MirrorRegistryException(uploadNeedsWifiMessage);
    }
    if (rgb.isEmpty) {
      throw MirrorRegistryException('There is no picture to send.');
    }
    device._uploading = true;
    device._touch();
    try {
      final result = await _sendPicture(
        device,
        lan,
        rgb,
        width: width,
        height: height,
      );
      // The mirror stores the image before answering 200; read the panel back
      // so the tile shows the picture the device actually has.
      if (!device._removed) {
        device._uploading = false;
        device._touch();
        await refresh(device, includeFrame: true);
      }
      return result;
    } catch (e) {
      if (!device._removed) device._error = _message(e);
      throw _wrapped(e);
    } finally {
      if (device._uploading) {
        device._uploading = false;
        if (!device._removed) device._touch();
      }
    }
  }

  /// Verifies identity and geometry, then sends the bytes. Kept apart from
  /// [uploadPicture] so the in-flight flag is cleared on every exit.
  Future<DisplayResult> _sendPicture(
    MirrorDevice device,
    MirrorLan lan,
    Uint8List rgb, {
    required int width,
    required int height,
  }) async {
    // Identity and geometry first: the picture is framed for a panel size, and
    // sending it to a mirror that changed shape would crop blindly.
    await _verifyLanIdentity(device, lan);
    if (device._width > 0 &&
        device._height > 0 &&
        (device._width != width || device._height != height)) {
      throw MirrorRegistryException(
        'The mirror\'s panel is ${device._width}×${device._height} now; '
        'frame the picture again for the new size.',
      );
    }
    final sent = await lan.uploadPicture(rgb, width: width, height: height);
    _markLanSuccess(device);
    if (!device._removed) {
      _applyDisplayResult(device, sent);
      device._error = null;
      await _persist();
    }
    return sent;
  }

  /// Pushes a layout over the device's own transports: a live BLE session
  /// first, otherwise the LAN endpoint.
  Future<void> sendLayout(MirrorDevice device, String json) async {
    _require(device);
    final session = device._connection.session;
    try {
      if (session != null) {
        await _verifyBleIdentity(device, session);
        await session.pushLayout(json);
      } else {
        final lan = _lanFor(device);
        if (lan == null) {
          throw MirrorRegistryException(
            'This device has no reachable transport for a layout.',
          );
        }
        await _verifyLanIdentity(device, lan);
        final result = await lan.putLayout(json);
        _markLanSuccess(device);
        if (!result.ok) {
          throw MirrorRegistryException(
            result.error ?? 'The mirror refused the layout.',
          );
        }
      }
      device._error = null;
      await _persist();
    } catch (e) {
      _noteFailure(device, e);
      throw _wrapped(e);
    }
    _noteChanged(device, structural: true);
    if (!device._removed) await refresh(device);
  }

  /// Records the panel size for a device. Only positive sizes are kept; the
  /// connection reports its own geometry separately.
  Future<void> updatePanelSize(
      MirrorDevice device, int width, int height) async {
    if (device._removed) return;
    if (width <= 0 || height <= 0) return;
    if (device._width == width && device._height == height) return;
    device._width = width;
    device._height = height;
    await _persist();
    _noteChanged(device, structural: true);
  }

  /// Adopts the name the owner chose. The device is told over a live session;
  /// the registry is what persists it.
  Future<void> rename(MirrorDevice device, String name) async {
    if (device._removed) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == device._name) return;
    device._name = trimmed;
    await _persist();
    _noteChanged(device, structural: true);
    if (device._connection.session != null) {
      try {
        await device._connection.renameDevice(trimmed);
      } catch (e) {
        device._error = _message(e);
        device._touch();
      }
    }
  }

  /// Records the panel orientation for this device. The transport that
  /// applies it belongs to the caller; a failure to apply leaves the record
  /// as the last confirmed value.
  Future<void> setFlip180(MirrorDevice device, bool flip180) async {
    if (device._removed) return;
    if (device._flip180 == flip180) return;
    device._flip180 = flip180;
    await _persist();
    _noteChanged(device, structural: true);
  }

  void _applyDisplayResult(MirrorDevice device, DisplayResult result) {
    device._mode = result.mode;
    device._baseMode = result.baseMode;
    device._pictureReady = result.pictureReady;
  }

  void _noteFailure(MirrorDevice device, Object error) {
    if (device._removed) return;
    device._error = _message(error);
    // A transport-level failure means this endpoint is not answering; an HTTP
    // error means the device answered and refused, so LAN is still up.
    if (error is MirrorApiException && error.statusCode == null) {
      device._lanReachable = false;
    } else if (error is SocketException ||
        error is TimeoutException ||
        error is HttpException) {
      device._lanReachable = false;
    }
    if (!device._lanReachable) device._frameFresh = false;
    device._touch();
  }

  static String _message(Object error) {
    if (error is MirrorRegistryException) return error.message;
    if (error is MirrorApiException) return error.message;
    return bleErrorMessage(error);
  }

  /// One error type at the registry boundary, keeping the device's status
  /// code: callers should not have to know which transport raised it.
  static MirrorRegistryException _wrapped(Object error) {
    if (error is MirrorRegistryException) return error;
    if (error is MirrorApiException) {
      return MirrorRegistryException(error.message,
          statusCode: error.statusCode);
    }
    return MirrorRegistryException(_message(error));
  }

  @override
  void dispose() {
    _disposed = true;
    for (final device in _devices) {
      device._removed = true;
      device._stopListening();
      device._connection.dispose();
      device.dispose();
    }
    _devices.clear();
    super.dispose();
  }
}

/// One refresh pass per record: a second caller joins the running pass, and a
/// frame request that arrives during a status-only pass gets one more pass.
class _RefreshRun {
  Future<void> done = Future<void>.value();
  bool wantsFrame = false;
  bool servedFrame = false;
}

/// A FIFO gate that runs at most [limit] operations at once. Polling a screen
/// of tiles must not open every socket in the same instant.
class _RefreshGate {
  _RefreshGate(this.limit);

  final int limit;
  int _active = 0;
  final Queue<Completer<void>> _waiting = Queue<Completer<void>>();

  Future<void Function()> acquire() async {
    if (_active < limit) {
      _active++;
      return _release;
    }
    final completer = Completer<void>();
    _waiting.add(completer);
    await completer.future;
    return _release;
  }

  void _release() {
    if (_waiting.isEmpty) {
      _active--;
      return;
    }
    // The slot moves to the next waiter without ever being free.
    _waiting.removeFirst().complete();
  }
}
