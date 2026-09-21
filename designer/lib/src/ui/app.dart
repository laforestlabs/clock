// The workspace.
//
// Two arrangements from one widget tree: side by side on a desktop, stacked
// with tabs on a phone. The preview is always visible in both, because the
// point of the app is watching the panel change as you edit.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller.dart';
import '../engine/engine.dart';
import '../model/layout.dart';
import '../services/bundled_firmware.dart';
import '../services/firmware_update.dart';
import '../services/layout_pusher.dart';
import '../services/layout_repository.dart';
import '../services/mirror_connection.dart';
import '../services/panel_orientation.dart';
import '../services/user_view.dart';
import 'ble_prompt.dart';
import 'datetime_field.dart';
import 'color_field.dart';
import 'firmware_prompt.dart';
import 'inspector.dart';
import 'mirror_screen.dart';
import 'panel_view.dart';
import 'game_screen.dart';
import 'settings_screen.dart';
import 'widget_list.dart';
const double _wideBreakpoint = 900;

/// Below this width the app bar folds the less-used actions into the overflow
/// menu, so the actions row cannot overflow on a phone.
const double _appBarBreakpoint = 600;

/// Whether the keyboard focus is currently inside an editable text region:
/// a TextField/TextFormField, or any other widget built on [EditableText].
///
/// Kept separate from the workspace key handler so a focused field owns its
/// caret. Without this guard, backspace and delete would delete the selected
/// widget instead of a character, the arrows would nudge it instead of moving
/// the caret, and Ctrl+Z would undo the layout instead of the text.
bool hasTextEditingFocus() {
  final context = FocusManager.instance.primaryFocus?.context;
  return context != null &&
      context.findAncestorWidgetOfExactType<EditableText>() != null;
}

class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({super.key, required this.engine, this.connection});

  final MirrorEngine engine;

  /// The BLE link to drive. The app leaves this null and the workspace owns
  /// and closes its own; a test injects one to drive the connection states
  /// without a radio.
  final MirrorConnection? connection;

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen> {
  late final DesignerController _c = DesignerController(widget.engine);
  final LayoutRepository _repo = LayoutRepository();
  final FocusNode _keyboardFocus = FocusNode();

  // Owned here, not by the Mirror screen, so the BLE link survives page
  // navigation: pushing and popping the Mirror screen never touches it. An
  // injected link belongs to the caller and is never closed here.
  late final MirrorConnection _connection =
      widget.connection ?? MirrorConnection();
  late final bool _ownsConnection = widget.connection == null;

  /// Sends a tapped stock layout to the connected mirror. Owned here for the
  /// same reason as the link: the picks happen on this screen, and the queue
  /// has to outlive the widget that is repainted between them.
  late final LayoutPusher _pusher =
      LayoutPusher(connection: _connection, onOutcome: _reportPush);

  /// The firmware this app ships, loaded the first time a mirror connects: a
  /// run that never connects never reads the 1.3MB image.
  BundledFirmware? _bundled;

  /// Device versions this run has already offered an update for, so a link
  /// that drops and comes back does not ask about the same one twice.
  final Set<String> _offeredFirmware = <String>{};

  /// Whether the offer is in flight, from the version check to the end of the
  /// update: the listeners fire on every state change and only one prompt may
  /// be open at a time.
  bool _offeringFirmware = false;

  List<StockLayout> _stock = const <StockLayout>[];
  UserView _view = UserView.defaultView;
  String? _activeStockPath;

  @override
  void initState() {
    super.initState();
    _connection.addListener(_onConnectionChanged);
    _bootstrap();
    // Dialogs (the Bluetooth-on prompt) need the first frame to exist.
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoConnect());
  }

  /// Offer the app's own firmware to a mirror that just connected running
  /// something older. Nothing happens for a mirror on the same version, on a
  /// newer one, or on a build whose version this app cannot read.
  void _onConnectionChanged() {
    if (_connection.status != MirrorConnectionStatus.connected) return;
    unawaited(_offerFirmwareUpdate());
  }

  Future<void> _offerFirmwareUpdate() async {
    if (_offeringFirmware || !mounted) return;
    final version = _connection.pong?.version ?? '';
    if (version.isEmpty || _offeredFirmware.contains(version)) return;

    _offeringFirmware = true;
    try {
      final bundled = _bundled ?? await loadBundledFirmware();
      if (!mounted || bundled == null) return;
      _bundled = bundled;
      if (!firmwareUpdateAvailable(
          deviceVersion: version, bundledVersion: bundled.version)) {
        return;
      }
      // Recorded before the ask: an answer of "not now" is an answer, and the
      // next reconnect should not raise it again.
      _offeredFirmware.add(version);

      final accepted = await confirmFirmwareUpdate(
        context,
        deviceVersion: version,
        bundledVersion: bundled.version,
      );
      if (!accepted || !mounted) return;
      await _installBundledFirmware(bundled);
    } finally {
      _offeringFirmware = false;
    }
  }

  /// Push the image this app ships to the connected mirror and report what
  /// happened. The address is the one the pong reported: the upload is
  /// megabytes over WiFi, and Bluetooth only carries the command.
  Future<void> _installBundledFirmware(BundledFirmware bundled) async {
    final ip = _connection.pong?.ip ?? '';
    if (ip.isEmpty || ip == '0.0.0.0') {
      _toast('The mirror has no WiFi IP; the phone and mirror must be on the '
          'same network');
      return;
    }
    if (!await ensureMirrorReachable(context, ip)) return;
    if (!mounted) return;

    try {
      final status = await pushFirmwareWithProgress(
        context,
        ip: ip,
        bytes: bundled.bytes,
        label: 'bundled v${bundled.version}',
      );
      if (!mounted) return;
      if (status != null) {
        // The mirror rebooted, so the BLE link died with it. Reconnect now
        // that the device is advertising the new image.
        unawaited(_connection.connectLast());
      }
      _toast(status == null
          ? 'Update uploaded; the mirror is rebooting'
          : 'Updated to ${status.version}');
    } catch (e) {
      if (mounted) {
        _toast('Update: ${e.toString().replaceFirst('Exception: ', '')}');
      }
    }
  }

  /// Reconnect to the last mirror on launch. Best-effort: a mirror that is
  /// out of range or powered off just lands in the "failed" state with the
  /// error visible on the Mirror screen.
  Future<void> _autoConnect() async {
    if (!await _connection.hasLastDevice()) return;
    final gate = await ensureBlePermissions();
    if (!gate.granted) return;
    if (!mounted) return;
    if (!await ensureBluetoothOn(context)) return;
    await _connection.connectLast();
  }

  Future<void> _bootstrap() async {
    final stock = await _repo.stockLayouts();
    final view = await loadUserView();
    final flipped = await loadPanelFlip180();
    await _connection.loadLastPanelSize();
    if (!mounted) return;
    _c.flip180 = flipped;
    setState(() {
      _stock = stock;
      _view = view;
    });

    // Prefer a stock layout matching the panel the mirror last reported, so
    // the default never opens at a size the hardware cannot show. With no
    // remembered size, fall back to the 64x32 reference build ('mini').
    final panelW = _connection.lastPanelWidth;
    final panelH = _connection.lastPanelHeight;
    StockLayout? preferred;
    if (panelW != null && panelW > 0 && panelH != null && panelH > 0) {
      for (final s in stock) {
        if (s.width == panelW && s.height == panelH) {
          preferred = s;
          break;
        }
      }
    }
    if (preferred == null) {
      for (final s in stock) {
        if (s.name == 'mini') {
          preferred = s;
          break;
        }
      }
    }
    preferred ??= stock.isNotEmpty ? stock.first : null;

    if (preferred != null) {
      _activeStockPath = preferred.assetPath;
      await _c.loadJson(await _repo.loadAsset(preferred.assetPath));
    } else {
      // No stock layouts at all: start on a blank canvas of the last-known
      // panel size (or the reference build when that is unknown too).
      await _c.newLayout(
        width: (panelW != null && panelW > 0) ? panelW : 128,
        height: (panelH != null && panelH > 0) ? panelH : 64,
      );
    }
  }

  @override
  void dispose() {
    _keyboardFocus.dispose();
    _c.dispose();
    _connection.removeListener(_onConnectionChanged);
    if (_ownsConnection) _connection.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ file

  Future<void> _open() async {
    if (!await _confirmDiscard()) return;
    final picked = await _repo.openFile();
    if (picked == null) return;
    await _c.loadJson(picked.json, path: picked.path, label: picked.label);
  }

  Future<void> _newLayout() async {
    if (!await _confirmDiscard()) return;
    await _c.newLayout();
  }

  /// True when it is safe to replace the document: nothing unsaved, or the
  /// owner chose to let it go. Every path that swaps the document runs this
  /// first, because the alternative is losing an afternoon's layout to one
  /// click on a stock preset, with the app aware the whole time that it had
  /// unsaved changes.
  Future<bool> _confirmDiscard() async {
    if (!_c.dirty) return true;

    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unsaved changes'),
        content: Text(
            '"${_c.doc.name}" has changes that have not been saved.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'discard'),
            child: const Text('Discard'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (!mounted) return false;
    if (choice == 'save') {
      await _save();
      // The save may itself have been cancelled at the file picker, so the
      // document is only safe to replace if it came back clean.
      return !_c.dirty;
    }
    return choice == 'discard';
  }

  Future<void> _save({bool forceAs = false}) async {
    final contents = _c.exportJson();
    final path = _c.sourcePath;

    if (!forceAs && path != null) {
      final ok = await _repo.saveTo(path, contents);
      if (ok) {
        final label = _c.sourceLabel;
        _c.markSaved(path, label: label);
        _toast('Saved to ${label ?? path}');
        return;
      }
      // Fall through to Save As when the original path is not writable, which
      // is the normal case for a layout opened from bundled assets.
    }

    final chosen = await _repo.saveAs(_c.doc.name, contents);
    if (chosen == null) return;
    _c.markSaved(chosen.location, label: chosen.label);
    _toast('Saved to ${chosen.label}');
  }

  void _toast(String message) {
    if (!mounted) return;
    // Replaced rather than queued, like the Mirror screen's toasts. A preset
    // tapped four times in a second reports four outcomes, and the only one
    // worth reading is the last.
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
  }

  void _openMirror() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MirrorScreen(controller: _c, connection: _connection),
      ),
    );
  }

  void _openMirrorSimplified() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MirrorScreen(
          controller: _c,
          connection: _connection,
          simplified: true,
        ),
      ),
    );
  }

  Future<void> _setView(UserView view) async {
    await saveUserView(view);
    if (mounted) setState(() => _view = view);
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(
          controller: _c,
          view: _view,
          connection: _connection,
          onViewChanged: _setView,
        ),
      ),
    );
  }

  void _openGames() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GameScreen(
          controller: _c,
          connection: _connection,
          // The default view plays: tilt is the controller and the pads are
          // the fallback, with no mode, panel size or diagnostics to choose.
          simplified: _view == UserView.defaultView,
        ),
      ),
    );
  }

  /// The BLE link state, always visible in the app bar. Tapping it (or the
  /// Mirror button) opens the Mirror screen for details and controls.
  Widget _buildConnectionIndicator({required bool compact}) {
    return ListenableBuilder(
      listenable: _connection,
      builder: (context, _) {
        final theme = Theme.of(context);
        final connection = _connection;
        switch (connection.status) {
          case MirrorConnectionStatus.connected:
            if (compact) {
              return IconButton(
                tooltip: 'Connected to ${connection.deviceName}',
                icon: Icon(Icons.bluetooth_connected,
                    size: 18, color: theme.colorScheme.primary),
                onPressed: _openMirror,
              );
            }
            return Tooltip(
              message: 'Connected to ${connection.deviceName}',
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onPressed: _openMirror,
                icon: Icon(Icons.bluetooth_connected,
                    size: 18, color: theme.colorScheme.primary),
                label: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 120),
                  child: Text(
                    connection.deviceName ?? '',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium,
                  ),
                ),
              ),
            );
          case MirrorConnectionStatus.connecting:
            return Tooltip(
              message: 'Connecting to ${connection.deviceName}...',
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            );
          case MirrorConnectionStatus.failed:
            return IconButton(
              tooltip: 'Reconnect failed: ${connection.error ?? 'unknown'}',
              icon: Icon(Icons.bluetooth, color: theme.colorScheme.error),
              onPressed: _openMirror,
            );
          case MirrorConnectionStatus.disconnected:
            return IconButton(
              tooltip: 'Not connected to a mirror',
              icon: const Icon(Icons.bluetooth_disabled),
              onPressed: _openMirror,
            );
        }
      },
    );
  }

  /// Open a stock preset, and while a mirror is connected send it there in the
  /// same tap.
  ///
  /// That is what makes the picker a live preview: the panel changes as the
  /// user clicks through the layouts, instead of after a separate trip to the
  /// Mirror screen. Tapping a preset writes it to the mirror exactly as the
  /// Push layout button does, so the layout it ends on is the one it keeps.
  Future<void> _openStock(StockLayout layout) async {
    if (!await _confirmDiscard()) return;
    final json = await _repo.loadAsset(layout.assetPath);
    _activeStockPath = layout.assetPath;

    final connected = _connection.session != null;
    if (connected) {
      // The asset's own text rather than the loaded document: the panel is
      // meant to get exactly the layout that was picked, and it can be on its
      // way while this screen renders it.
      _pusher.push(layout.name, json);
    }

    await _c.loadJson(json);
    // Connected, the push reports for itself what became of the tap; a second
    // toast for the local open would only queue behind it.
    if (!connected) _toast('Opened ${layout.name}');
  }

  /// Report the outcome of one preset push. A tap that a later tap replaced
  /// never reaches here: nothing was sent, so there is nothing to say.
  void _reportPush(LayoutPushOutcome outcome) {
    final error = outcome.error;
    _toast(error == null ? 'Pushed ${outcome.label}' : 'Not pushed: $error');
  }

  /// Stock presets that match the panel the mirror reported: the live pong
  /// while connected, otherwise the last remembered size. Only when neither
  /// is known does every preset stay visible.
  List<StockLayout> get _visibleStock {
    return stockLayoutsForPanel(
      _stock,
      _connection.panelWidth,
      _connection.panelHeight,
    );
  }

  // -------------------------------------------------------------- keyboard

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final control = HardwareKeyboard.instance.isControlPressed;
    if (hasTextEditingFocus()) {
      // Saving has no meaning inside a text field, so it stays available while
      // typing; every other shortcut is handed back to the field.
      if (control && event.logicalKey == LogicalKeyboardKey.keyS) {
        _save();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    final shift = HardwareKeyboard.instance.isShiftPressed;
    final step = shift ? 5 : 1;

    // Holding control turns the arrows into a resize, growing right and down.
    // Without it they move, as before.
    void arrow(int dx, int dy) {
      if (control) {
        _c.growSelected(dx, dy);
      } else {
        _c.nudgeSelected(dx, dy);
      }
    }

    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        arrow(-step, 0);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        arrow(step, 0);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        arrow(0, -step);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        arrow(0, step);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.delete:
      case LogicalKeyboardKey.backspace:
        _c.deleteSelected();
        return KeyEventResult.handled;
    }

    if (control) {
      if (event.logicalKey == LogicalKeyboardKey.keyZ) {
        shift ? _c.redo() : _c.undo();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyS) {
        _save();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyD) {
        _c.duplicateSelected();
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  // ------------------------------------------------------------------ view

  @override
  Widget build(BuildContext context) {
    return _view == UserView.developer ? _buildDeveloper() : _buildDefault();
  }

  Widget _buildDeveloper() {
    return Focus(
      focusNode: _keyboardFocus,
      onKeyEvent: _onKey,
      autofocus: true,
      child: AnimatedBuilder(
        animation: Listenable.merge(<Listenable>[_c, _connection]),
        builder: (context, _) {
          return Scaffold(
            appBar: _buildAppBar(),
            body: Column(
              children: <Widget>[
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) =>
                        constraints.maxWidth >= _wideBreakpoint
                            ? _buildWide()
                            : _buildNarrow(),
                  ),
                ),
                _DiagnosticsBar(controller: _c),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildDefault() {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[_c, _connection]),
      builder: (context, _) {
        final connected =
            _connection.status == MirrorConnectionStatus.connected;
        return Scaffold(
          appBar: AppBar(
            title: const Text('My Mirror'),
            actions: <Widget>[
              IconButton(
                tooltip: 'Games',
                icon: const Icon(Icons.sports_esports),
                onPressed: _openGames,
              ),
              IconButton(
                tooltip: connected ? 'Mirror connected' : 'Connect to mirror',
                icon: Icon(
                  connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                ),
                onPressed: _openMirrorSimplified,
              ),
              IconButton(
                tooltip: 'Settings',
                icon: const Icon(Icons.settings),
                onPressed: _openSettings,
              ),
            ],
          ),
          body: Column(
            children: <Widget>[
              Expanded(
                flex: 3,
                child: _CanvasArea(controller: _c, readOnly: true),
              ),
              const Divider(height: 1),
              Expanded(
                flex: 2,
                child: _SimplePanel(
                  controller: _c,
                  stock: _visibleStock,
                  activeStockPath: _activeStockPath,
                  connected: connected,
                  panelWidth: _connection.panelWidth,
                  panelHeight: _connection.panelHeight,
                  onPickStock: _openStock,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  PreferredSizeWidget _buildAppBar() {
    final compact = MediaQuery.sizeOf(context).width < _appBarBreakpoint;
    return AppBar(
      titleSpacing: 12,
      title: Row(
        children: <Widget>[
          Flexible(
            child: Text(
              _c.doc.name + (_c.dirty ? ' *' : ''),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '${_c.doc.width}x${_c.doc.height}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: <Widget>[
        if (!compact) ...<Widget>[
          IconButton(
            tooltip: 'Undo',
            icon: const Icon(Icons.undo),
            onPressed: _c.canUndo ? _c.undo : null,
          ),
          IconButton(
            tooltip: 'Redo',
            icon: const Icon(Icons.redo),
            onPressed: _c.canRedo ? _c.redo : null,
          ),
        ],
        AddWidgetButton(controller: _c),
        IconButton(
          tooltip: 'Games',
          icon: const Icon(Icons.sports_esports),
          onPressed: _openGames,
        ),
        _buildConnectionIndicator(compact: compact),
        IconButton(
          tooltip: 'Mirror',
          icon: const Icon(Icons.bluetooth_searching),
          onPressed: _openMirror,
        ),
        IconButton(
          tooltip: 'Default view',
          icon: const Icon(Icons.visibility),
          onPressed: () => _setView(UserView.defaultView),
        ),
        PopupMenuButton<String>(
          onSelected: (choice) {
            // Explicit breaks: implicit fallthrough rules differ across Dart
            // versions, and this costs nothing to be unambiguous about.
            switch (choice) {
              case 'new':
                _newLayout();
                break;
              case 'open':
                _open();
                break;
              case 'save':
                _save();
                break;
              case 'saveAs':
                _save(forceAs: true);
                break;
              case 'undo':
                _c.undo();
                break;
              case 'redo':
                _c.redo();
                break;
              case 'settings':
                _openSettings();
                break;
              default:
                final match = _stock.where((s) => s.assetPath == choice);
                if (match.isNotEmpty) _openStock(match.first);
                break;
            }
          },
          itemBuilder: (context) => <PopupMenuEntry<String>>[
            const PopupMenuItem<String>(value: 'new', child: Text('New layout')),
            const PopupMenuItem<String>(value: 'open', child: Text('Open...')),
            const PopupMenuItem<String>(value: 'save', child: Text('Save')),
            const PopupMenuItem<String>(value: 'saveAs', child: Text('Save as...')),
            if (_visibleStock.isNotEmpty) const PopupMenuDivider(),
            for (final s in _visibleStock)
              PopupMenuItem<String>(
                value: s.assetPath,
                child: Text('Stock: ${s.name}'),
              ),
            if (compact) ...<PopupMenuEntry<String>>[
              const PopupMenuDivider(),
              const PopupMenuItem<String>(value: 'undo', child: Text('Undo')),
              const PopupMenuItem<String>(value: 'redo', child: Text('Redo')),
            ],
            const PopupMenuDivider(),
            const PopupMenuItem<String>(value: 'settings', child: Text('Settings')),
          ],
        ),
      ],
    );
  }

  Widget _buildWide() {
    return Row(
      children: <Widget>[
        SizedBox(width: 250, child: WidgetListPanel(controller: _c)),
        const VerticalDivider(width: 1),
        Expanded(child: _CanvasArea(controller: _c)),
        const VerticalDivider(width: 1),
        SizedBox(width: 330, child: InspectorPanel(controller: _c)),
      ],
    );
  }

  Widget _buildNarrow() {
    return Column(
      children: <Widget>[
        // The preview keeps the top of the screen on a phone. Watching the
        // panel react is the entire point, so it never gets tabbed away.
        SizedBox(height: 240, child: _CanvasArea(controller: _c)),
        const Divider(height: 1),
        Expanded(
          child: DefaultTabController(
            length: 2,
            child: Column(
              children: <Widget>[
                const TabBar(
                  tabs: <Widget>[
                    Tab(text: 'Widgets', icon: Icon(Icons.layers, size: 18)),
                    Tab(text: 'Properties', icon: Icon(Icons.tune, size: 18)),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: <Widget>[
                      WidgetListPanel(controller: _c),
                      InspectorPanel(controller: _c),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _CanvasArea extends StatelessWidget {
  const _CanvasArea({required this.controller, this.readOnly = false});

  final DesignerController controller;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    // Deliberately no scroll view here. PanelView is an InteractiveViewer with
    // constrained: false, which sizes to the largest its parent allows and pans
    // an oversized child itself. A scroll view hands it an unbounded constraint
    // instead, which is a layout error, and the preview never paints at all.
    return ColoredBox(
      color: const Color(0xFF14181B),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: PanelView(controller: controller, readOnly: readOnly),
      ),
    );
  }
}

/// Parser warnings and errors, straight from the engine.
///
/// Worth surfacing permanently rather than hiding behind a menu: a widget
/// silently not drawing is the most common confusion when hand-editing a
/// layout, and the engine already explains exactly why.
class _DiagnosticsBar extends StatelessWidget {
  const _DiagnosticsBar({required this.controller});

  final DesignerController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = controller.error;
    final diags = controller.diagnostics;

    if (error == null && diags.isEmpty) return const SizedBox.shrink();

    final isError = error != null;
    final colour = isError ? theme.colorScheme.errorContainer : theme.colorScheme.surfaceContainerHighest;

    return Container(
      width: double.infinity,
      color: colour,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (isError)
            Row(
              children: <Widget>[
                const Icon(Icons.error_outline, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    // The last good frame is still on screen, which is worth
                    // saying so the user does not think the edit applied.
                    '$error  (still showing the last layout that parsed)',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          for (final d in diags.take(3))
            Row(
              children: <Widget>[
                const Icon(Icons.info_outline, size: 16),
                const SizedBox(width: 8),
                Expanded(child: Text(d, style: theme.textTheme.bodySmall)),
              ],
            ),
          if (diags.length > 3)
            Text('and ${diags.length - 3} more',
                style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// The simplified user-facing panel: pick a stock layout, then tune the few
/// inputs a stock layout actually exposes. No selection, no geometry.
///
/// A connected mirror is sent every layout the user picks, so the chips double
/// as a live preview of the presets on the panel itself.
///
/// Rather than mirror every widget's colour and text field, it promotes a
/// small fixed set: the background, the dominant foreground ("main") colour,
/// at most one accent, up to two literal text strings, and a target time when
/// the layout is a countdown. Everything else stays editable in the developer
/// view.
class _SimplePanel extends StatelessWidget {
  const _SimplePanel({
    required this.controller,
    required this.stock,
    required this.activeStockPath,
    required this.connected,
    required this.panelWidth,
    required this.panelHeight,
    required this.onPickStock,
  });

  final DesignerController controller;
  final List<StockLayout> stock;
  final String? activeStockPath;

  /// Whether a mirror is connected, which is what makes a pick a push.
  final bool connected;
  final int panelWidth;
  final int panelHeight;
  final ValueChanged<StockLayout> onPickStock;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final doc = controller.doc;
        final children = <Widget>[
          Text('Layout', style: theme.textTheme.titleMedium),
          if (connected && stock.isNotEmpty)
            // Said out loud because a tap now changes the panel as well as the
            // preview, and a picker that quietly rewrites the mirror is a
            // surprise worth spending a line on.
            Text(
              'Pick a layout to preview it on your mirror.',
              style: theme.textTheme.bodySmall,
            ),
          if (stock.isEmpty)
            Text(
              panelWidth > 0
                  ? 'No layouts match your mirror (${panelWidth}x$panelHeight).'
                  : 'Connect to your mirror to see matching layouts.',
              style: theme.textTheme.bodySmall,
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final s in stock)
                  ChoiceChip(
                    label: Text(s.name),
                    selected: s.assetPath == activeStockPath,
                    onSelected: (_) => onPickStock(s),
                  ),
              ],
            ),
        ];

        // Display text: at most two literal text widgets, in paint order.
        final texts = literalTextWidgets(doc);
        children
          ..add(const SizedBox(height: 16))
          ..add(Text('Text', style: theme.textTheme.titleMedium));
        if (texts.isEmpty) {
          children.add(Text(
            'This layout has no editable text.',
            style: theme.textTheme.bodySmall,
          ));
        } else {
          for (final entry in texts.take(2)) {
            final text = entry.widget.getString('text')!;
            children.add(TextFormField(
              key: ValueKey<String>('simple-text-${entry.index}-$text'),
              initialValue: text,
              decoration: InputDecoration(
                labelText:
                    entry.widget.id.isNotEmpty ? entry.widget.id : 'Text',
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              onFieldSubmitted: (v) => controller.updateWidget(
                entry.index,
                (w) => w.setString('text', v),
              ),
            ));
          }
        }

        // Colours: background, then at most a main and an accent colour.
        children
          ..add(const SizedBox(height: 16))
          ..add(Text('Colours', style: theme.textTheme.titleMedium))
          ..add(ColorField(
            label: 'Background',
            value: doc.background,
            onChanged: (v) {
              doc.background = v ?? '#000000';
              controller.refresh();
            },
          ));

        final main = mainColourTarget(doc);
        if (main != null) {
          children.add(ColorField(
            label: 'Main colour',
            value: main.widget.getString('color'),
            onChanged: (v) => controller.updateWidget(
              main.index,
              (w) => w.setString('color', v),
            ),
          ));
        }

        final accent = accentTarget(doc);
        if (accent != null) {
          children.add(ColorField(
            label: 'Accent',
            value: accent.widget.getString('accent'),
            onChanged: (v) => controller.updateWidget(
              accent.index,
              (w) => w.setString('accent', v),
            ),
          ));
        }

        // A target time when the layout is a countdown.
        final countdown = countdownTarget(doc);
        if (countdown != null) {
          children
            ..add(const SizedBox(height: 16))
            ..add(Text('Countdown', style: theme.textTheme.titleMedium))
            ..add(DateTimeField(
              label: 'Target time',
              value: countdown.widget.getInt('until'),
              onChanged: (v) => controller.updateWidget(
                countdown.index,
                (w) => w.setInt('until', v),
              ),
            ));
        }

        return ListView(
          padding: const EdgeInsets.all(16),
          children: children,
        );
      },
    );
  }
}

/// Literal text widgets in paint order: `text` widgets carrying a `text`
/// value rather than a model `bind`. These are the strings a user types.
List<({int index, LayoutWidget widget})> literalTextWidgets(LayoutDoc doc) {
  final result = <({int index, LayoutWidget widget})>[];
  for (var i = 0; i < doc.widgetCount; i++) {
    final w = doc.widgetAt(i);
    if (w == null || w.type != 'text') continue;
    if (w.getString('text') == null) continue;
    result.add((index: i, widget: w));
  }
  return result;
}

/// The widget whose colour the simple view promotes as "main": the largest
/// non-decorative widget carrying a `color`, ties broken by paint order.
({int index, LayoutWidget widget})? mainColourTarget(LayoutDoc doc) =>
    _largestWidgetWith(doc, key: 'color', skipDecoration: true);

/// The widget whose accent the simple view promotes: the largest widget
/// carrying an `accent`, ties broken by paint order.
({int index, LayoutWidget widget})? accentTarget(LayoutDoc doc) =>
    _largestWidgetWith(doc, key: 'accent');

/// The countdown widget whose target time the simple view exposes, if any.
({int index, LayoutWidget widget})? countdownTarget(LayoutDoc doc) =>
    _firstWidgetOfType(doc, 'countdown');

({int index, LayoutWidget widget})? _largestWidgetWith(
  LayoutDoc doc, {
  required String key,
  bool skipDecoration = false,
}) {
  ({int index, LayoutWidget widget})? best;
  var bestArea = -1.0;
  for (var i = 0; i < doc.widgetCount; i++) {
    final w = doc.widgetAt(i);
    if (w == null) continue;
    if (skipDecoration && (w.type == 'rect' || w.type == 'line')) continue;
    if (w.getString(key) == null) continue;
    final area = w.rect.width * w.rect.height;
    if (area > bestArea) {
      bestArea = area;
      best = (index: i, widget: w);
    }
  }
  return best;
}

({int index, LayoutWidget widget})? _firstWidgetOfType(
  LayoutDoc doc,
  String type,
) {
  for (var i = 0; i < doc.widgetCount; i++) {
    final w = doc.widgetAt(i);
    if (w != null && w.type == type) return (index: i, widget: w);
  }
  return null;
}
