// The editor's window: the map, the tools, the panels, and the way in.
//
// The app opens on the level the game ships today - imported from
// game_jumpman.c, unmodified and not yet saved - so the first thing the user
// sees is a level they know works rather than an empty grid. The repository is
// found from the running executable or the working directory; when neither has
// one, the app says so and offers to be pointed at game_jumpman.c.
//
// Exporting is deliberately not a silent write. The tables are generated, read
// back and compared with the model before anything touches the file, and the
// firmware version ritual that the repository's own gate demands is run and
// shown, not performed behind the user's back.

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../editor_state.dart';
import '../game_source.dart';
import '../jumpman_spec.dart';
import '../level_source.dart';
import 'findings_panel.dart';
import 'inspector_panel.dart';
import 'map_view.dart';
import 'palette_bar.dart';
import 'playtest_panel.dart';

class JumpmanEditorApp extends StatelessWidget {
  const JumpmanEditorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Jumpman Level Editor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF48B050),
        useMaterial3: true,
      ),
      home: const EditorHome(),
    );
  }
}

/// The way in: resolve the repository, read the game, import its level.
class EditorHome extends StatefulWidget {
  const EditorHome({super.key});

  @override
  State<EditorHome> createState() => _EditorHomeState();
}

class _EditorHomeState extends State<EditorHome> {
  EditorState? _state;
  bool _loading = true;
  String? _problem;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    _state?.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    setState(() {
      _loading = true;
      _problem = null;
    });
    try {
      final state = await openEditor();
      if (!mounted) {
        state?.dispose();
        return;
      }
      setState(() {
        _state?.dispose();
        _state = state;
        _loading = false;
      });
    } on JumpmanSpecException catch (e) {
      if (mounted) setState(() {
        _problem = e.message;
        _loading = false;
      });
    } on LevelSourceException catch (e) {
      if (mounted) setState(() {
        _problem = e.message;
        _loading = false;
      });
    } on FileSystemException catch (e) {
      if (mounted) setState(() {
        _problem = '${e.path}: ${e.message}';
        _loading = false;
      });
    }
  }

  Future<void> _pickGameFile() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Jumpman game source', extensions: ['c']),
      ],
    );
    if (file == null) return;
    final source = await GameSource.remember(file.path);
    if (!mounted) return;
    try {
      final state = await openEditorAt(source);
      if (!mounted) {
        state.dispose();
        return;
      }
      setState(() {
        _state?.dispose();
        _state = state;
        _problem = null;
      });
    } on JumpmanSpecException catch (e) {
      setState(() => _problem = e.message);
    } on LevelSourceException catch (e) {
      setState(() => _problem = e.message);
    } on FileSystemException catch (e) {
      setState(() => _problem = '${e.path}: ${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    if (state != null) return EditorScreen(state: state);
    return Scaffold(
      appBar: AppBar(title: const Text('Jumpman Level Editor')),
      body: Center(
        child: _loading
            ? const CircularProgressIndicator()
            : ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'The repository could not be found.',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'The editor reads the level out of '
                      'gamekit/examples/jumpman/game_jumpman.c, and writes it '
                      'back there. It looked for the repository beside the '
                      'running app and in the working directory, and found '
                      'neither. Point it at the game source and it will '
                      'remember.',
                    ),
                    if (_problem != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _problem!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        FilledButton.icon(
                          onPressed: _pickGameFile,
                          icon: const Icon(Icons.folder_open, size: 18),
                          label: const Text('Choose game_jumpman.c'),
                        ),
                        const SizedBox(width: 12),
                        TextButton.icon(
                          onPressed: _open,
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text('Look again'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// The editor proper.
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.state});

  final EditorState state;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyN, control: true):
              state.newLevel,
          const SingleActivator(LogicalKeyboardKey.keyO, control: true):
              state.openProject,
          const SingleActivator(LogicalKeyboardKey.keyS, control: true):
              state.save,
          const SingleActivator(LogicalKeyboardKey.keyS,
              control: true, shift: true): state.saveAs,
          const SingleActivator(LogicalKeyboardKey.keyE, control: true): () {
            state.exportLevel();
            state.runFirmwareCheck();
          },
          const SingleActivator(LogicalKeyboardKey.keyZ, control: true):
              state.undo,
          const SingleActivator(LogicalKeyboardKey.keyZ,
              control: true, shift: true): state.redo,
          const SingleActivator(LogicalKeyboardKey.delete):
              state.deleteSelected,
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: AppBar(
              title: Text(
                'Jumpman Level Editor  ·  ${state.projectName}'
                '${state.dirty ? ' *' : ''}',
              ),
              actions: [
                TextButton(onPressed: state.newLevel, child: const Text('New')),
                TextButton(
                    onPressed: state.openProject, child: const Text('Open')),
                TextButton(onPressed: state.save, child: const Text('Save')),
                TextButton(
                    onPressed: state.saveAs, child: const Text('Save as')),
                TextButton(onPressed: state.revert, child: const Text('Revert')),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilledButton.icon(
                    onPressed: () {
                      state.exportLevel();
                      state.runFirmwareCheck();
                    },
                    icon: const Icon(Icons.save_alt, size: 18),
                    label: const Text('Export'),
                  ),
                ),
              ],
            ),
            body: Column(
              children: [
                Material(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: PaletteBar(state: state),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: Row(
                    children: [
                      Expanded(child: MapView(state: state)),
                      const VerticalDivider(width: 1),
                      SizedBox(
                        width: 420,
                        child: DefaultTabController(
                          length: 4,
                          child: Column(
                            children: [
                              const TabBar(
                                tabs: [
                                  Tab(text: 'Inspector'),
                                  Tab(text: 'Findings'),
                                  Tab(text: 'Playtest'),
                                  Tab(text: 'Export'),
                                ],
                              ),
                              Expanded(
                                child: TabBarView(
                                  children: [
                                    InspectorPanel(state: state),
                                    FindingsPanel(state: state),
                                    PlaytestPanel(state: state),
                                    _ExportTab(state: state),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          state.statusLine,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      Text(
                        state.gameSource.gameFile,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Exporting, and the version ritual the repository's own gate demands.
class _ExportTab extends StatelessWidget {
  const _ExportTab({required this.state});

  final EditorState state;

  Future<void> _confirmBump(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Bump and stamp'),
        content: const Text(kBumpAndStampWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Bump and stamp'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await state.bumpAndStamp();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('Export', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Writes this level\'s tables into ${state.gameSource.gameFile}, '
          'replacing the five tables and the three #defines and nothing else.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: () {
            state.exportLevel();
            state.runFirmwareCheck();
          },
          icon: const Icon(Icons.save_alt, size: 18),
          label: const Text('Export to game_jumpman.c'),
        ),
        if (state.exportReport != null) ...[
          const SizedBox(height: 12),
          SelectableText(
            state.exportReport!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: state.exportFailed ? theme.colorScheme.error : null,
              fontFamily: 'monospace',
            ),
          ),
        ],
        const Divider(height: 24),
        Row(
          children: [
            Expanded(
              child: Text('Firmware version', style: theme.textTheme.titleSmall),
            ),
            TextButton(
              onPressed: state.firmwareBusy ? null : state.runFirmwareCheck,
              child: const Text('Check'),
            ),
          ],
        ),
        Text(
          'The image is built from gamekit/, so a change here has to be stamped '
          'with a new version. The version is an image identity you decide, so '
          'the editor never bumps it on its own.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        if (state.firmwareBusy) const LinearProgressIndicator(),
        if (state.firmwareCheckOutput != null)
          SelectableText(
            state.firmwareCheckOutput!,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              color: state.firmwareCheckOk == false
                  ? theme.colorScheme.error
                  : null,
            ),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: state.firmwareBusy
              ? null
              : () => _confirmBump(context),
          icon: const Icon(Icons.numbers, size: 18),
          label: Text(state.firmwareCheckOk == false
              ? 'Bump and stamp'
              : 'Bump and stamp anyway'),
        ),
      ],
    );
  }
}
