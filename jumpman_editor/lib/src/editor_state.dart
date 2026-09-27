// The editor's state: the level, everything done to it, and what it has to say.
//
// One ChangeNotifier holds the whole document - the model, the undo stack, the
// selection, the findings, the playtest and the export status - because they are
// one thing: an edit invalidates the checks, the scan results and the running
// playtest, and there is no use pretending otherwise by splitting them.
//
// The UI is deliberately dumb: it reads fields and calls methods, and every
// decision about what an edit means is here.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'autoplay.dart';
import 'game_source.dart';
import 'jump_level.dart';
import 'jumpman_spec.dart';
import 'level_source.dart';
import 'playtest.dart';
import 'playtest_window.dart';
import 'scan.dart';
import 'validate.dart';

/// What a click on the map does.
enum EditorTool {
  select('Select'),
  terrain('Terrain'),
  pit('Pit'),
  ground('Ground'),
  block('Block'),
  coin('Coin'),
  enemy('Enemy'),
  pipe('Pipe'),
  checkpoint('Checkpoint'),
  start('Start'),
  erase('Erase');

  const EditorTool(this.label);
  final String label;
}

/// What the inspector is showing.
enum SelectionKind { column, pipe, coin, enemy }

/// One selected thing on the map.
class Selection {
  const Selection({
    required this.kind,
    required this.column,
    this.pipe,
    this.coin,
    this.enemy,
  });

  final SelectionKind kind;
  final int column;
  final JumpPipe? pipe;
  final JumpCoin? coin;
  final JumpEnemy? enemy;
}

/// How many edits the undo stack holds. The model is a kilobyte, so this is
/// nothing, and whole snapshots mean there is no command pattern to get wrong.
const int kUndoDepth = 200;

/// The name the level the game ships is imported under.
const String kAuthoredProjectName = 'authored';

/// What the "Bump and stamp" button's confirmation says, because it is the whole
/// of what the button is about to do to a file the firmware test reads.
const String kBumpAndStampWarning =
    'Bump the firmware version, stamp the sources, and re-run the check?\n\n'
    'The version is an image identity you decide, and bumping it without '
    'rebuilding the bundled OTA image makes '
    'designer/test/bundled_firmware_test.dart fail until tools/bundle_firmware.sh '
    'runs. This only rewrites firmware/CMakeLists.txt and firmware/version.lock.';

/// The editor's whole document.
class EditorState extends ChangeNotifier {
  EditorState({
    required this.spec,
    required this.gameSource,
    required JumpLevel level,
    String projectName = kAuthoredProjectName,
    String? projectPath,
  })  : _level = level,
        // A copy: dirty is a comparison, so the two must not be one object.
        _saved = level.clone(),
        projectName = projectName,
        projectPath = projectPath {
    _revalidate();
  }

  final JumpmanSpec spec;
  final GameSource gameSource;

  JumpLevel _level;
  JumpLevel _saved;

  /// The level being edited.
  JumpLevel get level => _level;

  /// The project's name and, once it has been saved or opened, its file.
  String projectName;
  String? projectPath;

  // ------------------------------------------------------------- undo / redo

  final List<JumpLevel> _undo = <JumpLevel>[];
  final List<JumpLevel> _redo = <JumpLevel>[];
  JumpLevel? _stroke;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// Whether the level differs from the file it was loaded from or saved to.
  bool get dirty => _level != _saved;

  /// Whether an edit has been started and not yet finished. A drag is one edit.
  bool get inStroke => _stroke != null;

  /// Start one edit: a click, or the whole of a drag. Nothing between this and
  /// [endStroke] adds a second undo entry, which is what makes one stroke one
  /// undo.
  void beginStroke() {
    if (_stroke != null) return;
    _stroke = _level.clone();
  }

  /// Apply [change] to the level. It is part of the edit in progress - the undo
  /// entry was taken when the edit started - so this never touches the undo
  /// stack, and the checks and the UI are brought up to date as it lands.
  void mutate(void Function(JumpLevel level) change) {
    change(_level);
    _revalidate();
  }

  /// Finish an edit. An edit that changed nothing is not one, so it leaves no
  /// undo entry and does not invalidate the checks.
  void endStroke() {
    final before = _stroke;
    _stroke = null;
    if (before == null || before == _level) return;
    _undo.add(before);
    if (_undo.length > kUndoDepth) _undo.removeAt(0);
    _redo.clear();
    _invalidate();
  }

  /// One edit, done and finished: the shape of a click. Inside a stroke it is
  /// just the change, because that stroke is already one undo entry.
  void edit(void Function(JumpLevel level) change) {
    final own = _stroke == null;
    if (own) beginStroke();
    mutate(change);
    if (own) endStroke();
  }

  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(_level);
    _level = _undo.removeLast();
    _invalidate();
  }

  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(_level);
    _level = _redo.removeLast();
    _invalidate();
  }

  // ------------------------------------------------------------------- tools

  EditorTool tool = EditorTool.select;
  int blockKind = 0;
  int enemyKind = 0;
  int enemyDir = -1;
  int pipeH = 5;
  bool pipePlant = true;

  /// Pixels per level pixel. Only the horizontal axis scrolls, so this is the
  /// whole of the map's scale.
  double zoom = 12;

  /// A column the map should scroll to: set by clicking a finding, cleared by
  /// the map once it has gone there. The map owns its own scrolling, because a
  /// ScrollController and a notifier both holding an offset is two answers to
  /// one question.
  int? revealRequest;

  Selection? selection;

  /// What the hover read-out is about: the cell under the cursor.
  int? hoverColumn;
  int? hoverRow;

  List<Finding> _findings = const [];
  List<Finding> _scanFindings = const [];

  /// Everything wrong with the level: the structural checks, then the scan's
  /// findings, worst first. A scan result is dropped by any edit, because it was
  /// about the level as it was.
  List<Finding> get findings => sortFindings([..._findings, ..._scanFindings]);

  List<Finding> get structuralFindings => _findings;

  List<Finding> get scanFindings => _scanFindings;

  /// The last thing that happened, for the status line.
  String? status;

  void setTool(EditorTool value) {
    tool = value;
    notifyListeners();
  }

  void setBlockKind(int value) {
    blockKind = value;
    notifyListeners();
  }

  void setEnemyKind(int value) {
    enemyKind = value;
    notifyListeners();
  }

  void setEnemyDir(int value) {
    enemyDir = value;
    notifyListeners();
  }

  void setPipeH(int value) {
    pipeH = value;
    notifyListeners();
  }

  void setPipePlant(bool value) {
    pipePlant = value;
    notifyListeners();
  }

  void setZoom(double value) {
    zoom = value.clamp(4, 40).toDouble();
    notifyListeners();
  }

  /// Ask the map to scroll [column] into view (a clicked finding, a revealed
  /// breakpoint). The map clears it once it has.
  void requestReveal(int column) {
    revealRequest = column;
    notifyListeners();
  }

  /// A clicked finding: show the column it is about and select it, so the
  /// inspector says what is there rather than only where it is.
  void revealFinding(int column) {
    selection = Selection(kind: SelectionKind.column, column: column);
    requestReveal(column);
  }

  void clearRevealRequest() {
    revealRequest = null;
  }

  void setHover(int? column, int? row) {
    if (column == hoverColumn && row == hoverRow) return;
    hoverColumn = column;
    hoverRow = row;
    notifyListeners();
  }

  // -------------------------------------------------------------- map edits

  /// What a cell under the cursor is, for the hover read-out and Select.
  void selectAt(int column, int row) {
    if (column < 0 || column >= spec.cols) return;
    final pipe = _level.pipeAt(column);
    if (pipe != null) {
      selection =
          Selection(kind: SelectionKind.pipe, column: column, pipe: pipe);
    } else {
      final coin = _level.coinAt(column, row);
      if (coin != null) {
        selection =
            Selection(kind: SelectionKind.coin, column: column, coin: coin);
      } else {
        final enemy = _level.enemyAt(column);
        if (enemy != null) {
          selection = Selection(
              kind: SelectionKind.enemy, column: column, enemy: enemy);
        } else {
          selection = Selection(kind: SelectionKind.column, column: column);
        }
      }
    }
    notifyListeners();
  }

  /// The Terrain tool: a column's ground surface becomes the row under the
  /// cursor, which is how a plateau is raised and a pit is dug one column at a
  /// time.
  void setSurface(int column, int row) =>
      edit((level) => level.surface[column] = row);

  /// The Pit tool.
  void makePit(int column) => edit((level) => level.surface[column] = kPit);

  /// The Ground tool: back to the row plain ground sits on, which is the way out
  /// of a pit and off a raised platform.
  void makeGround(int column) =>
      edit((level) => level.surface[column] = level.groundRow);

  /// The Block tool: the block's row is the row under the cursor.
  void placeBlock(int column, int row) => edit((level) {
        level.blocks[column] = packBlock(blockKind, row.clamp(0, 31));
      });

  void eraseBlock(int column) =>
      edit((level) => level.blocks[column] = kNoBlock);

  void placeCoin(int column, int row) =>
      edit((level) => level.coins.add(JumpCoin(x: column, y: row)));

  void placeEnemy(int column, int row) => edit((level) => level.enemies
      .add(JumpEnemy(x: column, row: row, dir: enemyDir, kind: enemyKind)));

  /// The Pipe tool: a pipe is three columns wide with its left edge where the
  /// cursor is, and it replaces any pipe it overlaps.
  void placePipe(int column) => edit((level) {
        level.pipes.removeWhere(
            (p) => p.x < column + level.pipeW && column < p.x + level.pipeW);
        level.pipes
            .add(JumpPipe(x: column, h: pipeH, plant: pipePlant ? 1 : 0));
      });

  void setStart(int column) => edit((level) => level.startX = column);

  void setCheckpoint(int column) => edit((level) => level.checkpointX = column);

  /// The Erase tool: whatever is on the cell, gone. Blocks and coins are found
  /// by the cell, enemies and pipes by the column they stand in.
  void eraseAt(int column, int row) => edit((level) {
        if (level.blockAt(column) != kNoBlock) level.blocks[column] = kNoBlock;
        level.coins.removeWhere((c) =>
            column >= c.x && column < c.x + 2 && row >= c.y && row < c.y + 2);
        level.enemies.removeWhere((e) => e.x == column);
        level.pipes.removeWhere((pipe) =>
            level.pipeW > 0 &&
            column >= pipe.x &&
            column < pipe.x + level.pipeW);
      });

  // ------------------------------------------------------- the selected item

  /// Change the selected item's own fields, for the inspector's steppers.
  void updateSelected(
      void Function(JumpLevel level, Selection selection) change) {
    final selected = selection;
    if (selected == null) return;
    edit((level) => change(level, selected));
  }

  void deleteSelected() {
    final selected = selection;
    if (selected == null) return;
    edit((level) {
      switch (selected.kind) {
        case SelectionKind.pipe:
          level.pipes.remove(selected.pipe);
        case SelectionKind.coin:
          level.coins.remove(selected.coin);
        case SelectionKind.enemy:
          level.enemies.remove(selected.enemy);
        case SelectionKind.column:
          level.blocks[selected.column] = kNoBlock;
      }
    });
    selection = null;
    notifyListeners();
  }

  // ------------------------------------------------------- project files

  /// A new level: solid ground everywhere, the run's two columns where the
  /// game's own level puts them, and nothing else.
  void newLevel() {
    _level = JumpLevel.empty(spec);
    _saved = _level.clone();
    _undo.clear();
    _redo.clear();
    _scanFindings = const [];
    projectName = 'untitled';
    projectPath = null;
    selection = null;
    status = 'new level';
    _revalidate();
  }

  /// The level the game ships today, re-imported from its source. This is also
  /// the state the editor opens on: the user starts from a level they know
  /// works.
  void revert() {
    final text = gameSource.readGameSource();
    _level = LevelSource.importFrom(
        source: text, spec: spec, path: gameSource.gameFile);
    _saved = _level.clone();
    _undo.clear();
    _redo.clear();
    _scanFindings = const [];
    projectName = kAuthoredProjectName;
    projectPath = null;
    selection = null;
    status = 'reverted to the level in game_jumpman.c';
    _revalidate();
  }

  static const XTypeGroup _levelTypeGroup =
      XTypeGroup(label: 'Jumpman level', extensions: ['json']);

  Future<String?> _levelsDirectory() async {
    final prefs = await SharedPreferences.getInstance();
    final remembered = prefs.getString(kRememberedLevelDirKey);
    if (remembered != null && Directory(remembered).existsSync()) {
      return remembered;
    }
    final dir = gameSource.levelsDir;
    if (dir != null) Directory(dir).createSync(recursive: true);
    return dir;
  }

  Future<void> openProject() async {
    final initial = await _levelsDirectory();
    final chosen = await openFile(
      acceptedTypeGroups: [_levelTypeGroup],
      initialDirectory: initial,
    );
    if (chosen == null) return;
    final path = chosen.path;
    try {
      final json = jsonDecode(File(path).readAsStringSync());
      if (json is! Map<String, Object?>) {
        throw LevelFormatException('$path is not a JSON object.');
      }
      _level = JumpLevel.fromJson(json, spec, path: path);
      _saved = _level.clone();
      _undo.clear();
      _redo.clear();
      _scanFindings = const [];
      selection = null;
      projectPath = path;
      projectName = p.basenameWithoutExtension(path);
      status = 'opened $path';
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kRememberedLevelDirKey, p.dirname(path));
    } on LevelFormatException catch (e) {
      status = e.message;
    } on FormatException catch (e) {
      status = '$path is not readable as JSON: ${e.message}';
    }
    _revalidate();
  }

  Future<bool> save() async {
    final path = projectPath ?? await _chooseSavePath();
    if (path == null) return false;
    return _writeProject(path);
  }

  Future<bool> saveAs() async {
    final path = await _chooseSavePath();
    if (path == null) return false;
    return _writeProject(path);
  }

  Future<String?> _chooseSavePath() async {
    final initial = await _levelsDirectory();
    final location = await getSaveLocation(
      suggestedName: '$projectName.json',
      initialDirectory: initial,
    );
    if (location == null) return null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kRememberedLevelDirKey, p.dirname(location.path));
    return location.path;
  }

  bool _writeProject(String path) {
    try {
      Directory(p.dirname(path)).createSync(recursive: true);
      File(path).writeAsStringSync(const JsonEncoder.withIndent('  ')
          .convert(_level.toJson(spec, projectName)));
      _saved = _level.clone();
      projectPath = path;
      projectName = p.basenameWithoutExtension(path);
      status = 'saved $path';
      notifyListeners();
      return true;
    } on FileSystemException catch (e) {
      status = 'could not write $path: ${e.message}';
      notifyListeners();
      return false;
    }
  }

  // ------------------------------------------------------------- exporting

  String? exportReport;
  bool exportFailed = false;

  /// Write the level's tables into the game's source, after reading the text it
  /// just produced back and refusing to write it if it is not this level.
  void exportLevel() {
    exportFailed = false;
    try {
      final source = gameSource.readGameSource();
      final text = LevelSource.apply(
        level: _level,
        source: source,
        spec: spec,
        path: gameSource.gameFile,
      );
      final back = LevelSource.importFrom(
          source: text, spec: spec, path: gameSource.gameFile);
      if (back != _level) {
        exportFailed = true;
        exportReport = 'nothing was written: the tables this level produces do '
            'not read back as this level.\n\n'
            '${_firstDifference(_level, back)}';
        notifyListeners();
        return;
      }
      final tables = LevelSource.tables(text, gameSource.gameFile);
      final from = tables.map((t) => t.start).reduce((a, b) => a < b ? a : b);
      final to = tables.map((t) => t.end).reduce((a, b) => a > b ? a : b);
      File(gameSource.gameFile).writeAsStringSync(text);
      exportReport = 'wrote ${gameSource.gameFile}\nlevel tables replaced: '
          'bytes $from-$to';
      status = 'exported to ${p.basename(gameSource.gameFile)}';
    } on LevelSourceException catch (e) {
      exportFailed = true;
      exportReport = e.message;
    } on FileSystemException catch (e) {
      exportFailed = true;
      exportReport = '${gameSource.gameFile}: ${e.message}';
    }
    notifyListeners();
  }

  static String _firstDifference(JumpLevel a, JumpLevel b) {
    if (a.cols != b.cols)
      return 'the column counts differ (${a.cols} and ${b.cols}).';
    for (var x = 0; x < a.cols; x++) {
      if (a.surface[x] != b.surface[x]) {
        return 'column $x: surface ${a.surface[x]} became ${b.surface[x]}.';
      }
      if (a.blocks[x] != b.blocks[x]) {
        return 'column $x: block ${a.blocks[x]} became ${b.blocks[x]}.';
      }
    }
    if (a.startX != b.startX || a.checkpointX != b.checkpointX) {
      return 'the run\'s columns differ.';
    }
    return 'the pipes, coins or enemies differ.';
  }

  // -------------------------------------------------- the firmware version

  /// The repository root the version commands run in, or null when there is no
  /// repository (a game file picked by hand outside one).
  String? get repoRoot => gameSource.root.isEmpty ? null : gameSource.root;

  String? firmwareCheckOutput;
  bool? firmwareCheckOk;
  bool firmwareBusy = false;

  Future<void> runFirmwareCheck() async {
    final root = repoRoot;
    if (root == null) {
      firmwareCheckOutput =
          'no repository: the game source was picked by hand, so there is '
          'nothing to check the firmware version against.';
      firmwareCheckOk = null;
      notifyListeners();
      return;
    }
    firmwareBusy = true;
    notifyListeners();
    final result = await Process.run(
      'python3',
      ['tools/firmware_version.py', 'check'],
      workingDirectory: root,
    );
    firmwareCheckOk = result.exitCode == 0;
    firmwareCheckOutput = '${result.stdout}${result.stderr}'.trim();
    firmwareBusy = false;
    notifyListeners();
  }

  /// The version the firmware's CMakeLists declares, and the next patch after
  /// it.
  String? firmwareVersion;
  String? nextFirmwareVersion;

  Future<void> bumpAndStamp() async {
    final root = repoRoot;
    if (root == null) return;
    firmwareBusy = true;
    notifyListeners();
    try {
      final cmake = File(p.join(root, 'firmware', 'CMakeLists.txt'));
      final text = cmake.readAsStringSync();
      final re = RegExp(r'project\(smart_mirror VERSION ([^)\s]+)\)');
      final match = re.firstMatch(text);
      final parsed = match == null
          ? null
          : RegExp(r'^(\d+)\.(\d+)\.(\d+)$').firstMatch(match.group(1)!);
      if (parsed == null) {
        firmwareCheckOutput =
            'firmware/CMakeLists.txt does not state a x.y.z version, so there is '
            'nothing to bump.';
        firmwareCheckOk = false;
        return;
      }
      firmwareVersion = match!.group(1);
      final next = '${parsed.group(1)}.${parsed.group(2)}.'
          '${int.parse(parsed.group(3)!) + 1}';
      nextFirmwareVersion = next;
      cmake.writeAsStringSync(text.replaceRange(
          match.start, match.end, 'project(smart_mirror VERSION $next)'));

      final stamp = await Process.run(
        'python3',
        ['tools/firmware_version.py', 'stamp'],
        workingDirectory: root,
      );
      if (stamp.exitCode != 0) {
        firmwareCheckOutput =
            'stamp failed:\n${stamp.stdout}${stamp.stderr}'.trim();
        firmwareCheckOk = false;
        return;
      }
      firmwareBusy = false;
      await runFirmwareCheck();
    } on FileSystemException catch (e) {
      firmwareCheckOutput = 'could not bump the version: ${e.message}';
      firmwareCheckOk = false;
    } finally {
      firmwareBusy = false;
      notifyListeners();
    }
  }

  // ------------------------------------------------------------- playtest

  /// The playtest window this editor opened, if any. It is a process of its own
  /// (see playtest_window.dart), so the editor drives it by launching it with a
  /// level and reading the report it writes back.
  Process? _playtestWindow;
  Timer? _playtestPoll;
  Directory? _playtestDir;
  String? _playtestReportPath;

  /// What the window last told us, and whether it is the computer driving.
  PlaytestReport? playtestReport;
  bool playtestAuto = false;

  /// The skill the next auto playtest will run with, chosen in the panel. It is
  /// a preference, not part of any one run, so it outlives the window.
  AutoSkill playtestSkill = AutoSkill.high;

  /// The skill the window on screen is driving with, or null when nothing is
  /// running - or when a person is driving. Kept apart from [playtestSkill] so
  /// that a restart repeats the run that is on screen even after the selection
  /// has moved on to the next one.
  AutoSkill? playtestRunSkill;

  /// Choose the skill the next auto playtest runs with. The selection is kept
  /// even while a run is going: it is about the next run, not this one.
  void selectPlaytestSkill(AutoSkill skill) {
    if (skill == playtestSkill) return;
    playtestSkill = skill;
    notifyListeners();
  }

  /// Set when the level is edited while a window plays: that window plays the
  /// level as it was when it opened, so the map stops following it.
  bool playtestStale = false;

  /// Why a window could not be opened, if one could not be.
  String? playtestError;

  bool get playtestRunning => _playtestWindow != null;

  /// The executable a playtest window is launched from: this app's own, which is
  /// how the editor becomes the playtest window (see main.dart). A test that
  /// needs to launch the built bundle rather than the test runner overrides it.
  @visibleForTesting
  String get playtestExecutable => Platform.resolvedExecutable;

  /// The column the map's camera window is showing, or null when nothing is
  /// playing - or when the window is playing a level that has since changed.
  int? get cameraWindow =>
      playtestRunning && !playtestStale ? playtestReport?.camera : null;

  /// Open a playtest window on the level as it is now: [fromColumn] for "play
  /// from here", and [auto] to have the computer drive it, which is the auto
  /// playtest - the same window, testing the level rather than playing it.
  /// [skill] is how well the computer drives; it defaults to the panel's
  /// selection, and a restart passes the running window's own skill so that the
  /// run on screen is repeated rather than replaced.
  Future<void> openPlaytestWindow({
    int? fromColumn,
    bool auto = false,
    AutoSkill? skill,
  }) async {
    final runSkill = skill ?? playtestSkill;
    await closePlaytestWindow();
    playtestError = null;
    try {
      final dir = await Directory.systemTemp.createTemp('jumpman-playtest-');
      _playtestDir = dir;
      final levelFile = File(p.join(dir.path, 'level.json'));
      levelFile.writeAsStringSync(jsonEncode(_level.toJson(spec, projectName)));
      final reportFile = File(p.join(dir.path, 'report.json'));
      _playtestReportPath = reportFile.path;

      final options = PlaytestOptions(
        levelPath: levelFile.path,
        auto: auto,
        skill: runSkill,
        fromColumn: fromColumn,
        reportPath: reportFile.path,
      );
      final process = await Process.start(playtestExecutable, options.toArgs());
      _playtestWindow = process;
      playtestAuto = auto;
      playtestRunSkill = auto ? runSkill : null;
      playtestStale = false;
      playtestReport = null;
      status = auto
          ? 'the computer is testing the level in its own window '
              '(${runSkill.label} skill)'
          : 'playing in its own window'
              '${fromColumn == null ? '' : ' from column $fromColumn'}';
      _playtestPoll?.cancel();
      _playtestPoll = Timer.periodic(
          const Duration(milliseconds: 250), (_) => _readPlaytestReport());
      // The window can be closed on its own: when it goes, say so, and keep its
      // last report up so the run's outcome is still on screen.
      unawaited(process.exitCode.then((_) {
        if (identical(_playtestWindow, process)) {
          _playtestWindow = null;
          _playtestPoll?.cancel();
          _playtestPoll = null;
          status = auto
              ? 'the auto playtest window closed'
              : 'the playtest window closed';
          notifyListeners();
        }
      }));
    } on ProcessException catch (e) {
      playtestError = 'could not open the playtest window: ${e.message}';
      status = playtestError;
      await closePlaytestWindow();
    }
    notifyListeners();
  }

  /// Close the window, if one is open. The report is cleared with it: it is
  /// about a run that is over.
  Future<void> closePlaytestWindow() async {
    _playtestPoll?.cancel();
    _playtestPoll = null;
    final process = _playtestWindow;
    _playtestWindow = null;
    process?.kill();
    playtestReport = null;
    playtestStale = false;
    playtestAuto = false;
    playtestRunSkill = null;
    final dir = _playtestDir;
    _playtestDir = null;
    _playtestReportPath = null;
    if (dir != null) {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // A temporary directory left behind is the OS's problem, not ours.
      }
    }
  }

  /// Restart the window's run from the level's start - or from where the player
  /// is, for "play from here".
  Future<void> restartPlaytestWindow({bool fromHere = false}) async {
    if (!playtestRunning) return;
    await openPlaytestWindow(
      fromColumn: fromHere ? playtestReport?.playerX : null,
      auto: playtestAuto,
      skill: playtestRunSkill,
    );
  }

  void _readPlaytestReport() {
    final path = _playtestReportPath;
    if (path == null) return;
    try {
      final file = File(path);
      if (!file.existsSync()) return;
      final report =
          PlaytestReport.fromJson(jsonDecode(file.readAsStringSync()));
      if (report == null) return;
      final changed = report.tick != playtestReport?.tick ||
          report.lives != playtestReport?.lives ||
          report.status != playtestReport?.status;
      playtestReport = report;
      if (changed) notifyListeners();
    } on FileSystemException {
      // The window is between writes, or gone: the next tick will say.
    } on FormatException {
      // Half a report; the writer renames, so this should not happen.
    }
  }

  // -------------------------------------------------------------- scanning

  bool scanning = false;
  double scanProgress = 0;

  /// Sweep every pit and step. The results are hints and any edit drops them.
  Future<void> checkReachability() async {
    if (scanning) return;
    scanning = true;
    scanProgress = 0;
    _scanFindings = const [];
    notifyListeners();
    // A playtest window is a process of its own, so a scan and a playtest do not
    // contend for the game's one level: both can run.
    try {
      final report = await scanReachability(
        level: _level,
        spec: spec,
        onProgress: (value) {
          scanProgress = value;
          notifyListeners();
        },
        breathe: () => Future<void>.delayed(Duration.zero),
      );
      _scanFindings = report.findings;
      status = report.findings.isEmpty
          ? 'reachability: nothing unclearable (${report.runs} runs)'
          : 'reachability: ${report.findings.length} to look at '
              '(${report.runs} runs)';
    } on PlaytestException catch (e) {
      _scanFindings = [
        Finding(
          severity: FindingSeverity.error,
          message: e.message,
          fromScan: true,
        ),
      ];
      status = e.message;
    } finally {
      scanning = false;
      notifyListeners();
    }
  }

  // -------------------------------------------------------------- internals

  void _invalidate() {
    // An edit is about the level as it now is: a scan result was about the level
    // as it was, so it does not survive one. A playtest window keeps running -
    // it is the user's window, and closing it because they touched the map would
    // be rude - but it is playing the level as it was when it opened, so the map
    // stops following a run that is no longer about what is on screen.
    _scanFindings = const [];
    if (playtestRunning && !playtestStale) {
      playtestStale = true;
      status = 'the level changed: the playtest window is still playing the '
          'level it was opened on';
    }
    _revalidate();
  }

  void _revalidate() {
    _findings = validateLevel(_level, spec);
    notifyListeners();
  }

  /// The status line: what last happened, or what the checks say when nothing
  /// has.
  String get statusLine {
    final last = status;
    if (last != null) return last;
    if (_findings.isEmpty) return 'no structural findings';
    final errors =
        _findings.where((f) => f.severity == FindingSeverity.error).length;
    final warnings = _findings.length - errors;
    return '$errors ${errors == 1 ? 'error' : 'errors'}, '
        '$warnings ${warnings == 1 ? 'warning' : 'warnings'}';
  }

  @override
  void dispose() {
    unawaited(closePlaytestWindow());
    super.dispose();
  }
}

/// Open the editor on the level the game ships: resolve the repository, read the
/// level's shape out of the game, and import the level itself. Null when there is
/// no repository to open.
Future<EditorState?> openEditor() async {
  final source = await GameSource.resolve();
  if (source == null) return null;
  return openEditorAt(source);
}

/// Open the editor on an explicit source, which is what the file picker's answer
/// and the tests both need.
Future<EditorState> openEditorAt(GameSource source) async {
  final text = source.readGameSource();
  final spec = JumpmanSpec.parse(text, path: source.gameFile);
  final level =
      LevelSource.importFrom(source: text, spec: spec, path: source.gameFile);
  return EditorState(spec: spec, gameSource: source, level: level);
}
