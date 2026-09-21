// Routes that need the native render engine, and the one navigation observer
// the screens share.
//
// The engine is no longer what the app starts with. It is loaded on the route
// that needs it — the layout workspace — so a checkout whose C core was never
// compiled still opens on the device dashboard, and a failed load is a page
// with the fix on it rather than a red crash box on launch.

import 'dart:async';

import 'package:flutter/material.dart';

import '../engine/bindings.dart';
import '../engine/engine.dart';
import '../services/mirror_devices.dart';
import 'app.dart';

/// Watches the app's navigator so a screen can tell whether it is the route on
/// top.
///
/// The device page polls its device while it is visible and stops while a
/// nested route covers it, which is the difference between a dashboard and a
/// battery drain. Attached once, in `MaterialApp.navigatorObservers`.
final RouteObserver<PageRoute<dynamic>> appRouteObserver =
    RouteObserver<PageRoute<dynamic>>();

/// Opens the layout workspace: the clock editor, or the developer simulator
/// when [device] is null.
///
/// A device workspace is pushed on top of the device's own route, which
/// already holds the Bluetooth link, so nothing is connected or disconnected
/// here — the link lives as long as the device page, including under this
/// route. When no device route is underneath, the record is activated so the
/// workspace has a link at all.
Future<void> openWorkspace(BuildContext context, {MirrorDevice? device}) async {
  final target = device;
  if (target != null && !target.isActive && !target.removed) {
    // Not awaited: a Bluetooth connect can take seconds, and the workspace is
    // useful (and says what it is waiting for) before the link lands.
    unawaited(target.owner.activate(target));
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => WorkspaceRoute(device: target)),
  );
}

/// The workspace route's own engine loader.
///
/// One engine per workspace, closed by the workspace's controller: the
/// controller's dispose already destroys the engine, so nothing here closes it
/// a second time.
class WorkspaceRoute extends StatefulWidget {
  const WorkspaceRoute({super.key, this.device});

  /// The device this workspace edits, null for the local simulator.
  final MirrorDevice? device;

  @override
  State<WorkspaceRoute> createState() => _WorkspaceRouteState();
}

class _WorkspaceRouteState extends State<WorkspaceRoute> {
  MirrorEngine? _engine;
  String? _failure;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    try {
      setState(() {
        _engine = MirrorEngine.open();
        _failure = null;
      });
    } on MirrorLibraryException catch (e) {
      setState(() {
        _engine = null;
        _failure = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final failure = _failure;
    if (failure != null) {
      return EngineMissing(message: failure, onRetry: _load);
    }
    final engine = _engine;
    if (engine == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return WorkspaceScreen(engine: engine, device: widget.device);
  }
}

/// Why the native engine is not usable, and what to do about it.
///
/// Loading the library is the one thing most likely to fail on a fresh
/// checkout, so it gets an explicit screen with the fix rather than a red
/// crash box. Shared with the device page, whose Games route needs the same
/// library for the game catalogue.
class EngineMissing extends StatelessWidget {
  const EngineMissing({super.key, required this.message, this.onRetry});

  final String message;

  /// Re-attempt the load. Null when there is nothing to retry (the attempt
  /// already happened on another route).
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Render engine')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.memory_outlined,
                    size: 48, color: theme.colorScheme.error),
                const SizedBox(height: 16),
                Text('The render engine did not load',
                    style: theme.textTheme.headlineSmall),
                const SizedBox(height: 12),
                Text(message, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 24),
                Text(
                  'This app renders through the same C core as the firmware, '
                  'so the workspace cannot run without it. Devices, previews '
                  'and picture uploads do not need it.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                const SelectableText(
                  'cd designer && ./setup.sh\n'
                  'flutter run -d linux',
                  style: TextStyle(fontFamily: 'monospace'),
                ),
                if (onRetry != null) ...<Widget>[
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: onRetry,
                    child: const Text('Try again'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
