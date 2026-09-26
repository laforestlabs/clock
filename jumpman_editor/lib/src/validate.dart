// What is wrong with a level, before the game is asked to play it.
//
// The game's loader will build almost anything: it drops a level's records that
// do not fit, clamps nothing, and says nothing. Two classes of mistake are worth
// catching first, and they are different from each other:
//
// - an error is something the game refuses or that makes the level unwinnable,
//   so the editor will not export it without saying so;
// - a warning is something that will probably not play as intended - a coin
//   inside terrain, an enemy standing over a pit.
//
// The checks are pure and take the model only, so they run on every edit and
// never make the UI wait.

import 'jump_level.dart';
import 'jumpman_spec.dart';
import 'wire.dart';

/// How bad a finding is.
enum FindingSeverity { error, warning }

/// One thing wrong with a level, at a column when it has one.
class Finding {
  const Finding({
    required this.severity,
    required this.message,
    this.column,
    this.fromScan = false,
  });

  final FindingSeverity severity;
  final String message;

  /// The column the finding is about, for the map to scroll to. Null when the
  /// finding is about the level as a whole.
  final int? column;

  /// Whether a reachability scan produced it rather than [validateLevel]. The
  /// list shows both, and says which is which: a scan is a hint, a check is a
  /// fact about the level.
  final bool fromScan;

  Finding asScanResult() => Finding(
        severity: severity,
        message: message,
        column: column,
        fromScan: true,
      );

  @override
  String toString() => '${severity.name}: $message'
      '${column == null ? '' : ' (column $column)'}';
}

/// Everything wrong with [level], worst first and then left to right.
List<Finding> validateLevel(JumpLevel level, JumpmanSpec spec) {
  final findings = <Finding>[];

  void error(String message, [int? column]) => findings.add(
      Finding(severity: FindingSeverity.error, message: message, column: column));
  void warn(String message, [int? column]) => findings.add(
      Finding(severity: FindingSeverity.warning, message: message, column: column));

  // ---- the run's two columns --------------------------------------------

  if (level.startX < 0 || level.startX >= spec.cols) {
    error('the start column ${level.startX} is outside the level', level.startX);
  } else if (level.isPit(level.startX)) {
    error('the run starts on a pit column', level.startX);
  }
  if (level.checkpointX < 0 || level.checkpointX >= spec.cols) {
    error('the checkpoint column ${level.checkpointX} is outside the level',
        level.checkpointX);
  } else if (level.isPit(level.checkpointX)) {
    error('the checkpoint is on a pit column', level.checkpointX);
  }
  if (level.checkpointX < level.startX) {
    error('the checkpoint is before the start, so it can never fire',
        level.checkpointX);
  }

  // ---- the player's spawn box -------------------------------------------

  final spawnRow = level.surfaceAt(level.startX);
  if (spawnRow != kPit) {
    final top = spawnRow - spec.playerHSmall;
    final right = level.startX + spec.playerW - 1;
    if (top < 0) {
      error('the player does not fit above the surface at the start column',
          level.startX);
    } else if (right >= spec.cols) {
      error('the player\'s spawn box runs off the end of the level',
          level.startX);
    } else {
      for (var x = level.startX; x <= right; x++) {
        final block = level.blockRowAt(x);
        if (block != null &&
            top < block + spec.blockH &&
            spawnRow > block) {
          error('the run starts inside a block', x);
          break;
        }
      }
    }
  }

  // ---- pipes -------------------------------------------------------------

  for (final p in level.pipes) {
    if (p.h == 0 || p.h >= spec.groundRow) {
      error('a pipe stands ${p.h} rows above the ground, which is not a pipe',
          p.x);
    }
    if (p.x < 0 || p.x + spec.pipeW > spec.cols) {
      error('a pipe runs off the end of the level', p.x);
    }
    for (var x = p.x; x < p.x + spec.pipeW && x < spec.cols; x++) {
      if (level.isPit(x)) {
        error('a pipe stands over a pit', x);
        break;
      }
    }
  }

  // ---- coins -------------------------------------------------------------

  for (var i = 0; i < level.coins.length; i++) {
    final c = level.coins[i];
    if (c.x + 2 > spec.cols || c.y + 2 > spec.rows) {
      error('a coin is outside the field', c.x);
      continue;
    }
    var inTerrain = false;
    for (var x = c.x; x < c.x + 2; x++) {
      if (c.y + 2 > level.surfaceAt(x)) inTerrain = true;
      final block = level.blockRowAt(x);
      if (block != null && c.y < block + spec.blockH && c.y + 2 > block) {
        inTerrain = true;
      }
    }
    if (inTerrain) {
      warn('a coin is inside terrain', c.x);
    }
    // Reported once, by the earlier of the two coins.
    for (var j = 0; j < i; j++) {
      final other = level.coins[j];
      if ((other.x - c.x).abs() < 2 && (other.y - c.y).abs() < 2) {
        warn('a coin overlaps another coin', c.x);
        break;
      }
    }
  }

  // ---- enemies -----------------------------------------------------------

  for (var i = 0; i < level.enemies.length; i++) {
    final e = level.enemies[i];
    if (spec.enemyKindByValue(e.kind) == null) {
      error('an enemy is not a kind this game has', e.x);
    }
    if (e.x < 0 || e.x >= spec.cols) {
      error('an enemy starts outside the level', e.x);
      continue;
    }
    if (level.surfaceAt(e.x) == kPit) {
      warn('an enemy stands over a pit', e.x);
    }
    for (var j = 0; j < i; j++) {
      if (level.enemies[j].x == e.x) {
        warn('two enemies share a column', e.x);
        break;
      }
    }
  }

  // ---- blocks ------------------------------------------------------------

  for (var x = 0; x < spec.cols; x++) {
    final row = level.blockRowAt(x);
    if (row == null) continue;
    if (row + spec.blockH > spec.rows) {
      warn('a block hangs below the field', x);
    }
    if (level.pipeAt(x) != null) {
      warn('a block sits inside a pipe', x);
    }
  }

  // ---- the flagpole ------------------------------------------------------

  for (var x = spec.flagX - 3; x <= spec.flagX; x++) {
    if (x < 0 || x >= spec.cols) continue;
    if (level.isPit(x)) {
      error('the flagpole has no ground to be reached from', x);
      break;
    }
  }

  // ---- the caps the loader drops silently --------------------------------

  final groundRuns = groundRunsOf(level).length;
  if (groundRuns > spec.groundMax) {
    error('$groundRuns ground runs and the game holds ${spec.groundMax}');
  }
  final blockRuns = blockRunsOf(level).length;
  if (blockRuns > spec.blockMax) {
    error('$blockRuns block runs and the game holds ${spec.blockMax}');
  }
  if (level.pipes.length > spec.pipeSlots) {
    error('${level.pipes.length} pipes and the game holds ${spec.pipeSlots}');
  }
  if (level.coins.length > spec.coinSlots) {
    error('${level.coins.length} coins and the game holds ${spec.coinSlots}');
  }
  if (level.enemies.length > spec.enemySlots) {
    error('${level.enemies.length} enemies and the game holds ${spec.enemySlots}');
  }

  return sortFindings(findings);
}

/// Worst first, then left to right, then in the order they were found.
List<Finding> sortFindings(List<Finding> findings) {
  final out = [...findings];
  out.sort((a, b) {
    final bySeverity = a.severity.index.compareTo(b.severity.index);
    if (bySeverity != 0) return bySeverity;
    return (a.column ?? -1).compareTo(b.column ?? -1);
  });
  return out;
}
