// The workspace.
//
// Two arrangements from one widget tree: side by side on a desktop, stacked
// with tabs on a phone. The preview is always visible in both, because the
// point of the app is watching the panel change as you edit.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller.dart';
import '../engine/engine.dart';
import '../services/layout_repository.dart';
import 'inspector.dart';
import 'mirror_screen.dart';
import 'panel_view.dart';
import 'game_screen.dart';
import 'widget_list.dart';
const double _wideBreakpoint = 900;

class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({super.key, required this.engine});

  final MirrorEngine engine;

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen> {
  late final DesignerController _c = DesignerController(widget.engine);
  final LayoutRepository _repo = LayoutRepository();
  final FocusNode _keyboardFocus = FocusNode();

  List<StockLayout> _stock = const <StockLayout>[];

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final stock = await _repo.stockLayouts();
    if (!mounted) return;
    setState(() => _stock = stock);

    // Open the 64x32 clock and weather layout by default, since a single
    // P2.5-64x32 panel is the reference build. Written as a loop rather than
    // firstOrNull, which lives in package:collection and is not part of the
    // core library.
    StockLayout? preferred;
    for (final s in stock) {
      if (s.name == 'mini') {
        preferred = s;
        break;
      }
    }
    preferred ??= stock.isNotEmpty ? stock.first : null;

    if (preferred != null) {
      await _c.loadJson(await _repo.loadAsset(preferred.assetPath));
    } else {
      await _c.newLayout();
    }
  }

  @override
  void dispose() {
    _keyboardFocus.dispose();
    _c.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ file

  Future<void> _open() async {
    final picked = await _repo.openFile();
    if (picked == null) return;
    await _c.loadJson(picked.json, path: picked.path);
  }

  Future<void> _save({bool forceAs = false}) async {
    final contents = _c.exportJson();
    final path = _c.sourcePath;

    if (!forceAs && path != null) {
      final ok = await _repo.saveTo(path, contents);
      if (ok) {
        _c.markSaved(path);
        _toast('Saved to $path');
        return;
      }
      // Fall through to Save As when the original path is not writable, which
      // is the normal case for a layout opened from bundled assets.
    }

    final chosen = await _repo.saveAs(_c.doc.name, contents);
    if (chosen == null) return;
    _c.markSaved(chosen);
    _toast('Saved to $chosen');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _openStock(StockLayout layout) async {
    await _c.loadJson(await _repo.loadAsset(layout.assetPath));
    _toast('Opened ${layout.name}');
  }

  // -------------------------------------------------------------- keyboard

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final shift = HardwareKeyboard.instance.isShiftPressed;
    final control = HardwareKeyboard.instance.isControlPressed;
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

    if (HardwareKeyboard.instance.isControlPressed) {
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
    return Focus(
      focusNode: _keyboardFocus,
      onKeyEvent: _onKey,
      autofocus: true,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          return Scaffold(
            appBar: _buildAppBar(),
            body: Column(
              children: <Widget>[
                _ViewToolbar(controller: _c),
                const Divider(height: 1),
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

  PreferredSizeWidget _buildAppBar() {
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
        AddWidgetButton(controller: _c),
        IconButton(
          tooltip: 'Games',
          icon: const Icon(Icons.sports_esports),
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => GameScreen(controller: _c),
              ),
            );
          },
        ),
        IconButton(
          tooltip: 'Mirror',
          icon: const Icon(Icons.bluetooth_searching),
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => MirrorScreen(controller: _c),
              ),
            );
          },
        ),
        PopupMenuButton<String>(
          onSelected: (choice) {
            // Explicit breaks: implicit fallthrough rules differ across Dart
            // versions, and this costs nothing to be unambiguous about.
            switch (choice) {
              case 'new':
                _c.newLayout();
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
            if (_stock.isNotEmpty) const PopupMenuDivider(),
            for (final s in _stock)
              PopupMenuItem<String>(
                value: s.assetPath,
                child: Text('Stock: ${s.name}'),
              ),
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
  const _CanvasArea({required this.controller});

  final DesignerController controller;

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
        child: PanelView(controller: controller),
      ),
    );
  }
}

/// Preview controls. None of these change the layout; they change how it is
/// being looked at. The exception is brightness, which is a real device
/// setting and is applied by the engine.
class _ViewToolbar extends StatelessWidget {
  const _ViewToolbar({required this.controller});

  final DesignerController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: <Widget>[
            Text('Data', style: theme.textTheme.bodySmall),
            const SizedBox(width: 8),
            SegmentedButton<int>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: <ButtonSegment<int>>[
                for (var i = 0; i < controller.engine.variants.length; i++)
                  ButtonSegment<int>(
                    value: i,
                    label: Text(
                      controller.engine.variants[i],
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
              ],
              selected: <int>{controller.variant},
              onSelectionChanged: (s) => controller.setVariant(s.first),
            ),
            const SizedBox(width: 20),

            IconButton(
              tooltip: 'Zoom out',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.zoom_out),
              onPressed: () => controller.zoom = controller.zoom - 1,
            ),
            Text('${controller.zoom.toInt()}x',
                style: theme.textTheme.bodySmall),
            IconButton(
              tooltip: 'Zoom in',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.zoom_in),
              onPressed: () => controller.zoom = controller.zoom + 1,
            ),
            IconButton(
              tooltip: 'Fit to window',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.fit_screen),
              // Greyed out while the zoom is already following the window,
              // which doubles as the indicator for which mode is active.
              onPressed:
                  controller.zoomFitsWindow ? null : controller.fitToWindow,
            ),

            const SizedBox(width: 12),
            IconButton(
              tooltip: 'Show discrete LED pixels',
              visualDensity: VisualDensity.compact,
              isSelected: controller.ledPixels,
              icon: const Icon(Icons.grid_on_outlined),
              selectedIcon: const Icon(Icons.grid_on),
              onPressed: () => controller.ledPixels = !controller.ledPixels,
            ),

            const SizedBox(width: 12),
            Tooltip(
              message: 'Simulates diffusion through a wood veneer face.\n'
                  'Thicker veneer spreads each pixel\'s light into the gaps.',
              child: Row(
                children: <Widget>[
                  const Icon(Icons.blur_on, size: 18),
                  const SizedBox(width: 4),
                  Text('Veneer ${controller.veneer.toInt()}%',
                      style: theme.textTheme.bodySmall),
                  SizedBox(
                    width: 130,
                    child: Slider(
                      value: controller.veneer,
                      min: 0,
                      max: 100,
                      onChanged: (v) => controller.veneer = v,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
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
