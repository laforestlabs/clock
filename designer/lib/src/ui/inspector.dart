// The property inspector for the selected widget.
//
// Field lists come from field_schema.dart, but the choices inside them (fonts,
// bindable paths) are read from the engine at runtime. Adding a .font file or
// a model binding in C therefore shows up here without touching Dart.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller.dart';
import '../engine/engine.dart';
import '../model/field_schema.dart';
import '../model/layout.dart';

/// A glyph scale for display: whole multiples without a decimal point, the
/// fractions Fit derives with one.
String _formatScale(double s) =>
    s == s.roundToDouble() ? '${s.round()}' : s.toStringAsFixed(1);

class InspectorPanel extends StatelessWidget {
  const InspectorPanel({super.key, required this.controller});

  final DesignerController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final widget = controller.doc.widgetAt(controller.selected);
        if (widget == null) return _LayoutProperties(controller: controller);

        final specs = <FieldSpec>[
          ...commonFields,
          ...fieldsFor(widget.type),
        ];

        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          children: <Widget>[
            _Header(controller: controller, widget: widget),
            const SizedBox(height: 8),
            _RectEditor(controller: controller, widget: widget),
            const Divider(height: 24),
            for (final spec in specs)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _Field(
                  controller: controller,
                  widget: widget,
                  spec: spec,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.controller, required this.widget});

  final DesignerController controller;
  final LayoutWidget widget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(widget.label, style: theme.textTheme.titleMedium),
        ),
        IconButton(
          tooltip: 'Duplicate',
          icon: const Icon(Icons.copy_outlined, size: 20),
          onPressed: controller.duplicateSelected,
        ),
        IconButton(
          tooltip: 'Delete',
          icon: const Icon(Icons.delete_outline, size: 20),
          onPressed: controller.deleteSelected,
        ),
      ],
    );
  }
}

/// Position and size, plus arrow-key nudging.
///
/// Typed entry matters more than dragging here: on a 64px canvas a single
/// pixel is a meaningful amount, and dragging to an exact value is fiddly.
class _RectEditor extends StatelessWidget {
  const _RectEditor({required this.controller, required this.widget});

  final DesignerController controller;
  final LayoutWidget widget;

  @override
  Widget build(BuildContext context) {
    final r = widget.rect;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
                child: _num(context, 'X', r.left.toInt(), (v) {
              controller.setSelectedRect(
                  Rect.fromLTWH(v.toDouble(), r.top, r.width, r.height));
            })),
            const SizedBox(width: 8),
            Expanded(
                child: _num(context, 'Y', r.top.toInt(), (v) {
              controller.setSelectedRect(
                  Rect.fromLTWH(r.left, v.toDouble(), r.width, r.height));
            })),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Expanded(
                child: _num(context, 'W', r.width.toInt(), (v) {
              controller.setSelectedRect(
                  Rect.fromLTWH(r.left, r.top, v.toDouble(), r.height));
            })),
            const SizedBox(width: 8),
            Expanded(
                child: _num(context, 'H', r.height.toInt(), (v) {
              controller.setSelectedRect(
                  Rect.fromLTWH(r.left, r.top, r.width, v.toDouble()));
            })),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            _nudge(Icons.keyboard_arrow_left,
                () => controller.nudgeSelected(-1, 0)),
            Column(
              children: <Widget>[
                _nudge(Icons.keyboard_arrow_up,
                    () => controller.nudgeSelected(0, -1)),
                _nudge(Icons.keyboard_arrow_down,
                    () => controller.nudgeSelected(0, 1)),
              ],
            ),
            _nudge(Icons.keyboard_arrow_right,
                () => controller.nudgeSelected(1, 0)),
          ],
        ),
      ],
    );
  }

  Widget _nudge(IconData icon, VoidCallback onTap) => IconButton(
        visualDensity: VisualDensity.compact,
        icon: Icon(icon, size: 20),
        onPressed: onTap,
      );

  Widget _num(
    BuildContext context,
    String label,
    int value,
    ValueChanged<int> onChanged,
  ) {
    return TextFormField(
      // Keying on the value makes the field pick up changes made by dragging
      // on the canvas, which would otherwise not refresh the text.
      key: ValueKey<String>('$label$value'),
      initialValue: '$value',
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      keyboardType: TextInputType.number,
      inputFormatters: <TextInputFormatter>[
        FilteringTextInputFormatter.allow(RegExp(r'-?\d*')),
      ],
      onFieldSubmitted: (text) {
        final parsed = int.tryParse(text);
        if (parsed != null) onChanged(parsed);
      },
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.widget,
    required this.spec,
  });

  final DesignerController controller;
  final LayoutWidget widget;
  final FieldSpec spec;

  /// What the engine resolves for this widget against the current mock data:
  /// the font cut a family or Auto font lands on, and the scale Fit derives
  /// from the box. Null when the engine has not placed the widget.
  WidgetInfo? get _drawn {
    final i = controller.selected;
    final infos = controller.widgetInfo;
    return (i >= 0 && i < infos.length) ? infos[i] : null;
  }

  @override
  Widget build(BuildContext context) {
    switch (spec.kind) {
      case FieldKind.boolean:
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(spec.label),
          value: widget.getBool(spec.key) ?? _booleanDefault(spec.key),
          onChanged: (v) =>
              controller.updateSelected((w) => w.setBool(spec.key, v)),
        );

      case FieldKind.color:
        return _ColorField(
          label: spec.label,
          value: widget.getString(spec.key),
          help: spec.help,
          onChanged: (v) =>
              controller.updateSelected((w) => w.setString(spec.key, v)),
        );

      case FieldKind.font:
        final drawn = _drawn?.font ?? '';
        return _Dropdown(
          label: spec.label,
          value: widget.getString(spec.key),
          // The cut the engine actually draws with, shown when the configured
          // value leaves the choice to the engine: a family names a style, not
          // a size, and Auto font shops further. Suppressed when they agree,
          // where it would only repeat the dropdown.
          help: drawn.isNotEmpty && drawn != widget.getString(spec.key)
              ? 'Drawing $drawn'
              : null,
          // Families, not cuts: choosing a style is the user's call, choosing
          // a size is the engine's. Icon sets are excluded. They are fonts
          // only in the sense that they reuse the glyph machinery: wx maps
          // the digits onto weather pictograms, so picking it for a label
          // replaces the text with symbols. Nobody reaches for that on
          // purpose from a font menu. A layout naming an exact cut still
          // shows it, via _Dropdown's handling of unlisted values.
          options: controller.engine.families
              .where((f) => f.drawsText && f.name == 'display')
              .map((f) => f.name)
              .toList(growable: false),
          onChanged: (v) =>
              controller.updateSelected((w) => w.setString(spec.key, v)),
        );

      case FieldKind.iconSet:
        final drawnIcon = _drawn?.font ?? '';
        return _Dropdown(
          label: spec.label,
          value: widget.getString(spec.key),
          help: drawnIcon.isNotEmpty && drawnIcon != widget.getString(spec.key)
              ? 'Drawing $drawnIcon'
              : null,
          // Icon sets are fonts, so the same catalogue serves both, filtered by
          // the declared role. Height used to stand in for this, which offered
          // the clock faces as icon sets: an icon is indexed by digit, so a
          // digits cut was a valid pick that drew the numeral instead of the
          // icon.
          options: controller.engine.families
              .where((f) => f.isIconSet)
              .map((f) => f.name)
              .toList(growable: false),
          onChanged: (v) =>
              controller.updateSelected((w) => w.setString(spec.key, v)),
        );

      case FieldKind.bind:
        return _BindField(
          label: spec.label,
          help: spec.help,
          value: widget.getString(spec.key),
          options: controller.engine.bindPaths,
          onChanged: (v) =>
              controller.updateSelected((w) => w.setString(spec.key, v)),
        );

      case FieldKind.format:
        return _FormatField(
          label: spec.label,
          help: spec.help,
          value: widget.getString(spec.key),
          presets: formatPresets[widget.type] ?? const <String>[],
          onChanged: (v) =>
              controller.updateSelected((w) => w.setString(spec.key, v)),
        );

      case FieldKind.align:
      case FieldKind.valign:
        final options =
            spec.kind == FieldKind.align ? alignOptions : valignOptions;
        return _Segmented(
          label: spec.label,
          value: widget.getString(spec.key) ?? options.first,
          options: options,
          onChanged: (v) =>
              controller.updateSelected((w) => w.setString(spec.key, v)),
        );

      case FieldKind.triState:
        // A tri-state over an absent key: Auto removes it and lets the font
        // decide; the other two write it explicitly. A switch cannot say
        // this, because its off state would write false and force blocky
        // where the layout meant no opinion.
        final smooth = widget.getBool(spec.key);
        return _Segmented(
          label: spec.label,
          value: smooth == null ? 'Auto' : (smooth ? 'Smooth' : 'Blocky'),
          options: const <String>['Auto', 'Smooth', 'Blocky'],
          onChanged: (v) => controller.updateSelected(
              (w) => w.setBool(spec.key, v == 'Auto' ? null : v == 'Smooth')),
        );

      case FieldKind.integer:
        // With Fit on, the pinned scale is parked and the box decides. Show
        // the figure the engine is actually drawing at, which is what moves
        // while a resize drag grows or shrinks the box.
        final fitScale = spec.key == 'scale' && widget.getBool('fit') == true
            ? _drawn?.scale
            : null;
        return _IntField(
          label: spec.label,
          value: widget.getInt(spec.key),
          min: spec.min ?? 0,
          max: spec.max ?? 99,
          effective: fitScale != null && fitScale > 0 ? fitScale : null,
          onChanged: (v) =>
              controller.updateSelected((w) => w.setInt(spec.key, v)),
        );

      case FieldKind.text:
        return _TextField(
          label: spec.label,
          help: spec.help,
          value: spec.key == 'id' ? widget.id : widget.getString(spec.key),
          onChanged: (v) => controller.updateSelected((w) {
            if (spec.key == 'id') {
              w.id = v ?? '';
            } else {
              w.setString(spec.key, v);
            }
          }),
        );
    }
  }

  /// Defaults mirror widget_defaults() in core/src/layout_json.c, so an unset
  /// switch shows the state the renderer will actually use.
  bool _booleanDefault(String key) {
    switch (key) {
      case 'show_time':
      case 'hide_done':
        return true;
      default:
        return false;
    }
  }
}

class _TextField extends StatelessWidget {
  const _TextField({
    required this.label,
    required this.value,
    required this.onChanged,
    this.help,
  });

  final String label;
  final String? value;
  final String? help;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      key: ValueKey<String>('$label${value ?? ""}'),
      initialValue: value ?? '',
      decoration: InputDecoration(
        labelText: label,
        helperText: help,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      onFieldSubmitted: onChanged,
    );
  }
}

class _IntField extends StatelessWidget {
  const _IntField({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.effective,
  });

  final String label;
  final int? value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  /// What the engine actually draws at when the slider's value is parked:
  /// Fit derives the scale from the box, so the live figure is what matters.
  final double? effective;

  @override
  Widget build(BuildContext context) {
    final current = (value ?? min).clamp(min, max);
    final eff = effective;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          eff != null
              ? '$label: ${_formatScale(eff)} (fit)'
              : '$label: $current',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Slider(
          value: current.toDouble(),
          min: min.toDouble(),
          max: max.toDouble(),
          divisions: (max - min).clamp(1, 100),
          label: '$current',
          onChanged: (v) => onChanged(v.round()),
        ),
      ],
    );
  }
}

class _Dropdown extends StatelessWidget {
  const _Dropdown({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.help,
  });

  final String label;
  final String? value;
  final List<String> options;
  final ValueChanged<String?> onChanged;
  final String? help;

  @override
  Widget build(BuildContext context) {
    // A value not in the list (hand-edited, or a font this build lacks) must
    // still display rather than throwing.
    final items = <String>[
      if (value != null && value!.isNotEmpty && !options.contains(value))
        value!,
      ...options,
    ];

    return DropdownButtonFormField<String>(
      initialValue: value?.isNotEmpty == true ? value : null,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        helperText: help,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      items: <DropdownMenuItem<String>>[
        const DropdownMenuItem<String>(child: Text('(default)')),
        ...items.map(
          (o) => DropdownMenuItem<String>(value: o, child: Text(o)),
        ),
      ],
      onChanged: onChanged,
    );
  }
}

class _Segmented extends StatelessWidget {
  const _Segmented({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: options
              .map((o) => ButtonSegment<String>(value: o, label: Text(o)))
              .toList(growable: false),
          selected: <String>{options.contains(value) ? value : options.first},
          onSelectionChanged: (s) => onChanged(s.first),
        ),
      ],
    );
  }
}

class _ColorField extends StatelessWidget {
  const _ColorField({
    required this.label,
    required this.value,
    required this.onChanged,
    this.help,
  });

  final String label;
  final String? value;
  final String? help;
  final ValueChanged<String?> onChanged;

  /// Palette chosen to stay legible through a two-way mirror: saturated and
  /// bright, with no mid greys, which vanish at 20 percent transmission.
  static const List<String> _swatches = <String>[
    '#FFFFFF',
    '#00E5FF',
    '#66D9EF',
    '#FF9F43',
    '#FFC24D',
    '#E06C5A',
    '#5AA0E0',
    '#A0E060',
    '#8899AA',
    '#1E2A33',
  ];

  Color? get _parsed {
    final v = value;
    if (v == null || v.isEmpty) return null;
    final hex = v.startsWith('#') ? v.substring(1) : v;
    if (hex.length != 6) return null;
    final n = int.tryParse(hex, radix: 16);
    return n == null ? null : Color(0xFF000000 | n);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: _parsed ?? Colors.transparent,
                border: Border.all(color: Colors.white24),
                borderRadius: BorderRadius.circular(4),
              ),
              child: _parsed == null
                  ? const Icon(Icons.clear, size: 14, color: Colors.white38)
                  : null,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextFormField(
                key: ValueKey<String>('$label${value ?? ""}'),
                initialValue: value ?? '',
                decoration: InputDecoration(
                  labelText: label,
                  helperText: help,
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                onFieldSubmitted: onChanged,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: _swatches
              .map(
                (hex) => InkWell(
                  onTap: () => onChanged(hex),
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: Color(
                          0xFF000000 | int.parse(hex.substring(1), radix: 16)),
                      border: Border.all(color: Colors.white24),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              )
              .toList(growable: false),
        ),
      ],
    );
  }
}

class _BindField extends StatelessWidget {
  const _BindField({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.help,
  });

  final String label;
  final String? value;
  final String? help;
  final List<String> options;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        TextFormField(
          key: ValueKey<String>('$label${value ?? ""}'),
          initialValue: value ?? '',
          decoration: InputDecoration(
            labelText: label,
            helperText: help,
            isDense: true,
            border: const OutlineInputBorder(),
            suffixIcon: PopupMenuButton<String>(
              icon: const Icon(Icons.list, size: 18),
              tooltip: 'Bindable paths',
              onSelected: onChanged,
              itemBuilder: (context) => options
                  .map((p) => PopupMenuItem<String>(value: p, child: Text(p)))
                  .toList(growable: false),
            ),
          ),
          onFieldSubmitted: onChanged,
        ),
      ],
    );
  }
}

class _FormatField extends StatelessWidget {
  const _FormatField({
    required this.label,
    required this.value,
    required this.presets,
    required this.onChanged,
    this.help,
  });

  final String label;
  final String? value;
  final String? help;
  final List<String> presets;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        TextFormField(
          key: ValueKey<String>('$label${value ?? ""}'),
          initialValue: value ?? '',
          decoration: InputDecoration(
            labelText: label,
            helperText: help,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          onFieldSubmitted: onChanged,
        ),
        if (presets.isNotEmpty) ...<Widget>[
          const SizedBox(height: 6),
          // Tapping a preset beats typing strftime on a phone keyboard.
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: presets
                .map(
                  (p) => ActionChip(
                    visualDensity: VisualDensity.compact,
                    label: Text(p, style: const TextStyle(fontSize: 11)),
                    onPressed: () => onChanged(p),
                  ),
                )
                .toList(growable: false),
          ),
        ],
      ],
    );
  }
}

/// Shown when nothing is selected: the layout's own properties.
class _LayoutProperties extends StatelessWidget {
  const _LayoutProperties({required this.controller});

  final DesignerController controller;

  static const List<({String label, int w, int h})> _presets =
      <({String label, int w, int h})>[
    (label: '64x64 (1 panel)', w: 64, h: 64),
    (label: '128x64 (2 panels)', w: 128, h: 64),
    (label: '128x128 (4 panels)', w: 128, h: 128),
    (label: '192x64 (3 panels)', w: 192, h: 64),
  ];

  @override
  Widget build(BuildContext context) {
    final doc = controller.doc;
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: <Widget>[
        Text('Layout', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text('Select a widget to edit it, or change the canvas below.',
            style: theme.textTheme.bodySmall),
        const SizedBox(height: 16),
        TextFormField(
          key: ValueKey<String>('name${doc.name}'),
          initialValue: doc.name,
          decoration: const InputDecoration(
            labelText: 'Name',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onFieldSubmitted: (v) {
            doc.name = v;
            controller.refresh();
          },
        ),
        const SizedBox(height: 16),
        Text('Canvas', style: theme.textTheme.bodySmall),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: _presets
              .map(
                (p) => ChoiceChip(
                  label: Text(p.label, style: const TextStyle(fontSize: 11)),
                  selected: doc.width == p.w && doc.height == p.h,
                  onSelected: (_) {
                    doc.resize(p.w, p.h);
                    controller.refresh();
                  },
                ),
              )
              .toList(growable: false),
        ),
        const SizedBox(height: 16),
        _ColorField(
          label: 'Background',
          value: doc.background,
          onChanged: (v) {
            doc.background = v ?? '#000000';
            controller.refresh();
          },
        ),
        const SizedBox(height: 16),
        Text('Panel brightness: ${doc.brightness}',
            style: theme.textTheme.bodySmall),
        Slider(
          value: doc.brightness.toDouble(),
          min: 0,
          max: 255,
          divisions: 51,
          label: '${doc.brightness}',
          onChanged: (v) {
            doc.brightness = v.round();
            controller.refresh();
          },
        ),
        Text(
          'Applied on device before gamma, so this is a real hardware setting '
          'and not a preview effect.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}
