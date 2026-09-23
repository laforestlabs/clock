// The device's own control surface: its Bluetooth link, its network status,
// and the settings, firmware and setup actions that belong to it.
//
// Everything here is scoped to one device record. The Bluetooth section is a
// view over that record's own [MirrorConnection], and the network section uses
// only that record's endpoint, so no control on this screen can reach a
// different mirror. Finding and adding devices happens on the dashboard (Add
// device); this screen never scans or lists other devices.
//
// Missing BLE on a desktop is tolerated: the Bluetooth section says so, and
// the network section still shows the mirror's status and preview.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';

import '../controller.dart';
import '../services/bundled_firmware.dart';
import '../services/device_location.dart';
import '../services/mirror_ble.dart';
import '../services/mirror_config.dart';
import '../services/mirror_connection.dart';
import '../services/mirror_devices.dart';
import '../services/mirror_location.dart';
import '../services/mirror_wifi.dart';
import '../services/mirror_wifi_status.dart';
import 'ble_prompt.dart';
import 'firmware_prompt.dart';
import 'location_picker.dart';
import 'onboarding_screen.dart';
import 'place_pin_page.dart';
import 'wifi_setup_form.dart';

class MirrorScreen extends StatefulWidget {
  const MirrorScreen({
    super.key,
    required this.controller,
    required this.device,
    this.simplified = false,
  });

  final DesignerController controller;

  /// The device this screen controls. Its own connection is the Bluetooth
  /// link used, and its endpoint the only LAN address, so every action here
  /// is pinned to this record.
  final MirrorDevice device;

  /// Trimmed deployment surface: BLE only, no LAN, bundled firmware only.
  final bool simplified;

  @override
  State<MirrorScreen> createState() => _MirrorScreenState();
}

class _MirrorScreenState extends State<MirrorScreen> {
  DesignerController get _c => widget.controller;
  MirrorDevice get _device => widget.device;
  MirrorDevices get _devices => widget.device.owner;
  MirrorConnection get _connection => widget.device.connection;

  // ------------------------------------------------------------- BLE

  bool _bleBusy = false;

  /// Why a connect could not even be started (permissions, adapter, no
  /// Bluetooth address). Cleared when one starts.
  String? _connectProblem;

  /// Bundled firmware version, loaded only in simplified mode for the
  /// "Update to latest" button.
  BundledFirmware? _bundled;

  // Live panel brightness (0..255) and whether the device follows the
  // layout. Null until the connected mirror answers "get brightness", which
  // hides the control on older firmware that does not know the command.
  int? _brightness;
  bool _brightnessAuto = true;
  // Live WiFi state, null until the mirror answers "get wifi" (an older
  // firmware that does not know the command hides the control).
  BleWifiStatus? _wifi;

  // A permission denial that can only be undone in the system settings.
  bool _blePermissionPermanent = false;

  // ------------------------------------------------------------- LAN

  /// True while a firmware upload runs, so the section's buttons disable
  /// rather than start a second transfer.
  bool _otaBusy = false;

  @override
  void initState() {
    super.initState();
    if (_connection.session != null) {
      // Re-entering with a live session: refresh the brightness slider and
      // the WiFi control from the device instead of waiting for a new connect.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadBrightness();
        _loadWifi();
      });
    }
    if (widget.simplified) _loadBundledVersion();
    if (_device.endpoint != null) {
      // One status pull on entry; the dashboard's own poll keeps it current
      // while the tile is visible.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_refreshDevice());
      });
    }
  }

  /// Loads the bundled firmware for the simplified "Update to latest" button.
  Future<void> _loadBundledVersion() async {
    final bundled = await loadBundledFirmware();
    if (!mounted) return;
    setState(() => _bundled = bundled);
  }

  @override
  void dispose() {
    // Deliberately no connection teardown here: the record owns the session
    // and it must survive this screen being popped.
    super.dispose();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _handleError(Object e, String what) {
    _toast('$what: ${bleErrorMessage(e)}');
  }

  // ------------------------------------------------------- connection

  /// Bring up this device's Bluetooth link. The record's own connection is
  /// the only target, so this can never attach to another mirror.
  Future<void> _connectDevice() async {
    if (_device.bleId == null) {
      setState(() => _connectProblem =
          'This device has no Bluetooth address yet. Pair it from Add '
              'device.');
      return;
    }
    setState(() {
      _connectProblem = null;
      _blePermissionPermanent = false;
    });
    final gate = await ensureBlePermissions();
    if (!mounted) return;
    if (!gate.granted) {
      setState(() {
        _connectProblem = gate.permanentDenied
            ? 'Bluetooth permission denied; grant it in Settings'
            : 'Bluetooth permission denied';
        _blePermissionPermanent = gate.permanentDenied;
      });
      return;
    }
    if (!await FlutterBluePlus.isSupported) {
      if (!mounted) return;
      setState(() => _connectProblem = 'Bluetooth is not available here');
      return;
    }
    if (!mounted) return;
    if (!await ensureBluetoothOn(context)) {
      if (!mounted) return;
      setState(
          () => _connectProblem = 'Bluetooth is off; enable it to connect');
      return;
    }
    setState(() => _bleBusy = true);
    try {
      // Through the registry: it serializes the handover, verifies the
      // session's identity and records what the link reports.
      await _devices.connect(_device);
    } catch (e) {
      if (mounted) setState(() => _connectProblem = bleErrorMessage(e));
    } finally {
      if (mounted) setState(() => _bleBusy = false);
    }
    if (!mounted) return;
    if (_connection.status != MirrorConnectionStatus.connected) return;
    setState(() {
      _brightness = null;
      _brightnessAuto = true;
      _wifi = null;
    });
    await _loadWifi();
    await _maybeRunSetup();
    await _loadBrightness();
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

  /// Read the WiFi state once so the control starts at the truth. A mirror
  /// on old firmware answers "unknown command", the parse returns null, and
  /// the control stays hidden.
  Future<void> _loadWifi() async {
    final session = _connection.session;
    if (session == null) return;
    try {
      final w = await session.getWifi();
      if (!mounted || w == null) return;
      setState(() => _wifi = w);
    } catch (e) {
      _handleError(e, 'wifi');
    }
  }

  /// A freshly connected mirror with no saved network is guided through the
  /// setup walkthrough (WiFi, location, time & units); a mirror that already
  /// has credentials just shows the normal control. [_wifi] stays null until
  /// the mirror answers "get wifi", and old firmware never does, so this
  /// stays quiet on firmware without the command.
  Future<void> _maybeRunSetup() async {
    final w = _wifi;
    if (w == null || w.saved) return;
    await _runSetup(includeWifi: true);
  }

  /// Guided WiFi setup: scan, pick a network, push credentials, and await
  /// the connect outcome. Used for both a fresh mirror and an edit.
  Future<void> _wifiSetup() async {
    final session = _connection.session;
    if (session == null) return;

    final saved = await showDialog<WifiConfig>(
      context: context,
      builder: (_) => _WifiSetupDialog(session: session),
    );
    if (saved == null || !mounted) return;

    final problem = saved.validate();
    if (problem != null) {
      _toast('Not pushed: $problem');
      return;
    }

    setState(() => _bleBusy = true);
    try {
      // Subscribe to the async outcome before pushing so it cannot be missed.
      final resultFuture = session.awaitWifiResult();
      await session.pushWifi(saved);
      final result = await resultFuture;
      if (!mounted) return;
      if (result != null && result.connected) {
        _toast('Connected to ${saved.ssid}');
      } else if (result != null) {
        _toast('WiFi failed: ${result.detail}');
      } else {
        _toast('Saved; waiting for the mirror to connect');
      }
      await _loadWifi();
    } catch (e) {
      _handleError(e, 'wifi');
    } finally {
      if (mounted) setState(() => _bleBusy = false);
    }
  }

  /// Full guided setup as a page: WiFi (when [includeWifi]), location, and
  /// time & units. The page owns its pushes; this only wires the BLE seams
  /// and refreshes the controls afterwards. The name it collects is recorded
  /// on this device's own record.
  Future<void> _runSetup({required bool includeWifi}) async {
    final session = _connection.session;
    if (session == null) return;
    final status = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => MirrorOnboardingPage(
          includeWifi: includeWifi,
          currentName: _device.name,
          nameApplied: (n) => _devices.rename(_device, n),
          wifiScan: session.scanWifi,
          wifiPush: session.pushWifi,
          wifiAwait: session.awaitWifiResult,
          wifiStatus: session.getWifi,
          configPush: session.pushConfig,
        ),
      ),
    );
    if (!mounted) return;
    if (status != null) _toast('Setup complete: $status');
    await _loadWifi();
  }

  /// Forget the saved network; the mirror reopens its setup portal.
  Future<void> _wifiForget() async {
    final session = _connection.session;
    if (session == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forget this network?'),
        content: const Text(
            'The mirror forgets its WiFi and opens the setup portal.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _bleBusy = true);
    try {
      await session.forgetWifi();
      if (mounted) setState(() => _wifi = null);
      await _loadWifi();
      if (mounted) _toast('WiFi forgotten');
    } catch (e) {
      _handleError(e, 'wifi');
    } finally {
      if (mounted) setState(() => _bleBusy = false);
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
        _wifi = null;
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

  /// Push the workspace's layout to this device. The registry picks the
  /// transport (a live Bluetooth session first, otherwise the device's own
  /// endpoint) and refreshes the record from the device's answer.
  Future<void> _pushLayout() async {
    final width = _connection.panelWidth;
    final height = _connection.panelHeight;
    if (width > 0 &&
        height > 0 &&
        (_c.doc.width != width || _c.doc.height != height)) {
      _toastSizeMismatch(width, height);
      return;
    }
    setState(() => _bleBusy = true);
    try {
      await _devices.sendLayout(_device, _c.exportJson());
      if (mounted) _toast('Layout sent to ${_device.name}');
    } catch (e) {
      _handleError(e, 'push layout');
    } finally {
      if (mounted) setState(() => _bleBusy = false);
    }
  }

  /// Pull this device's status (and reachability) through its own endpoint.
  Future<void> _refreshDevice() async {
    try {
      await _devices.refresh(_device);
    } catch (_) {
      // The record's own error and reachability flags are what the section
      // renders; a failure here has nowhere better to go.
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
      builder: (_) => MirrorConfigDialog(initial: current),
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

  // ------------------------------------------------------- firmware

  /// Bundled-only firmware update for the trimmed surface: no file or URL
  /// source, no source dialog.
  Future<void> _updateFirmwareLatest() async {
    final bundled = _bundled ?? await loadBundledFirmware();
    if (!mounted || bundled == null) return;
    if (!_device.canUpdateFirmware) {
      _toast(MirrorDevice.needsBluetooth);
      return;
    }
    await _uploadAndWait(bundled.bytes, 'bundled v${bundled.version}');
  }

  Future<void> _uploadAndWait(Uint8List bytes, String fileName) async {
    setState(() {
      _otaBusy = true;
      _bleBusy = true;
    });
    try {
      final version = await pushFirmwareOverBleWithProgress(context,
          devices: _devices, device: _device, bytes: bytes, label: fileName);
      if (!mounted) return;
      _toast(version == null
          ? 'Update uploaded; the mirror is rebooting'
          : 'Updated to $version');
      if (mounted) await _refreshDevice();
    } catch (e) {
      if (mounted) _handleError(e, 'update');
    } finally {
      if (mounted) {
        setState(() {
          _otaBusy = false;
          _bleBusy = false;
        });
      }
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

  /// Confirm twice (consequences dialog, then an explicit per-item
  /// acknowledgement), wipe the mirror, and drop the session: the device
  /// reboots unprovisioned and the BLE link dies with it, same as a reboot.
  Future<void> _factoryResetBle() async {
    final session = _connection.session;
    if (session == null) return;
    final confirmed = await _confirmFactoryReset(_device.name);
    if (!confirmed) return;
    if (!mounted) return;
    setState(() => _bleBusy = true);
    try {
      await session.factoryReset();
      _toast('Factory reset: the mirror is rebooting and must be set up '
          'again');
      await _disconnectBle();
    } catch (e) {
      _handleError(e, 'factory reset');
    } finally {
      if (mounted) setState(() => _bleBusy = false);
    }
  }

  /// The two confirmation layers for a factory reset. The first spells out
  /// what is about to happen and what it costs; the second makes the user
  /// acknowledge the two irreversible consequences item by item before the
  /// destructive button unlocks. Returns true only when both are cleared.
  Future<bool> _confirmFactoryReset(String deviceName) async {
    final theme = Theme.of(context);
    const consequences = <String>[
      'Forget its WiFi network and password.',
      'Lose its location, timezone, clock format, temperature unit, and '
          'brightness override.',
      'Lose the layout pushed to it; the panel falls back to the factory '
          'layout shipped inside the firmware.',
      'Restart into setup mode, needing to be configured from scratch.',
    ];
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(Icons.warning_amber_rounded,
            color: theme.colorScheme.error, size: 36),
        title: const Text('Factory reset this mirror?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('You are about to erase everything you have set on '
                  '"$deviceName". Afterwards the mirror will:'),
              const SizedBox(height: 10),
              for (final c in consequences)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text('\u2022'),
                      const SizedBox(width: 8),
                      Expanded(child: Text(c)),
                    ],
                  ),
                ),
              const SizedBox(height: 6),
              Text(
                'This cannot be undone. Nothing survives except the '
                'firmware itself.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
            ),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return false;

    // Layer two: ticking both acknowledgements is the only thing that
    // unlocks the final button, so a reflex tap cannot fire the command.
    final acknowledged = await showDialog<bool>(
      context: context,
      builder: (_) => _FactoryResetAckDialog(deviceName: deviceName),
    );
    return acknowledged == true;
  }

  // ------------------------------------------------------------ view

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_device.name)),
      // The Bluetooth section is a view over this device's own connection and
      // the record's status, so a state change (connect, disconnect, dropped
      // link, a fresh poll) rebuilds it even when it happened while this
      // screen was not on stage.
      body: ListenableBuilder(
        listenable: Listenable.merge(<Listenable>[_connection, _device]),
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
    final connection = _connection;
    final session = connection.session;
    if (session != null) return _buildConnected();
    if (connection.status == MirrorConnectionStatus.connecting) {
      return Row(
        children: <Widget>[
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Text('Connecting to ${_device.name}...'),
        ],
      );
    }

    // Not connected: say why, and offer the one action that can change it.
    // Everything here is still this device's own link, so a retry can only
    // bring back the mirror this screen is about.
    final String message;
    if (_connectProblem != null) {
      message = _connectProblem!;
    } else if (connection.status == MirrorConnectionStatus.failed) {
      message = 'Could not connect to ${_device.name}: '
          '${connection.error ?? 'unknown error'}';
    } else if (_device.bleId == null) {
      message = 'This device has no Bluetooth address yet. Pair it from Add '
          'device to reach its setup, WiFi and game controls.';
    } else {
      message = 'Not connected.';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(message, style: const TextStyle(color: Colors.grey)),
        if (_device.bleId != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: _bleBusy ? null : _connectDevice,
                  icon: const Icon(Icons.bluetooth, size: 18),
                  label: Text(connection.status == MirrorConnectionStatus.failed
                      ? 'Retry'
                      : 'Connect'),
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

  /// The controls that need a live Bluetooth session. Every one of them
  /// talks over this device's own link.
  Widget _buildConnected() {
    final connection = _connection;
    final pong = connection.pong;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Connected to ${_device.name}'),
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
              onPressed: _bleBusy ? null : _pushLayout,
              icon: const Icon(Icons.send, size: 18),
              label: const Text('Push layout'),
            ),
            OutlinedButton.icon(
              onPressed: (_bleBusy || _otaBusy || _bundled == null)
                  ? null
                  : _updateFirmwareLatest,
              icon: const Icon(Icons.system_update, size: 18),
              label: Text(_bundled == null
                  ? 'Update unavailable'
                  : 'Update to latest (v${_bundled!.version})'),
            ),
            if (!widget.simplified) ...<Widget>[
              OutlinedButton.icon(
                onPressed: _bleBusy ? null : _configure,
                icon: const Icon(Icons.tune, size: 18),
                label: const Text('Configure'),
              ),
              TextButton.icon(
                onPressed: _bleBusy ? null : _rebootBle,
                icon: const Icon(Icons.restart_alt, size: 18),
                label: const Text('Reboot'),
              ),
              FilledButton.icon(
                onPressed: _bleBusy ? null : _factoryResetBle,
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                ),
                icon: const Icon(Icons.delete_forever_outlined, size: 18),
                label: const Text('Factory reset'),
              ),
            ],
            TextButton(
              onPressed: _disconnectBle,
              child: const Text('Disconnect'),
            ),
          ],
        ),
        // WiFi: shown whenever the mirror answered "get wifi", in every
        // view. Setting up or changing the network is a normal owner task,
        // not a developer-only one. A fresh mirror gets a prominent "Set up
        // WiFi" call to action; a configured one offers Change / Forget.
        if (_wifi != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _wifi!.saved
                ? Row(
                    children: <Widget>[
                      const Icon(Icons.wifi, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _wifi!.connected
                              ? '${_wifi!.ssid} (${_wifi!.ip})'
                              : _wifi!.ssid,
                          style: const TextStyle(color: Colors.grey),
                        ),
                      ),
                      TextButton(
                        onPressed: _bleBusy ? null : _wifiSetup,
                        child: const Text('Change'),
                      ),
                      TextButton(
                        onPressed: _bleBusy ? null : _wifiForget,
                        child: const Text('Forget'),
                      ),
                      // The trimmed phone view has no Configure dialog, so
                      // the walkthrough is its only setup surface: rerun it
                      // here to revisit location and time & units later.
                      if (widget.simplified)
                        TextButton(
                          onPressed: _bleBusy
                              ? null
                              : () => _runSetup(includeWifi: false),
                          child: const Text('Set up'),
                        ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text('WiFi not set up',
                          style: TextStyle(color: Colors.orange)),
                      const SizedBox(height: 4),
                      FilledButton.icon(
                        onPressed: _bleBusy
                            ? null
                            : () => _runSetup(includeWifi: true),
                        icon: const Icon(Icons.wifi_find, size: 18),
                        label: const Text('Set up WiFi'),
                      ),
                    ],
                  ),
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

  /// This device's own network address and the one action that needs it. The
  /// endpoint is the record's, port included, so a mirror on a non-default
  /// mDNS or manual port keeps working; nothing here can address another
  /// device.
  Widget _buildLanSection() {
    final endpoint = _device.endpoint;
    if (endpoint == null) {
      return const Text(
        'No Wi-Fi address is known for this device yet. Let discovery find it '
        'again, or add its address from Add device.',
        style: TextStyle(color: Colors.grey),
      );
    }
    final status = _device.status;
    final reachable = _device.lanReachable;
    final String statusText;
    if (!reachable) {
      statusText = 'Not reached yet';
    } else if (status == null) {
      statusText = 'Connected';
    } else {
      statusText =
          'v${status.version}${status.core.isNotEmpty ? '  core ${status.core}' : ''}'
          '  ${status.layout} ${status.width}x${status.height}  '
          '${status.brightness}/255';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(endpoint, style: const TextStyle(color: Colors.grey)),
        const SizedBox(height: 4),
        Text(statusText, style: const TextStyle(color: Colors.grey)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: <Widget>[
            OutlinedButton.icon(
              onPressed: _otaBusy ? null : _refreshDevice,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Refresh'),
            ),
          ],
        ),
      ],
    );
  }
}

class _WifiSetupDialog extends StatefulWidget {
  const _WifiSetupDialog({required this.session});

  final BleSession session;

  @override
  State<_WifiSetupDialog> createState() => _WifiSetupDialogState();
}

class _WifiSetupDialogState extends State<_WifiSetupDialog> {
  WifiConfig? _draft;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Set up WiFi'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: WifiSetupForm(
            scan: widget.session.scanWifi,
            onDraft: (c) => setState(() => _draft = c),
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed:
              _draft == null ? null : () => Navigator.of(context).pop(_draft),
          child: const Text('Connect'),
        ),
      ],
    );
  }
}

/// Configure dialog: timezone preset (or custom), location, clock format and
/// temperature unit. Only reachable over BLE, per the owner's decision.
///
/// The location controls are the setup wizard's own [LocationPicker], so the
/// three sources (ZIP/city, this device's GPS, a map pin) and the timezone
/// lookup behind them behave identically on both surfaces. The picker is
/// prefilled with the device's stored point when its numbers parse; saving
/// rounds to five decimal places, which is what the wizard pushes too, so a
/// device whose stored value carries more precision is rounded here.
class MirrorConfigDialog extends StatefulWidget {
  const MirrorConfigDialog({
    super.key,
    this.initial,
    this.geocode = geocodeSearch,
    this.timezoneLookup = timezoneIanaForCoordinates,
    this.deviceLocation = currentDeviceLocation,
    this.pickOnMap = _showPinPicker,
  });

  final MirrorConfig? initial;

  /// Location seams, forwarded to the picker: production defaults, fakes in
  /// tests.
  final Future<List<GeocodeResult>> Function(String query) geocode;
  final Future<String?> Function(double latitude, double longitude)
      timezoneLookup;
  final Future<LatLng> Function() deviceLocation;
  final Future<LatLng?> Function(BuildContext context, {LatLng? initial})
      pickOnMap;

  static Future<LatLng?> _showPinPicker(BuildContext context,
          {LatLng? initial}) =>
      showPlacePinPicker(context, initial: initial);

  @override
  State<MirrorConfigDialog> createState() => _MirrorConfigDialogState();
}

class _MirrorConfigDialogState extends State<MirrorConfigDialog> {
  late final TextEditingController _tzCustom;
  String? _presetTz;

  /// Set once the owner picks a zone themselves; a derived one never
  /// overwrites it.
  bool _tzTouched = false;

  /// True when the picker's zone could not be turned into a POSIX string (or
  /// the lookup failed), so nothing was prefilled and the owner is told.
  bool _tzUnmapped = false;

  /// The picker's choice; null when the owner has not chosen a point.
  LocationChoice? _choice;

  /// Display settings default to the device's factory values (12-hour,
  /// Fahrenheit) when the device could not be prefilled. They are always
  /// pushed: unlike the location there is no "unchanged" empty state for a
  /// choice, and the defaults match a fresh mirror.
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
    _choice = _initialChoice(initial);
  }

  @override
  void dispose() {
    _tzCustom.dispose();
    super.dispose();
  }

  /// The picker prefill: the device's stored point, when both numbers parse
  /// and are in range. No timezone: the dialog has no zone source until a
  /// lookup runs, and the picker asks for one only when the owner changes the
  /// location.
  LocationChoice? _initialChoice(MirrorConfig? initial) {
    final lat = double.tryParse(initial?.latitude ?? '');
    final lon = double.tryParse(initial?.longitude ?? '');
    if (lat == null || lon == null) return null;
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
    return LocationChoice(
      latitude: lat,
      longitude: lon,
      place: initial?.place ?? '',
    );
  }

  /// Prefill the timezone from the picker's choice, unless the owner already
  /// changed the control. Mutates state; callers wrap in setState.
  void _deriveFromChoice() {
    final choice = _choice;
    if (choice == null) return;
    final tz = posixTzForIana(choice.timezoneIana);
    _tzUnmapped = tz == null;
    if (tz == null || _tzTouched) return;
    final presetValues = kTimezonePresets.map((p) => p.tz).toSet();
    if (presetValues.contains(tz)) {
      _presetTz = tz;
    } else {
      _presetTz = '';
      _tzCustom.text = tz;
    }
  }

  void _onLocationChanged(LocationChoice choice) {
    setState(() {
      _choice = choice;
      // Runs again when the zone arrives after the choice, which is how a GPS
      // fix or a pin gets a timezone into this dropdown.
      _deriveFromChoice();
    });
  }

  String? get _timezone {
    if (_presetTz == null || _presetTz!.isEmpty) {
      final custom = _tzCustom.text.trim();
      return custom.isEmpty ? null : custom;
    }
    return _presetTz;
  }

  MirrorConfig _collect() {
    final place = _choice?.place.trim() ?? '';
    return MirrorConfig(
      timezone: _timezone,
      latitude: _choice?.latitude.toStringAsFixed(5),
      longitude: _choice?.longitude.toStringAsFixed(5),
      place: place.isEmpty
          ? null
          : (place.length <= 23 ? place : place.substring(0, 23)),
      clock12h: _clock12h,
      tempF: _tempF,
    );
  }

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
              // FormField keeps the value it was created with, so a zone
              // derived after the dialog opened only appears if the field is
              // rebuilt with it.
              key: ValueKey<String?>(_presetTz),
              initialValue: _presetTz,
              // "Los Angeles (PST8PDT,M3.2.0,M11.1.0)" is wider than the
              // dialog's field: let the button take the row and ellipsize
              // rather than overflow.
              isExpanded: true,
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
                _tzTouched = true;
                _presetTz = value;
              }),
            ),
            if (_tzUnmapped && _timezone == null)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Could not set the timezone from this location; '
                  'choose one here.',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ),
            if (_presetTz == null || _presetTz!.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: TextField(
                  controller: _tzCustom,
                  onChanged: (_) => _tzTouched = true,
                  decoration: const InputDecoration(
                    labelText: 'POSIX timezone string',
                    hintText: 'e.g. UTC0',
                  ),
                ),
              ),
            const SizedBox(height: 8),
            LocationPicker(
              initial: _choice,
              geocode: widget.geocode,
              timezoneLookup: widget.timezoneLookup,
              deviceLocation: widget.deviceLocation,
              pickOnMap: widget.pickOnMap,
              onChanged: _onLocationChanged,
            ),
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const <ButtonSegment<bool>>[
                ButtonSegment<bool>(value: true, label: Text('12-hour clock')),
                ButtonSegment<bool>(value: false, label: Text('24-hour clock')),
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

/// Second confirmation layer for the factory reset: the destructive button
/// stays disabled until the user has ticked each of the two irreversible
/// consequences separately, so agreeing is deliberate, not reflexive.
class _FactoryResetAckDialog extends StatefulWidget {
  const _FactoryResetAckDialog({required this.deviceName});

  final String deviceName;

  @override
  State<_FactoryResetAckDialog> createState() => _FactoryResetAckDialogState();
}

class _FactoryResetAckDialogState extends State<_FactoryResetAckDialog> {
  bool _eraseAck = false;
  bool _setupAck = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final confirmed = _eraseAck && _setupAck;
    return AlertDialog(
      icon: Icon(Icons.dangerous_outlined,
          color: theme.colorScheme.error, size: 36),
      title: const Text('Final confirmation'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Read each line and tick it to confirm the reset of '
              '"${widget.deviceName}".'),
          CheckboxListTile(
            value: _eraseAck,
            onChanged: (v) => setState(() => _eraseAck = v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            title: const Text('All settings, the WiFi password, and the '
                'pushed layout will be permanently erased; nothing can be '
                'recovered.'),
          ),
          CheckboxListTile(
            value: _setupAck,
            onChanged: (v) => setState(() => _setupAck = v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            title: const Text('The mirror restarts as if it were brand new '
                'and must be set up again from scratch.'),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: confirmed ? () => Navigator.of(context).pop(true) : null,
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.error,
            foregroundColor: theme.colorScheme.onError,
          ),
          child: const Text('Erase and factory reset'),
        ),
      ],
    );
  }
}
