// The level's shape, read out of the game's own source.
//
// Jumpman's width, its ground row, its flag column, its slot counts, its caps
// and its block and enemy kinds are all constants in game_jumpman.c. The editor
// reads them from there rather than repeating a number: an edited level must fit
// the field the game was compiled for, and a value that exists twice is a value
// that can disagree with itself.
//
// Nothing here guesses. A macro the editor needs and cannot find, or cannot
// evaluate, is a hard error that names the macro and the file - a level editor
// that invents a ground row would export a level the game plays differently.

/// A kind the game knows: the C symbol, its value, and what to call it on screen.
class SpecKind {
  const SpecKind({
    required this.symbol,
    required this.value,
    required this.display,
    required this.suffix,
  });

  /// The C symbol, e.g. `BM_MUSH`. This is what an export writes, so an export
  /// can never invent a constant the game does not have.
  final String symbol;

  /// The value the game compiles.
  final int value;

  /// What the picker and the inspector show, e.g. `Mushroom`.
  final String display;

  /// The symbol without its prefix, e.g. `MUSH`: what a level file stores, so
  /// the file reads like the game's own table rather than like a numbering.
  final String suffix;

  @override
  String toString() => display;
}

/// Thrown when the game source does not say something the editor needs.
class JumpmanSpecException implements Exception {
  const JumpmanSpecException(this.message);
  final String message;
  @override
  String toString() => 'JumpmanSpecException: $message';
}

/// The level's shape, as the game states it.
class JumpmanSpec {
  const JumpmanSpec({
    required this.cols,
    required this.rows,
    required this.groundRow,
    required this.flagX,
    required this.pipeW,
    required this.blockH,
    required this.pipeSlots,
    required this.coinSlots,
    required this.enemySlots,
    required this.groundMax,
    required this.blockMax,
    required this.playerW,
    required this.playerHSmall,
    required this.startX,
    required this.checkpointX,
    required this.tickMs,
    required this.blockKinds,
    required this.enemyKinds,
  });

  /// Columns in a level. A level is always this wide; a shorter one is authored
  /// by leaving the tail as plain ground.
  final int cols;

  /// World rows in the field.
  final int rows;

  /// The row plain ground sits on.
  final int groundRow;

  /// The flagpole's column, derived from the level width by the game's own
  /// expression rather than pinned to a number.
  final int flagX;

  final int pipeW;
  final int blockH;
  final int pipeSlots;
  final int coinSlots;
  final int enemySlots;

  /// Caps on the runs a wire blob may carry.
  final int groundMax;
  final int blockMax;

  final int playerW;
  final int playerHSmall;

  /// Where a run starts, and where a death after the checkpoint puts the player
  /// back. Both are part of the level, not of the game's constants.
  final int startX;
  final int checkpointX;

  /// The game's tick, in milliseconds: what the playtest and the scans pace
  /// themselves by.
  final int tickMs;

  /// The blocks the game can place, in the order the source declares them.
  final List<SpecKind> blockKinds;

  /// The enemies the game can place.
  final List<SpecKind> enemyKinds;

  SpecKind? blockKindBySuffix(String suffix) =>
      _bySuffix(blockKinds, suffix);

  SpecKind? enemyKindBySuffix(String suffix) =>
      _bySuffix(enemyKinds, suffix);

  SpecKind? blockKindByValue(int value) =>
      _byValue(blockKinds, value);

  SpecKind? enemyKindByValue(int value) =>
      _byValue(enemyKinds, value);

  static SpecKind? _bySuffix(List<SpecKind> kinds, String suffix) {
    for (final k in kinds) {
      if (k.suffix == suffix) return k;
    }
    return null;
  }

  static SpecKind? _byValue(List<SpecKind> kinds, int value) {
    for (final k in kinds) {
      if (k.value == value) return k;
    }
    return null;
  }

  /// The shape of the game in [source], which is the text of [path]. [path] is
  /// only used to name the file in an error.
  static JumpmanSpec parse(String source, {required String path}) {
    final clean = _stripComments(source);
    final raw = _defineValues(clean);
    final macros = _Macros(raw, path);

    int need(String name, String what) {
      if (!raw.containsKey(name)) {
        throw JumpmanSpecException(
          '$path does not define $name ($what). The editor reads the level\'s '
          'shape from the game rather than guessing it.',
        );
      }
      return macros.value(name, what: what);
    }

    final cols = need('JUMP_COLS', 'the level width');

    final blockKinds = <SpecKind>[];
    for (final name in raw.keys) {
      if (!name.startsWith('BM_')) continue;
      final suffix = name.substring(3);
      blockKinds.add(SpecKind(
        symbol: name,
        value: macros.value(name, what: 'a block kind'),
        display: _displayName(suffix),
        suffix: suffix,
      ));
    }
    if (blockKinds.isEmpty) {
      throw JumpmanSpecException(
        '$path defines no BM_* block kinds. The editor paints the kinds the '
        'game has.',
      );
    }

    final enemyKinds = _parseEnemyKinds(clean, macros, path);
    if (enemyKinds.isEmpty) {
      throw JumpmanSpecException(
        '$path declares no EK_* enemy kinds. The editor places the enemies the '
        'game has.',
      );
    }

    final tickMs = _parseTickMs(clean, path);

    return JumpmanSpec(
      cols: cols,
      rows: need('JUMP_ROWS', 'the field height'),
      groundRow: need('JUMP_GROUND_ROW', 'the ground row'),
      flagX: need('FLAG_X', 'the flagpole column'),
      pipeW: need('PIPE_W', 'the pipe width'),
      blockH: need('BLOCK_H', 'the block height'),
      pipeSlots: need('PIPE_SLOTS', 'the pipe slots'),
      coinSlots: need('COIN_SLOTS', 'the coin slots'),
      enemySlots: need('ENEMY_SLOTS', 'the enemy slots'),
      groundMax: need('JM_GROUND_MAX', 'the ground run cap'),
      blockMax: need('JM_BLOCK_MAX', 'the block run cap'),
      playerW: need('PLAYER_W', 'the player width'),
      playerHSmall: need('PLAYER_H_SMALL', 'the small player height'),
      startX: need('JM_LEVEL_START_X', 'the level start column'),
      checkpointX: need('JM_LEVEL_CHECKPOINT_X', 'the level checkpoint column'),
      tickMs: tickMs,
      blockKinds: List.unmodifiable(blockKinds),
      enemyKinds: List.unmodifiable(enemyKinds),
    );
  }

  /// Block and enemy comments and string literals are not code; blanking them
  /// keeps a `/* 256 columns */` from being read as a macro value.
  static String _stripComments(String text) => text
      .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), ' ')
      .replaceAll(RegExp(r'//[^\n]*'), ' ');

  static Map<String, String> _defineValues(String source) {
    final values = <String, String>{};
    final re = RegExp(
      r'^[ \t]*#[ \t]*define[ \t]+([A-Za-z_][A-Za-z0-9_]*)[ \t]+(.+)$',
      multiLine: true,
    );
    for (final m in re.allMatches(source)) {
      values[m.group(1)!] = m.group(2)!.trim();
    }
    return values;
  }

  /// `enum { EK_GOOMBA = 0, EK_KOOPA = 1, EK_SHELL = 2 };` - the enumerators the
  /// game gives its enemies, in source order, with the implicit values a C enum
  /// gives an entry that states none.
  static List<SpecKind> _parseEnemyKinds(
      String source, _Macros macros, String path) {
    final kinds = <SpecKind>[];
    for (final m in RegExp(r'enum\s*\{([^}]*)\}').allMatches(source)) {
      final body = m.group(1)!;
      if (!body.contains('EK_')) continue;
      var next = 0;
      for (final entry in body.split(',')) {
        final text = entry.trim();
        if (text.isEmpty) continue;
        final parts = text.split('=');
        final name = parts[0].trim();
        if (!name.startsWith('EK_')) continue;
        final value = parts.length > 1
            ? macros.eval(parts[1].trim(), what: 'the value of $name')
            : next;
        next = value + 1;
        final suffix = name.substring(3);
        kinds.add(SpecKind(
          symbol: name,
          value: value,
          display: _displayName(suffix),
          suffix: suffix,
        ));
      }
      if (kinds.isNotEmpty) return kinds;
    }
    return kinds;
  }

  /// The game's tick, out of its vtable. The playtest steps exactly this long,
  /// so a change to the game's pace moves the editor with it.
  static int _parseTickMs(String source, String path) {
    final m = RegExp(r'\.tick_ms\s*=\s*(\d+)').firstMatch(source);
    if (m == null) {
      throw JumpmanSpecException(
        '$path states no tick_ms in the game\'s vtable, so the editor cannot '
        'pace a playtest against it.',
      );
    }
    return int.parse(m.group(1)!);
  }

  static const Map<String, String> _knownNames = {
    'MUSH': 'Mushroom',
    'COIN': 'Coin',
    'BRICK': 'Brick',
    'STONE': 'Stone',
    'USED': 'Used',
    'BROKEN': 'Broken',
    'GOOMBA': 'Goomba',
    'KOOPA': 'Koopa',
    'SHELL': 'Shell',
  };

  static String _displayName(String suffix) =>
      _knownNames[suffix] ?? suffix;
}

/// The `#define`d numbers of one source file, evaluated on demand.
class _Macros {
  _Macros(this.raw, this.path);

  final Map<String, String> raw;
  final String path;
  final Map<String, int> _done = {};
  final Set<String> _busy = {};

  /// The value of a macro, or an error naming it. A macro whose definition
  /// refers to another is evaluated through that one, so `(JUMP_COLS - 4)`
  /// follows JUMP_COLS rather than pinning the answer.
  int value(String name, {required String what}) {
    final done = _done[name];
    if (done != null) return done;
    if (!raw.containsKey(name)) {
      throw JumpmanSpecException(
        '$path does not define $name ($what).',
      );
    }
    if (!_busy.add(name)) {
      throw JumpmanSpecException('$path defines $name in terms of itself.');
    }
    final result = eval(raw[name]!, what: '$name, $what');
    _busy.remove(name);
    _done[name] = result;
    return result;
  }

  /// An integer expression: `25`, `0xFF`, `(JUMP_COLS - 4)`, `PIPE_SLOTS + 1`.
  int eval(String expression, {required String what}) {
    final tokens = _tokenize(expression, what);
    final parser = _Expr(tokens, this, what);
    final value = parser.expression();
    if (!parser.atEnd) {
      throw JumpmanSpecException(
        '$path: cannot read "$expression" as $what.',
      );
    }
    return value;
  }

  List<String> _tokenize(String expression, String what) {
    final tokens = <String>[];
    var i = 0;
    while (i < expression.length) {
      final c = expression[i];
      if (c.trim().isEmpty) {
        i++;
        continue;
      }
      if (_digits.hasMatch(c) || (c == '0' && i + 1 < expression.length && expression[i + 1] == 'x')) {
        final start = i;
        if (c == '0' && i + 1 < expression.length && expression[i + 1] == 'x') {
          i += 2;
          while (i < expression.length && _hexDigits.hasMatch(expression[i])) {
            i++;
          }
        } else {
          while (i < expression.length && _digits.hasMatch(expression[i])) {
            i++;
          }
        }
        tokens.add(expression.substring(start, i));
        continue;
      }
      if (_identStart.hasMatch(c)) {
        final start = i;
        while (i < expression.length && _identPart.hasMatch(expression[i])) {
          i++;
        }
        tokens.add(expression.substring(start, i));
        continue;
      }
      if ('()+-*/%'.contains(c)) {
        tokens.add(c);
        i++;
        continue;
      }
      throw JumpmanSpecException(
        '$path: "$c" cannot appear in the definition of $what.',
      );
    }
    return tokens;
  }

  static final RegExp _digits = RegExp(r'[0-9]');
  static final RegExp _hexDigits = RegExp(r'[0-9a-fA-F]');
  static final RegExp _identStart = RegExp(r'[A-Za-z_]');
  static final RegExp _identPart = RegExp(r'[A-Za-z0-9_]');
}

/// A recursive-descent reader for the small integer expressions the game's
/// constants are written in.
class _Expr {
  _Expr(this.tokens, this.macros, this.what);

  final List<String> tokens;
  final _Macros macros;
  final String what;
  int _at = 0;

  bool get atEnd => _at >= tokens.length;

  String? get _peek => atEnd ? null : tokens[_at];

  int expression() {
    var value = _term();
    while (true) {
      final t = _peek;
      if (t == '+') {
        _at++;
        value += _term();
      } else if (t == '-') {
        _at++;
        value -= _term();
      } else {
        return value;
      }
    }
  }

  int _term() {
    var value = _factor();
    while (true) {
      final t = _peek;
      if (t == '*') {
        _at++;
        value *= _factor();
      } else if (t == '/') {
        _at++;
        final d = _factor();
        if (d == 0) {
          throw JumpmanSpecException('$what divides by zero.');
        }
        value ~/= d;
      } else if (t == '%') {
        _at++;
        final d = _factor();
        if (d == 0) {
          throw JumpmanSpecException('$what divides by zero.');
        }
        value %= d;
      } else {
        return value;
      }
    }
  }

  int _factor() {
    final t = _peek;
    if (t == null) {
      throw JumpmanSpecException('$what stops before it is finished.');
    }
    if (t == '-') {
      _at++;
      return -_factor();
    }
    if (t == '+') {
      _at++;
      return _factor();
    }
    if (t == '(') {
      _at++;
      final value = expression();
      if (_peek != ')') {
        throw JumpmanSpecException('$what has an unclosed parenthesis.');
      }
      _at++;
      return value;
    }
    _at++;
    if (t.startsWith('0x') || t.startsWith('0X')) {
      return int.parse(t.substring(2), radix: 16);
    }
    final literal = int.tryParse(t);
    if (literal != null) return literal;
    return macros.value(t, what: what);
  }
}
