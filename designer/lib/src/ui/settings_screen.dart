// App settings: the workspace mode and the panel's physical orientation.
//
// Orientation is a device setting, not a view setting: the panel itself is
// rotated, so a change here is pushed over the same BLE link the Mirror screen
// uses. The local pref is only the seed for the preview when there is no
// mirror to ask.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../controller.dart';
import '../services/mirror_ble.dart';
import '../services/mirror_config.dart';
import '../services/mirror_connection.dart';
import '../services/user_view.dart';

/// App settings: the workspace mode and how the panel is oriented.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.controller,
    required this.view,
    required this.onViewChanged,
    this.connection,
  });

  final DesignerController controller;
  final UserView view;
  final ValueChanged<UserView> onViewChanged;

  /// The workspace's link to the mirror, or null where there is none (tests,
  /// desktop with no mirror): the screen then only edits the preview.
  final MirrorConnection? connection;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late UserView _view = widget.view;

  /// True while a flip push is in flight. A second tap would race the first:
  /// its "previous" value would be a preview the panel has not confirmed, so
  /// a failure could revert to a state the panel was never in.
  bool _flipBusy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_adoptDeviceFlip180());
  }

  /// The panel is the truth for orientation and the local pref only the seed
  /// for when there is no mirror to ask: a phone that never flipped this
  /// mirror would otherwise preview (and push) the wrong state. Best-effort,
  /// so an older firmware that does not answer keeps the seed.
  Future<void> _adoptDeviceFlip180() async {
    final session = widget.connection?.session;
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
    // Through setFlip180, not the bare setter: the pref is the offline seed
    // for the next launch and must not keep claiming a state the panel left.
    if (flipped != null) await widget.controller.setFlip180(flipped);
  }

  Future<void> _setFlip180(bool value) async {
    final previous = widget.controller.flip180;
    if (value == previous || _flipBusy) return;

    // Preview and seed first, so the toggle never lags the finger; a rejected
    // push reverts both below.
    await widget.controller.setFlip180(value);

    final session = widget.connection?.session;
    // Offline this stays a preview-only setting, as it always was: nothing on
    // a panel contradicts it and there is no link to push over.
    if (session == null) return;

    _flipBusy = true;
    try {
      await session.pushConfig(<String, dynamic>{'flip180': value});
    } catch (e) {
      // The panel is still in [previous], so the preview must not keep
      // claiming the new value just because the tap landed.
      await widget.controller.setFlip180(previous);
      final reason = e is BlePushException
          ? e.toString()
          : e.toString().replaceFirst('Exception: ', '');
      _toast('Panel not flipped: $reason');
    } finally {
      _flipBusy = false;
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final c = widget.controller;
          return ListView(
            children: <Widget>[
              SwitchListTile(
                title: const Text('Developer mode'),
                subtitle: const Text(
                    'Full workspace: widget editing, games, and firmware tools'),
                value: _view == UserView.developer,
                onChanged: (v) {
                  final view =
                      v ? UserView.developer : UserView.defaultView;
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
                    onSelectionChanged: (selection) =>
                        _setFlip180(selection.first),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(
                  'Rotates the mirror\'s display 180 degrees, for a panel '
                  'mounted upside down. The preview follows it; with no mirror '
                  'connected the toggle changes the preview only.',
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
