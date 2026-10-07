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

/// The rows of one or more glyphs as they were before an edit. Undo and redo
/// are the same operation on opposite stacks: swap in the recorded rows and
/// record what they replace. A map rather than a single glyph, because a
/// font-wide pass -- trimming every glyph's edges -- is one edit and has to
/// come back in one keystroke.
class _GlyphEdit {
  _GlyphEdit(this.rows);

  /// Pre-edit rows by codepoint, in the order they were touched.
  final Map<int, List<String>> rows;

  /// The glyph the edit was made on, so undo can put the editor back on it.
  int get codepoint => rows.keys.first;
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
  /// hover. Only a move that crosses into another column notifies: a hover
  /// that stays inside one column must not rebuild the app, but the controls
  /// acting on this column have to be able to name it.
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
        'display-thin9',
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
    _clampCursor();
    notifyListeners();
  }

  // ----------------------------------------------------------------- trim

  /// Whether the selected glyph has blank columns at an edge, so the trim
  /// controls can show themselves as usable.
  bool get canTrimGlyph {
    final f = font;
    final g = glyph;
    return f != null && g != null && _trimmed(f, g) != null;
  }

  /// Whether any glyph in the open font has a blank column at an edge.
  bool get canTrimAnyGlyph {
    final f = font;
    return f != null && f.glyphs.any((g) => _trimmed(f, g) != null);
  }

  /// Drop the blank columns at both edges of the selected glyph.
  void trimGlyph() {
    final f = font;
    final g = glyph;
    if (f == null || g == null) return;
    final rows = _trimmed(f, g);
    if (rows == null) return;
    _record(g);
    g.rows = rows;
    _clampCursor();
    notifyListeners();
  }

  /// Drop the blank columns at both edges of every glyph in the open font, as
  /// one undo step: this is the pass an author runs when a cut's advances are
  /// everywhere a column or two wider than its ink.
  void trimAllGlyphs() {
    final f = font;
    if (f == null) return;
    final before = <int, List<String>>{};
    for (final g in f.glyphs) {
      final rows = _trimmed(f, g);
      if (rows == null) continue;
      before[g.codepoint] = List<String>.of(g.rows);
      g.rows = rows;
    }
    if (before.isEmpty) {
      status = 'No blank edge columns in ${f.name}';
      notifyListeners();
      return;
    }
    _recordRows(before);
    _clampCursor();
    status = 'Trimmed the blank edge columns of ${before.length} of '
        '${f.glyphs.length} glyphs in ${f.name}';
    notifyListeners();
  }

  /// The rows [glyph] would have with its blank edge columns gone, or null
  /// when it has none to lose.
  ///
  /// The pen adds the font's gap between glyphs, so a column left blank at an
  /// edge is not spacing that was chosen -- it is spacing added twice, and the
  /// advance it inflates is what throws a line's kerning out. A glyph with no
  /// ink at all is the one case where that reading does not hold: a space is
  /// nothing but width, and trimming it to the one column the format needs
  /// would close the word gap, so it is left alone.
  ///
  /// The digits are the other: a cut's ten figures are tabular so a clock does
  /// not reflow as its digits change, and in a face that draws one the hyphen
  /// stands in for a digit in the engine's `--:--` placeholder, which is held
  /// exactly as wide as a real time. Those glyphs are trimmed together, to the
  /// width the widest of them needs, so the pass still takes the slack off the
  /// set without ever leaving the ten at different widths.
  static List<String>? _trimmed(FontSource font, GlyphSource glyph) {
    final bounds = glyph.inkBounds;
    if (bounds == null) return null;
    final (left, right) = bounds;
    if (_isTabular(font, glyph)) {
      final cell = _tabularCell(font);
      if (cell == null || cell == glyph.width) return null;
      return _repad(glyph.rows, left, right, cell);
    }
    if (left == 0 && right == glyph.width - 1) return null;
    return <String>[
      for (final row in glyph.rows) row.substring(left, right + 1),
    ];
  }

  /// Whether the trim holds [glyph] at the cut's tabular cell width rather
  /// than cutting it back to its ink.
  static bool _isTabular(FontSource font, GlyphSource glyph) =>
      (glyph.codepoint >= 0x30 && glyph.codepoint <= 0x39) ||
      (glyph.codepoint == 0x2d &&
          (font.role == 'digits' || font.family == 'display'));

  /// The width the ten digits of [font] hold: the widest ink any of them
  /// needs. Null for a cut with no digits to measure.
  static int? _tabularCell(FontSource font) {
    int? cell;
    for (var cp = 0x30; cp <= 0x39; cp++) {
      final bounds = font.glyph(cp)?.inkBounds;
      if (bounds == null) continue;
      final ink = bounds.$2 - bounds.$1 + 1;
      if (cell == null || ink > cell) cell = ink;
    }
    return cell;
  }

  /// [rows] cut back to [target] columns, or widened to it, with the ink left
  /// where the pen put it: the blank columns go from the right margin first,
  /// and come back on the right when the cell has to grow.
  static List<String> _repad(
    List<String> rows,
    int left,
    int right,
    int target,
  ) {
    final width = rows.first.length;
    if (target == width) return rows;
    if (target < width) {
      final rightMargin = width - 1 - right;
      final excess = width - target;
      final fromRight = excess < rightMargin ? excess : rightMargin;
      final fromLeft = excess - fromRight;
      return <String>[
        for (final row in rows) row.substring(fromLeft, width - fromRight),
      ];
    }
    return <String>[
      for (final row in rows) row.padRight(target, '.'),
    ];
  }

  void _record(GlyphSource glyph) =>
      _recordRows(<int, List<String>>{
        glyph.codepoint: List<String>.of(glyph.rows),
      });

  /// Record an edit that touched several glyphs as one undo step. Called with
  /// the rows as they were, before anything is changed.
  void _recordRows(Map<int, List<String>> rows) {
    if (rows.isEmpty) return;
    _undo.add(_GlyphEdit(rows));
    _redo.clear();
    if (_undo.length > 256) _undo.removeAt(0);
  }

  /// Undo follows the edit's own glyph rather than the selection, so a trip
  /// through another glyph does not strand the change.
  void undo() {
    if (_undo.isEmpty || font == null) return;
    final edit = _undo.removeLast();
    final replaced = _swapIn(edit.rows);
    if (replaced.isEmpty) return;
    _redo.add(_GlyphEdit(replaced));
    selected = edit.codepoint;
    _clampCursor();
    notifyListeners();
  }

  void redo() {
    if (_redo.isEmpty || font == null) return;
    final edit = _redo.removeLast();
    final replaced = _swapIn(edit.rows);
    if (replaced.isEmpty) return;
    _undo.add(_GlyphEdit(replaced));
    selected = edit.codepoint;
    _clampCursor();
    notifyListeners();
  }

  /// Put [rows] into the font, returning what was there, so the caller can
  /// make that the opposite edit. A glyph the font no longer holds is skipped.
  Map<int, List<String>> _swapIn(Map<int, List<String>> rows) {
    final replaced = <int, List<String>>{};
    for (final entry in rows.entries) {
      final target = font!.glyph(entry.key);
      if (target == null) continue;
      replaced[target.codepoint] = List<String>.of(target.rows);
      target.rows = List<String>.of(entry.value);
    }
    return replaced;
  }

  /// Keep the column the column tools act on inside the glyph: an edit can
  /// narrow the glyph out from under it.
  void _clampCursor() {
    final g = glyph;
    if (g == null || g.width == 0) return;
    cursorColumn = cursorColumn.clamp(0, g.width - 1);
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

  void setCursorColumn(int column) {
    if (column == cursorColumn) return;
    cursorColumn = column;
    notifyListeners();
  }

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
