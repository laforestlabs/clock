// The window: the font catalogue on the left, the simulated panel in the
// middle, the glyph being edited on the right.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../designer_state.dart';
import '../frame.dart';
import '../panel.dart';
import '../repo.dart';
import 'glyph_inspector.dart';
import 'panel_view.dart';

class FontDesignerApp extends StatefulWidget {
  const FontDesignerApp({super.key});

  @override
  State<FontDesignerApp> createState() => _FontDesignerAppState();
}

class _FontDesignerAppState extends State<FontDesignerApp> {
  final DesignerState state = DesignerState();
  bool _ready = false;
  bool _found = false;

  /// The path offered when no checkout was found, filled in with the likeliest
  /// guess so the common case is one keystroke.
  late final TextEditingController _rootField =
      TextEditingController(text: Directory.current.path);

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final found = await state.restore();
    if (!mounted) return;
    setState(() {
      _found = found;
      _ready = true;
    });
  }

  @override
  void dispose() {
    state.dispose();
    _rootField.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Font Designer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4FC3F7),
          brightness: Brightness.dark,
        ),
      ),
      home: !_ready
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : _found
              ? Workspace(state: state)
              : _RootPicker(
                  controller: _rootField,
                  onOpen: (path) async {
                    await state.open(path);
                    if (mounted) setState(() => _found = true);
                  },
                ),
    );
  }
}

/// Shown when the checkout could not be found by walking up from the working
/// directory: the tool has to be pointed at one rather than guess.
class _RootPicker extends StatelessWidget {
  const _RootPicker({required this.controller, required this.onOpen});

  final TextEditingController controller;
  final Future<void> Function(String path) onOpen;

  @override
  Widget build(BuildContext context) {
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
                Text('Where is the checkout?',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                const Text(
                  'Font Designer edits fonts/*.font and runs tools/fontgen.py, '
                  'so it needs the repository root. It looks for one by walking '
                  'up from the working directory, and found none.',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    labelText: 'Repository root',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: onOpen,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => onOpen(controller.text.trim()),
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Open'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class Workspace extends StatefulWidget {
  const Workspace({super.key, required this.state});

  final DesignerState state;

  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> {
  double editorZoom = 18;
  String filter = '';

  DesignerState get state => widget.state;

  @override
  void initState() {
    super.initState();
    // A cut is generated art that a person is touching up by hand, so losing
    // an unsaved pixel is the worst thing this tool could do. Closing the
    // window is one of the two ways to lose them.
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        if (!state.dirty) return ui.AppExitResponse.exit;
        final choice = await _askAboutUnsaved('before closing');
        if (choice == 'save') await state.save();
        return choice == null || choice == 'cancel'
            ? ui.AppExitResponse.cancel
            : ui.AppExitResponse.exit;
      },
    );
  }

  late final AppLifecycleListener _lifecycle;

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  /// Asks what to do about unsaved pixels. Returns 'save', 'discard', or null
  /// when the user cancelled.
  Future<String?> _askAboutUnsaved(String when) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${state.font?.path} has unsaved pixels'),
        content: Text('Save them $when?'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'discard'),
            child: const Text('Discard'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'save'),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    return choice;
  }

  /// Discarding everything is the one action here with no way back, so it is
  /// the one that asks.
  Future<void> _revert() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Discard the changes to ${state.font?.path}?'),
        content: const Text(
            'Every edited glyph in this font goes back to what the file has. '
            'The file itself is not touched.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep them'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (ok ?? false) state.revertAll();
  }

  /// Anything that would throw away unsaved pixels asks first.
  Future<void> _guarded(Future<void> Function() action) async {
    if (!state.dirty) {
      await action();
      return;
    }
    final choice = await _askAboutUnsaved('before moving on');
    if (choice == null || choice == 'cancel') return;
    if (choice == 'save') await state.save();
    await action();
  }

  @override
  Widget build(BuildContext context) {
    // The workspace owns its subscription: every control it builds reads the
    // state, so a change anywhere has to rebuild all of it, and a caller that
    // pumps this widget on its own gets the same behaviour as the app does.
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: <Widget>[
            const Flexible(
              child: Text('Font Designer', overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 12),
            if (state.font != null)
              Flexible(
                flex: 2,
                child: Text(
                  state.font!.path,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
        actions: <Widget>[
          IconButton(
            tooltip: 'Undo',
            onPressed: state.canUndo ? state.undo : null,
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            tooltip: 'Redo',
            onPressed: state.canRedo ? state.redo : null,
            icon: const Icon(Icons.redo),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: state.dirty ? _revert : null,
            icon: const Icon(Icons.settings_backup_restore),
            label: const Text('Revert'),
          ),
          FilledButton.icon(
            onPressed: state.dirty ? state.saveAndRegenerate : null,
            icon: const Icon(Icons.save),
            label: const Text('Save + build'),
          ),
          IconButton(
            tooltip: 'Regenerate the C tables (tools/fontgen.py)',
            onPressed: state.busy ? null : state.regenerate,
            icon: const Icon(Icons.build_circle_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SizedBox(
                  width: 268,
                  child: _Sidebar(
                    state: state,
                    filter: filter,
                    onFilter: (value) => setState(() => filter = value),
                    onSelect: (ref) => _guarded(() => state.selectFont(ref)),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: _PreviewArea(state: state)),
                const VerticalDivider(width: 1),
                SizedBox(
                  width: 344,
                  child: _Inspector(
                    state: state,
                    zoom: editorZoom,
                    onZoom: (value) => setState(() => editorZoom = value),
                  ),
                ),
              ],
            ),
          ),
          _StatusBar(state: state),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------- sidebar

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.state,
    required this.filter,
    required this.onFilter,
    required this.onSelect,
  });

  final DesignerState state;
  final String filter;
  final ValueChanged<String> onFilter;
  final ValueChanged<FontRef> onSelect;

  @override
  Widget build(BuildContext context) {
    final needle = filter.trim().toLowerCase();
    final matches = state.refs
        .where((r) => needle.isEmpty || r.name.toLowerCase().contains(needle))
        .toList();

    final groups = <String, List<FontRef>>{};
    for (final ref in matches) {
      groups.putIfAbsent(ref.group, () => <FontRef>[]).add(ref);
    }

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: TextField(
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 18),
              hintText: 'Filter fonts',
              border: OutlineInputBorder(),
            ),
            onChanged: onFilter,
          ),
        ),
        Expanded(
          flex: 3,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: <Widget>[
              for (final entry in groups.entries) ...<Widget>[
                _GroupHeader(entry.key),
                for (final ref in entry.value)
                  ListTile(
                    dense: true,
                    selected: state.font?.path == ref.path,
                    title: Text(ref.name),
                    onTap: () => onSelect(ref),
                  ),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          flex: 4,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
            child: _PanelControls(state: state),
          ),
        ),
      ],
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
        child: Text(
          label.toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                letterSpacing: 0.8,
                color: Theme.of(context).colorScheme.primary,
              ),
        ),
      );
}

/// The simulated hardware. Defaults are the panel this product ships: 64x32 at
/// P2.5 with half the pitch left dark.
class _PanelControls extends StatelessWidget {
  const _PanelControls({required this.state});

  final DesignerState state;

  @override
  Widget build(BuildContext context) {
    final panel = state.panel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const _GroupHeader('Panel'),
        _NumberRow(
          label: 'Columns',
          value: panel.columns,
          min: 8,
          max: 256,
          onChanged: (v) => state.setPanel(panel.copyWith(columns: v)),
        ),
        _NumberRow(
          label: 'Rows',
          value: panel.rows,
          min: 4,
          max: 128,
          onChanged: (v) => state.setPanel(panel.copyWith(rows: v)),
        ),
        _SliderRow(
          label: 'Pitch',
          value: panel.pitchMm,
          min: 1,
          max: 10,
          divisions: 18,
          display: 'P${panel.pitchMm.toStringAsFixed(1)}mm',
          onChanged: (v) => state.setPanel(panel.copyWith(pitchMm: v)),
        ),
        _SliderRow(
          label: 'Dead space',
          value: panel.gapShare,
          min: 0,
          max: 0.8,
          divisions: 16,
          display: '${(panel.gapShare * 100).round()}% of pitch',
          onChanged: (v) => state.setPanel(panel.copyWith(gapShare: v)),
        ),
        _SliderRow(
          label: 'Brightness',
          value: panel.brightness.toDouble(),
          min: 0,
          max: 255,
          divisions: 255,
          display: '${panel.brightness} / 255',
          onChanged: (v) => state.setPanel(panel.copyWith(brightness: v.round())),
        ),
        _SliderRow(
          label: 'Eye distance',
          value: panel.distanceM,
          min: 0.3,
          max: 6,
          divisions: 57,
          display: '${panel.distanceM.toStringAsFixed(1)} m',
          onChanged: (v) => state.setPanel(panel.copyWith(distanceM: v)),
        ),
        const SizedBox(height: 4),
        Row(
          children: <Widget>[
            const SizedBox(width: 76, child: Text('Emitter')),
            Expanded(
              child: SegmentedButton<EmitterShape>(
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                segments: const <ButtonSegment<EmitterShape>>[
                  ButtonSegment(
                      value: EmitterShape.round, label: Text('Round')),
                  ButtonSegment(
                      value: EmitterShape.square, label: Text('Square')),
                ],
                selected: <EmitterShape>{panel.shape},
                onSelectionChanged: (selection) =>
                    state.setPanel(panel.copyWith(shape: selection.first)),
              ),
            ),
          ],
        ),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Outline unlit cells'),
          value: state.showOutlines,
          onChanged: state.setShowOutlines,
        ),
        const SizedBox(height: 4),
        Text(
          panel.summary,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _NumberRow extends StatelessWidget {
  const _NumberRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        SizedBox(width: 76, child: Text(label)),
        Expanded(
          child: Slider(
            value: value.toDouble().clamp(min.toDouble(), max.toDouble()),
            min: min.toDouble(),
            max: max.toDouble(),
            divisions: max - min,
            label: '$value',
            onChanged: (v) => onChanged(v.round()),
          ),
        ),
        SizedBox(
          width: 40,
          child: Text('$value', textAlign: TextAlign.right),
        ),
      ],
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 8),
            Text(display,
                textAlign: TextAlign.right,
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------- preview

class _PreviewArea extends StatelessWidget {
  const _PreviewArea({required this.state});

  final DesignerState state;

  @override
  Widget build(BuildContext context) {
    final font = state.font;
    if (font == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            state.error ?? 'Choose a font.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      );
    }

    final isSheet = state.mode == PreviewMode.sheet;
    final pages = isSheet ? state.sheetPages : const <SheetPage>[];
    final page = isSheet ? state.currentSheetPage : null;
    final frame = isSheet && page != null
        ? sheetFrame(font, state.panel, page, rgb: state.colour)
        : textFrame(font, state.panel, state.sample,
            scale: state.scale, rgb: state.colour);

    return Column(
      children: <Widget>[
        // Two lines, and the first one scrolls sideways: the controls here are
        // a fixed width each, so at a narrow window a single row would either
        // overflow or squeeze the sample field to nothing.
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Row(
            children: <Widget>[
              SegmentedButton<PreviewMode>(
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                segments: const <ButtonSegment<PreviewMode>>[
                  ButtonSegment(
                      value: PreviewMode.text,
                      label: Text('Text'),
                      icon: Icon(Icons.text_fields)),
                  ButtonSegment(
                      value: PreviewMode.sheet,
                      label: Text('Character sheet'),
                      icon: Icon(Icons.grid_on)),
                ],
                selected: <PreviewMode>{state.mode},
                onSelectionChanged: (selection) =>
                    state.setMode(selection.first),
              ),
              if (isSheet) ...<Widget>[
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Previous page',
                  onPressed: state.sheetPage > 0
                      ? () => state.setSheetPage(state.sheetPage - 1)
                      : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                Text('Page ${state.sheetPage + 1} of ${pages.length}'),
                IconButton(
                  tooltip: 'Next page',
                  onPressed: state.sheetPage < pages.length - 1
                      ? () => state.setSheetPage(state.sheetPage + 1)
                      : null,
                  icon: const Icon(Icons.chevron_right),
                ),
              ] else ...<Widget>[
                const SizedBox(width: 16),
                _ScaleControl(state: state),
              ],
              const SizedBox(width: 16),
              _ColourControl(state: state),
            ],
          ),
        ),
        if (!isSheet)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: TextFormField(
              key: const ValueKey<String>('sample'),
              initialValue: state.sample,
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'Sample text',
                border: OutlineInputBorder(),
              ),
              onChanged: state.setSample,
            ),
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final room = Size(constraints.maxWidth, constraints.maxHeight);
              final zoom = state.zoomFor(
                  Size(room.width - 16, room.height - 16));
              final panelWidget = CustomPaint(
                painter: PanelPainter(
                  frame: frame,
                  spec: state.panel,
                  zoom: zoom,
                  showOutlines: state.showOutlines,
                ),
                size: Size.infinite,
              );
              // The eye's own blur, at this zoom. Small at arm's length and
              // real across a room, which is the whole reason the pitch and
              // the viewing distance are inputs.
              final blur = state.panel.eyeBlurCells * zoom;
              final blurred = blur < 0.05
                  ? panelWidget
                  : ImageFiltered(
                      imageFilter: ui.ImageFilter.blur(
                        sigmaX: blur,
                        sigmaY: blur,
                        tileMode: TileMode.decal,
                      ),
                      child: panelWidget,
                    );
              return Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  blurred,
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 6,
                    child: Center(child: _PreviewCaption(state: state, isSheet: isSheet)),
                  ),
                ],
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
          child: Row(
            children: <Widget>[
              const Text('Zoom'),
              Expanded(
                child: Slider(
                  value: state.pinnedZoom ?? 0,
                  min: 0,
                  max: 40,
                  divisions: 40,
                  label: state.pinnedZoom == null
                      ? 'fit'
                      : state.pinnedZoom!.toStringAsFixed(0),
                  onChanged: (v) => state.setZoom(v == 0 ? null : v),
                ),
              ),
              TextButton(
                onPressed: () => state.setZoom(null),
                child: const Text('Fit'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PreviewCaption extends StatelessWidget {
  const _PreviewCaption({required this.state, required this.isSheet});

  final DesignerState state;
  final bool isSheet;

  @override
  Widget build(BuildContext context) {
    final font = state.font;
    if (font == null) return const SizedBox.shrink();
    final page = state.currentSheetPage;
    final over = !isSheet && state.sampleWidth > state.panel.columns;
    final text = isSheet
        ? '${page?.placed.length ?? 0} of ${font.glyphs.length} glyphs'
            ' on this page · cell ${font.height}px'
        : over
            ? 'Ink ${state.sampleWidth}px — ${state.sampleWidth - state.panel.columns}'
                'px past the ${state.panel.columns}px panel, which clips it'
            : 'Ink ${state.sampleWidth}px · cell ${font.height}\u00d7'
                '${font.height} at \u00d7${state.scale}';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xCC000000),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: over ? Theme.of(context).colorScheme.error : null,
              ),
        ),
      ),
    );
  }
}

class _ScaleControl extends StatelessWidget {
  const _ScaleControl({required this.state});

  final DesignerState state;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        const Text('Scale'),
        IconButton(
          onPressed: state.scale > 1 ? () => state.setScale(state.scale - 1) : null,
          icon: const Icon(Icons.remove),
          visualDensity: VisualDensity.compact,
        ),
        Text('\u00d7${state.scale}'),
        IconButton(
          onPressed: state.scale < 8 ? () => state.setScale(state.scale + 1) : null,
          icon: const Icon(Icons.add),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}

class _ColourControl extends StatelessWidget {
  const _ColourControl({required this.state});

  final DesignerState state;

  static const List<(String, int)> _swatches = <(String, int)>[
    ('White', 0xFFFFFF),
    ('Amber', 0xFFB300),
    ('Red', 0xFF3B30),
    ('Green', 0x34C759),
    ('Blue', 0x4FC3F7),
    ('Grey 50%', 0x808080),
  ];

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: 'Ink colour',
      onSelected: state.setColour,
      itemBuilder: (context) => <PopupMenuEntry<int>>[
        for (final (label, value) in _swatches)
          PopupMenuItem<int>(
            value: value,
            child: Row(
              children: <Widget>[
                Container(width: 14, height: 14, color: Color(0xFF000000 | value)),
                const SizedBox(width: 8),
                Text(label),
              ],
            ),
          ),
      ],
      child: Row(
        children: <Widget>[
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: Color(0xFF000000 | state.colour),
              border: Border.all(color: const Color(0x55FFFFFF)),
            ),
          ),
          const SizedBox(width: 6),
          const Text('Ink'),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------- inspector

class _Inspector extends StatelessWidget {
  const _Inspector({
    required this.state,
    required this.zoom,
    required this.onZoom,
  });

  final DesignerState state;
  final double zoom;
  final ValueChanged<double> onZoom;

  @override
  Widget build(BuildContext context) {
    final font = state.font;
    final glyph = state.glyph;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Text(
            font == null ? 'Glyphs' : font.summary,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        SizedBox(
          height: 154,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: GlyphStrip(state: state),
          ),
        ),
        const Divider(height: 1),
        if (glyph == null)
          const Expanded(
            child: Center(child: Text('No glyph.')),
          )
        else ...<Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: <Widget>[
                Text(
                  '${glyph.label}  ·  ${glyph.codepoint}  ·  '
                  '${glyph.width}\u00d7${glyph.rows.length}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const Spacer(),
                if (glyph.dirty)
                  Text('edited',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.tertiary)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Row(
              children: <Widget>[
                const Text('Paint'),
                const SizedBox(width: 8),
                for (final ink in font!.inkChars)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: ChoiceChip(
                      label: Text(ink),
                      selected: state.paintInk == ink,
                      onSelected: (_) => state.setPaintInk(ink),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                const Spacer(),
                Text('zoom ${zoom.toStringAsFixed(0)}'),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
            child: Slider(
              value: zoom,
              min: 6,
              max: 40,
              divisions: 34,
              onChanged: onZoom,
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: GlyphEditor(state: state, zoom: zoom),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: <Widget>[
                _ToolButton(
                  icon: Icons.west,
                  label: 'Shift left',
                  onPressed: () => state.shiftGlyph(-1),
                ),
                _ToolButton(
                  icon: Icons.east,
                  label: 'Shift right',
                  onPressed: () => state.shiftGlyph(1),
                ),
                _ToolButton(
                  icon: Icons.add_box_outlined,
                  label: 'Insert column',
                  onPressed: () => state.insertColumn(state.cursorColumn),
                ),
                _ToolButton(
                  icon: Icons.indeterminate_check_box_outlined,
                  label: 'Delete column',
                  onPressed: () => state.deleteColumn(state.cursorColumn),
                ),
                _ToolButton(
                  icon: Icons.clear,
                  label: 'Clear',
                  onPressed: state.clearGlyph,
                ),
                _ToolButton(
                  icon: Icons.settings_backup_restore,
                  label: 'Revert glyph',
                  onPressed: glyph.dirty ? state.revertGlyph : null,
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: label,
        child: IconButton.filledTonal(
          onPressed: onPressed,
          icon: Icon(icon),
          visualDensity: VisualDensity.compact,
        ),
      );
}

// ---------------------------------------------------------------- status bar

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.state});

  final DesignerState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 30,
      decoration: const BoxDecoration(
        color: Color(0xFF101317),
        border: Border(top: BorderSide(color: Color(0x22FFFFFF))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: <Widget>[
          if (state.busy)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          Expanded(
            child: Text(
              state.status ?? (state.repo?.root ?? ''),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (state.dirty)
            _Chip('unsaved pixels', scheme.tertiary),
          if (state.stale)
            _Chip('C tables behind the sources — regenerate', scheme.error),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.label, this.colour);

  final String label;
  final Color colour;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            border: Border.all(color: colour),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(label, style: TextStyle(color: colour, fontSize: 11)),
        ),
      );
}
