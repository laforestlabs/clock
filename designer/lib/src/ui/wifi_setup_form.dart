// The guided WiFi pick: scan, choose a network (or type one manually), and
// enter a password. Presentation only: it reports the draft through [onDraft]
// and never touches the air, so both the Mirror screen's dialog and the
// setup wizard embed it and own their push/await flow.

import 'package:flutter/material.dart';

import '../services/mirror_ble.dart';
import '../services/mirror_wifi.dart';
import '../services/mirror_wifi_status.dart';

class WifiSetupForm extends StatefulWidget {
  const WifiSetupForm({
    super.key,
    required this.scan,
    required this.onDraft,
  });

  /// The device scan: normally [BleSession.scanWifi], injectable for previews
  /// and tests.
  final Future<List<BleWifiNetwork>> Function() scan;

  /// Called with the current draft on every change, and null when there is
  /// nothing to submit yet.
  final ValueChanged<WifiConfig?> onDraft;

  @override
  State<WifiSetupForm> createState() => _WifiSetupFormState();
}

class _WifiSetupFormState extends State<WifiSetupForm> {
  bool _scanning = true;
  String? _scanError;
  List<BleWifiNetwork> _networks = const <BleWifiNetwork>[];
  String? _selected;
  bool _selectedOpen = false;
  bool _manual = false;
  late final TextEditingController _ssid;
  late final TextEditingController _pass;

  @override
  void initState() {
    super.initState();
    _ssid = TextEditingController();
    _pass = TextEditingController();
    _scan();
  }

  @override
  void dispose() {
    _ssid.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _scanError = null;
    });
    try {
      final nets = await widget.scan();
      if (!mounted) return;
      setState(() {
        _networks = nets;
        _scanning = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanError = e.toString().replaceFirst('Exception: ', '');
        _scanning = false;
      });
    }
  }

  void _emitDraft() {
    final ssid = _ssid.text.trim();
    widget.onDraft(
      ssid.isEmpty ? null : WifiConfig(ssid: ssid, pass: _pass.text),
    );
  }

  void _pick(BleWifiNetwork net) {
    setState(() {
      _selected = net.ssid;
      _selectedOpen = net.open;
      _manual = false;
      _ssid.text = net.ssid;
      _pass.text = '';
    });
    _emitDraft();
  }

  void _pickManual() {
    setState(() {
      _selected = null;
      _manual = true;
      _ssid.text = '';
      _pass.text = '';
    });
    _emitDraft();
  }

  bool get _showPassword => _manual || !_selectedOpen;

  @override
  Widget build(BuildContext context) {
    if (_scanning) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text('Scanning for networks...'),
          ],
        ),
      );
    }
    if (_scanError != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(_scanError!, style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 8),
          TextButton(onPressed: _scan, child: const Text('Rescan')),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (_networks.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child:
                Text('No networks found', style: TextStyle(color: Colors.grey)),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: ListView(
              shrinkWrap: true,
              children: <Widget>[
                for (final net in _networks)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      net.open ? Icons.wifi : Icons.wifi_lock,
                      size: 18,
                    ),
                    title: Text(net.ssid),
                    subtitle: Text('${net.rssi} dBm'),
                    selected: _selected == net.ssid,
                    onTap: () => _pick(net),
                  ),
              ],
            ),
          ),
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.edit, size: 18),
          title: const Text('Enter SSID manually'),
          selected: _manual,
          onTap: _pickManual,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _ssid,
          maxLength: 31,
          onChanged: (_) => setState(_emitDraft),
          decoration: const InputDecoration(
            labelText: 'SSID',
            counterText: '',
          ),
        ),
        if (_showPassword)
          TextField(
            controller: _pass,
            maxLength: 63,
            obscureText: true,
            onChanged: (_) => _emitDraft(),
            decoration: const InputDecoration(
              labelText: 'Password',
              counterText: '',
            ),
          ),
      ],
    );
  }
}
