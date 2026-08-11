// The editable layout model.
//
// Backed directly by the decoded JSON map rather than a parallel set of typed
// fields, for one specific reason: a layout may contain keys this build has
// never heard of, written by a newer designer or hand-added by the user.
// Round tripping through a strongly typed struct would silently drop them.
// Holding the raw map and exposing typed accessors over it means unknown keys
// survive an open-edit-save cycle untouched.
//
// The C engine remains the authority on what any of it means. This model only
// has to produce valid JSON.

import 'dart:convert';
import 'dart:ui' show Rect;

class LayoutDoc {
  LayoutDoc(this._raw) {
    // 'widgets' has to be a list before anything reads it. A hand-edited file
    // can carry null or an object there, and putIfAbsent would leave both in
    // place: the key exists, it is simply the wrong type. Every accessor below
    // then throws a TypeError out of a UI build rather than out of the decode,
    // so `on FormatException` at the call site never sees it.
    //
    // The C engine treats the same input as an empty widget list and renders a
    // blank canvas, and the designer matching that is what keeps a layout the
    // mirror will happily display from crashing the tool that edits it.
    final existing = _raw['widgets'];
    if (existing is! List) _raw['widgets'] = <dynamic>[];
  }

  factory LayoutDoc.decode(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('layout root must be a JSON object');
    }
    return LayoutDoc(decoded);
  }

  factory LayoutDoc.blank({int width = 128, int height = 64}) {
    return LayoutDoc(<String, dynamic>{
      'name': 'untitled',
      'canvas': <String, dynamic>{'width': width, 'height': height},
      'background': '#000000',
      'brightness': 200,
      'widgets': <dynamic>[],
    });
  }

  final Map<String, dynamic> _raw;

  Map<String, dynamic> get raw => _raw;

  /// A detached copy, used for undo snapshots.
  LayoutDoc clone() =>
      LayoutDoc(jsonDecode(jsonEncode(_raw)) as Map<String, dynamic>);

  String encode({bool pretty = true}) => pretty
      ? const JsonEncoder.withIndent('  ').convert(_raw)
      : jsonEncode(_raw);

  // ------------------------------------------------------------ properties

  String get name => (_raw['name'] as String?) ?? 'untitled';
  set name(String value) => _raw['name'] = value;

  String get background =>
      (_raw['background'] as String?) ?? (_raw['bg'] as String?) ?? '#000000';
  set background(String value) => _raw['background'] = value;

  int get brightness => _asInt(_raw['brightness']) ?? 255;
  set brightness(int value) => _raw['brightness'] = value.clamp(0, 255);

  int get width => _canvasField('width', 'w') ?? 128;
  int get height => _canvasField('height', 'h') ?? 64;

  void resize(int w, int h) {
    _raw['canvas'] = <String, dynamic>{'width': w, 'height': h};
  }

  /// Canvas may be written as an object or as a [w, h] pair. Both are accepted
  /// on read; writes always normalise to the object form.
  int? _canvasField(String long, String short) {
    final canvas = _raw['canvas'];
    if (canvas is Map) {
      return _asInt(canvas[long]) ?? _asInt(canvas[short]);
    }
    if (canvas is List && canvas.length >= 2) {
      return _asInt(long == 'width' ? canvas[0] : canvas[1]);
    }
    return _asInt(_raw[long]);
  }

  // -------------------------------------------------------------- widgets

  List<dynamic> get _widgetList => _raw['widgets'] as List<dynamic>;

  int get widgetCount => _widgetList.length;

  List<LayoutWidget> get widgets => _widgetList
      .whereType<Map<String, dynamic>>()
      .map(LayoutWidget.new)
      .toList(growable: false);

  LayoutWidget? widgetAt(int index) {
    if (index < 0 || index >= _widgetList.length) return null;
    final entry = _widgetList[index];
    return entry is Map<String, dynamic> ? LayoutWidget(entry) : null;
  }

  LayoutWidget addWidget(String type, {Rect? rect}) {
    final placed = rect ?? _findFreeSpot();
    final raw = <String, dynamic>{
      'type': type,
      'rect': <int>[
        placed.left.round(),
        placed.top.round(),
        placed.width.round(),
        placed.height.round(),
      ],
      'color': '#FFFFFF',
    };
    const textTypes = <String>{
      'text',
      'clock',
      'date',
      'weather',
      'agenda',
      'todo'
    };
    if (textTypes.contains(type)) {
      raw['font'] = 'display';
      raw['fit'] = true;
    }
    final widget = LayoutWidget(raw);
    _widgetList.add(widget.raw);
    return widget;
  }

  void removeWidget(int index) {
    if (index < 0 || index >= _widgetList.length) return;
    _widgetList.removeAt(index);
  }

  LayoutWidget duplicateWidget(int index) {
    final source = widgetAt(index);
    if (source == null) return addWidget('text');

    final copy = jsonDecode(jsonEncode(source.raw)) as Map<String, dynamic>;
    final widget = LayoutWidget(copy);

    // Offset so the duplicate is visibly separate rather than hidden exactly
    // behind the original.
    final r = widget.rect;
    widget.rect = Rect.fromLTWH(
      (r.left + 2).clamp(0.0, (width - r.width).toDouble()).toDouble(),
      (r.top + 2).clamp(0.0, (height - r.height).toDouble()).toDouble(),
      r.width,
      r.height,
    );
    if (widget.id.isNotEmpty) widget.id = '${widget.id}-copy';

    _widgetList.insert(index + 1, widget.raw);
    return widget;
  }

  /// Reorders a widget. Order is paint order, so later entries draw on top.
  void moveWidget(int from, int to) {
    if (from < 0 || from >= _widgetList.length) return;
    if (to < 0 || to >= _widgetList.length) return;
    final entry = _widgetList.removeAt(from);
    _widgetList.insert(to, entry);
  }

  /// Places a new widget in the first row that nothing else occupies, so
  /// adding several in a row does not stack them all at the origin.
  Rect _findFreeSpot() {
    const w = 40.0;
    const h = 8.0;
    for (var y = 0; y + h <= height; y += 9) {
      final candidate = Rect.fromLTWH(1, y.toDouble(), w, h);
      final clash =
          widgets.any((existing) => existing.rect.overlaps(candidate));
      if (!clash) return candidate;
    }
    return const Rect.fromLTWH(1, 1, w, h);
  }
}

/// One widget, as a view over its JSON map. Mutating an accessor writes
/// straight through to the map that the document will serialize.
class LayoutWidget {
  LayoutWidget(this.raw);

  final Map<String, dynamic> raw;

  String get type => (raw['type'] as String?) ?? '';
  set type(String value) => raw['type'] = value;

  String get id => (raw['id'] as String?) ?? '';
  set id(String value) {
    if (value.isEmpty) {
      raw.remove('id');
    } else {
      raw['id'] = value;
    }
  }

  String get label => id.isNotEmpty ? id : type;

  bool get visible => raw['visible'] as bool? ?? true;
  set visible(bool value) {
    // Only write the key when it differs from the default, to keep hand-edited
    // layouts tidy.
    if (value) {
      raw.remove('visible');
    } else {
      raw['visible'] = false;
    }
  }

  Rect get rect {
    final value = raw['rect'];
    if (value is List && value.length >= 4) {
      return Rect.fromLTWH(
        (_asInt(value[0]) ?? 0).toDouble(),
        (_asInt(value[1]) ?? 0).toDouble(),
        (_asInt(value[2]) ?? 0).toDouble(),
        (_asInt(value[3]) ?? 0).toDouble(),
      );
    }
    if (value is Map) {
      return Rect.fromLTWH(
        (_asInt(value['x']) ?? 0).toDouble(),
        (_asInt(value['y']) ?? 0).toDouble(),
        (_asInt(value['w']) ?? _asInt(value['width']) ?? 0).toDouble(),
        (_asInt(value['h']) ?? _asInt(value['height']) ?? 0).toDouble(),
      );
    }
    return Rect.zero;
  }

  set rect(Rect value) {
    // Always written as an array. The engine accepts both forms, but one
    // canonical output keeps diffs between saved layouts readable.
    raw['rect'] = <int>[
      value.left.round(),
      value.top.round(),
      value.width.round(),
      value.height.round(),
    ];
  }

  String? getString(String key) {
    final value = raw[key];
    return value is String ? value : null;
  }

  void setString(String key, String? value) {
    if (value == null || value.isEmpty) {
      raw.remove(key);
    } else {
      raw[key] = value;
    }
  }

  int? getInt(String key) => _asInt(raw[key]);

  void setInt(String key, int? value) {
    if (value == null) {
      raw.remove(key);
    } else {
      raw[key] = value;
    }
  }

  bool? getBool(String key) {
    final value = raw[key];
    if (value is bool) return value;
    if (value is num) return value != 0;
    return null;
  }

  void setBool(String key, bool? value) {
    if (value == null) {
      raw.remove(key);
    } else {
      raw[key] = value;
    }
  }
}

int? _asInt(dynamic value) {
  if (value is int) return value;
  if (value is double) return value.round();
  if (value is String) return int.tryParse(value);
  return null;
}
