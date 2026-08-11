// The Mirror screen: push the current layout to a mirror, configure it, and
// update its firmware.
//
// Two ways to reach a mirror:
//   - Bluetooth (phone): scan for "Smart Mirror-*", connect, push layout or
//     open the configure dialog. The BLE session's pong reports the mirror's
//     WiFi IP, which is what the phone would use for a firmware upload.
//   - On this network (desktop): mDNS discovery plus a manual IP field (the
//     fallback for every platform where discovery fails, and how you point
//     at tool/fake_mirror.dart during development). LAN entries get Push
//     layout and Update firmware.
//
// Missing BLE or mDNS on a desktop is tolerated: the sections show
// "unavailable" instead of crashing, and the manual IP path still works.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../controller.dart';
import '../services/mirror_ble.dart';
import '../services/mirror_config.dart';
import '../services/mirror_discovery.dart';
import '../services/mirror_lan.dart';

/// What the BLE pong line reports: "pong <version> <ip> <layout> <w> <h>".
class _PongInfo {
  const _PongInfo(this.version, this.ip, this.layout, this.width, this.height);

  final String version;
  final String ip;
  final String layout;
  final int width;
  final int height;

  static _PongInfo? parse(String pong) {
    final parts = pong.split(' ');
    if (parts.length < 6 || parts[0] != 'pong') return null;
    return _PongInfo(
      parts[1],
      parts[2],
      parts[3],
      int.tryParse(parts[4]) ?? 0,
      int.tryParse(parts[5]) ?? 0,
    );
  }
}

class MirrorScreen extends StatefulWidget {
  const MirrorScreen({super.key, required this.controller});

  final DesignerController controller;

  @override
  State<MirrorScreen> createState() => _MirrorScreenState();
}

class _MirrorScreenState extends State<MirrorScreen> {
  DesignerController get _c => widget.controller;

  // ------------------------------------------------------------- BLE

  final List<BleScanEntry> _bleDevices = <BleScanEntry>[];
  bool _scanning = false;
  String? _bleUnavailable;
  BleSession? _session;
  String? _bleName;
  _PongInfo? _pong;
  bool _bleBusy = false;

  // Live panel brightness (0..255) and whether the device follows the
  // layout. Null until the connected mirror answers "get brightness", which
  // hides the control on older firmware that does not know the command.
  int? _brightness;
  bool _brightnessAuto = true;

  // A permission denial that can only be undone in the system settings.
  bool _blePermissionPermanent = false;

  // ------------------------------------------------------------- LAN

  final List<LanDevice> _lanDevices = <LanDevice>[];
  final List<MirrorStatus?> _lanStatuses = <MirrorStatus?>[];
  final List<bool> _lanBusy = <bool>[];
  bool _browsing = false;
  String? _mdnsUnavailable;
  final TextEditingController _ipField = TextEditingController();

  // Avoid overlapping async work on the same device.
  int _workToken = 0;

  @override
  void initState() {
    super.initState();
    _browse();
  }

  @override
  void dispose() {
    _session?.close();
    _ipField.dispose();
    super.dispose();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _handleError(Object e, String what) {
    final msg = e is BleUnavailableException || e is BlePushException
        ? e.toString()
        : e.toString().replaceFirst('Exception: ', '');
    _toast('$what: $msg');
  }

  // ---------------------------------------------------------- scan

  /// Android 12+ needs runtime grants for BLUETOOTH_SCAN and BLUETOOTH_CONNECT
  /// before scanning; Android 11 and below need a location grant instead (the
  /// manifest declares ACCESS_FINE_LOCATION with maxSdkVersion 30, and the
  /// plugin has no legacy scan/connect mapping on those builds). Everything
  /// else needs no runtime permission. Returns false and fills
  /// [_bleUnavailable] when a needed permission is denied.
  ///
  /// The request is one batch call (a single dialog listing every permission)
  /// and the outcome is read back with `Permission.status` afterwards:
  /// permission_handler's request callback can report denied for a permission
  /// the user just granted (a known race on Android 12+), while `status`
  /// reads the live OS state.
  Future<bool> _ensureBlePermissions() async {
    if (!Platform.isAndroid) return true;

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
      final permanent = status.isPermanentlyDenied;
      if (mounted) {
        setState(() {
          _bleUnavailable = permanent
              ? 'Bluetooth permission denied; grant it in Settings'
              : 'Bluetooth permission denied';
          _blePermissionPermanent = permanent;
        });
      }
      return false;
    }
    return true;
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _bleUnavailable = null;
      _bleDevices.clear();
    });
    try {
      if (!await _ensureBlePermissions()) return;
      final found = await scanForMirrors();
      if (!mounted) return;
      setState(() => _bleDevices.addAll(found));
    } on BleUnavailableException catch (e) {
      if (!mounted) return;
      setState(() => _bleUnavailable = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _bleUnavailable = '$e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _connect(BleScanEntry entry) async {
    setState(() => _bleBusy = true);
    try {
      final session = await BleSession.connect(entry.device);
      try {
        final pong = await session.ping();
        if (!mounted) {
          await session.close();
          return;
        }
        setState(() {
          _session = session;
          _bleName = entry.name;
          _pong = _PongInfo.parse(pong);
          _brightness = null;
          _brightnessAuto = true;
        });
        _toast('Connected to ${entry.name}');
        await _loadBrightness();
      } catch (e) {
        // The mirror accepted the link but did not answer. Close the
        // session so the GATT registration and the mirror's single
        // connection slot are freed; otherwise every later connect fails
        // against a stale registration and a busy mirror.
        await session.close();
        rethrow;
      }
    } catch (e) {
      _handleError(e, 'connect');
    } finally {
      if (mounted) setState(() => _bleBusy = false);
    }
  }

  /// Read the live brightness once so the slider starts at the truth. A
  /// mirror on old firmware answers "unknown command", the parse returns
  /// null, and the control stays hidden.
  Future<void> _loadBrightness() async {
    final session = _session;
    if (session == null) return;
    try {
      final b = await session.getBrightness();
      if (!mounted || b == null) return;
      setState(() {
        _brightness = b.value;
        _brightnessAuto = b.auto;
      });
    } catch (e) {
      _handleError(e, 'brightness');
    }
  }

  /// Apply a manual override; [value] is the slider position at release.
  Future<void> _sendBrightness(int value) async {
    final session = _session;
    if (session == null) return;
    setState(() => _bleBusy = true);
    try {
      await session.setBrightness(value);
      if (mounted) setState(() => _brightness = value);
    } catch (e) {
      _handleError(e, 'brightness');
    } finally {
      if (mounted) setState(() => _bleBusy = false);
    }
  }

  /// Toggle between a manual override and "follow the layout". Turning the
  /// override off sends "set brightness auto"; turning it on pins the current
  /// live value so the slider has a real starting point.
  Future<void> _setBrightnessAuto(bool auto) async {
    final session = _session;
    if (session == null) return;
    setState(() => _bleBusy = true);
    try {
      await session.setBrightness(auto ? null : _brightness);
      if (mounted) setState(() => _brightnessAuto = auto);
    } catch (e) {
      _handleError(e, 'brightness');
    } finally {
      if (mounted) setState(() => _bleBusy = false);
    }
  }

  Future<void> _disconnectBle() async {
    final session = _session;
    _session = null;
    setState(() {
      _bleName = null;
      _pong = null;
      _brightness = null;
      _brightnessAuto = true;
    });
    await session?.close();
  }

  Future<void> _pushLayoutBle() async {
    final session = _session;
    if (session == null) return;
    setState(() => _bleBusy = true);
    try {
      final status = await session.pushLayout(_c.exportJson());
      _toast('Pushed: $status');
    } catch (e) {
      _handleError(e, 'push layout');
    } finally {
      if (mounted) setState(() => _bleBusy = false);
    }
  }

  Future<void> _configure() async {
    final session = _session;
    if (session == null) return;

    // Best-effort prefill from the device.
    MirrorConfig? current;
    try {
      final raw = await session.getConfigRaw();
      if (raw != null && raw.startsWith('config ')) {
        final decoded =
            jsonDecode(raw.substring('config '.length)) as Map<String, dynamic>;
        current = MirrorConfig.fromJson(decoded);
      }
    } catch (_) {
      // Prefill is optional; the dialog opens with empty fields.
    }
    if (!mounted) return;

    final saved = await showDialog<MirrorConfig>(
      context: context,
      builder: (_) => _ConfigureDialog(initial: current),
    );
    if (saved == null || !mounted) return;

    final problem = saved.validate();
    if (problem != null) {
      _toast('Not pushed: $problem');
      return;
    }

    setState(() => _bleBusy = true);
    try {
      final status = await session.pushConfig(saved.toJson());
      _toast('Configured: $status');
    } catch (e) {
      _handleError(e, 'configure');
    } finally {
      if (mounted) setState(() => _bleBusy = false);
    }
  }

  // ------------------------------------------------------- discovery

  Future<void> _browse() async {
    setState(() {
      _browsing = true;
      _mdnsUnavailable = null;
    });
    final token = ++_workToken;
    try {
      await for (final device in browseMdns()) {
        if (!mounted || token != _workToken) return;
        setState(() {
          if (!_lanDevices.any((d) => d.ip == device.ip)) {
            _lanDevices.add(device);
            _lanStatuses.add(null);
            _lanBusy.add(false);
            _refreshLanStatus(_lanDevices.length - 1);
          }
        });
      }
    } catch (_) {
      if (mounted && token == _workToken) {
        setState(() => _mdnsUnavailable = 'mDNS discovery unavailable here');
      }
    } finally {
      if (mounted && token == _workToken) {
        setState(() => _browsing = false);
      }
    }
  }

  void _addManualIp() {
    final raw = _ipField.text.trim();
    if (raw.isEmpty) return;
    var host = raw;
    if (!host.contains('://')) host = 'http://$host';
    final uri = Uri.tryParse(host);
    if (uri == null || uri.host.isEmpty) {
      _toast('Enter an IP or host, optionally with a port (e.g. 127.0.0.1:8080)');
      return;
    }
    final ip = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
    if (_lanDevices.any((d) => d.ip == ip)) {
      _toast('$ip is already listed');
      return;
    }
    setState(() {
      _lanDevices.add(LanDevice('manual ($ip)', ip, uri.hasPort ? uri.port : 80));
      _lanStatuses.add(null);
      _lanBusy.add(false);
      _ipField.clear();
    });
    _refreshLanStatus(_lanDevices.length - 1);
  }

  Future<void> _refreshLanStatus(int index) async {
    final token = ++_workToken;
    final device = _lanDevices[index];
    try {
      final status = await MirrorLan(device.ip).status();
      if (!mounted || token != _workToken) return;
      setState(() => _lanStatuses[index] = status);
    } catch (e) {
      if (!mounted || token != _workToken) return;
      setState(() {
        _lanStatuses[index] = null;
      });
      // A mirror that is just rebooting answers nothing for a while; the
      // user can hit the entry's refresh via a new status pull on push.
    }
  }

  Future<void> _pushLayoutLan(int index) async {
    final device = _lanDevices[index];
    setState(() => _lanBusy[index] = true);
    try {
      final result = await MirrorLan(device.ip).putLayout(_c.exportJson());
      if (result.ok) {
        _toast(result.diag.isEmpty
            ? 'Layout pushed to ${device.ip}'
            : 'Pushed with warnings: ${result.diag.join('; ')}');
      } else {
        _toast('Rejected by ${device.ip}: ${result.error}');
      }
      await _refreshLanStatus(index);
    } catch (e) {
      _handleError(e, 'push layout');
    } finally {
      if (mounted) setState(() => _lanBusy[index] = false);
    }
  }

  Future<void> _updateFirmwareLan(int index) async {
    final device = _lanDevices[index];
    final status = _lanStatuses[index];
    if (status == null ||
        status.ip.isEmpty ||
        status.ip == '0.0.0.0' ||
        status.ip == '0.0.0.0:0') {
      _toast('No WiFi IP reported; firmware upload needs the LAN address');
      return;
    }
    await _updateFirmware(device.ip);
    if (mounted) await _refreshLanStatus(index);
  }

  /// Firmware update from the BLE section: the pong carries the mirror's
  /// WiFi IP, which is what the upload talks to. Fails with the ordinary
  /// "could not reach" error when the phone is not on the same WiFi.
  Future<void> _updateFirmwareBle() async {
    final ip = _pong?.ip;
    if (ip == null || ip.isEmpty || ip == '0.0.0.0') {
      _toast('The mirror has no WiFi IP; the phone and mirror must be on '
          'the same network');
      return;
    }
    await _updateFirmware(ip);
  }

  /// Shared OTA flow: pick the image (file or URL download), upload it over
  /// the LAN API, then poll until the mirror answers again after its reboot.
  Future<void> _updateFirmware(String ip) async {
    final source = await showDialog<_FirmwareSource>(
      context: context,
      builder: (_) => const _FirmwareSourceDialog(),
    );
    if (source == null || !mounted) return;

    final File file;
    final String fileName;
    if (source.url == null) {
      const typeGroup = XTypeGroup(label: 'firmware', extensions: <String>['bin']);
      final picked =
          await openFile(acceptedTypeGroups: const <XTypeGroup>[typeGroup]);
      if (picked == null || !mounted) return;
      file = File(picked.path);
      fileName = picked.name;
    } else {
      if (!mounted) return;
      unawaited(showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _DownloadingDialog(),
      ));
      try {
        file = await _downloadFirmware(source.url!);
      } catch (e) {
        if (mounted) Navigator.of(context).pop(); // close the download dialog
        if (mounted) _handleError(e, 'download');
        return;
      }
      if (mounted) Navigator.of(context).pop(); // close the download dialog
      if (!mounted) return;
      fileName = 'ota.bin';
    }

    final progress = ValueNotifier<double>(0);
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _UploadDialog(progress: progress, fileName: fileName),
    ));

    try {
      await MirrorLan(ip).uploadFirmware(
        file,
        onProgress: (sent, total) =>
            progress.value = total > 0 ? sent / total : 0,
      );
      // The mirror reboots into the new image; poll until it answers again.
      final newStatus = await _waitForReboot(ip);
      if (!mounted) return;
      Navigator.of(context).pop(); // close the upload dialog
      _toast(newStatus == null
          ? 'Update uploaded; the mirror is rebooting'
          : 'Updated to ${newStatus.version}');
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        _handleError(e, 'update');
      }
    }
  }

  /// Download a firmware image from [url] into the app's temp directory and
  /// sanity-check it (non-empty, fits a 4 MB OTA partition). Throws
  /// [MirrorApiException] on transport or size problems.
  Future<File> _downloadFirmware(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      throw MirrorApiException('enter a full http:// URL');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 10));
      final resp = await req.close().timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        throw MirrorApiException('download failed: HTTP ${resp.statusCode}');
      }
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/ota.bin');
      final sink = file.openWrite();
      await resp.pipe(sink);
      await sink.close();
      final size = await file.length();
      if (size == 0) {
        throw MirrorApiException('the downloaded image is empty');
      }
      if (size > 4 * 1024 * 1024) {
        throw MirrorApiException('the downloaded image is too large (max 4 MB)');
      }
      return file;
    } on SocketException catch (e) {
      throw MirrorApiException('could not reach $url: ${e.message}');
    } finally {
      client.close(force: true);
    }
  }

  /// Confirm, ask the mirror to restart, and drop the session: the device is
  /// going down and the BLE connection dies with it.
  Future<void> _rebootBle() async {
    final session = _session;
    if (session == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reboot the mirror?'),
        content: const Text('The panel restarts; reconnect in a few seconds.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reboot'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _bleBusy = true);
    try {
      await session.reboot();
      _toast('Rebooting the mirror');
      await _disconnectBle();
    } catch (e) {
      _handleError(e, 'reboot');
    } finally {
      if (mounted) setState(() => _bleBusy = false);
    }
  }

  /// Poll status until the mirror answers again (it restarts during OTA),
  /// or give up after 60 seconds.
  Future<MirrorStatus?> _waitForReboot(String ip) async {
    final lan = MirrorLan(ip);
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      try {
        return await lan.status();
      } catch (_) {
        // Still down; keep polling.
      }
    }
    return null;
  }

  // ------------------------------------------------------------ view

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mirror')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _sectionTitle('Bluetooth'),
          _buildBleSection(),
          const SizedBox(height: 24),
          _sectionTitle('On this network'),
          _buildLanSection(),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    );
  }

  Widget _buildBleSection() {
    if (_bleUnavailable != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(_bleUnavailable!, style: const TextStyle(color: Colors.grey)),
          if (_blePermissionPermanent)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: <Widget>[
                  OutlinedButton.icon(
                    onPressed: _scanning ? null : _scan,
                    icon: const Icon(Icons.bluetooth_searching, size: 18),
                    label: const Text('Scan again'),
                  ),
                  const SizedBox(width: 8),
                  const TextButton(
                    onPressed: openAppSettings,
                    child: Text('Open settings'),
                  ),                ],
              ),
            ),
        ],
      );
    }

    final session = _session;
    if (session != null) {
      final pong = _pong;
      final otaReady = pong != null &&
          pong.ip.isNotEmpty &&
          pong.ip != '0.0.0.0';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Connected to $_bleName'),
          if (pong != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'v${pong.version}  IP ${pong.ip}  layout ${pong.layout} '
                '(${pong.width}x${pong.height})',
                style: const TextStyle(color: Colors.grey),
              ),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: <Widget>[
              FilledButton.icon(
                onPressed: _bleBusy ? null : _pushLayoutBle,
                icon: const Icon(Icons.send, size: 18),
                label: const Text('Push layout'),
              ),
              OutlinedButton.icon(
                onPressed: _bleBusy ? null : _configure,
                icon: const Icon(Icons.tune, size: 18),
                label: const Text('Configure'),
              ),
              Tooltip(
                message: 'Uploads over WiFi, so the phone and mirror must be '
                    'on the same network',
                child: OutlinedButton.icon(
                  onPressed: _bleBusy || !otaReady ? null : _updateFirmwareBle,
                  icon: const Icon(Icons.system_update, size: 18),
                  label: const Text('Update firmware'),
                ),
              ),
              TextButton.icon(
                onPressed: _bleBusy ? null : _rebootBle,
                icon: const Icon(Icons.restart_alt, size: 18),
                label: const Text('Reboot'),
              ),
              TextButton(
                onPressed: _disconnectBle,
                child: const Text('Disconnect'),
              ),
            ],
          ),
          // Brightness is only shown once the mirror answered "get
          // brightness"; old firmware hides the whole control.
          if (_brightness != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: <Widget>[
                  const Text('Brightness'),
                  Expanded(
                    child: Slider(
                      value: (_brightness ?? 0).clamp(0, 255).toDouble(),
                      min: 0,
                      max: 255,
                      divisions: 255,
                      label: '$_brightness',
                      // The layout owns brightness in auto mode; dragging is
                      // what takes manual control.
                      onChanged: _bleBusy || _brightnessAuto
                          ? null
                          : (v) => setState(() => _brightness = v.round()),
                      onChangeEnd: _bleBusy || _brightnessAuto
                          ? null
                          : (v) => _sendBrightness(v.round()),
                    ),
                  ),
                  Text('${_brightness ?? 0}/255'),
                  const SizedBox(width: 8),
                  Switch(
                    value: _brightnessAuto,
                    onChanged: _bleBusy ? null : _setBrightnessAuto,
                  ),
                  const Text('Auto'),
                ],
              ),
            ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            FilledButton.icon(
              onPressed: _scanning ? null : _scan,
              icon: const Icon(Icons.bluetooth_searching, size: 18),
              label: Text(_scanning ? 'Scanning...' : 'Scan'),
            ),
          ],
        ),
        if (_scanning)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Scanning for Smart Mirror devices...',
                style: TextStyle(color: Colors.grey)),
          )
        else if (_bleDevices.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('No mirrors found. Scan to look for Smart Mirror devices.',
                style: TextStyle(color: Colors.grey)),
          )
        else
          for (final entry in _bleDevices)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(entry.name),
              subtitle: Text('${entry.rssi} dBm'),
              trailing: FilledButton(
                onPressed: _bleBusy ? null : () => _connect(entry),
                child: const Text('Connect'),
              ),
            ),
      ],
    );
  }

  Widget _buildLanSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            if (_mdnsUnavailable == null)
              OutlinedButton.icon(
                onPressed: _browsing ? null : _browse,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(_browsing ? 'Browsing...' : 'Browse'),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _ipField,
                decoration: const InputDecoration(
                  hintText: 'Manual IP (e.g. 127.0.0.1:8080)',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _addManualIp(),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: _addManualIp,
              child: const Text('Add'),
            ),
          ],
        ),
        if (_mdnsUnavailable != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_mdnsUnavailable!,
                style: const TextStyle(color: Colors.grey)),
          ),
        if (_lanDevices.isEmpty && _mdnsUnavailable == null)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('No mirrors on this network. Add an IP manually.',
                style: TextStyle(color: Colors.grey)),
          ),
        for (var i = 0; i < _lanDevices.length; i++) _buildLanTile(i),
      ],
    );
  }

  Widget _buildLanTile(int index) {
    final device = _lanDevices[index];
    final status = _lanStatuses[index];
    final busy = _lanBusy[index];

    final statusText = status == null
        ? 'status unknown'
        : 'v${status.version}${status.core.isNotEmpty ? '  core ${status.core}' : ''}'
            '  ${status.layout} ${status.width}x${status.height}  '
            '${status.brightness}/255';

    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text('${device.name} (${device.ip})'),
      subtitle: Text(statusText,
          style: const TextStyle(color: Colors.grey)),
      trailing: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          FilledButton(
            onPressed: busy ? null : () => _pushLayoutLan(index),
            child: const Text('Push layout'),
          ),
          OutlinedButton(
            onPressed: busy ? null : () => _updateFirmwareLan(index),
            child: const Text('Update firmware'),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ dialog

/// Configure dialog: timezone preset (or custom), coordinates, place label.
/// Only reachable over BLE, per the owner's decision.
class _ConfigureDialog extends StatefulWidget {
  const _ConfigureDialog({this.initial});

  final MirrorConfig? initial;

  @override
  State<_ConfigureDialog> createState() => _ConfigureDialogState();
}

class _ConfigureDialogState extends State<_ConfigureDialog> {
  late final TextEditingController _tzCustom;
  late final TextEditingController _lat;
  late final TextEditingController _lon;
  late final TextEditingController _place;
  String? _presetTz;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    final tz = initial?.timezone;
    final presetValues = kTimezonePresets.map((p) => p.tz).toSet();
    if (tz != null && presetValues.contains(tz)) {
      _presetTz = tz;
    } else {
      // A non-empty value that matches no preset is a custom string; either
      // way the dropdown must not receive a value it has no item for.
      _presetTz = tz == null ? null : '';
    }
    _tzCustom = TextEditingController(text: tz ?? '');
    _lat = TextEditingController(text: initial?.latitude ?? '');
    _lon = TextEditingController(text: initial?.longitude ?? '');
    _place = TextEditingController(text: initial?.place ?? '');
  }

  @override
  void dispose() {
    _tzCustom.dispose();
    _lat.dispose();
    _lon.dispose();
    _place.dispose();
    super.dispose();
  }

  String? get _timezone {
    if (_presetTz == null || _presetTz!.isEmpty) {
      final custom = _tzCustom.text.trim();
      return custom.isEmpty ? null : custom;
    }
    return _presetTz;
  }

  MirrorConfig _collect() => MirrorConfig(
        timezone: _timezone,
        latitude: _lat.text.trim().isEmpty ? null : _lat.text.trim(),
        longitude: _lon.text.trim().isEmpty ? null : _lon.text.trim(),
        place: _place.text.trim().isEmpty ? null : _place.text.trim(),
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Configure mirror'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            DropdownButtonFormField<String?>(
              initialValue: _presetTz,
              decoration: const InputDecoration(labelText: 'Timezone'),
              items: <DropdownMenuItem<String?>>[
                for (final p in kTimezonePresets)
                  DropdownMenuItem<String?>(
                    value: p.tz,
                    child: Text('${p.label} (${p.tz})'),
                  ),
                const DropdownMenuItem<String?>(
                  value: '',
                  child: Text('Custom...'),
                ),
              ],
              onChanged: (value) => setState(() {
                _presetTz = value;
              }),
            ),
            if (_presetTz == null || _presetTz!.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: TextField(
                  controller: _tzCustom,
                  decoration: const InputDecoration(
                    labelText: 'POSIX timezone string',
                    hintText: 'e.g. UTC0',
                  ),
                ),
              ),
            const SizedBox(height: 8),
            TextField(
              controller: _lat,
              keyboardType: const TextInputType.numberWithOptions(
                  decimal: true, signed: true),
              decoration: const InputDecoration(labelText: 'Latitude'),
            ),
            TextField(
              controller: _lon,
              keyboardType: const TextInputType.numberWithOptions(
                  decimal: true, signed: true),
              decoration: const InputDecoration(labelText: 'Longitude'),
            ),
            TextField(
              controller: _place,
              maxLength: 23,
              decoration: const InputDecoration(labelText: 'Place name'),
            ),
            // The dialog is BLE-only; the LAN API deliberately has no config
            // endpoint.
            const Text(
              'Sent over Bluetooth to the mirror',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_collect()),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Upload progress dialog; dismissed by the caller when the upload finishes.
class _UploadDialog extends StatelessWidget {
  const _UploadDialog({required this.progress, required this.fileName});

  final ValueListenable<double> progress;
  final String fileName;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Updating firmware'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(fileName, style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 12),
          ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (context, value, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                LinearProgressIndicator(value: value),
                const SizedBox(height: 8),
                Text('${(value * 100).toStringAsFixed(0)}%'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// How the user chose to provide the image: a local file, or a URL to
/// download (url non-null).
class _FirmwareSource {
  const _FirmwareSource.chooseFile() : url = null;
  const _FirmwareSource.download(this.url);

  final String? url;
}

/// Two ways to get the image onto the phone: pick the .bin, or fetch it from
/// a PC that runs `tools/build_ota.sh --serve`.
class _FirmwareSourceDialog extends StatelessWidget {
  const _FirmwareSourceDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Firmware image'),
      content: const Text(
        'The .bin is the app partition image from the PC build '
        '(tools/build_ota.sh).',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context)
              .pop(const _FirmwareSource.chooseFile()),
          child: const Text('Choose file'),
        ),
        FilledButton(
          onPressed: () async {
            final url = await showDialog<String>(
              context: context,
              builder: (_) => const _DownloadUrlDialog(),
            );
            if (url != null && context.mounted) {
              Navigator.of(context).pop(_FirmwareSource.download(url));
            }
          },
          child: const Text('Download from URL'),
        ),
      ],
    );
  }
}

/// URL prompt for the download source; remembers the last value so a
/// repeated OTA is one paste less.
class _DownloadUrlDialog extends StatefulWidget {
  const _DownloadUrlDialog();

  @override
  State<_DownloadUrlDialog> createState() => _DownloadUrlDialogState();
}

class _DownloadUrlDialogState extends State<_DownloadUrlDialog> {
  static const String _prefsKey = 'ota_download_url';
  late final TextEditingController _url;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController();
    _prefill();
  }

  Future<void> _prefill() async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getString(_prefsKey);
    if (last != null && last.isNotEmpty && mounted) {
      setState(() => _url.text = last);
    }
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _ok() async {
    final url = _url.text.trim();
    if (url.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, url);
    if (mounted) Navigator.of(context).pop(url);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Download firmware'),
      content: TextField(
        controller: _url,
        autofocus: true,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(
          hintText: 'http://192.168.1.20:8000/smart_mirror-0.2.0.bin',
        ),
        onSubmitted: (_) => _ok(),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _ok,
          child: const Text('Download'),
        ),
      ],
    );
  }
}

/// Shown while a URL download runs; closed by the caller.
class _DownloadingDialog extends StatelessWidget {
  const _DownloadingDialog();

  @override
  Widget build(BuildContext context) {
    return const AlertDialog(
      content: Row(
        children: <Widget>[
          CircularProgressIndicator(),
          SizedBox(width: 16),
          Text('Downloading firmware...'),
        ],
      ),
    );
  }
}
