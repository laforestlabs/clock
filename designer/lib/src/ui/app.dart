// The workspace.
//
// Two arrangements from one widget tree: side by side on a desktop, stacked
// with tabs on a phone. The preview is always visible in both, because the
// point of the app is watching the panel change as you edit.
//
// It edits one of two things, and says which: a device record it is bound to,
// or the local simulator. A bound workspace reads the layout the mirror is
// actually showing, sends every preset it is given over that record's own
// transports, and takes its panel geometry and orientation from the device.
// The simulator never reaches out at all - opening it from the app menu must
// not write to whichever mirror happens to be remembered.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller.dart';
import '../engine/engine.dart';
import '../model/layout.dart';
import '../services/layout_pusher.dart';
import '../services/layout_repository.dart';
import '../services/mirror_connection.dart';
import '../services/mirror_devices.dart';
import '../services/panel_orientation.dart';
import '../services/user_view.dart';
import 'datetime_field.dart';
import 'color_field.dart';
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
  const WorkspaceScreen({super.key, required this.engine, this.device});

  final MirrorEngine engine;

  /// The mirror this workspace edits, or null for the local simulator.
  ///
  /// Bound, every preset goes to this record over its own transports and the
  /// panel size and orientation come from it. Null never reaches any radio:
  /// the local simulator is an offline development surface, so a remembered
  /// mirror cannot be written to by opening it.
  final MirrorDevice? device;

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen> {
  late final DesignerController _c = DesignerController(
    widget.engine,
    persistFlip180: _persistFlip180,
  );
  final LayoutRepository _repo = LayoutRepository();
  final FocusNode _keyboardFocus = FocusNode();

  /// The record being edited, or null for the local simulator.
  MirrorDevice? get _device => widget.device;

  /// Whether a stock pick is also a push.
  ///
  /// Only with a confirmed panel size: the firmware refuses a layout that does
  /// not match its own geometry, so a send before that is known could only be
  /// rejected - and a layout the panel never took must not look like it did.
  bool get _pushesToDevice {
    final device = _device;
    return device != null && device.width > 0 && device.height > 0;
  }

  /// The local simulator's inert link, built on first use and owned here.
  ///
  /// It is never connected and never discovered: the local Game screen needs a
  /// connection to build against, and that is the whole of its job.
  MirrorConnection? _localConnection;

  /// The link for the screens this workspace opens: the record's own while
  /// bound, the inert one for the simulator.
  MirrorConnection get _connection =>
      _device?.connection ?? (_localConnection ??= MirrorConnection());

  /// Sends a tapped stock layout to the bound device. Owned here for the same
  /// reason as the document: the picks happen on this screen and the queue has
  /// to outlive the widget repainted between them. Null on the simulator,
  /// where nothing leaves the machine.
  LayoutPusher? _pusher;

  /// Why the document on screen is a local draft rather than the layout the
  /// mirror holds, or null when it is the mirror's own (or there is no
  /// device). Shown until a preset is explicitly sent or a read succeeds.
  String? _draftReason;

  /// True while the device's layout is being read, so Retry reports progress.
  bool _loadingLayout = false;

  List<StockLayout> _stock = const <StockLayout>[];
  UserView _view = UserView.defaultView;
  String? _activeStockPath;

  @override
  void initState() {
    super.initState();
    final device = _device;
    if (device != null) {
      _pusher = LayoutPusher(
        send: (json) => device.owner.sendLayout(device, json),
        onOutcome: _reportPush,
      );
    }
    _bootstrap();
  }

  /// A workspace is bound once: the route is opened for one device, and the
  /// pusher captures that record when it is built. Retargeting in place would
  /// leave the queue pointed at the record the route was opened with.
  @override
  void didUpdateWidget(WorkspaceScreen old) {
    super.didUpdateWidget(old);
    assert(identical(old.device, widget.device),
        'a workspace does not retarget; open a route for the other device');
  }

  /// Records the preview's orientation where the owner of this workspace
  /// keeps it: the device's registry record while bound, the global simulator
  /// seed otherwise. Never both - a device's orientation is not the desktop
  /// pref's to write.
  Future<void> _persistFlip180(bool flipped) async {
    final device = _device;
    if (device == null) return savePanelFlip180(flipped);
    await device.owner.setFlip180(device, flipped);
  }

  Future<void> _bootstrap() async {
    final stock = await _repo.stockLayouts();
    final view = await loadUserView();
    final device = _device;
    // The device's own orientation while bound: the global pref describes the
    // simulator's preview, not this panel, and seeding from it would draw the
    // panel's own snapshot the wrong way up.
    final flipped = device?.flip180 ?? await loadPanelFlip180();
    if (!mounted) return;
    _c.flip180 = flipped;
    setState(() {
      _stock = stock;
      _view = view;
    });

    if (device == null) {
      await _openLocalDefault();
    } else {
      await _loadDeviceLayout(device);
    }
  }

  /// The simulator's opening document: the reference build, which is the
  /// panel the desktop preview is designed around. Deliberately not the panel
  /// size of any remembered mirror - this workspace is not that mirror's.
  Future<void> _openLocalDefault() async {
    final preferred = _preferredStock(0, 0);
    if (preferred != null) {
      _activeStockPath = preferred.assetPath;
      await _c.loadJson(await _repo.loadAsset(preferred.assetPath));
    } else {
      // No stock layouts at all: a blank canvas at the reference size.
      await _c.newLayout();
    }
  }

  /// The preset for a panel [width]x[height]: the exact size when a preset has
  /// it, otherwise the 64x32 reference build, otherwise whatever exists.
  StockLayout? _preferredStock(int width, int height) {
    if (width > 0 && height > 0) {
      for (final s in _stock) {
        if (s.width == width && s.height == height) return s;
      }
    }
    for (final s in _stock) {
      if (s.name == 'mini') return s;
    }
    return _stock.isEmpty ? null : _stock.first;
  }

  /// Opens the layout the device is actually showing, or an explicitly
  /// labeled local draft when it cannot be read.
  ///
  /// A mirror reachable only over Bluetooth has no layout-download command, so
  /// there is nothing to fetch: the workspace then seeds the preset matching
  /// its panel and says out loud that the document is a draft. Opening a clock
  /// editor must not change what the panel shows, so nothing here is ever
  /// sent - a preset the user picks is.
  Future<void> _loadDeviceLayout(MirrorDevice device) async {
    if (_loadingLayout) return;
    setState(() => _loadingLayout = true);

    var reason = '';
    var loaded = false;
    try {
      final json = await device.owner.loadLayout(device);
      if (!mounted) return;
      await _c.loadJson(json);
      loaded = true;
    } catch (e) {
      reason = e is MirrorRegistryException ? e.message : '$e';
    }
    if (!mounted) return;

    if (!loaded) {
      final draft = _preferredStock(device.width, device.height);
      if (draft != null) {
        _activeStockPath = draft.assetPath;
        await _c.loadJson(await _repo.loadAsset(draft.assetPath));
        if (!mounted) return;
      } else {
        await _c.newLayout(
          width: device.width > 0 ? device.width : 128,
          height: device.height > 0 ? device.height : 64,
        );
        if (!mounted) return;
      }
    }

    setState(() {
      _loadingLayout = false;
      _draftReason = loaded ? null : reason;
    });
    // The device's layout is not one of the presets, so no chip is current.
    if (loaded) _activeStockPath = null;
  }

  void _retryLayout() {
    final device = _device;
    if (device == null) return;
    unawaited(_loadDeviceLayout(device));
  }

  @override
  void dispose() {
    _keyboardFocus.dispose();
    // The queue is dropped before the controller: a push already on the wire
    // finishes against the device it was captured for, but nothing reports
    // back into a route that is gone.
    _pusher?.dispose();
    // Disposes the engine with it, and nothing else may: the workspace opened
    // that engine's controller once.
    _c.dispose();
    _localConnection?.dispose();
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
        content: Text('"${_c.doc.name}" has changes that have not been saved.'),
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

  /// This device's own setup and controls. The local simulator has no device
  /// to configure, so there is no route to open.
  void _openMirror({bool simplified = false}) {
    final device = _device;
    if (device == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MirrorScreen(
          controller: _c,
          device: device,
          simplified: simplified,
        ),
      ),
    );
  }

  Future<void> _setView(UserView view) async {
    await saveUserView(view);
    if (mounted) setState(() => _view = view);
  }

  void _openSettings() {
    final device = _device;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(
          controller: _c,
          view: _view,
          onViewChanged: _setView,
          // Bound, settings edits that device and applies orientation to it;
          // the simulator only edits its own preview.
          device: device,
          connection: device?.connection,
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
          // A bound workspace plays on that device and never falls back to a
          // local round; the simulator always plays locally.
          requireDevice: _device != null,
          // The default view plays: tilt is the controller and the pads are
          // the fallback, with no mode, panel size or diagnostics to choose.
          simplified: _view == UserView.defaultView,
        ),
      ),
    );
  }

  /// Who this workspace is editing, always visible in the app bar. Tapping a
  /// device opens its own screen; the simulator says what it is instead of
  /// offering a control that could reach a mirror the user did not choose.
  Widget _buildDeviceIndicator(
      {required bool compact, bool simplified = false}) {
    final device = _device;
    if (device == null) {
      return const Tooltip(
        message: 'Local simulator: layouts are previewed here, never sent',
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Icon(Icons.desktop_windows_outlined, size: 18),
        ),
      );
    }
    return ListenableBuilder(
      listenable: device,
      builder: (context, _) {
        final theme = Theme.of(context);
        final connected = device.connection.session != null;
        final IconData icon;
        final String transport;
        final Color colour;
        if (connected) {
          icon = Icons.bluetooth_connected;
          transport = 'Bluetooth';
          colour = theme.colorScheme.primary;
        } else if (device.lanReachable) {
          icon = Icons.wifi;
          transport = 'Wi-Fi';
          colour = theme.colorScheme.primary;
        } else {
          icon = Icons.cloud_off;
          transport = 'Offline';
          colour = device.error == null
              ? theme.colorScheme.outline
              : theme.colorScheme.error;
        }
        final tooltip = '${device.name} · $transport';
        if (compact) {
          return IconButton(
            tooltip: tooltip,
            icon: Icon(icon, size: 18, color: colour),
            onPressed: () => _openMirror(simplified: simplified),
          );
        }
        return Tooltip(
          message: tooltip,
          child: TextButton.icon(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            onPressed: () => _openMirror(simplified: simplified),
            icon: Icon(icon, size: 18, color: colour),
            label: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: Text(
                device.name,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium,
              ),
            ),
          ),
        );
      },
    );
  }

  /// Open a stock preset, and while this workspace is bound to a device send
  /// it there in the same tap.
  ///
  /// That is what makes the picker a live preview: the panel changes as the
  /// user clicks through the layouts, instead of after a separate trip to the
  /// device's own screen. Tapping a preset writes it to the device exactly as
  /// that screen's push does, so the layout it ends on is the one it keeps.
  /// The simulator keeps every pick local.
  Future<void> _openStock(StockLayout layout) async {
    if (!await _confirmDiscard()) return;
    final json = await _repo.loadAsset(layout.assetPath);
    _activeStockPath = layout.assetPath;

    final pusher = _pusher;
    final sending = pusher != null && _pushesToDevice;
    if (sending) {
      // The asset's own text rather than the loaded document: the panel is
      // meant to get exactly the layout that was picked, and it can be on its
      // way while this screen renders it.
      pusher.push(layout.name, json);
    }

    await _c.loadJson(json);
    if (sending) return;
    // Nothing was sent, and the user should know why: a second toast for the
    // local open would otherwise queue behind the push's own report.
    if (pusher == null) {
      _toast('Opened ${layout.name}');
    } else {
      _toast('Opened ${layout.name} — not sent: the panel size is unknown');
    }
  }

  /// Report the outcome of one preset push. A tap that a later tap replaced
  /// never reaches here: nothing was sent, so there is nothing to say.
  void _reportPush(LayoutPushOutcome outcome) {
    final device = _device;
    final error = outcome.error;
    if (error == null) {
      // The device is showing this now, so it is no longer a draft - and the
      // record's own status and preview are what changed, not this render.
      if (mounted && _draftReason != null) {
        setState(() => _draftReason = null);
      }
      if (device != null) {
        unawaited(device.owner.refresh(device, includeFrame: true));
      }
    }
    _toast(error == null ? 'Pushed ${outcome.label}' : 'Not pushed: $error');
  }

  /// Stock presets that match the panel of the device this workspace is bound
  /// to. The simulator has no panel to match and keeps every preset visible.
  List<StockLayout> get _visibleStock {
    final device = _device;
    return stockLayoutsForPanel(
      _stock,
      device?.width ?? 0,
      device?.height ?? 0,
    );
  }

  /// The listenables this screen redraws on: the document, and the device
  /// record while bound (its geometry decides whether a pick is a push).
  Listenable get _redraws =>
      Listenable.merge(<Listenable>[_c, if (_device != null) _device!]);

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
        animation: _redraws,
        builder: (context, _) {
          return Scaffold(
            appBar: _buildAppBar(),
            body: Column(
              children: <Widget>[
                if (_draftReason != null)
                  _DraftBar(
                    reason: _draftReason!,
                    busy: _loadingLayout,
                    onRetry: _retryLayout,
                  ),
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
      animation: _redraws,
      builder: (context, _) {
        final device = _device;
        return Scaffold(
          appBar: AppBar(
            title: Text(device == null ? 'Local simulator' : device.name),
            actions: <Widget>[
              IconButton(
                tooltip: 'Games',
                icon: const Icon(Icons.sports_esports),
                onPressed: _openGames,
              ),
              if (device != null)
                _buildDeviceIndicator(compact: true, simplified: true),
              IconButton(
                tooltip: 'Settings',
                icon: const Icon(Icons.settings),
                onPressed: _openSettings,
              ),
            ],
          ),
          body: Column(
            children: <Widget>[
              if (_draftReason != null)
                _DraftBar(
                  reason: _draftReason!,
                  busy: _loadingLayout,
                  onRetry: _retryLayout,
                ),
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
                  connected: _pushesToDevice,
                  bound: device != null,
                  panelWidth: device?.width ?? 0,
                  panelHeight: device?.height ?? 0,
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
        _buildDeviceIndicator(compact: compact),
        if (_device != null)
          IconButton(
            tooltip: 'Mirror',
            icon: const Icon(Icons.bluetooth_searching),
            onPressed: () => _openMirror(),
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
            const PopupMenuItem<String>(
                value: 'new', child: Text('New layout')),
            const PopupMenuItem<String>(value: 'open', child: Text('Open...')),
            const PopupMenuItem<String>(value: 'save', child: Text('Save')),
            const PopupMenuItem<String>(
                value: 'saveAs', child: Text('Save as...')),
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
            const PopupMenuItem<String>(
                value: 'settings', child: Text('Settings')),
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

/// Says that the document on screen is not what the device is showing.
///
/// A mirror reachable only over Bluetooth cannot have its layout read, and a
/// workspace that silently opened a stock preset would be claiming the panel
/// holds a layout it has never seen. The bar names the actual reason and
/// offers the retry that would replace the draft.
class _DraftBar extends StatelessWidget {
  const _DraftBar({
    required this.reason,
    required this.busy,
    required this.onRetry,
  });

  final String reason;

  /// True while a read is in flight, so Retry cannot be tapped twice.
  final bool busy;

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        child: Row(
          children: <Widget>[
            const Icon(Icons.edit_note, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Local draft — not the layout on the mirror. $reason',
                style: theme.textTheme.bodySmall,
              ),
            ),
            TextButton(
              onPressed: busy ? null : onRetry,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
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
    final colour = isError
        ? theme.colorScheme.errorContainer
        : theme.colorScheme.surfaceContainerHighest;

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
/// A preset pick is sent to the device the workspace is bound to, so the chips
/// double as a live preview of the presets on the panel itself. The local
/// simulator has no device, and every pick stays on this screen.
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
    required this.bound,
    required this.panelWidth,
    required this.panelHeight,
    required this.onPickStock,
  });

  final DesignerController controller;
  final List<StockLayout> stock;
  final String? activeStockPath;

  /// Whether a pick is also a push, which is what needs the panel size: a
  /// layout the firmware would refuse must not look like it went out.
  final bool connected;

  /// Whether a device is bound at all, which is what an empty preset list is
  /// explained by.
  final bool bound;
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
              !bound
                  ? 'No layout presets are bundled with this build.'
                  : panelWidth > 0
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
