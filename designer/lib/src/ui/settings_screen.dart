// App settings: the workspace mode and the panel's physical orientation.
//
// Orientation is a device setting, not a view setting: the panel itself is
// rotated, so a change here is pushed over the same BLE link the device's own
// route uses. Two shapes are supported, and neither can reach a device other
// than the one it was opened for:
//
//   - Bound to a device record: the link is that record's own, the toggle is
//     only live while that record has a session, and the accepted value is
//     recorded on that record through the controller's persist callback (the
//     workspace binds it to the registry, so nothing here writes the global
//     preview seed). Offline the toggle is disabled: an orientation the panel
//     never acknowledged must not be saved as its state.
//   - Local simulator (no record, null connection): the toggle edits the
//     preview only, exactly as it always did.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../controller.dart';
import '../services/mirror_ble.dart';
import '../services/mirror_config.dart';
import '../services/mirror_connection.dart';
import '../services/mirror_devices.dart';
import '../services/user_view.dart';

/// App settings: the workspace mode and how the panel is oriented.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.controller,
    required this.view,
    required this.onViewChanged,
    this.connection,
    this.device,
  });

  final DesignerController controller;
  final UserView view;
  final ValueChanged<UserView> onViewChanged;

  /// The workspace's link to the mirror when this screen is not bound to a
  /// device record, or null where there is none (tests, local simulator): the
  /// screen then only edits the preview.
  final MirrorConnection? connection;

  /// The device this screen is scoped to, or null for the local simulator.
  /// Its own connection is the link used, its recorded orientation is the
  /// truth, and offline the toggle is disabled rather than saving a state the
  /// panel never confirmed.
  final MirrorDevice? device;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late UserView _view = widget.view;

  /// True while a flip push is in flight. A second tap would race the first:
  /// its "previous" value would be a preview the panel has not confirmed, so
  /// a failure could revert to a state the panel was never in.
  bool _flipBusy = false;

  /// The link the toggle drives: the bound record's own connection, never a
  /// free-standing one that could point at another mirror.
  MirrorConnection? get _link => widget.device?.connection ?? widget.connection;

  /// Whether this screen is scoped to a device record.
  bool get _bound => widget.device != null;

  /// Whether the orientation can be applied right now. Orientation travels
  /// over Bluetooth only, so a bound device with no live session has no
  /// transport for it; the simulator has no panel to contradict the preview.
  bool get _canFlip => !_bound || _link?.session != null;

  @override
  void initState() {
    super.initState();
    unawaited(_adoptDeviceFlip180());
  }

  /// The panel is the truth for orientation and the local pref only the seed
  /// for when there is no mirror to ask: a phone that never flipped this
  /// mirror would otherwise preview (and push) the wrong state. Best-effort,
  /// so an older firmware that does not answer keeps the seed.
  ///
  /// Bound to a device, [DesignerController.setFlip180] writes the record the
  /// workspace bound it to, never the global preview seed; the simulator
  /// keeps the default seed.
  Future<void> _adoptDeviceFlip180() async {
    final session = _link?.session;
    if (session == null) return;
    bool? flipped;
    try {
      final raw = await session.getConfigRaw();
      if (raw != null && raw.startsWith('config ')) {
        final decoded =
            jsonDecode(raw.substring('config '.length)) as Map<String, dynamic>;
        flipped = MirrorConfig.fromJson(decoded)?.flip180;
      }
    } catch (_) {
      return;
    }
    if (!mounted || !identical(_link?.session, session)) return;
    // Through setFlip180, not the bare setter: the stored value must not keep
    // claiming a state the panel left.
    if (flipped != null) await widget.controller.setFlip180(flipped);
  }

  Future<void> _setFlip180(bool value) async {
    // A disabled control cannot fire, but a stale callback could: never touch
    // a bound device's orientation without a live session to apply it on.
    if (!_canFlip) return;
    final previous = widget.controller.flip180;
    if (value == previous || _flipBusy) return;

    final session = _link?.session;
    // Offline this stays a preview-only setting, as it always was: nothing on
    // a panel contradicts it and there is no link to push over.
    if (session == null) {
      await widget.controller.setFlip180(value);
      return;
    }

    // Persist only acknowledged device state; a crash during a push must not
    // leave an unconfirmed orientation recorded as the panel's truth.
    setState(() => _flipBusy = true);
    try {
      await session.pushConfig(<String, dynamic>{'flip180': value});
      if (!mounted || !identical(_link?.session, session)) return;
      await widget.controller.setFlip180(value);
    } catch (e) {
      final reason = e is BlePushException
          ? e.toString()
          : e.toString().replaceFirst('Exception: ', '');
      _toast('Could not confirm panel orientation: $reason');
    } finally {
      if (mounted) setState(() => _flipBusy = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// What the orientation control does here, said for the surface the owner
  /// is actually on.
  String _orientationNote() {
    final device = widget.device;
    if (device == null) {
      return 'Rotates the mirror\'s display 180 degrees, for a panel '
          'mounted upside down. The preview follows it; with no mirror '
          'connected the toggle changes the preview only.';
    }
    if (!_canFlip) {
      return 'Rotates the mirror\'s display 180 degrees, for a panel '
          'mounted upside down. Connect ${device.displayName} over Bluetooth to '
          'change it: an orientation the panel has not acknowledged is not '
          'saved.';
    }
    return 'Rotates the mirror\'s display 180 degrees, for a panel '
        'mounted upside down. Sent to ${device.displayName} over Bluetooth and '
        'saved on that device.';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final c = widget.controller;
          final canFlip = _canFlip;
          return ListView(
            children: <Widget>[
              SwitchListTile(
                title: const Text('Developer mode'),
                subtitle: const Text(
                    'Full workspace: widget editing and firmware tools'),
                value: _view == UserView.developer,
                onChanged: (v) {
                  final view = v ? UserView.developer : UserView.defaultView;
                  setState(() => _view = view);
                  widget.onViewChanged(view);
                },
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text('Panel orientation',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SegmentedButton<bool>(
                    segments: const <ButtonSegment<bool>>[
                      ButtonSegment<bool>(
                        value: false,
                        label: Text('Normal'),
                        icon: Icon(Icons.screen_rotation_alt),
                      ),
                      ButtonSegment<bool>(
                        value: true,
                        label: Text('Upside down'),
                        icon: Icon(Icons.screen_rotation),
                      ),
                    ],
                    selected: <bool>{c.flip180},
                    onSelectionChanged: canFlip
                        ? (selection) => _setFlip180(selection.first)
                        : null,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(
                  _orientationNote(),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
