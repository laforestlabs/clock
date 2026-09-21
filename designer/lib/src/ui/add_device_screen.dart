// Adding a mirror: an address on the network, or a Bluetooth device nearby.
//
// Two ways in, and they mean different things. A LAN address is a mirror that
// answers on Wi-Fi already; a nearby Bluetooth device is paired to a record
// only after it confirms the same firmware identity, so picking the wrong
// radio can never bind two mirrors together.
//
// This is also where Bluetooth is asked for: scanning, the permission prompt
// and the adapter prompt all start from an explicit tap here, never from the
// home screen appearing.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../services/mirror_ble.dart';
import '../services/mirror_devices.dart';
import 'ble_prompt.dart';

/// Splits what the owner typed into a host and a port.
///
/// Accepts `192.168.1.50`, `smart-mirror-ab12.local` and `192.168.1.50:8080`;
/// a port inside the address wins over the port field, because it is the more
/// specific thing the owner typed. Returns null when there is nothing usable
/// to try.
({String host, int port})? parseMirrorAddress(String input,
    {String port = ''}) {
  var host = input.trim();
  var portText = port.trim();
  if (host.isEmpty) return null;

  final colon = host.lastIndexOf(':');
  if (colon > 0) {
    final tail = host.substring(colon + 1);
    if (int.tryParse(tail) != null) {
      host = host.substring(0, colon);
      portText = tail;
    }
  }

  final parsed = portText.isEmpty ? 80 : int.tryParse(portText);
  if (parsed == null || parsed <= 0 || parsed > 65535) return null;
  if (host.isEmpty) return null;
  return (host: host, port: parsed);
}

class AddDeviceScreen extends StatefulWidget {
  const AddDeviceScreen({super.key, required this.devices, this.pairWith});

  final MirrorDevices devices;

  /// When set, this screen pairs a nearby Bluetooth device with an existing
  /// record (a LAN tile with no Bluetooth alias yet) instead of adding a new
  /// one. The candidate must confirm the record's firmware identity.
  final MirrorDevice? pairWith;

  @override
  State<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

class _AddDeviceScreenState extends State<AddDeviceScreen> {
  final TextEditingController _host = TextEditingController();
  final TextEditingController _port = TextEditingController();

  final List<BleScanEntry> _nearby = <BleScanEntry>[];
  bool _adding = false;
  bool _scanning = false;
  bool _searching = false;
  String? _error;
  String? _note;

  bool get _pairing => widget.pairWith != null;

  @override
  void initState() {
    super.initState();
    if (_pairing) {
      // The owner tapped "Connect Bluetooth" to get here; scanning is what
      // they asked for.
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_scan()));
    }
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _addManual() async {
    final parsed = parseMirrorAddress(_host.text, port: _port.text);
    if (parsed == null) {
      setState(() => _error = 'Enter an address like 192.168.1.50 or '
          '192.168.1.50:8080.');
      return;
    }
    setState(() {
      _adding = true;
      _error = null;
    });
    try {
      final device = await widget.devices.addLan(parsed.host, parsed.port);
      if (!mounted) return;
      Navigator.of(context).pop(device);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _adding = false;
        _error = describeRegistryError(e);
      });
    }
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _error = null;
      _nearby.clear();
    });
    try {
      if (!await FlutterBluePlus.isSupported) {
        if (!mounted) return;
        setState(() => _error = 'This device has no Bluetooth.');
        return;
      }
      if (!mounted) return;
      if (!await ensureBluetoothOn(context)) {
        if (!mounted) return;
        setState(() => _error = 'Bluetooth is off; turn it on to scan.');
        return;
      }
      final found = await widget.devices.scanBle();
      if (!mounted) return;
      setState(() => _nearby.addAll(found));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = describeRegistryError(e));
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _pick(BleScanEntry entry) async {
    if (_adding) return;
    setState(() {
      _adding = true;
      _error = null;
    });
    final pairing = widget.pairWith;
    try {
      final MirrorDevice device;
      if (pairing == null) {
        device = await widget.devices.addBle(entry);
      } else {
        await widget.devices.attachBle(pairing, entry);
        device = pairing.mergedInto ?? pairing;
      }
      if (!mounted) return;
      Navigator.of(context).pop(device);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _adding = false;
        _error = describeRegistryError(e);
      });
    }
  }

  /// Runs the LAN browse. Confirmed mirrors add themselves to the registry as
  /// the browse finds them, so this reports rather than lists.
  Future<void> _searchNetwork() async {
    setState(() {
      _searching = true;
      _note = null;
    });
    final before = widget.devices.devices.length;
    await widget.devices.refreshDiscovery();
    if (!mounted) return;
    final added = widget.devices.devices.length - before;
    setState(() {
      _searching = false;
      _note = widget.devices.discoveryError ??
          (added > 0
              ? 'Found $added mirror${added == 1 ? '' : 's'}.'
              : 'No new mirrors answered.');
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pairing = widget.pairWith;
    return Scaffold(
      appBar: AppBar(
        title: Text(pairing == null ? 'Add device' : 'Connect Bluetooth'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: <Widget>[
          if (pairing != null) ...<Widget>[
            Text(
              'Pair ${pairing.name} with Bluetooth',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Games and the setup wizard run over Bluetooth. The mirror this '
              'phone connects to must be the same one at '
              '${pairing.endpoint ?? 'this record'}, so its identity is '
              'checked before anything is sent.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
          ] else ...<Widget>[
            Text('On this network', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Mirrors advertising themselves are found automatically. You '
              'can also type the address shown in the mirror\'s own setup '
              'screen.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _host,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Address',
                      hintText: '192.168.1.50',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => unawaited(_addManual()),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _port,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Port',
                      hintText: '80',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => unawaited(_addManual()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // A Wrap, not a Row: two labelled buttons do not fit a phone at
            // large text scale, and an overflow stripe is not a layout.
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: _adding ? null : () => unawaited(_addManual()),
                  icon: const Icon(Icons.add),
                  label: const Text('Add address'),
                ),
                OutlinedButton.icon(
                  onPressed:
                      _searching ? null : () => unawaited(_searchNetwork()),
                  icon: _searching
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_find),
                  label: const Text('Search network'),
                ),
              ],
            ),
            if (_note != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(_note!, style: theme.textTheme.bodySmall),
            ],
            const Divider(height: 32),
          ],
          Row(
            children: <Widget>[
              Expanded(
                child: Text('Nearby', style: theme.textTheme.titleMedium),
              ),
              TextButton.icon(
                onPressed: _scanning ? null : () => unawaited(_scan()),
                icon: _scanning
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.bluetooth_searching),
                label: Text(_scanning ? 'Scanning…' : 'Scan'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_error != null) ...<Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.error_outline,
                    size: 18, color: theme.colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_error!, style: theme.textTheme.bodySmall),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          if (_nearby.isEmpty)
            Text(
              'No Bluetooth devices yet. Tap Scan with the mirror powered on '
              'and in range.',
              style: theme.textTheme.bodySmall,
            )
          else
            for (final entry in _nearby)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.bluetooth),
                title: Text(entry.name.isEmpty
                    ? entry.device.remoteId.str
                    : entry.name),
                subtitle:
                    Text('${entry.device.remoteId.str} · ${entry.rssi} dBm'),
                enabled: !_adding,
                onTap: () => unawaited(_pick(entry)),
              ),
        ],
      ),
    );
  }
}

/// A failure sentence for the owner: registry and transport errors both carry
/// human-facing text, with or without an `Exception:` prefix.
String describeRegistryError(Object error) {
  if (error is MirrorRegistryException) return error.message;
  return bleErrorMessage(error);
}
