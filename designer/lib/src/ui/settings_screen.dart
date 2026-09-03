import 'package:flutter/material.dart';

import '../controller.dart';
import '../services/user_view.dart';

/// App settings: the workspace mode and how the panel preview is oriented.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.controller,
    required this.view,
    required this.onViewChanged,
  });

  final DesignerController controller;
  final UserView view;
  final ValueChanged<UserView> onViewChanged;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late UserView _view = widget.view;

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
                        c.setFlip180(selection.first),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(
                  'Flips the panel preview 180 degrees, for a mirror mounted '
                  'upside down.',
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
