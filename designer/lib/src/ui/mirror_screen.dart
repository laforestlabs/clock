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

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

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

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _bleUnavailable = null;
      _bleDevices.clear();
    });
    try {
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
      final pong = await session.ping();
      if (!mounted) return;
      setState(() {
        _session = session;
        _bleName = entry.name;
        _pong = _PongInfo.parse(pong);
      });
      _toast('Connected to ${entry.name}');
    } catch (e) {
      _handleError(e, 'connect');
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

  Future<void> _updateFirmware(int index) async {
    final device = _lanDevices[index];
    final status = _lanStatuses[index];
    if (status == null ||
        status.ip.isEmpty ||
        status.ip == '0.0.0.0' ||
        status.ip == '0.0.0.0:0') {
      _toast('No WiFi IP reported; firmware upload needs the LAN address');
      return;
    }

    const typeGroup = XTypeGroup(label: 'firmware', extensions: <String>['bin']);
    final file = await openFile(acceptedTypeGroups: const <XTypeGroup>[typeGroup]);
    if (file == null) return;

    if (!mounted) return;
    final progress = ValueNotifier<double>(0);
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _UploadDialog(progress: progress, fileName: file.name),
    ));

    try {
      await MirrorLan(device.ip).uploadFirmware(
        File(file.path),
        onProgress: (sent, total) =>
            progress.value = total > 0 ? sent / total : 0,
      );
      // The mirror reboots into the new image; poll until it answers again.
      final newStatus = await _waitForReboot(device.ip);
      if (!mounted) return;
      Navigator.of(context).pop(); // close the upload dialog
      _toast(newStatus == null
          ? 'Update uploaded; the mirror is rebooting'
          : 'Updated to ${newStatus.version}');
      await _refreshLanStatus(index);
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        _handleError(e, 'update');
      }
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
      return Text(_bleUnavailable!, style: const TextStyle(color: Colors.grey));
    }

    final session = _session;
    if (session != null) {
      final pong = _pong;
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
              TextButton(
                onPressed: _disconnectBle,
                child: const Text('Disconnect'),
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
        if (_bleDevices.isEmpty)
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
        : 'v${status.version}  ${status.layout} '
            '${status.width}x${status.height}  ${status.brightness}/255';

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
            onPressed: busy ? null : () => _updateFirmware(index),
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
