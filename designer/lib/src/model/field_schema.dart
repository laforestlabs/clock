// Which properties the inspector shows for each widget type.
//
// This is presentation metadata only. The engine is still the authority on
// what any field does, and an unknown key set by hand in the JSON survives
// editing untouched because LayoutWidget keeps the raw map.
//
// Keep this in step with the widget draw functions in core/src/render.c. A
// field listed here that the renderer ignores is a harmless no-op; a field the
// renderer uses but that is missing here just cannot be edited in the UI.

import 'package:flutter/foundation.dart';

enum FieldKind {
  text,
  color,
  font,
  iconSet,
  bind,
  format,
  align,
  valign,
  integer,
  boolean,
}

@immutable
class FieldSpec {
  const FieldSpec(
    this.key,
    this.label,
    this.kind, {
    this.help,
    this.min,
    this.max,
  });

  final String key;
  final String label;
  final FieldKind kind;
  final String? help;
  final int? min;
  final int? max;
}

/// Fields every widget has, shown above the type-specific ones.
const List<FieldSpec> commonFields = <FieldSpec>[
  FieldSpec('id', 'ID', FieldKind.text,
      help: 'Optional name, shown in the widget list'),
  FieldSpec('color', 'Colour', FieldKind.color),
  FieldSpec('bg', 'Background', FieldKind.color,
      help: 'Leave empty for transparent'),
  FieldSpec('visible', 'Visible', FieldKind.boolean),
];

const FieldSpec _font = FieldSpec('font', 'Font', FieldKind.font);
const FieldSpec _scale = FieldSpec('scale', 'Scale', FieldKind.integer,
    min: 1,
    max: 8,
    help: 'Whole-pixel glyph scale. Ignored while Fit is on');
const FieldSpec _fit = FieldSpec('fit', 'Fit to box', FieldKind.boolean,
    help: 'Scale the text to the box height, so resizing grows it');
const FieldSpec _align = FieldSpec('align', 'Align', FieldKind.align);
const FieldSpec _valign = FieldSpec('valign', 'Vertical', FieldKind.valign);
const FieldSpec _accent = FieldSpec('accent', 'Accent', FieldKind.color,
    help: 'Secondary colour: event times, bullets, dimmed rows');
const FieldSpec _lineGap =
    FieldSpec('line_gap', 'Line gap', FieldKind.integer, min: 0, max: 16);
const FieldSpec _maxItems =
    FieldSpec('max_items', 'Max rows', FieldKind.integer, min: 0, max: 12);

const Map<String, List<FieldSpec>> _byType = <String, List<FieldSpec>>{
  'rect': <FieldSpec>[],
  'line': <FieldSpec>[],
  'text': <FieldSpec>[
    FieldSpec('text', 'Literal text', FieldKind.text,
        help: 'Used when no binding is set'),
    FieldSpec('bind', 'Binding', FieldKind.bind,
        help: 'Model path, e.g. weather.temp_c'),
    FieldSpec('format', 'Format', FieldKind.format,
        help: r'printf style, e.g. %.0f°C'),
    _font,
    _scale,
    _fit,
    _align,
    _valign,
  ],
  'clock': <FieldSpec>[
    FieldSpec('format', 'Format', FieldKind.format,
        help: r'strftime style, default %H:%M'),
    _font,
    _scale,
    _fit,
    _align,
    _valign,
  ],
  'date': <FieldSpec>[
    FieldSpec('format', 'Format', FieldKind.format,
        help: r'strftime style, default %a %e %b'),
    _font,
    _scale,
    _fit,
    _align,
    _valign,
  ],
  'weather': <FieldSpec>[
    _font,
    _scale,
    _fit,
    _accent,
    _lineGap,
    _align,
  ],
  'icon': <FieldSpec>[
    FieldSpec('icon_set', 'Icon set', FieldKind.iconSet),
    _scale,
    _fit,
    FieldSpec('bind', 'Binding', FieldKind.bind,
        help: 'Usually weather.code'),
    _align,
    _valign,
  ],
  'agenda': <FieldSpec>[
    _font,
    _scale,
    _fit,
    _accent,
    _maxItems,
    _lineGap,
    FieldSpec('show_time', 'Show times', FieldKind.boolean),
  ],
  'todo': <FieldSpec>[
    _font,
    _scale,
    _fit,
    _accent,
    _maxItems,
    _lineGap,
    FieldSpec('hide_done', 'Hide completed', FieldKind.boolean),
  ],
};

List<FieldSpec> fieldsFor(String type) =>
    _byType[type] ?? const <FieldSpec>[];

/// True when the engine knows this type. An unknown type still renders in the
/// list so the user can see and fix it, but it draws nothing on the panel.
bool isKnownType(String type) => _byType.containsKey(type);

const List<String> alignOptions = <String>['left', 'center', 'right'];
const List<String> valignOptions = <String>['top', 'middle', 'bottom'];

/// Format presets offered as one-tap chips, since remembering strftime on a
/// phone keyboard is miserable.
const Map<String, List<String>> formatPresets = <String, List<String>>{
  'clock': <String>['%H:%M', '%H:%M:%S', '%I:%M %p', '%l:%M'],
  'date': <String>['%a %e %b', '%d/%m', '%A', '%e %B', '%a %d %b %Y'],
  'text': <String>[r'%.0f', r'%.1f', r'%.0f°C', r'%d%%', r'%s'],
};
