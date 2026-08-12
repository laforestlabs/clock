// The game screen.
//
// Shows the game running on a simulated LED panel, driven by a ticker that
// steps the simulation every frame and renders the RGBA8888 bytes through the
// same paint path the layout preview uses: one emitter disc per lit cell with
// dead space between pixels, and the same veneer diffusion pass.
//
// The veneer and LED settings are shared with the designer through the
// DesignerController: changing them here changes the layout preview too, and
// vice versa. They are display-layer settings, not game state.
//
// Controls: arrow keys / WASD drive the game's direction controls (Up/Down for
// rally, a full d-pad for snake and tetris, Left/Right for breakout and
// invaders), Space fires where a game has a Shoot control and restarts
// otherwise, touch steers on a phone.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../controller.dart';
import '../engine/game_engine.dart';
import '../services/mirror_ble.dart';
import '../services/mirror_ble_game.dart';
import '../services/mirror_connection.dart';

/// How a touch on the panel maps to the running game's controls.
enum _TouchMode { vertical, horizontal, compass }

/// A game running on a simulated panel.
class GameScreen extends StatefulWidget {
  const GameScreen({
    super.key,
    required this.controller,
    required this.connection,
  });

  /// Shares veneer and LED settings with the layout designer.
  final DesignerController controller;

  /// The app-scoped BLE link. While connected, this screen becomes a gamepad
  /// for the game the mirror runs on its panel; the simulation below is only
  /// for the not-connected case.
  final MirrorConnection connection;

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen>
    with SingleTickerProviderStateMixin {
  late Ticker _ticker;
  late FocusNode _keyboardFocus;
  GameEngine? _engine;
  ui.Image? _image;
  Uint8List? _frame;
  Duration _lastTime = Duration.zero;

  // Panel sizes the game can run at, same set the hardware supports.
  static const _panelSizes = <_PanelPreset>[
    _PanelPreset('Mini (64x32)', 64, 32),
    _PanelPreset('Square (64x64)', 64, 64),
    _PanelPreset('Wide (128x64)', 128, 64),
    _PanelPreset('Large (128x128)', 128, 128),
  ];
  int _sizeIndex = 0;

  int _seed = 1;
  int _players = 1;
  bool _running = false;

  // Held key/touch state per control, sized when a game starts. The screen
  // feeds the full held state every frame, exactly like a controller client
  // would, so holding a key keeps the game moving.
  List<bool> _held = const <bool>[];

  List<GameInfo> _games = const <GameInfo>[];
  int _gameIndex = 0;

  DesignerController get _c => widget.controller;
  MirrorConnection get _connection => widget.connection;

  // Controller mode: the mirror runs the game, this phone streams buttons.
  List<String>? _mirrorGameIds;
  int _mirrorGameIndex = 0;
  MirrorGame? _mirrorGame;
  bool _mirrorUnsupported = false;
  bool _mirrorLoading = false;
  int _lastMirrorSendMs = 0;

  /// Whether this screen is a gamepad for a connected mirror.
  bool get _isControllerMode => _connection.session != null;

  @override
  void initState() {
    super.initState();
    // The game screen is operated like a handheld controller. Keep both
    // thumbs on the controls instead of allowing the phone to rotate back to
    // a narrow portrait layout while it is in use.
    unawaited(SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]));
    _games = GameEngine.games;
    _ticker = Ticker(_onTick);
    _keyboardFocus = FocusNode();
    _connection.addListener(_onConnectionChanged);
    // First evaluation after the first build: the connection may already be
    // up when the screen opens, and a listener that setStates during build
    // would assert.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onConnectionChanged());
  }

  @override
  void dispose() {
    // The rest of the designer supports either phone orientation.
    unawaited(SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]));
    _connection.removeListener(_onConnectionChanged);
    if (_mirrorGame != null) {
      // Leaving the screen stops the mirror's game.
      unawaited(_connection.session?.stopGame());
    }
    _ticker.stop();
    _keyboardFocus.dispose();
    _engine?.dispose();
    super.dispose();
  }

  void _startGame() {
    _engine?.dispose();
    final game = _games[_gameIndex];
    final panel = _panelSizes[_sizeIndex];
    setState(() {
      _engine = GameEngine.open(
        gameId: game.id,
        panelWidth: panel.w,
        panelHeight: panel.h,
        seed: _seed,
        players: _players,
      );
      _running = true;
      _image = null;
      _frame = null;
      _held = List<bool>.filled(game.controls.length, false);
    });
    _ticker.start();
    // Critical: reclaim focus after the Play button was tapped, so the Focus
    // wrapping the body gets keyboard events before the traversal system.
    _keyboardFocus.requestFocus();
    _seed++;
  }

  void _stopGame() {
    _ticker.stop();
    setState(() => _running = false);
  }

  /// The connection changed (connected, disconnected, failed). Keeps the
  /// controller-mode state in sync with the link.
  void _onConnectionChanged() {
    if (!mounted) return;
    setState(() {
      if (_connection.status == MirrorConnectionStatus.connected) {
        final session = _connection.session;
        if (session?.gameIn == null) {
          // Firmware predates the gamepad channel.
          _mirrorUnsupported = true;
        } else {
          _mirrorUnsupported = false;
          unawaited(_loadMirrorGames());
        }
      } else {
        // Disconnected: the firmware stops the game on its own (its
        // disconnect handler), so this is purely local cleanup.
        _mirrorGameIds = null;
        _mirrorGame = null;
        _mirrorGameIndex = 0;
        _mirrorUnsupported = false;
        _ticker.stop();
      }
    });
  }

  /// Fetch the mirror's game list once. A null reply (old firmware answering
  /// "unknown command") marks the mirror unsupported.
  Future<void> _loadMirrorGames() async {
    if (_mirrorLoading || _mirrorGameIds != null) return;
    _mirrorLoading = true;
    try {
      final session = _connection.session;
      if (session == null) return;
      final ids = await session.listGames();
      if (!mounted) return;
      setState(() {
        if (ids == null) {
          _mirrorUnsupported = true;
        } else {
          _mirrorGameIds = ids;
          _mirrorUnsupported = false;
        }
      });
    } finally {
      _mirrorLoading = false;
    }
  }

  Future<void> _startMirrorGame() async {
    final session = _connection.session;
    final ids = _mirrorGameIds;
    if (session == null || ids == null || ids.isEmpty) return;
    final id = ids[_mirrorGameIndex < ids.length ? _mirrorGameIndex : 0];
    try {
      final g = await session.startGame(id);
      if (!mounted) return;
      setState(() {
        _mirrorGame = g;
        _held = List<bool>.filled(g.controls.length, false);
      });
      // Ticker.start returns a TickerFuture; the tick's completion is
      // irrelevant here.
      unawaited(_ticker.start());
    } on BlePushException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not start the game: ${e.message}')),
      );
    }
  }

  Future<void> _stopMirrorGame() async {
    final session = _connection.session;
    _ticker.stop();
    setState(() => _mirrorGame = null);
    await session?.stopGame();
  }

  /// Display name for a mirror game id: the local simulation's name when the
  /// app knows the id, otherwise the raw id.
  String _mirrorGameLabel(String id) {
    for (final g in _games) {
      if (g.id == id) return g.name;
    }
    return id;
  }

  void _onTick(Duration elapsed) {
    final mirrorGame = _mirrorGame;
    if (mirrorGame != null) {
      // Controller mode: stream the full held state, throttled to one
      // packet per 30 ms so a 60 fps ticker does not flood the link.
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastMirrorSendMs >= 30) {
        _lastMirrorSendMs = now;
        unawaited(_connection.session?.sendGameInput(_held));
      }
      return;
    }

    final engine = _engine;
    if (engine == null || !_running) return;

    final dt = _lastTime == Duration.zero
        ? const Duration(milliseconds: 16)
        : elapsed - _lastTime;
    _lastTime = elapsed;

    // Feed held state every frame so motion continues while held. The full
    // held state is delivered each frame (every control, pressed or not),
    // which is the contract the runtime's held-input tests pin down.
    final game = _games[_gameIndex];
    for (var i = 0; i < game.controls.length; i++) {
      final held = i < _held.length && _held[i];
      engine.button(playerId: 1, code: i, value: held ? 1 : 0);
    }

    final ms = dt.inMilliseconds.clamp(1, 100);
    engine.step(ms);

    final bytes = engine.renderBytes();
    if (bytes == null) return;

    engine.decodeImage(bytes).then((img) {
      if (!mounted || !_running) return;
      setState(() {
        _image = img;
        _frame = bytes;
      });
    });
  }

  // The onKeyEvent handler returns KeyEventResult.handled for arrow keys,
  // which consumes the event before Flutter's directional focus traversal can
  // act on it. This is the fix: as long as the Focus wrapping the body is the
  // primary focus, arrows never escape to move focus between widgets.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // Consume arrow keys on every event type, including KeyRepeatEvent.
    // A held arrow key produces KeyDown then a stream of KeyRepeatEvents;
    // returning ignored for those lets Flutter's directional focus traversal
    // see the arrows and move focus to the dropdowns, stealing control.
    if (event is! KeyDownEvent &&
        event is! KeyRepeatEvent &&
        event is! KeyUpEvent) {
      return KeyEventResult.ignored;
    }
    final pressed = event is! KeyUpEvent;

    // Space fires the game's Shoot control when it has one, and starts the
    // game otherwise.
    if (event.logicalKey == LogicalKeyboardKey.space) {
      final shoot = _controlIndexForLabel('Shoot');
      if (shoot != null) {
        if (shoot < _held.length) _held[shoot] = pressed;
      } else if (pressed) {
        _startGame();
      }
      return KeyEventResult.handled;
    }

    // Direction keys map to the game's controls by label, so rally (Up/Down)
    // and snake (Up/Down/Left/Right) share one handler and a game that
    // reorders its controls keeps working.
    final control = _controlIndexFor(event.logicalKey);
    if (control != null) {
      if (control < _held.length) _held[control] = pressed;
      return KeyEventResult.handled;
    }

    switch (event.logicalKey) {
      case LogicalKeyboardKey.escape:
        if (pressed) _stopGame();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Games'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.sports_esports),
            tooltip: 'Play',
            onPressed: _isControllerMode
                ? (_mirrorGame == null &&
                        !_mirrorUnsupported &&
                        (_mirrorGameIds?.isNotEmpty ?? false)
                    ? _startMirrorGame
                    : null)
                : (_running ? null : _startGame),
          ),
          IconButton(
            icon: const Icon(Icons.stop),
            tooltip: 'Stop',
            onPressed: _isControllerMode
                ? (_mirrorGame != null ? _stopMirrorGame : null)
                : (_running ? _stopGame : null),
          ),
        ],
      ),
      // While connected to a mirror, the body is the gamepad; the Focus
      // wrapper (and its keyboard handling) is for the local simulation
      // only.
      body: _isControllerMode
          ? _buildControllerBody()
          : _games.isEmpty
              ? const Center(child: Text('No games compiled into this build.'))
              : Focus(
                  focusNode: _keyboardFocus,
                  onKeyEvent: _onKey,
                  autofocus: true,
                  child: AnimatedBuilder(
                    animation: _c,
                    builder: (context, _) => Column(
                      children: <Widget>[
                        _buildControls(),
                        Expanded(child: _buildCanvasArea()),
                      ],
                    ),
                  ),
                ),
    );
  }

  Widget _buildControls() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Wrap(
        spacing: 12,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          // Disable controls while running so they cannot be interacted with
          // or gain focus. ExcludeFocus removes them from the tab order.
          ExcludeFocus(
            excluding: _running,
            child: DropdownButton<int>(
              value: _gameIndex,
              items: [
                for (var i = 0; i < _games.length; i++)
                  DropdownMenuItem(
                    value: i,
                    child: Text(_games[i].name),
                  ),
              ],
              onChanged: _running
                  ? null
                  : (v) => setState(() {
                        _gameIndex = v!;
                        // A game may cap players below the previous selection.
                        if (_players > _games[_gameIndex].maxPlayers) {
                          _players = _games[_gameIndex].maxPlayers;
                        }
                      }),
            ),
          ),
          ExcludeFocus(
            excluding: _running,
            child: DropdownButton<int>(
              value: _sizeIndex,
              items: [
                for (var i = 0; i < _panelSizes.length; i++)
                  DropdownMenuItem(
                    value: i,
                    child: Text(_panelSizes[i].label),
                  ),
              ],
              onChanged:
                  _running ? null : (v) => setState(() => _sizeIndex = v!),
            ),
          ),
          ExcludeFocus(
            excluding: _running,
            child: DropdownButton<int>(
              value: _players,
              items: [
                for (var p = 1; p <= _games[_gameIndex].maxPlayers; p++)
                  DropdownMenuItem(
                    value: p,
                    child: Text('$p player${p > 1 ? "s" : ""}'),
                  ),
              ],
              onChanged: _running ? null : (v) => setState(() => _players = v!),
            ),
          ),
          // Veneer slider: shared with the designer through _c.veneer.
          Row(mainAxisSize: MainAxisSize.min, children: [
            const Text('veneer', style: TextStyle(fontSize: 12)),
            SizedBox(
              width: 100,
              child: Slider(
                value: _c.veneer,
                min: 0,
                max: 100,
                onChanged: (v) => _c.veneer = v,
              ),
            ),
          ]),
          // LED toggle: shared with the designer through _c.ledPixels.
          SizedBox(
            width: 120,
            child: SwitchListTile(
              dense: true,
              title: const Text('LED', style: TextStyle(fontSize: 12)),
              value: _c.ledPixels,
              onChanged: (v) => _c.ledPixels = v,
            ),
          ),
          Text('tick: ${_engine?.tick ?? 0}',
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      ),
    );
  }

  /// The controller-mode body: a gamepad for the game the mirror runs. The
  /// mirror is the display, so there is no simulated panel here.
  Widget _buildControllerBody() {
    if (_mirrorUnsupported) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            "This mirror's firmware does not support games over Bluetooth. "
            'Update the firmware to enable the gamepad.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final game = _mirrorGame;
    if (game == null) {
      final ids = _mirrorGameIds;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'Playing on ${_connection.deviceName ?? 'the mirror'}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            if (ids == null || ids.isEmpty)
              const Text('Loading games...')
            else
              DropdownButton<int>(
                value: _mirrorGameIndex < ids.length ? _mirrorGameIndex : 0,
                items: <DropdownMenuItem<int>>[
                  for (var i = 0; i < ids.length; i++)
                    DropdownMenuItem(
                      value: i,
                      child: Text(_mirrorGameLabel(ids[i])),
                    ),
                ],
                onChanged: (v) => setState(() => _mirrorGameIndex = v ?? 0),
              ),
            const SizedBox(height: 24),
            const Text(
              'The mirror shows the game on its panel; this phone is the '
              'gamepad.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ],
        ),
      );
    }

    return _buildGamepad(game);
  }

  /// A landscape gamepad with movement under the left thumb and action
  /// buttons under the right thumb.
  Widget _buildGamepad(MirrorGame game) {
    final controls = game.controls;

    int indexOf(String label) {
      for (var i = 0; i < controls.length; i++) {
        if (controls[i] == label) return i;
      }
      return -1;
    }

    final up = indexOf('Up');
    final down = indexOf('Down');
    final left = indexOf('Left');
    final right = indexOf('Right');

    // Anything that is not a direction renders as a fire button.
    const directions = <String>{'Up', 'Down', 'Left', 'Right'};
    final extras = <int>[
      for (var i = 0; i < controls.length; i++)
        if (!directions.contains(controls[i])) i,
    ];

    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Three d-pad rows plus their gaps should fit without scrolling on
          // a small phone, while larger screens get a comfortably large hit
          // target. The clamp keeps every button well above the 48dp minimum.
          final heightLimitedSize = (constraints.maxHeight - 58) / 3.35;
          final widthLimitedSize = (constraints.maxWidth - 64) / 6.4;
          final availableSize = heightLimitedSize < widthLimitedSize
              ? heightLimitedSize
              : widthLimitedSize;
          final buttonSize = availableSize.clamp(64.0, 112.0);
          final gap = (buttonSize * .12).clamp(8.0, 14.0);

          Widget direction(int index) => index < 0
              ? SizedBox.square(dimension: buttonSize)
              : _padButton(game, index, size: buttonSize);

          final hasFourDirections =
              up >= 0 && down >= 0 && left >= 0 && right >= 0;
          final Widget pad = hasFourDirections
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    direction(up),
                    SizedBox(height: gap),
                    Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
                      direction(left),
                      SizedBox(width: gap),
                      SizedBox.square(dimension: buttonSize),
                      SizedBox(width: gap),
                      direction(right),
                    ]),
                    SizedBox(height: gap),
                    direction(down),
                  ],
                )
              : up >= 0 && down >= 0
                  ? Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
                      direction(up),
                      SizedBox(height: gap),
                      direction(down),
                    ])
                  : Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
                      if (left >= 0) direction(left),
                      if (left >= 0 && right >= 0) SizedBox(width: gap),
                      if (right >= 0) direction(right),
                    ]);

          return Stack(
            alignment: Alignment.topCenter,
            children: <Widget>[
              Text(
                _mirrorGameLabel(game.id),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Padding(
                padding: const EdgeInsets.only(top: 34),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    Expanded(
                        child:
                            Align(alignment: Alignment.centerLeft, child: pad)),
                    const SizedBox(width: 24),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Wrap(
                          spacing: gap,
                          runSpacing: gap,
                          alignment: WrapAlignment.end,
                          children: <Widget>[
                            for (final index in extras)
                              _padButton(game, index, size: buttonSize),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// One gamepad button: tap down presses, tap up/cancel releases. The
  /// pressed visual follows the held state.
  Widget _padButton(
    MirrorGame game,
    int controlIndex, {
    double size = 88,
  }) {
    final pressed = controlIndex < _held.length && _held[controlIndex];
    final label = game.controls[controlIndex];
    final Widget child = switch (label) {
      'Up' => Icon(Icons.keyboard_arrow_up, size: size * .52),
      'Down' => Icon(Icons.keyboard_arrow_down, size: size * .52),
      'Left' => Icon(Icons.keyboard_arrow_left, size: size * .52),
      'Right' => Icon(Icons.keyboard_arrow_right, size: size * .52),
      _ => Text(
          label,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
    };
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() {
        if (controlIndex < _held.length) _held[controlIndex] = true;
      }),
      onTapUp: (_) => setState(() {
        if (controlIndex < _held.length) _held[controlIndex] = false;
      }),
      onTapCancel: () => setState(() {
        if (controlIndex < _held.length) _held[controlIndex] = false;
      }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 70),
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: pressed
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        child: child,
      ),
    );
  }

  /// The canvas area: computes an integer zoom that fills the available space,
  /// then draws the game at that zoom with the same LED + veneer paint path
  /// the layout preview uses.
  Widget _buildCanvasArea() {
    final engine = _engine;
    if (engine == null || _image == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sports_esports, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text(
              'Press Play or Space to start.\n'
              'Arrow keys / WASD move or steer, Space fires.\n'
              'Touch the panel to move on a phone.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
          ],
        ),
      );
    }

    final cw = engine.width;
    final ch = engine.height;

    return LayoutBuilder(
      builder: (context, constraints) {
        final zw = (constraints.maxWidth / cw).floor();
        final zh = (constraints.maxHeight / ch).floor();
        var zoom = zw < zh ? zw : zh;
        if (zoom < 1) zoom = 1;

        final w = cw * zoom;
        final h = ch * zoom;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _handleTouch(
              d.localPosition, true, Size(w.toDouble(), h.toDouble())),
          onTapUp: (_) => _releaseAll(),
          onTapCancel: () => _releaseAll(),
          onPanEnd: (_) => _releaseAll(),
          onPanCancel: () => _releaseAll(),
          child: Center(
            child: SizedBox(
              width: w.toDouble(),
              height: h.toDouble(),
              child: CustomPaint(
                isComplex: true,
                painter: _GamePainter(
                  image: _image,
                  frame: _frame,
                  zoom: zoom.toDouble(),
                  ledPixels: _c.ledPixels,
                  veneer: _c.veneer,
                  canvasWidth: cw,
                  canvasHeight: ch,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _handleTouch(Offset local, bool pressed, Size renderSize) {
    final midY = renderSize.height / 2;
    final midX = renderSize.width / 2;
    setState(() {
      switch (_touchMode()) {
        case _TouchMode.compass:
          // A d-pad compass on the panel: top-left Up, top-right Right,
          // bottom-right Down, bottom-left Left.
          final String label;
          if (local.dy < midY) {
            label = local.dx < midX ? 'Up' : 'Right';
          } else {
            label = local.dx < midX ? 'Left' : 'Down';
          }
          for (final d in const <String>['Up', 'Down', 'Left', 'Right']) {
            _setHeld(d, d == label ? pressed : false);
          }
          break;
        case _TouchMode.horizontal:
          // Left and right halves of the panel steer (breakout, invaders).
          _setHeld('Left', local.dx < midX ? pressed : false);
          _setHeld('Right', local.dx >= midX ? pressed : false);
          break;
        case _TouchMode.vertical:
          // Top and bottom halves move up and down (rally).
          _setHeld('Up', local.dy < midY ? pressed : false);
          _setHeld('Down', local.dy >= midY ? pressed : false);
          break;
      }
    });
  }

  void _releaseAll() {
    setState(() {
      for (var i = 0; i < _held.length; i++) {
        _held[i] = false;
      }
    });
  }

  /// How touch on the panel maps to the running game's controls.
  _TouchMode _touchMode() {
    final controls = _games[_gameIndex].controls;
    final hasUp = controls.contains('Up');
    final hasDown = controls.contains('Down');
    final hasLeft = controls.contains('Left');
    final hasRight = controls.contains('Right');
    if (hasUp && hasDown && hasLeft && hasRight) return _TouchMode.compass;
    if (hasLeft && hasRight) return _TouchMode.horizontal;
    return _TouchMode.vertical;
  }

  /// Set the held state of the control labelled [label], if the game has one.
  void _setHeld(String label, bool value) {
    final controls = _games[_gameIndex].controls;
    for (var i = 0; i < controls.length && i < _held.length; i++) {
      if (controls[i] == label) {
        _held[i] = value;
        return;
      }
    }
  }

  /// Map a key to the index of the control it drives, by control label.
  /// Not const: LogicalKeyboardKey overrides ==/hashCode, which a const map
  /// key cannot do.
  static final Map<LogicalKeyboardKey, String> _keyLabels =
      <LogicalKeyboardKey, String>{
    LogicalKeyboardKey.arrowUp: 'Up',
    LogicalKeyboardKey.keyW: 'Up',
    LogicalKeyboardKey.arrowDown: 'Down',
    LogicalKeyboardKey.keyS: 'Down',
    LogicalKeyboardKey.arrowLeft: 'Left',
    LogicalKeyboardKey.keyA: 'Left',
    LogicalKeyboardKey.arrowRight: 'Right',
    LogicalKeyboardKey.keyD: 'Right',
  };

  /// Map a control label to its index, or null when the game has no such
  /// control.
  int? _controlIndexForLabel(String label) {
    final controls = _games[_gameIndex].controls;
    for (var i = 0; i < controls.length; i++) {
      if (controls[i] == label) return i;
    }
    return null;
  }

  int? _controlIndexFor(LogicalKeyboardKey key) {
    final label = _keyLabels[key];
    if (label == null) return null;
    return _controlIndexForLabel(label);
  }
}

/// Paints the game frame as a pixel-exact LED panel.
///
/// Same two-pass approach as _PanelPainter in panel_view.dart: first the
/// emitter discs (or the crisp bitmap when LED is off), then the veneer scatter
/// pass for the diffusion that a wood face over the matrix would add.
class _GamePainter extends CustomPainter {
  _GamePainter({
    required this.image,
    required this.frame,
    required this.zoom,
    required this.ledPixels,
    required this.veneer,
    required this.canvasWidth,
    required this.canvasHeight,
  });

  final ui.Image? image;
  final Uint8List? frame;
  final double zoom;

  /// Whether to draw discrete emitters rather than the smooth bitmap.
  final bool ledPixels;

  /// Veneer diffusion strength, 0 to 100.
  final double veneer;
  final int canvasWidth;
  final int canvasHeight;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRect(bounds, Paint()..color = const Color(0xFF000000));

    final img = image;
    if (img == null) return;

    // Calibrated so 100% is what 50% meant before the slider was rebased:
    // the diffusion strength is half the slider value.
    final v = veneer / 200;
    final src =
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
    final dst = Rect.fromLTWH(0, 0, canvasWidth * zoom, canvasHeight * zoom);

    if (!ledPixels || frame == null || zoom < 3) {
      final paint = Paint()
        ..filterQuality = FilterQuality.none
        ..isAntiAlias = false;
      if (v <= 0) {
        canvas.drawImageRect(img, src, dst, paint);
      } else {
        canvas.saveLayer(
          bounds,
          Paint()
            ..imageFilter =
                ui.ImageFilter.blur(sigmaX: zoom * 8 * v, sigmaY: zoom * 8 * v),
        );
        canvas.drawImageRect(img, src, dst, paint);
        canvas.restore();
      }
      return;
    }

    _paintLed(canvas, img, bounds, v);
  }

  /// The panel as a field of point sources, ported from _PanelPainter.
  void _paintLed(Canvas canvas, ui.Image img, Rect bounds, double v) {
    final pixels = frame!;
    const emitterPitch = 0.68;
    final radius = zoom * emitterPitch / 2;
    final half = zoom * 0.5;
    final paint = Paint()..isAntiAlias = true;
    if (v > 0) {
      paint.maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, zoom * 2 * v);
    }

    if (v > 0) {
      _drawScatter(canvas, img, bounds, zoom * 5 * v, 0.50 * v);
      _drawScatter(canvas, img, bounds, zoom * 1.8 * v, 0.65 * v);
    }

    for (var y = 0; y < canvasHeight; y++) {
      final cy = y * zoom + half;
      final row = y * canvasWidth * 4;
      for (var x = 0; x < canvasWidth; x++) {
        final i = row + x * 4;
        final r = pixels[i];
        final g = pixels[i + 1];
        final b = pixels[i + 2];
        if (r == 0 && g == 0 && b == 0) continue;
        paint.color = Color.fromARGB(255, r, g, b);
        canvas.drawCircle(Offset(x * zoom + half, cy), radius, paint);
      }
    }
  }

  void _drawScatter(
      Canvas canvas, ui.Image img, Rect bounds, double sigma, double opacity) {
    canvas.saveLayer(
      bounds,
      Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
    );
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Rect.fromLTWH(0, 0, canvasWidth * zoom, canvasHeight * zoom),
      Paint()
        ..filterQuality = FilterQuality.none
        ..isAntiAlias = false
        ..colorFilter = ColorFilter.mode(
            Color.fromRGBO(255, 255, 255, opacity), BlendMode.modulate),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GamePainter old) =>
      old.image != image ||
      old.frame != frame ||
      old.zoom != zoom ||
      old.ledPixels != ledPixels ||
      old.veneer != veneer ||
      old.canvasWidth != canvasWidth ||
      old.canvasHeight != canvasHeight;
}

class _PanelPreset {
  const _PanelPreset(this.label, this.w, this.h);
  final String label;
  final int w, h;
}
