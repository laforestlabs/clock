// Application state.
//
// The render pipeline is deliberately dumb: any change to the layout is
// serialized to JSON, handed to the C engine, and re-rendered. At 128x64 that
// is 8192 pixels, so a full round trip costs well under a millisecond and
// there is no incremental-update machinery to get wrong.
//
// It also means the preview always reflects what the engine actually parsed,
// including anything it chose to ignore or warn about, rather than what Dart
// thinks it wrote.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'engine/engine.dart';
import 'model/layout.dart';

class DesignerController extends ChangeNotifier {
  DesignerController(this._engine);

  final MirrorEngine _engine;
  MirrorEngine get engine => _engine;

  LayoutDoc _doc = LayoutDoc.blank();
  LayoutDoc get doc => _doc;

  ui.Image? _image;
  ui.Image? get image => _image;

  int _selected = -1;
  int get selected => _selected;

  String? _sourcePath;
  String? get sourcePath => _sourcePath;

  bool _dirty = false;
  bool get dirty => _dirty;

  int _variant = 0;
  int get variant => _variant;

  int? _brightnessOverride;
  int? get brightnessOverride => _brightnessOverride;

  /// Two-way mirror transmission as a percentage. Applied by the view as a
  /// colour filter, never by the engine, because it simulates glass in front
  /// of the panel rather than anything the panel does.
  double _transmission = 100;
  double get transmission => _transmission;
  set transmission(double value) {
    _transmission = value.clamp(5, 100);
    notifyListeners();
  }

  double _zoom = 6;
  double get zoom => _zoom;
  set zoom(double value) {
    _zoom = value.clamp(1, 24);
    notifyListeners();
  }

  bool _ledGrid = true;
  bool get ledGrid => _ledGrid;
  set ledGrid(bool value) {
    _ledGrid = value;
    notifyListeners();
  }

  List<String> _diagnostics = const <String>[];
  List<String> get diagnostics => _diagnostics;

  String? _error;
  String? get error => _error;

  final List<String> _undo = <String>[];
  final List<String> _redo = <String>[];
  static const int _historyLimit = 60;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// Guards against an older async decode landing after a newer one and
  /// showing a stale frame.
  int _renderSeq = 0;

  List<WidgetInfo> _widgetInfo = const <WidgetInfo>[];
  List<WidgetInfo> get widgetInfo => _widgetInfo;

  // ---------------------------------------------------------------- loading

  Future<void> loadJson(String source, {String? path, bool markClean = true}) async {
    try {
      _doc = LayoutDoc.decode(source);
    } on FormatException catch (e) {
      _error = 'Not valid JSON: ${e.message}';
      notifyListeners();
      return;
    }

    _sourcePath = path;
    _selected = -1;
    _undo.clear();
    _redo.clear();
    if (markClean) _dirty = false;
    await _refresh();
  }

  Future<void> newLayout({int width = 128, int height = 64}) async {
    _doc = LayoutDoc.blank(width: width, height: height);
    _sourcePath = null;
    _selected = -1;
    _undo.clear();
    _redo.clear();
    _dirty = true;
    await _refresh();
  }

  /// The JSON to write to disk. Taken from the Dart model rather than the
  /// engine's serializer so that any keys this build does not understand are
  /// preserved instead of being dropped on save.
  String exportJson() => _doc.encode();

  void markSaved(String path) {
    _sourcePath = path;
    _dirty = false;
    notifyListeners();
  }

  // ----------------------------------------------------------------- edits

  void _pushUndo() {
    _undo.add(_doc.encode(pretty: false));
    if (_undo.length > _historyLimit) _undo.removeAt(0);
    _redo.clear();
  }

  Future<void> _applyEdit(void Function() mutate) async {
    _pushUndo();
    mutate();
    _dirty = true;
    await _refresh();
  }

  Future<void> undo() async {
    if (_undo.isEmpty) return;
    _redo.add(_doc.encode(pretty: false));
    _doc = LayoutDoc.decode(_undo.removeLast());
    _clampSelection();
    _dirty = true;
    await _refresh();
  }

  Future<void> redo() async {
    if (_redo.isEmpty) return;
    _undo.add(_doc.encode(pretty: false));
    _doc = LayoutDoc.decode(_redo.removeLast());
    _clampSelection();
    _dirty = true;
    await _refresh();
  }

  void _clampSelection() {
    if (_selected >= _doc.widgetCount) _selected = _doc.widgetCount - 1;
  }

  void select(int index) {
    if (index == _selected) return;
    _selected = (index >= 0 && index < _doc.widgetCount) ? index : -1;
    notifyListeners();
  }

  /// Selects whatever is drawn at a canvas pixel. Uses the engine's hit test
  /// so a tap always picks what is actually visible there.
  void selectAt(int x, int y) => select(_engine.hitTest(x, y));

  Future<void> addWidget(String type) async {
    await _applyEdit(() {
      _doc.addWidget(type);
      _selected = _doc.widgetCount - 1;
    });
  }

  Future<void> deleteSelected() async {
    if (_selected < 0) return;
    final index = _selected;
    await _applyEdit(() {
      _doc.removeWidget(index);
      _selected = -1;
    });
  }

  Future<void> duplicateSelected() async {
    if (_selected < 0) return;
    final index = _selected;
    await _applyEdit(() {
      _doc.duplicateWidget(index);
      _selected = index + 1;
    });
  }

  Future<void> reorder(int from, int to) async {
    await _applyEdit(() {
      _doc.moveWidget(from, to);
      if (_selected == from) _selected = to;
    });
  }

  Future<void> updateSelected(void Function(LayoutWidget w) mutate) async {
    final widget = _doc.widgetAt(_selected);
    if (widget == null) return;
    await _applyEdit(() => mutate(widget));
  }

  /// Smallest widget the editor will produce. The engine hit tests against the
  /// rect, so a zero-width widget would be invisible *and* impossible to select
  /// again: it would be lost the moment it was resized away.
  static const int _minSize = 1;

  /// Moves the selected widget, clamped so it stays reachable on the canvas.
  ///
  /// [coalesce] suppresses a new undo entry, so a drag gesture collapses into
  /// one undoable step rather than one per pointer event.
  Future<void> nudgeSelected(int dx, int dy, {bool coalesce = false}) async {
    final widget = _doc.widgetAt(_selected);
    if (widget == null) return;
    final r = widget.rect;
    await resizeSelected(
      r.translate(dx.toDouble(), dy.toDouble()),
      coalesce: coalesce,
    );
  }

  /// Sets the selected widget's geometry, clamped to something usable.
  ///
  /// Every rect edit funnels through here: drag handles, the arrow keys and the
  /// inspector's typed X/Y/W/H fields, so there is one definition of legal
  /// geometry rather than one per entry point.
  ///
  /// [coalesce] suppresses a new undo entry, so a drag gesture collapses into
  /// one undoable step rather than one per pointer event.
  Future<void> resizeSelected(ui.Rect rect, {bool coalesce = false}) async {
    final widget = _doc.widgetAt(_selected);
    if (widget == null) return;

    final clamped = _clampToCanvas(rect);
    if (clamped == widget.rect) return;

    if (!coalesce) _pushUndo();
    widget.rect = clamped;
    _dirty = true;
    await _refresh();
  }

  /// Grows or shrinks the selected widget, holding its top-left corner still.
  ///
  /// The keyboard counterpart to dragging a bottom-right handle.
  Future<void> growSelected(int dw, int dh, {bool coalesce = false}) async {
    final widget = _doc.widgetAt(_selected);
    if (widget == null) return;
    final r = widget.rect;
    await resizeSelected(
      ui.Rect.fromLTWH(r.left, r.top, r.width + dw, r.height + dh),
      coalesce: coalesce,
    );
  }

  Future<void> setSelectedRect(ui.Rect rect) => resizeSelected(rect);

  /// Enforces a minimum size and keeps the origin on the canvas.
  ///
  /// Size is deliberately *not* clamped to the canvas. A hand-authored layout
  /// may hold a widget larger than the panel, and merely nudging it should not
  /// silently shrink it. Resize gestures stop themselves at the edge instead.
  ui.Rect _clampToCanvas(ui.Rect rect) {
    // Whole pixels only. The panel has no sub-pixel positions, and rounding
    // here is what makes the unchanged-check in the caller meaningful, rather
    // than comparing a fractional drag position against a stored integer rect.
    final rawW = rect.width.round();
    final rawH = rect.height.round();
    final w = rawW < _minSize ? _minSize : rawW;
    final h = rawH < _minSize ? _minSize : rawH;

    final maxX = _doc.width - w;
    final maxY = _doc.height - h;

    return ui.Rect.fromLTWH(
      rect.left.round().clamp(0, maxX < 0 ? 0 : maxX).toDouble(),
      rect.top.round().clamp(0, maxY < 0 ? 0 : maxY).toDouble(),
      w.toDouble(),
      h.toDouble(),
    );
  }

  /// Call once at the start of a drag so the whole gesture is one undo step.
  void beginGesture() => _pushUndo();

  // --------------------------------------------------------- view settings

  Future<void> setVariant(int variant) async {
    _variant = variant;
    _engine.setVariant(variant);
    await _refresh();
  }

  Future<void> setBrightnessOverride(int? value) async {
    _brightnessOverride = value;
    _engine.setBrightness(value);
    await _refresh();
  }

  // -------------------------------------------------------------- pipeline

  /// Serialize, hand to the engine, re-render. Everything funnels through here.
  Future<void> _refresh() async {
    final json = _doc.encode(pretty: false);
    final ok = _engine.load(json);

    if (!ok) {
      // Keep showing the last good frame. The engine deliberately retains the
      // previously loaded layout, so the preview does not flash black while
      // the user is midway through an edit.
      _error = _engine.lastError;
      _diagnostics = _engine.diagnostics;
      notifyListeners();
      return;
    }

    _error = null;
    _diagnostics = _engine.diagnostics;
    _widgetInfo = _engine.widgets();

    final seq = ++_renderSeq;
    final decoded = await _engine.renderImage();
    if (seq != _renderSeq) {
      // A newer render already landed. Drop this frame and its image.
      decoded?.dispose();
      return;
    }

    _image?.dispose();
    _image = decoded;
    notifyListeners();
  }

  /// Re-runs the pipeline. Used after the engine is first created.
  Future<void> refresh() => _refresh();

  @override
  void dispose() {
    _image?.dispose();
    _engine.dispose();
    super.dispose();
  }
}
