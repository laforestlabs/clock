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

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../controller.dart';
import '../engine/game_engine.dart';

/// How a touch on the panel maps to the running game's controls.
enum _TouchMode { vertical, horizontal, compass }

/// A game running on a simulated panel.
class GameScreen extends StatefulWidget {
  const GameScreen({super.key, required this.controller});

  /// Shares veneer and LED settings with the layout designer.
  final DesignerController controller;

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

  @override
  void initState() {
    super.initState();
    _games = GameEngine.games;
    _ticker = Ticker(_onTick);
    _keyboardFocus = FocusNode();
  }

  @override
  void dispose() {
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

  void _onTick(Duration elapsed) {
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
            onPressed: _running ? null : _startGame,
          ),
          IconButton(
            icon: const Icon(Icons.stop),
            tooltip: 'Stop',
            onPressed: _running ? _stopGame : null,
          ),
        ],
      ),
      // The Focus wraps the ENTIRE body, not just the canvas. This is the only
      // way arrow keys reach the game before Flutter's directional focus
      // traversal moves focus to the dropdowns and sliders. Returning
      // KeyEventResult.handled consumes the event so traversal never sees it.
      body: _games.isEmpty
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
    final src = Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
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
            ..imageFilter = ui.ImageFilter.blur(
                sigmaX: zoom * 8 * v, sigmaY: zoom * 8 * v),
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
      paint.maskFilter =
          ui.MaskFilter.blur(ui.BlurStyle.normal, zoom * 2 * v);
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
      Paint()
        ..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
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