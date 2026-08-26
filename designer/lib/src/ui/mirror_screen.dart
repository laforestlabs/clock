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
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../controller.dart';
import '../services/bundled_firmware.dart';
import '../services/mirror_ble.dart';
import '../services/mirror_config.dart';
import '../services/mirror_connection.dart';
import '../services/mirror_discovery.dart';
import '../services/mirror_lan.dart';
import 'ble_prompt.dart';

class MirrorScreen extends StatefulWidget {
  const MirrorScreen({
    super.key,
    required this.controller,
    required this.connection,
    this.simplified = false,
  });

  final DesignerController controller;

  /// The app-scoped BLE link, owned by the workspace so it survives this
  /// screen being pushed and popped.
  final MirrorConnection connection;

  /// Trimmed deployment surface: BLE only, no LAN, bundled firmware only.
  final bool simplified;

  @override
  State<MirrorScreen> createState() => _MirrorScreenState();
}

class _MirrorScreenState extends State<MirrorScreen> {
  DesignerController get _c => widget.controller;
  MirrorConnection get _connection => widget.connection;

  // ------------------------------------------------------------- BLE

  final List<BleScanEntry> _bleDevices = <BleScanEntry>[];
  bool _scanning = false;
  String? _bleUnavailable;
  bool _bleBusy = false;

  /// Bundled firmware version, loaded only in simplified mode for the
  /// "Update to latest" button.
  BundledFirmware? _bundled;

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
    // Re-entering the screen with a live session: refresh the brightness
    // slider from the device instead of waiting for a new connect.
    if (_connection.session != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadBrightness());
    }
    if (widget.simplified) _loadBundledVersion();
  }

  /// Loads the bundled firmware for the simplified "Update to latest" button.
  Future<void> _loadBundledVersion() async {
    final bundled = await loadBundledFirmware();
    if (!mounted) return;
    setState(() => _bundled = bundled);
  }

  @override
  void dispose() {
    // Deliberately no connection teardown here: the session is owned by the
    // workspace and must survive this screen being popped.
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

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _bleUnavailable = null;
      _bleDevices.clear();
    });
    try {
      final gate = await ensureBlePermissions();
      if (!mounted) return;
      if (!gate.granted) {
        setState(() {
          _bleUnavailable = gate.permanentDenied
              ? 'Bluetooth permission denied; grant it in Settings'
              : 'Bluetooth permission denied';
          _blePermissionPermanent = gate.permanentDenied;
        });
        return;
      }
      if (!await FlutterBluePlus.isSupported) {
        if (!mounted) return;
        setState(() => _bleUnavailable = 'Bluetooth is not available here');
        return;
      }
      if (!mounted) return;
      if (!await ensureBluetoothOn(context)) {
        if (!mounted) return;
        setState(
            () => _bleUnavailable = 'Bluetooth is off; enable it to scan');
        return;
      }
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
    await _connection.connect(entry);
    if (!mounted) return;
    if (_connection.status != MirrorConnectionStatus.connected) return;
    setState(() {
      _brightness = null;
      _brightnessAuto = true;
    });
    _toast('Connected to ${entry.name}');
    await _loadBrightness();
  }

  /// Reconnect to the last remembered mirror after a failed connect.
  Future<void> _retryConnect() async {
    if (!await ensureBluetoothOn(context)) return;
    await _connection.connectLast();
    if (!mounted) return;
    if (_connection.status == MirrorConnectionStatus.connected) {
      setState(() {
        _brightness = null;
        _brightnessAuto = true;
      });
      await _loadBrightness();
    }
  }

  /// Read the live brightness once so the slider starts at the truth. A
  /// mirror on old firmware answers "unknown command", the parse returns
  /// null, and the control stays hidden.
  Future<void> _loadBrightness() async {
    final session = _connection.session;
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
    final session = _connection.session;
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
    final session = _connection.session;
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
    await _connection.disconnect();
    if (mounted) {
      setState(() {
        _brightness = null;
        _brightnessAuto = true;
      });
    }
  }

  /// A layout whose canvas differs from the mirror's panel would render
  /// clipped or rejected on the device. Block the push and point at a fix.
  void _toastSizeMismatch(int w, int h) {
    _toast('Not pushed: this layout is ${_c.doc.width}x${_c.doc.height}, '
        'but your mirror is ${w}x$h. Open a ${w}x$h layout or resize the '
        'canvas.');
  }

  Future<void> _pushLayoutBle() async {
    final session = _connection.session;
    if (session == null) return;
    final pong = _connection.pong;
    if (pong != null && pong.width > 0 && pong.height > 0 &&
        (_c.doc.width != pong.width || _c.doc.height != pong.height)) {
      _toastSizeMismatch(pong.width, pong.height);
      return;
    }
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
    final session = _connection.session;
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
    final status = _lanStatuses[index];
    if (status != null && status.width > 0 && status.height > 0 &&
        (_c.doc.width != status.width || _c.doc.height != status.height)) {
      _toastSizeMismatch(status.width, status.height);
      return;
    }
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
    await _updateFirmware(device.ip, deviceVersion: status.version);
    if (mounted) await _refreshLanStatus(index);
  }

  /// Firmware update from the BLE section: the pong carries the mirror's
  /// WiFi IP, which is what the upload talks to. Fails with the ordinary
  /// "could not reach" error when the phone is not on the same WiFi.
  Future<void> _updateFirmwareBle() async {
    final ip = _connection.pong?.ip;
    if (ip == null || ip.isEmpty || ip == '0.0.0.0') {
      _toast('The mirror has no WiFi IP; the phone and mirror must be on '
          'the same network');
      return;
    }
    await _updateFirmware(ip, deviceVersion: _connection.pong?.version ?? '');
  }

  /// Bundled-only firmware update: no file or URL source, no source dialog.
  Future<void> _updateFirmwareLatest() async {
    final bundled = _bundled ?? await loadBundledFirmware();
    if (!mounted) return;
    if (bundled == null) {
      _toast('No firmware bundled with this app');
      return;
    }
    final ip = _connection.pong?.ip;
    if (ip == null || ip.isEmpty || ip == '0.0.0.0') {
      _toast('The mirror has no WiFi IP; the phone and mirror must be on the same network');
      return;
    }
    await _uploadAndWait(ip, bundled.bytes, 'bundled v${bundled.version}');
  }

  /// Shared OTA flow: prefer the firmware bundled with this app, offering a
  /// file or a URL as fallbacks. Upload the chosen bytes over the LAN API,
  /// then poll until the mirror answers again after its reboot.
  Future<void> _updateFirmware(String ip, {String deviceVersion = ''}) async {
    final bundled = await loadBundledFirmware();
    if (!mounted) return;

    final source = await showDialog<_FirmwareSource>(
      context: context,
      builder: (_) => _FirmwareSourceDialog(
        bundledVersion: bundled?.version,
        deviceVersion: deviceVersion,
      ),
    );
    if (source == null || !mounted) return;

    final Uint8List bytes;
    final String fileName;
    if (source.kind == _FirmwareSourceKind.bundled) {
      bytes = bundled!.bytes;
      fileName = 'bundled v${bundled.version}';
    } else if (source.kind == _FirmwareSourceKind.file) {
      const typeGroup =
          XTypeGroup(label: 'firmware', extensions: <String>['bin']);
      final picked =
          await openFile(acceptedTypeGroups: const <XTypeGroup>[typeGroup]);
      if (picked == null || !mounted) return;
      bytes = await File(picked.path).readAsBytes();
      fileName = picked.name;
    } else {
      if (!mounted) return;
      unawaited(showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _DownloadingDialog(),
      ));
      try {
        bytes = await _downloadFirmwareBytes(source.url!);
      } catch (e) {
        if (mounted) Navigator.of(context).pop(); // close the download dialog
        if (mounted) _handleError(e, 'download');
        return;
      }
      if (mounted) Navigator.of(context).pop(); // close the download dialog
      fileName = 'ota.bin';
    }

    await _uploadAndWait(ip, bytes, fileName);
  }

  /// Stream [bytes] to the mirror's OTA endpoint, poll until it answers after
  /// the reboot, then toast the result.
  Future<void> _uploadAndWait(
      String ip, Uint8List bytes, String fileName) async {
    final progress = ValueNotifier<double>(0);
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _UploadDialog(progress: progress, fileName: fileName),
    ));

    try {
      await MirrorLan(ip).uploadFirmwareBytes(
        bytes,
        onProgress: (sent, total) =>
            progress.value = total > 0 ? sent / total : 0,
      );
      // The mirror reboots into the new image; poll until it answers again.
      final newStatus = await _waitForReboot(ip);
      if (!mounted) return;
      Navigator.of(context).pop(); // close the upload dialog
      if (newStatus != null) {
        // The mirror rebooted, so the BLE link died. Reconnect it now that
        // the device is advertising again (no-op when nothing is remembered
        // or on platforms without BLE).
        unawaited(_connection.connectLast());
      }
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

  /// Download a firmware image from [url] and sanity-check it (non-empty,
  /// fits a 4 MB OTA partition). Throws [MirrorApiException] on transport or
  /// size problems.
  Future<Uint8List> _downloadFirmwareBytes(String url) async {
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
      final builder = BytesBuilder(copy: false);
      await resp.forEach(builder.add);
      final bytes = builder.takeBytes();
      if (bytes.isEmpty) {
        throw MirrorApiException('the downloaded image is empty');
      }
      if (bytes.length > 4 * 1024 * 1024) {
        throw MirrorApiException('the downloaded image is too large (max 4 MB)');
      }
      return bytes;
    } on SocketException catch (e) {
      throw MirrorApiException('could not reach $url: ${e.message}');
    } finally {
      client.close(force: true);
    }
  }

  /// Confirm, ask the mirror to restart, and drop the session: the device is
  /// going down and the BLE connection dies with it.
  Future<void> _rebootBle() async {
    final session = _connection.session;
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
      // The BLE section is a view over the workspace-owned connection, so a
      // state change (connect, disconnect, dropped link) rebuilds it even
      // when it happened while this screen was not on stage.
      body: ListenableBuilder(
        listenable: _connection,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            _sectionTitle('Bluetooth'),
            _buildBleSection(),
            if (!widget.simplified) ...<Widget>[
              const SizedBox(height: 24),
              _sectionTitle('On this network'),
              _buildLanSection(),
            ],
          ],
        ),
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
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: _scanning ? null : _scan,
                  icon: const Icon(Icons.bluetooth_searching, size: 18),
                  label: const Text('Scan again'),
                ),
                if (_blePermissionPermanent) ...<Widget>[
                  const SizedBox(width: 8),
                  const TextButton(
                    onPressed: openAppSettings,
                    child: Text('Open settings'),
                  ),
                ],
              ],
            ),
          ),
        ],
      );
    }

    final connection = _connection;
    if (connection.status == MirrorConnectionStatus.connecting) {
      return Row(
        children: <Widget>[
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Text('Connecting to ${connection.deviceName}...'),
        ],
      );
    }

    final session = connection.session;
    if (session != null) {
      final pong = connection.pong;
      final otaReady = pong != null &&
          pong.ip.isNotEmpty &&
          pong.ip != '0.0.0.0';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Connected to ${connection.deviceName}'),
          if (!widget.simplified && pong != null)
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
              if (widget.simplified)
                OutlinedButton.icon(
                  onPressed: (_bleBusy || _bundled == null)
                      ? null
                      : _updateFirmwareLatest,
                  icon: const Icon(Icons.system_update, size: 18),
                  label: Text(_bundled == null
                      ? 'Update unavailable'
                      : 'Update to latest (v${_bundled!.version})'),
                )
              else ...<Widget>[
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
              ],
              TextButton(
                onPressed: _disconnectBle,
                child: const Text('Disconnect'),
              ),
            ],
          ),
          // Brightness is only shown once the mirror answered "get
          // brightness"; old firmware hides the whole control.
          if (!widget.simplified && _brightness != null)
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

    if (connection.status == MirrorConnectionStatus.failed) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Could not connect to ${connection.deviceName}: '
              '${connection.error ?? 'unknown error'}'),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              OutlinedButton.icon(
                onPressed: _retryConnect,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Retry'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _scanning ? null : _scan,
                icon: const Icon(Icons.bluetooth_searching, size: 18),
                label: const Text('Scan again'),
              ),
            ],
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
              subtitle: widget.simplified ? null : Text('${entry.rssi} dBm'),
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

/// Configure dialog: timezone preset (or custom), coordinates, place label,
/// clock format and temperature unit. Only reachable over BLE, per the
/// owner's decision.
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

  /// Display settings default to the device's factory values (12-hour,
  /// Fahrenheit) when the device could not be prefilled. They are always
  /// pushed: unlike the text fields there is no "unchanged" empty state for
  /// a choice, and the defaults match a fresh mirror.
  late bool _clock12h;
  late bool _tempF;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _clock12h = initial?.clock12h ?? true;
    _tempF = initial?.tempF ?? true;
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
        clock12h: _clock12h,
        tempF: _tempF,
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
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const <ButtonSegment<bool>>[
                ButtonSegment<bool>(
                    value: true, label: Text('12-hour clock')),
                ButtonSegment<bool>(
                    value: false, label: Text('24-hour clock')),
              ],
              selected: <bool>{_clock12h},
              onSelectionChanged: (s) => setState(() => _clock12h = s.first),
            ),
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const <ButtonSegment<bool>>[
                ButtonSegment<bool>(value: true, label: Text('Fahrenheit')),
                ButtonSegment<bool>(value: false, label: Text('Celsius')),
              ],
              selected: <bool>{_tempF},
              onSelectionChanged: (s) => setState(() => _tempF = s.first),
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

/// How the user chose to provide the image: the firmware bundled with this
/// app, a local file, or a URL to download.
enum _FirmwareSourceKind { bundled, file, download }

class _FirmwareSource {
  const _FirmwareSource.bundled()
      : kind = _FirmwareSourceKind.bundled,
        url = null;
  const _FirmwareSource.chooseFile()
      : kind = _FirmwareSourceKind.file,
        url = null;
  const _FirmwareSource.download(this.url)
      : kind = _FirmwareSourceKind.download;

  final _FirmwareSourceKind kind;
  final String? url;
}

/// Source selection for an update. The bundled firmware is the normal path:
/// update the app, then install what it ships. File and URL stay available as
/// fallbacks for a specific image.
class _FirmwareSourceDialog extends StatelessWidget {
  const _FirmwareSourceDialog({
    required this.bundledVersion,
    required this.deviceVersion,
  });

  final String? bundledVersion;
  final String deviceVersion;

  @override
  Widget build(BuildContext context) {
    final bundled = bundledVersion;
    final String body;
    if (bundled == null) {
      body = 'No firmware is bundled with this build. Choose an image to '
          'upload.';
    } else if (deviceVersion.isEmpty) {
      body = 'Install the firmware bundled with this app (v$bundled).';
    } else if (deviceVersion == bundled) {
      body = 'The mirror is already on v$bundled, the version bundled with '
          'this app. Reinstall it, or choose another image.';
    } else {
      body = 'Install the bundled firmware v$bundled '
          '(the mirror is on v$deviceVersion).';
    }

    return AlertDialog(
      title: const Text('Update firmware'),
      content: Text(body),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context)
              .pop(const _FirmwareSource.chooseFile()),
          child: const Text('Choose file...'),
        ),
        TextButton(
          onPressed: () async {
            final url = await showDialog<String>(
              context: context,
              builder: (_) => const _DownloadUrlDialog(),
            );
            if (url != null && context.mounted) {
              Navigator.of(context).pop(_FirmwareSource.download(url));
            }
          },
          child: const Text('From URL...'),
        ),
        if (bundled != null)
          FilledButton(
            onPressed: () => Navigator.of(context)
                .pop(const _FirmwareSource.bundled()),
            child: Text(deviceVersion == bundled
                ? 'Reinstall v$bundled'
                : 'Install v$bundled'),
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
