// The playtest window: the level, played in a window of its own.
//
// The editor opens it as a second process, telling it which level to play (see
// PlaytestOptions and editor_state.dart). A process rather than a second window
// in one, for two reasons. The game's level injection is process-wide, so a
// window of its own is what keeps a playtest from moving the level a scan is
// probing; and a real window can be moved to another screen, resized and left
// open beside the editor while the level is edited against it.
//
// It opens nearly maximized (linux/runner/my_application.cc, patched by
// setup.sh, sizes it that way when it sees --playtest), and the panel is drawn
// at the largest whole-number scale that fits: the panel is 64x32, so anything
// but a whole number turns the game's pixels into mush.
//
// The computer can drive it. That is the auto playtest: the same window, with a
// bot at the controls instead of a person, for testing a level you have just
// changed rather than playing it.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'autoplay.dart';
import 'game_source.dart';
import 'jump_level.dart';
import 'jumpman_spec.dart';
import 'playtest.dart';

/// What the editor told this window to play.
///
/// The window is launched with a command line, and this is the one place that
/// protocol is stated: the editor builds the arguments with [toArgs] and the
/// window reads them with [fromArgs], so the two cannot disagree.
class PlaytestOptions {
  const PlaytestOptions({
    required this.levelPath,
    this.auto = false,
    this.skill = AutoSkill.high,
    this.fromColumn,
    this.reportPath,
  });

  /// The level to play, as a project file: the editor writes one out for the
  /// window, so an unsaved level plays exactly as it looks.
  final String levelPath;

  /// Whether the computer drives instead of a person.
  final bool auto;

  /// How well the computer drives, when it is driving. Ignored when a person
  /// is at the keys.
  final AutoSkill skill;

  /// The column to start from, for "play from here".
  final int? fromColumn;

  /// Where to write the read-out the editor follows. Null when nobody is
  /// watching.
  final String? reportPath;

  static const String _playtestFlag = '--playtest';
  static const String _autoFlag = '--auto';
  static const String _skillFlag = '--skill';
  static const String _fromFlag = '--from';
  static const String _reportFlag = '--report';

  List<String> toArgs() => [
        _playtestFlag,
        levelPath,
        // The skill only means something to the computer, so it travels with
        // the flag that tells the window the computer is driving.
        if (auto) ...[_autoFlag, _skillFlag, skill.name],
        if (fromColumn != null) ...[_fromFlag, '$fromColumn'],
        if (reportPath != null) ...[_reportFlag, reportPath!],
      ];

  /// The options in a command line, or null when this is the editor itself.
  static PlaytestOptions? fromArgs(List<String> args) {
    String? value(String flag) {
      final at = args.indexOf(flag);
      if (at < 0 || at + 1 >= args.length) return null;
      return args[at + 1];
    }

    final level = value(_playtestFlag);
    if (level == null) return null;
    final from = value(_fromFlag);
    return PlaytestOptions(
      levelPath: level,
      auto: args.contains(_autoFlag),
      skill: _readSkill(args),
      fromColumn: from == null ? null : int.tryParse(from),
      reportPath: value(_reportFlag),
    );
  }

  /// The skill a command line names, or [AutoSkill.high] when it names none -
  /// which is what a command line from before the skills existed names. A skill
  /// that is not one of the three is a command line that cannot be obeyed, so it
  /// is rejected rather than quietly guessed at.
  static AutoSkill _readSkill(List<String> args) {
    final at = args.indexOf(_skillFlag);
    if (at < 0) return AutoSkill.high;
    if (at + 1 >= args.length) {
      throw const FormatException('--skill needs one of high, medium or low');
    }
    final name = args[at + 1];
    for (final skill in AutoSkill.values) {
      if (skill.name == name) return skill;
    }
    throw FormatException(
        'unknown skill "$name": expected high, medium or low');
  }
}

/// The playtest window's application.
class PlaytestWindowApp extends StatelessWidget {
  const PlaytestWindowApp({super.key, required this.options});

  final PlaytestOptions options;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Jumpman playtest',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF48B050),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: PlaytestWindow(options: options),
    );
  }
}

/// One playtest: a level, a session on it, and whoever is driving.
class PlaytestWindow extends StatefulWidget {
  const PlaytestWindow({super.key, required this.options});

  final PlaytestOptions options;

  @override
  State<PlaytestWindow> createState() => _PlaytestWindowState();
}

class _PlaytestWindowState extends State<PlaytestWindow>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final FocusNode _focus = FocusNode(debugLabel: 'playtest-window');

  JumpmanSpec? _spec;
  JumpLevel? _level;
  Playtest? _session;
  AutoPlayer? _bot;
  String? _error;

  /// Whether the computer is driving. A key hands the controls back.
  late bool _auto = widget.options.auto;
  bool _playing = true;

  ui.Image? _image;
  bool _decoding = false;
  bool _pending = false;
  Duration _last = Duration.zero;
  int _accumMicros = 0;

  int _reached = 0;
  int _deaths = 0;
  int _diedAt = -1;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    _load();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _focus.dispose();
    _session?.dispose();
    _image?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      // The level's shape comes from the game, exactly as in the editor: this
      // window and the editor read the same source, so a level cannot mean two
      // things in two windows.
      final source = await GameSource.resolve();
      if (source == null || !File(source.gameFile).existsSync()) {
        setState(() => _error = 'The game source could not be found, so the '
            'level\'s shape cannot be read.');
        return;
      }
      final spec =
          JumpmanSpec.parse(source.readGameSource(), path: source.gameFile);
      final decoded =
          jsonDecode(File(widget.options.levelPath).readAsStringSync());
      if (decoded is! Map<String, Object?>) {
        setState(() => _error = '${widget.options.levelPath} is not a level.');
        return;
      }
      final level =
          JumpLevel.fromJson(decoded, spec, path: widget.options.levelPath);
      setState(() {
        _spec = spec;
        _level = level;
      });
      _open(fromColumn: widget.options.fromColumn);
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _focus.requestFocus());
    } on JumpmanSpecException catch (e) {
      setState(() => _error = e.message);
    } on LevelFormatException catch (e) {
      setState(() => _error = e.message);
    } on FileSystemException catch (e) {
      setState(() => _error = '${e.path}: ${e.message}');
    } on FormatException catch (e) {
      setState(() =>
          _error = '${widget.options.levelPath} is not readable: ${e.message}');
    }
  }

  /// Open a session on the level, from [fromColumn] when one is given.
  void _open({int? fromColumn}) {
    final level = _level;
    final spec = _spec;
    if (level == null || spec == null) return;
    _session?.dispose();
    try {
      _session = Playtest.open(level: level, spec: spec, startX: fromColumn);
    } on PlaytestException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    _bot = AutoPlayer(
      level: level,
      spec: spec,
      skill: widget.options.skill,
    );
    _playing = true;
    _accumMicros = 0;
    _writeReport();
  }

  // --------------------------------------------------------------- the run

  void _onTick(Duration elapsed) {
    final delta = elapsed - _last;
    _last = elapsed;
    final session = _session;
    final spec = _spec;
    if (session == null || spec == null || !_playing) return;

    _accumMicros += delta.inMicroseconds;
    final stepMicros = spec.tickMs * 1000;
    var steps = 0;
    var stop = false;
    while (!stop && _accumMicros >= stepMicros) {
      _accumMicros -= stepMicros;
      stop = !_step(session);
      steps++;
    }
    if (steps == 0) return;
    if (stop) setState(() => _playing = false);
    _requestFrame();
    _writeReport();
  }

  /// One tick, with whoever is driving. False when the run is over.
  bool _step(Playtest session) {
    final bot = _bot;
    if (_auto && bot != null && !bot.isStuck) {
      final input = bot.next(
        playerX: session.playerX,
        onGround: session.onGround,
        enemyGap: session.enemyGap,
        enemyKind: session.enemyKind,
        plantOut: session.plantOut,
      );
      session.setRight(input.right);
      if (input.jump) {
        session.pressJump();
      } else {
        session.releaseJump();
      }
    }
    session.step();

    if (session.playerX > _reached) _reached = session.playerX;
    final death = session.deathColumn;
    if (death != null && death != _diedAt) {
      _deaths++;
      _diedAt = death;
    }
    if (session.isOver) return false;
    if (_auto && (bot?.isStuck ?? false)) return false;
    return true;
  }

  PlaytestReport _report(Playtest session) => PlaytestReport(
        tick: session.tick,
        playerX: session.playerX,
        playerY: session.playerY,
        camera: session.camera,
        lives: session.lives,
        status: session.status,
        auto: _auto,
        reached: _reached,
        deaths: _deaths,
        diedAt: _diedAt < 0 ? null : _diedAt,
        stuckAt: _bot?.stuckAt,
      );

  /// Tell the editor where the run is. Written and renamed, so a reader never
  /// sees half a report.
  void _writeReport() {
    final path = widget.options.reportPath;
    final session = _session;
    if (path == null || session == null) return;
    try {
      final temp = File('$path.tmp');
      temp.writeAsStringSync(jsonEncode(_report(session).toJson()));
      temp.renameSync(path);
    } on FileSystemException {
      // The editor closed and took its directory with it: the window is still a
      // playtest, so this is not worth interrupting the run for.
    }
  }

  // ------------------------------------------------------------ the frames

  void _requestFrame() {
    if (_decoding) {
      _pending = true;
      return;
    }
    final session = _session;
    final bytes = session?.frame();
    if (session == null || bytes == null) return;
    _decoding = true;
    session.decode(bytes).then((image) {
      if (!mounted) {
        image?.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = image;
      });
      _decoding = false;
      if (_pending) {
        _pending = false;
        _requestFrame();
      }
    });
  }

  // ------------------------------------------------------------- the keys

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent &&
        event is! KeyUpEvent &&
        event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final session = _session;
    if (session == null) return KeyEventResult.ignored;

    // A hand on the controls takes them back from the computer.
    if (_auto && event is KeyDownEvent) {
      setState(() => _auto = false);
      _bot?.release();
      session.releaseAll();
    }

    final down = event is KeyDownEvent || event is KeyRepeatEvent;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.keyA) {
      session.setLeft(down);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.keyD) {
      session.setRight(down);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.keyW) {
      if (down) {
        session.pressJump();
      } else {
        session.releaseJump();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyP && event is KeyDownEvent) {
      setState(() => _playing = !_playing);
      if (!_playing) session.releaseAll();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyR && event is KeyDownEvent) {
      _open();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // --------------------------------------------------------------- the UI

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spec = _spec;
    final session = _session;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _focus,
        onKeyEvent: _onKey,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _focus.requestFocus(),
          child: SafeArea(
            child: Column(
              children: [
                Container(
                  color: theme.colorScheme.surfaceContainerHigh,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    children: [
                      Icon(
                          _auto
                              ? Icons.smart_toy_outlined
                              : Icons.videogame_asset,
                          size: 18),
                      const SizedBox(width: 8),
                      Text(
                          _auto
                              ? 'auto playtest · ${widget.options.skill.label}'
                              : 'playtest',
                          style: theme.textTheme.titleSmall),
                      const SizedBox(width: 16),
                      if (_error != null)
                        Expanded(
                          child: Text(_error!,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: theme.colorScheme.error)),
                        )
                      else if (session != null)
                        Expanded(
                          child: Text(
                            'tick ${session.tick}   column ${session.playerX}'
                            '${spec == null ? '' : ' of ${spec.cols}'}   '
                            'lives ${session.lives}   ${_statusName(session.status)}'
                            '${_auto ? '   ${_report(session).summary()}' : ''}',
                            style: theme.textTheme.bodyMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                        )
                      else
                        const Expanded(child: Text('opening...')),
                      _controls(),
                    ],
                  ),
                ),
                Expanded(
                  child: Center(
                    child: _error != null
                        ? const SizedBox.shrink()
                        : _screen(theme),
                  ),
                ),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: Text(
                    'Left/A and Right/D run, Space/Up/W jumps, P pauses, '
                    'R restarts. The window plays the level as it was when it was '
                    'opened.',
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _controls() {
    return Row(
      children: [
        IconButton(
          tooltip: _playing ? 'pause (or press P)' : 'play (or press P)',
          onPressed: _session == null
              ? null
              : () {
                  setState(() => _playing = !_playing);
                  if (!_playing) _session!.releaseAll();
                },
          icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
        ),
        IconButton(
          tooltip: 'restart from the level\'s start',
          onPressed: _session == null ? null : () => _open(),
          icon: const Icon(Icons.restart_alt),
        ),
        IconButton(
          tooltip: 'play from here',
          onPressed: _session == null
              ? null
              : () => _open(fromColumn: _session!.playerX),
          icon: const Icon(Icons.flag_outlined),
        ),
        const SizedBox(width: 8),
        FilterChip(
          selected: _auto,
          onSelected: (value) {
            setState(() {
              _auto = value;
              if (!value) {
                _bot?.release();
                _session?.releaseAll();
              } else {
                _playing = true;
              }
            });
          },
          avatar: const Icon(Icons.smart_toy_outlined, size: 16),
          label: const Text('computer plays'),
        ),
      ],
    );
  }

  /// The panel, at the largest whole-number scale that fits the window.
  Widget _screen(ThemeData theme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final byWidth = (constraints.maxWidth / kPanelWidth).floor();
        final byHeight = (constraints.maxHeight / kPanelHeight).floor();
        final scale =
            (byWidth < byHeight ? byWidth : byHeight).clamp(1, 64).toInt();
        return Container(
          decoration: BoxDecoration(
            border: Border.all(color: theme.dividerColor),
          ),
          width: (kPanelWidth * scale).toDouble(),
          height: (kPanelHeight * scale).toDouble(),
          child: _image == null
              ? Center(
                  child: Text('no frame', style: theme.textTheme.bodySmall))
              : RawImage(
                  image: _image,
                  width: (kPanelWidth * scale).toDouble(),
                  height: (kPanelHeight * scale).toDouble(),
                  // fill, not the default: without a fit an image is drawn at
                  // its own pixel size inside whatever box it is given, which
                  // for a 64x32 panel on a full-screen window is a speck in the
                  // middle of it.
                  fit: BoxFit.fill,
                  // The pixels are the point: smoothing turns them to mush.
                  filterQuality: FilterQuality.none,
                ),
        );
      },
    );
  }

  static String _statusName(int status) {
    switch (status) {
      case kStatusPlaying:
        return 'playing';
      case kStatusDying:
        return 'dying';
      case kStatusWon:
        return 'won';
      case kStatusOver:
        return 'over';
    }
    return '$status';
  }
}
