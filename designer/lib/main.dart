// Smart mirror layout designer.
//
// Renders layouts through the same C engine that runs on the ESP32, so what
// you see here is what the panel shows, pixel for pixel.

import 'package:flutter/material.dart';

import 'src/engine/bindings.dart';
import 'src/engine/engine.dart';
import 'src/ui/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MirrorDesignerApp());
}

class MirrorDesignerApp extends StatelessWidget {
  const MirrorDesignerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mirror Designer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00E5FF),
          brightness: Brightness.dark,
        ),
      ),
      home: const _Bootstrap(),
    );
  }
}

/// Opens the native engine before showing the workspace.
///
/// Loading the library is the one thing most likely to fail on a fresh
/// checkout, so it gets an explicit screen with the fix rather than a red
/// crash box.
class _Bootstrap extends StatefulWidget {
  const _Bootstrap();

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  MirrorEngine? _engine;
  String? _failure;

  @override
  void initState() {
    super.initState();
    try {
      _engine = MirrorEngine.open();
    } on MirrorLibraryException catch (e) {
      _failure = e.message;
    }
  }

  @override
  Widget build(BuildContext context) {
    final failure = _failure;
    if (failure != null) return _EngineMissing(message: failure);

    final engine = _engine;
    if (engine == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return WorkspaceScreen(engine: engine);
  }
}

class _EngineMissing extends StatelessWidget {
  const _EngineMissing({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
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
                  'so it cannot run without it.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                const SelectableText(
                  'cd designer && ./setup.sh\n'
                  'flutter run -d linux',
                  style: TextStyle(fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
