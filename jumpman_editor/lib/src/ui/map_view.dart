// The map: the whole level, drawn the way the game draws it.
//
// The editor has to answer "does this look right?" before it can answer "does
// this play right?", and the only honest answer is the game's own palette. Every
// colour and every sprite below is copied from game_jumpman.c - jm_draw_ground,
// jm_draw_pipes, jm_draw_blocks, jm_draw_coins, jm_draw_enemies,
// jm_draw_checkpoint, jm_draw_flag and jm_sprite_col - so what the map shows is
// what the panel shows for the same level.
//
// Only the horizontal direction scrolls: a level is 256 columns wide and 22 rows
// tall, which is one long strip, and scrolling it vertically would only hide the
// ground the player stands on. Below the strip is a ruler, because "the pit
// starts at 105" is a thing the level editor asks constantly.

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../editor_state.dart';
import '../jump_level.dart';
import '../jumpman_spec.dart';

/// How tall the column ruler under the strip is.
const double kRulerHeight = 18;

class MapView extends StatefulWidget {
  const MapView({super.key, required this.state});

  final EditorState state;

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  final ScrollController _scroll = ScrollController();
  int? _lastCamera;
  bool _followScheduled = false;

  EditorState get _state => widget.state;

  @override
  void initState() {
    super.initState();
    _state.addListener(_onState);
  }

  @override
  void dispose() {
    _state.removeListener(_onState);
    _scroll.dispose();
    super.dispose();
  }

  void _onState() {
    final reveal = _state.revealRequest;
    if (reveal != null) {
      _state.clearRevealRequest();
      _scrollTo(reveal * _state.zoom - 120, animate: true);
    }
    final camera = _state.cameraWindow;
    if (camera != null && camera != _lastCamera) {
      _lastCamera = camera;
      _followCamera(camera);
    } else if (camera == null) {
      _lastCamera = null;
    }
  }

  void _followCamera(int camera) {
    if (_followScheduled) return;
    _followScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _followScheduled = false;
      if (!mounted) return;
      final zoom = _state.zoom;
      final left = camera * zoom;
      final right = left + 64 * zoom;
      final position = _scroll.position;
      if (left < position.pixels || right > position.pixels + position.viewportDimension) {
        final target = math.max(0.0, math.min(left, position.maxScrollExtent));
        _scroll.jumpTo(target);
      }
    });
  }

  void _scrollTo(double pixels, {bool animate = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final target = pixels.clamp(0.0, _scroll.position.maxScrollExtent);
      if (animate) {
        _scroll.animateTo(target,
            duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
      } else {
        _scroll.jumpTo(target);
      }
    });
  }

  /// The level cell under a point inside the strip.
  ({int column, int row})? _cell(Offset position) {
    final zoom = _state.zoom;
    final column = (position.dx / zoom).floor();
    final row = (position.dy / zoom).floor();
    if (column < 0 || column >= _state.spec.cols) return null;
    if (row < 0 || row >= _state.spec.rows) return null;
    return (column: column, row: row);
  }

  void _apply(Offset position) {
    final cell = _cell(position);
    if (cell == null) return;
    final state = _state;
    switch (state.tool) {
      case EditorTool.select:
        state.selectAt(cell.column, cell.row);
      case EditorTool.terrain:
        state.setSurface(cell.column, cell.row);
      case EditorTool.pit:
        state.makePit(cell.column);
      case EditorTool.ground:
        state.makeGround(cell.column);
      case EditorTool.block:
        state.placeBlock(cell.column, cell.row);
      case EditorTool.coin:
        state.placeCoin(cell.column, cell.row);
      case EditorTool.enemy:
        state.placeEnemy(cell.column, cell.row);
      case EditorTool.pipe:
        state.placePipe(cell.column);
      case EditorTool.checkpoint:
        state.setCheckpoint(cell.column);
      case EditorTool.start:
        state.setStart(cell.column);
      case EditorTool.erase:
        state.eraseAt(cell.column, cell.row);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final spec = state.spec;
    final zoom = state.zoom;
    final strip = Size(spec.cols * zoom, spec.rows * zoom);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Scrollbar(
            controller: _scroll,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              child: Listener(
                onPointerSignal: (event) {
                  if (event is! PointerScrollEvent) return;
                  if (!HardwareKeyboard.instance.isControlPressed) return;
                  GestureBinding.instance.pointerSignalResolver
                      .register(event, (event) {
                    final delta = (event as PointerScrollEvent).scrollDelta.dy;
                    state.setZoom(state.zoom * (delta > 0 ? 0.9 : 1.1));
                  });
                },
                child: MouseRegion(
                  onHover: (event) {
                    final cell = _cell(event.localPosition);
                    state.setHover(cell?.column, cell?.row);
                  },
                  onExit: (_) => state.setHover(null, null),
                  child: GestureDetector(
                    // A pan recogniser reports the press on onPanDown and the
                    // release as either onPanEnd (a drag) or onPanCancel (a
                    // click), which is what makes one drag one undo entry.
                    onPanDown: (details) {
                      state.beginStroke();
                      _apply(details.localPosition);
                    },
                    onPanUpdate: (details) => _apply(details.localPosition),
                    onPanEnd: (_) => state.endStroke(),
                    onPanCancel: () => state.endStroke(),
                    child: SizedBox(
                      width: strip.width,
                      height: strip.height + kRulerHeight,
                      child: CustomPaint(
                        painter: _LevelPainter(
                          state: state,
                          rulerHeight: kRulerHeight,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        _Readout(state: state),
      ],
    );
  }
}

/// The hover read-out: what is under the cursor, in the game's own terms.
class _Readout extends StatelessWidget {
  const _Readout({required this.state});

  final EditorState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final column = state.hoverColumn;
    final row = state.hoverRow;
    final level = state.level;
    final spec = state.spec;

    final parts = <String>[];
    if (column == null || row == null) {
      parts.add('point at a cell to read it');
    } else {
      parts.add('column $column');
      final surface = level.surfaceAt(column);
      parts.add(surface == kPit ? 'pit' : 'surface $surface');
      final pipe = level.pipeAt(column);
      if (pipe != null) {
        parts.add('pipe h${pipe.h}${pipe.plant != 0 ? ' plant' : ''}');
      }
      final block = level.blockKindAt(column);
      if (block != null) {
        final kind = spec.blockKindByValue(block);
        parts.add('block ${kind?.display ?? block} row ${level.blockRowAt(column)}');
      }
      final enemy = level.enemyAt(column);
      if (enemy != null) {
        final kind = spec.enemyKindByValue(enemy.kind);
        parts.add('enemy ${kind?.display ?? enemy.kind} on row ${enemy.row}');
      }
      final coin = level.coinAt(column, row);
      if (coin != null) parts.add('coin (${coin.x}, ${coin.y})');
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(
        parts.join('   ·   '),
        style: theme.textTheme.bodySmall,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// The level, the ruler under it, the selection and the camera window.
class _LevelPainter extends CustomPainter {
  _LevelPainter({required this.state, required this.rulerHeight});

  final EditorState state;
  final double rulerHeight;

  @override
  void paint(Canvas canvas, Size size) {
    final zoom = state.zoom;
    final spec = state.spec;
    final level = state.level;
    final paint = Paint()..isAntiAlias = false;

    void pixel(int x, int y, Color color) {
      paint.color = color;
      canvas.drawRect(
        Rect.fromLTWH(x * zoom, y * zoom, zoom, zoom),
        paint,
      );
    }

    void span(int x0, int y0, int w, int h, Color color) {
      paint.color = color;
      canvas.drawRect(
        Rect.fromLTWH(x0 * zoom, y0 * zoom, w * zoom, h * zoom),
        paint,
      );
    }

    // ---- ground, and the pipes' dirt under them (jm_draw_ground) -----------
    for (var x = 0; x < spec.cols; x++) {
      final surf = level.surfaceAt(x);
      if (surf == kPit) continue;
      for (var y = surf; y < spec.rows; y++) {
        if (y == surf) {
          pixel(x, y, _grass);
        } else if (y == surf + 1 && (x & 1) == 1) {
          pixel(x, y, _dirtDark);
        } else {
          pixel(x, y, _dirt);
        }
      }
    }

    // ---- pipes (jm_draw_pipes) --------------------------------------------
    for (final p in level.pipes) {
      final top = level.groundRow - p.h;
      span(p.x, top + 1, level.pipeW, level.groundRow - top - 1, _pipeBody);
      span(p.x, top, level.pipeW, 1, _pipeRim);
      for (var y = top + 1; y < level.groundRow; y++) {
        pixel(p.x, y, _pipeRim);
      }
      for (var y = top + 2; y < level.groundRow; y++) {
        pixel(p.x + level.pipeW - 1, y, _pipeShade);
      }
    }

    // ---- blocks (jm_draw_blocks) ------------------------------------------
    for (var x = 0; x < spec.cols;) {
      final v = level.blockAt(x);
      if (v == kNoBlock || blockKindOf(v) == _bmBroken) {
        x++;
        continue;
      }
      final kind = blockKindOf(v);
      final row = blockRowOf(v);
      var x0 = x;
      while (x0 > 0 && level.blockAt(x0 - 1) == v) {
        x0--;
      }
      var x1 = x;
      while (x1 + 1 < spec.cols && level.blockAt(x1 + 1) == v) {
        x1++;
      }

      final colours = _blockColours(kind);
      for (var cx = x; cx <= x1; cx++) {
        span(cx, row, 1, spec.blockH, colours.$1);
        pixel(cx, row, colours.$2);
        pixel(cx, row + spec.blockH - 1, _used);
      }
      if (kind == _bmCoin || kind == _bmMush) {
        final m = x0 + (x1 - x0) ~/ 2;
        final m2 = m + 1 <= x1 ? m + 1 : x1;
        pixel(m, row + 1, _mark);
        pixel(m2, row + 1, _mark);
        if (kind == _bmCoin) pixel(m, row + 2, _mark);
      }
      x = x1 + 1;
    }

    // ---- coins (jm_draw_coins) --------------------------------------------
    for (final c in level.coins) {
      span(c.x, c.y, 2, 2, _coin);
      pixel(c.x, c.y, _glint);
    }

    // ---- enemies (jm_draw_enemies) ----------------------------------------
    for (final e in level.enemies) {
      final kind = spec.enemyKindByValue(e.kind);
      final suffix = kind?.suffix;
      final height = suffix == 'KOOPA'
          ? 6
          : suffix == 'GOOMBA'
              ? 3
              : 3;
      final top = e.row - height;
      if (suffix == 'GOOMBA') {
        _sprite(canvas, zoom, e.x, top, _sprGoomba);
      } else if (suffix == 'KOOPA') {
        _sprite(canvas, zoom, e.x, top, _sprKoopa);
      } else {
        // The shell: three rows of rim with two dark pixels (jm_draw_shell).
        span(e.x, top, 4, 3, _shellRim);
        pixel(e.x + 1, top + 1, _shellDark);
        pixel(e.x + 2, top + 1, _shellDark);
      }
      // A one-pixel marker at the feet, on the side the enemy faces.
      if (e.dir != 0) {
        pixel(e.x + (e.dir < 0 ? 0 : 3), top + height - 1, _white);
      }
    }

    // ---- the checkpoint (jm_draw_checkpoint) ------------------------------
    final checkpoint = level.checkpointX;
    if (checkpoint >= 0 && checkpoint < spec.cols) {
      span(checkpoint, 12, 1, level.groundRow - 12, _poleGrey);
      span(checkpoint + 1, 12, 2, 2, _poleGrey);
    }

    // ---- the flagpole (jm_draw_flag) --------------------------------------
    final flag = spec.flagX;
    final flagTop = level.groundRow - 9;
    span(flag, flagTop, 1, level.groundRow - flagTop, _flagPole);
    pixel(flag + 1, flagTop, _flagCloth);
    pixel(flag + 2, flagTop, _flagCloth);
    pixel(flag + 1, flagTop + 1, _flagCloth);
    pixel(flag + 2, flagTop + 1, _flagCloth);
    pixel(flag + 1, flagTop + 2, _flagCloth);

    // ---- the start column --------------------------------------------------
    span(level.startX, 0, 1, spec.rows, _startMarker);

    // ---- the selection and the playtest's camera window -------------------
    final selection = state.selection;
    if (selection != null) {
      final stroke = Paint()
        ..isAntiAlias = false
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = _selection;
      Rect? box;
      switch (selection.kind) {
        case SelectionKind.pipe:
          final pipe = selection.pipe;
          if (pipe != null) {
            final top = level.groundRow - pipe.h;
            box = Rect.fromLTWH(
              pipe.x * zoom,
              top * zoom,
              level.pipeW * zoom,
              (level.groundRow - top) * zoom,
            );
          }
        case SelectionKind.coin:
          final coin = selection.coin;
          if (coin != null) {
            box = Rect.fromLTWH(coin.x * zoom, coin.y * zoom, 2 * zoom, 2 * zoom);
          }
        case SelectionKind.enemy:
          final enemy = selection.enemy;
          if (enemy != null) {
            box = Rect.fromLTWH(
              enemy.x * zoom,
              (enemy.row - 6) * zoom,
              4 * zoom,
              6 * zoom,
            );
          }
        case SelectionKind.column:
          box = Rect.fromLTWH(
            selection.column * zoom,
            0,
            zoom,
            spec.rows * zoom,
          );
      }
      if (box != null) canvas.drawRect(box, stroke);
    }

    final camera = state.cameraWindow;
    if (camera != null) {
      paint.color = _cameraWindow;
      canvas.drawRect(
        Rect.fromLTWH(camera * zoom, 0, 64 * zoom, spec.rows * zoom),
        paint,
      );
    }

    // ---- the ruler ---------------------------------------------------------
    final ruler = Paint()..color = _ruler;
    canvas.drawRect(
      Rect.fromLTWH(0, spec.rows * zoom, size.width, rulerHeight),
      ruler,
    );
    final text = TextPainter(textDirection: TextDirection.ltr);
    for (var x = 0; x < spec.cols; x++) {
      final major = x % 64 == 0;
      final minor = x % 10 == 0;
      if (!major && !minor) continue;
      paint.color = _rulerTick;
      canvas.drawRect(
        Rect.fromLTWH(x * zoom, spec.rows * zoom, 1, major ? 8 : 4),
        paint,
      );
      if (!major && zoom < 8) continue;
      text.text = TextSpan(
        text: '$x',
        style: TextStyle(
          fontSize: math.min(10, math.max(7, zoom * 0.6)),
          color: _rulerText,
        ),
      );
      text.layout();
      text.paint(
        canvas,
        Offset(x * zoom + 2, spec.rows * zoom + 6),
      );
    }
  }

  void _sprite(Canvas canvas, double zoom, int x, int y, List<String> rows) {
    final paint = Paint()..isAntiAlias = false;
    for (var dy = 0; dy < rows.length; dy++) {
      final line = rows[dy];
      for (var dx = 0; dx < line.length; dx++) {
        final ch = line[dx];
        if (ch == '.') continue;
        final colour = _spriteColours[ch];
        if (colour == null) continue;
        paint.color = colour;
        canvas.drawRect(
          Rect.fromLTWH((x + dx) * zoom, (y + dy) * zoom, zoom, zoom),
          paint,
        );
      }
    }
  }

  /// A block's base colour and its lit top row, by kind (jm_draw_blocks). A
  /// broken block is never painted, so it has no pair of its own.
  (Color, Color) _blockColours(int kind) {
    switch (kind) {
      case _bmCoin:
      case _bmMush:
        return (_coin, _goldLit);
      case _bmStone:
        return (_stone, _stoneLit);
      case _bmUsed:
        return (_used, _usedLit);
      case _bmBrick:
      default:
        return (_brick, _brickLit);
    }
  }

  @override
  bool shouldRepaint(covariant _LevelPainter old) => true;
}

// ---- the game's palette, and its sprite data ------------------------------
//
// Every value here is the one game_jumpman.c writes. They are `const` and named
// after the C functions that use them, so a mismatch is a visible diff rather
// than a guessed colour.

const Color _grass = Color(0xFF48B050); // jm_draw_ground: 72,176,80
const Color _dirt = Color(0xFF784828); // 120,72,40
const Color _dirtDark = Color(0xFF54301A); // 84,48,26
const Color _pipeBody = Color(0xFF28B848); // jm_draw_pipes: 40,184,72
const Color _pipeRim = Color(0xFF78F090); // 120,240,144
const Color _pipeShade = Color(0xFF187830); // 24,120,48
const Color _brick = Color(0xFFC46C30); // jm_draw_blocks: 196,108,48
const Color _brickLit = Color(0xFFECA058); // 236,160,88
const Color _stone = Color(0xFF9898A0); // 152,152,160
const Color _stoneLit = Color(0xFFC8C8D0); // 200,200,208
const Color _coin = Color(0xFFFFD840); // 255,216,64 (coins and gold blocks)
const Color _goldLit = Color(0xFFFFF0A0); // 255,240,160
const Color _used = Color(0xFF605850); // 96,88,80
const Color _usedLit = Color(0xFF807870); // 128,120,112
const Color _mark = Color(0xFF785408); // 120,84,8
const Color _glint = Color(0xFFFFF8C8); // 255,248,200
const Color _shellRim = Color(0xFF38C858); // jm_draw_shell: 56,200,88
const Color _shellDark = Color(0xFF187838); // 24,128,56
const Color _poleGrey = Color(0xFFB0B0B8); // jm_draw_checkpoint: 176,176,184
const Color _flagPole = Color(0xFFD8D8E0); // jm_draw_flag: 216,216,224
const Color _flagCloth = Color(0xFFF04840); // 240,72,64
const Color _white = Color(0xFFFFF8F0); // the sprite palette's white
const Color _startMarker = Color(0xFFE03830); // the player's cap red
const Color _selection = Color(0xFF00E5FF);
const Color _cameraWindow = Color(0x3320C0FF);
const Color _ruler = Color(0xFF202024);
const Color _rulerTick = Color(0xFFB0B0B8);
const Color _rulerText = Color(0xFFD0D0D8);

/// `jm_sprite_col`, letter for letter.
const Map<String, Color> _spriteColours = {
  'r': Color(0xFFE03830),
  's': Color(0xFFFCC898),
  'd': Color(0xFF3860D0),
  'b': Color(0xFF704424),
  'k': Color(0xFF181818),
  'w': Color(0xFFFFF8F0),
  'g': Color(0xFF38C858),
  'h': Color(0xFF187838),
  'y': Color(0xFFF8D040),
  'p': Color(0xFFFCC898),
  'a': Color(0xFF40281A),
  'n': Color(0xFF68402C),
};

/// `jm_spr_goomba` and `jm_spr_koopa`, letter for letter.
const List<String> _sprGoomba = ['aaaa', 'wnnw', 'nnnn'];
const List<String> _sprKoopa = [
  '..yy',
  'ggyy',
  'gggg',
  'ghgg',
  'gggg',
  'b..b',
];

// The block kinds the painter has to know by name. Their values are the game's
// (BM_* in game_jumpman.c); the spec hands out the same values, so a level can
// only ever carry these.
const int _bmBrick = 1;
const int _bmCoin = 2;
const int _bmMush = 3;
const int _bmStone = 4;
const int _bmUsed = 5;
const int _bmBroken = 6;

/// A block kind's swatch, for the pickers in the palette bar: the same colours
/// the map paints with, so a picker and the map cannot disagree.
Color? blockKindSwatch(JumpmanSpec spec, int value) {
  final kind = spec.blockKindByValue(value);
  if (kind == null) return null;
  switch (kind.suffix) {
    case 'BRICK':
      return _brick;
    case 'COIN':
    case 'MUSH':
      return _coin;
    case 'STONE':
      return _stone;
    case 'USED':
      return _used;
    case 'BROKEN':
      return _stoneLit;
  }
  return null;
}
