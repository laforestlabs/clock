// The one place the editor's state lives: which font is open, what has been
// changed in it, and the panel model the changes are judged against.

import 'dart:io';

import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'font_source.dart';
import 'frame.dart';
import 'panel.dart';
import 'repo.dart';

/// What the big preview is showing: a string, or the whole character set.
enum PreviewMode { text, sheet }

/// One glyph's rows as they were before an edit. Undo and redo are the same
/// operation on opposite stacks: swap in the recorded rows and record what
/// they replace.
class _GlyphEdit {
  _GlyphEdit(this.codepoint, this.rows);

  final int codepoint;
  final List<String> rows;
}

class DesignerState extends ChangeNotifier {
  DesignerState();

  static const String _kRoot = 'font_designer.root';
  static const String _kFont = 'font_designer.font';
  static const String _kSample = 'font_designer.sample';
  static const String _kScale = 'font_designer.scale';
  static const String _kColour = 'font_designer.colour';
  static const String _kColumns = 'font_designer.panel.columns';
  static const String _kRows = 'font_designer.panel.rows';
  static const String _kPitch = 'font_designer.panel.pitch';
  static const String _kGap = 'font_designer.panel.gap';
  static const String _kBrightness = 'font_designer.panel.brightness';
  static const String _kDistance = 'font_designer.panel.distance';
  static const String _kShape = 'font_designer.panel.shape';
  static const String _kOutlines = 'font_designer.show_outlines';

  SharedPreferences? _prefs;

  Repository? repo;

  /// Every source in the catalogue, in picker order.
  List<FontRef> refs = <FontRef>[];

  /// The open font, or null before one is chosen.
  FontSource? font;

  /// A file that could not be parsed, or a tool that failed. Shown rather
  /// than swallowed: the author needs the line number.
  String? error;

  /// The glyph the editor is on.
  int? selected;

  /// Ink character being painted, one of [FontSource.inkChars].
  String paintInk = '#';

  /// The column the column tools act on, set by the last click or the last
  /// hover. Deliberately not a notify: a hover must not rebuild the app.
  int cursorColumn = 0;

  int scale = 1;
  int colour = 0xFFFFFF;
  String sample = 'Handgloves 09:41 ABC';

  PanelSpec panel = const PanelSpec();

  PreviewMode mode = PreviewMode.text;
  int sheetPage = 0;

  /// Whether unlit cells are outlined, so a shape can be judged without
  /// guessing where the invisible pixels are.
  bool showOutlines = false;

  /// Screen pixels per cell, or null while the view is fitting the panel to
  /// whatever room it has.
  double? pinnedZoom;

  bool busy = false;

  /// The last thing a tool said, and whether the generated tables are behind
  /// the sources.
  String? status;
  bool stale = false;

  final List<_GlyphEdit> _undo = <_GlyphEdit>[];
  final List<_GlyphEdit> _redo = <_GlyphEdit>[];

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  bool get dirty => font?.dirty ?? false;

  /// The width the current sample needs, so the view can say when it runs off
  /// the panel instead of silently clipping.
  int get sampleWidth =>
      font == null ? 0 : textWidth(font!, sample, scale: scale);

  List<SheetPage> get sheetPages => font == null
      ? const <SheetPage>[]
      : paginateSheet(font!, panel, sheetOrder(font!));

  SheetPage? get currentSheetPage {
    final pages = sheetPages;
    if (pages.isEmpty) return null;
    return pages[sheetPage.clamp(0, pages.length - 1)];
  }

  // ------------------------------------------------------------- lifecycle

  /// Load the remembered settings and open the remembered checkout. Returns
  /// false when there is no checkout to open and the caller must ask for one.
  Future<bool> restore() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    sample = prefs.getString(_kSample) ?? sample;
    scale = prefs.getInt(_kScale) ?? scale;
    colour = prefs.getInt(_kColour) ?? colour;
    showOutlines = prefs.getBool(_kOutlines) ?? showOutlines;
    panel = PanelSpec(
      columns: prefs.getInt(_kColumns) ?? panel.columns,
      rows: prefs.getInt(_kRows) ?? panel.rows,
      pitchMm: prefs.getDouble(_kPitch) ?? panel.pitchMm,
      gapShare: prefs.getDouble(_kGap) ?? panel.gapShare,
      brightness: prefs.getInt(_kBrightness) ?? panel.brightness,
      distanceM: prefs.getDouble(_kDistance) ?? panel.distanceM,
      shape: (prefs.getString(_kShape) ?? 'round') == 'square'
          ? EmitterShape.square
          : EmitterShape.round,
    );

    final root = Repository.locate(from: prefs.getString(_kRoot));
    if (root == null) return false;
    await open(root);
    return true;
  }

  Future<void> open(String root) async {
    repo = Repository(root);
    refs = repo!.fonts();
    _undo.clear();
    _redo.clear();
    selected = null;
    font = null;
    sheetPage = 0;
    error = null;
    notifyListeners();

    await _prefs?.setString(_kRoot, root);

    if (refs.isNotEmpty) {
      // A face that can draw a sentence, rather than whichever name sorts
      // first: digits10, the alphabetically first file, would open the tool on
      // a clock face with ten glyphs and no letters.
      final remembered = _prefs?.getString(_kFont);
      final wanted = <String>[
        if (remembered != null) remembered,
        'display12',
        'sans9',
      ];
      final chosen = wanted
              .map((name) => refs.where((r) => r.name == name).firstOrNull)
              .whereType<FontRef>()
              .firstOrNull ??
          refs.first;
      await selectFont(chosen);
    }
    await refreshStale();
  }

  /// Ask fontgen whether the committed tables still match the sources.
  Future<void> refreshStale() async {
    final r = repo;
    if (r == null) return;
    stale = await r.generatedIsStale();
    notifyListeners();
  }

  Future<void> selectFont(FontRef ref) async {
    final r = repo;
    if (r == null) return;
    try {
      final loaded = await r.load(ref);
      font = loaded;
      selected = _firstInteresting(loaded);
      cursorColumn = 0;
      paintInk = loaded.inkChars.first;
      sheetPage = 0;
      _undo.clear();
      _redo.clear();
      error = null;
      await _prefs?.setString(_kFont, ref.name);
    } on FontSourceError catch (e) {
      font = null;
      selected = null;
      error = e.toString();
    } on Object catch (e) {
      font = null;
      selected = null;
      error = '${ref.path}: $e';
    }
    notifyListeners();
  }

  /// The glyph to open a font on: 'A' where there is one, so a text face opens
  /// on a letter rather than on its space or its first punctuation mark, and a
  /// digits or icon face on its first glyph that actually has ink. A blank
  /// glyph in the editor looks like a broken tool.
  static int _firstInteresting(FontSource font) {
    final a = font.glyph(0x41);
    if (a != null && a.rows.any((row) => row.contains('#'))) return 0x41;
    for (final glyph in font.glyphs) {
      if (glyph.rows.any((row) => row.contains('#'))) return glyph.codepoint;
    }
    return font.glyphs.first.codepoint;
  }

  void selectGlyph(int codepoint) {
    selected = codepoint;
    cursorColumn = 0;
    notifyListeners();
  }

  // ---------------------------------------------------------------- edits

  GlyphSource? get glyph {
    final f = font;
    final cp = selected;
    if (f == null || cp == null) return null;
    return f.glyph(cp);
  }

  bool inBounds(int row, int column) {
    final g = glyph;
    if (g == null) return false;
    return row >= 0 && row < g.rows.length && column >= 0 && column < g.width;
  }

  String inkAt(int row, int column) {
    final g = glyph;
    if (g == null || !inBounds(row, column)) return '.';
    return g.rows[row][column];
  }

  /// Set one pixel of the selected glyph. A no-op when nothing changes, so a
  /// drag paints rather than piling up undo entries.
  void setPixel(int row, int column, String ink) {
    final g = glyph;
    if (g == null || !inBounds(row, column) || ink.length != 1) return;
    if (g.rows[row][column] == ink) return;
    _record(g);
    final line = g.rows[row];
    g.rows[row] = line.substring(0, column) + ink + line.substring(column + 1);
    cursorColumn = column;
    notifyListeners();
  }

  void togglePixel(int row, int column) {
    if (!inBounds(row, column)) return;
    setPixel(row, column, inkAt(row, column) == '.' ? paintInk : '.');
  }

  void clearGlyph() {
    final g = glyph;
    if (g == null) return;
    _record(g);
    g.rows = List<String>.generate(g.rows.length, (_) => '.' * g.width);
    notifyListeners();
  }

  void revertGlyph() {
    final g = glyph;
    if (g == null || !g.dirty) return;
    _record(g);
    g.revert();
    notifyListeners();
  }

  void shiftGlyph(int dx) {
    final g = glyph;
    if (g == null || dx == 0) return;
    _record(g);
    g.rows = <String>[
      for (final row in g.rows) _shift(row, dx),
    ];
    notifyListeners();
  }

  static String _shift(String row, int dx) {
    final width = row.length;
    if (dx.abs() >= width) return '.' * width;
    if (dx > 0) return '${'.' * dx}${row.substring(0, width - dx)}';
    return '${row.substring(-dx)}${'.' * -dx}';
  }

  /// Insert a blank column at [at], widening the glyph's advance.
  void insertColumn(int at) {
    final g = glyph;
    if (g == null) return;
    _record(g);
    final index = at.clamp(0, g.width);
    g.rows = <String>[
      for (final row in g.rows)
        '${row.substring(0, index)}.${row.substring(index)}',
    ];
    notifyListeners();
  }

  /// Remove a column, narrowing the advance. A glyph cannot go to zero width:
  /// it would advance by the gap alone and draw nothing.
  void deleteColumn(int at) {
    final g = glyph;
    if (g == null || g.width <= 1) return;
    _record(g);
    final index = at.clamp(0, g.width - 1);
    g.rows = <String>[
      for (final row in g.rows)
        row.substring(0, index) + row.substring(index + 1),
    ];
    notifyListeners();
  }

  void _record(GlyphSource glyph) {
    _undo.add(_GlyphEdit(glyph.codepoint, List<String>.of(glyph.rows)));
    _redo.clear();
    if (_undo.length > 256) _undo.removeAt(0);
  }

  /// Undo follows the edit's own glyph rather than the selection, so a trip
  /// through another glyph does not strand the change.
  void undo() {
    if (_undo.isEmpty || font == null) return;
    final edit = _undo.removeLast();
    final target = font!.glyph(edit.codepoint);
    if (target == null) return;
    _redo.add(_GlyphEdit(edit.codepoint, List<String>.of(target.rows)));
    target.rows = List<String>.of(edit.rows);
    selected = edit.codepoint;
    notifyListeners();
  }

  void redo() {
    if (_redo.isEmpty || font == null) return;
    final edit = _redo.removeLast();
    final target = font!.glyph(edit.codepoint);
    if (target == null) return;
    _undo.add(_GlyphEdit(edit.codepoint, List<String>.of(target.rows)));
    target.rows = List<String>.of(edit.rows);
    selected = edit.codepoint;
    notifyListeners();
  }

  // --------------------------------------------------------------- output

  /// Write the open font. Returns whether anything was written.
  Future<bool> save() async {
    final f = font;
    final r = repo;
    if (r == null || f == null || !f.dirty) return false;
    busy = true;
    notifyListeners();
    try {
      await r.save(f);
      for (final glyph in f.glyphs) {
        glyph.markSaved();
      }
      status = 'Saved ${f.path}';
      return true;
    } on FileSystemException catch (e) {
      status = 'Could not save ${f.path}: ${e.message}';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Save, then compile the tables, so a saved edit is usable by the engine.
  Future<void> saveAndRegenerate() async {
    await save();
    await regenerate();
  }

  Future<void> regenerate() async {
    final r = repo;
    if (r == null) return;
    busy = true;
    notifyListeners();
    try {
      final run = await r.regenerate();
      status = run.ok
          ? 'Regenerated the glyph tables'
          : 'fontgen failed:\n${run.output}';
      stale = !run.ok;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Discard every unsaved change in the open font.
  void revertAll() {
    final f = font;
    if (f == null || !f.dirty) return;
    for (final g in f.glyphs) {
      g.revert();
    }
    _undo.clear();
    _redo.clear();
    status = 'Reverted ${f.path}';
    notifyListeners();
  }

  // ------------------------------------------------------------ view state

  void setPanel(PanelSpec next) {
    panel = next;
    _persistPanel();
    notifyListeners();
  }

  void setMode(PreviewMode next) {
    mode = next;
    notifyListeners();
  }

  void setSheetPage(int page) {
    final pages = sheetPages;
    if (pages.isEmpty) return;
    sheetPage = page.clamp(0, pages.length - 1);
    notifyListeners();
  }

  /// The zoom the panel view should use: the pinned choice, or the largest
  /// that shows the whole panel in [room].
  double zoomFor(Size room) {
    final pinned = pinnedZoom;
    if (pinned != null) return pinned;
    if (room.width <= 0 || room.height <= 0) return 1;
    final fit = <double>[
      room.width / panel.columns,
      room.height / panel.rows,
    ].reduce((a, b) => a < b ? a : b);
    return fit.clamp(1.0, 64.0);
  }

  void setZoom(double? zoom) {
    pinnedZoom = zoom;
    notifyListeners();
  }

  void setSample(String text) {
    sample = text;
    _persistString(_kSample, text);
    notifyListeners();
  }

  void setScale(int next) {
    scale = next.clamp(1, 8);
    _persistInt(_kScale, scale);
    notifyListeners();
  }

  void setColour(int rgb) {
    colour = rgb & 0xFFFFFF;
    _persistInt(_kColour, colour);
    notifyListeners();
  }

  void setPaintInk(String ink) {
    paintInk = ink;
    notifyListeners();
  }

  void setShowOutlines(bool on) {
    showOutlines = on;
    _persistBool(_kOutlines, on);
    notifyListeners();
  }

  void setCursorColumn(int column) => cursorColumn = column;

  void _persistPanel() {
    _persistInt(_kColumns, panel.columns);
    _persistInt(_kRows, panel.rows);
    _persistDouble(_kPitch, panel.pitchMm);
    _persistDouble(_kGap, panel.gapShare);
    _persistInt(_kBrightness, panel.brightness);
    _persistDouble(_kDistance, panel.distanceM);
    _persistString(_kShape,
        panel.shape == EmitterShape.square ? 'square' : 'round');
  }

  void _persistInt(String key, int value) => _prefs?.setInt(key, value);
  void _persistDouble(String key, double value) => _prefs?.setDouble(key, value);
  void _persistBool(String key, bool value) => _prefs?.setBool(key, value);
  void _persistString(String key, String value) => _prefs?.setString(key, value);
}
