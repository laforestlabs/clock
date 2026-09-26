// Reachability scans: can a jump clear every pit and climb every step?
//
// A level can be structurally perfect and still impossible: nothing in the
// tables says whether a five-column gap is jumpable, and the player only finds
// out by falling in. So the editor re-runs the game's own physics over the
// level's geometry, once per pit and once per step, sweeping where the jump is
// pressed and how long it is held, and reports the ones no timing clears.
//
// These are hints, not verdicts, and the panel says so. A probe presses Jump at
// most once, so a gap that is meant to be crossed in two hops - landing on a
// block mid-gap - reports as unclearable. What the sweep cannot model is the
// player, and what it deliberately does not model is an enemy.
//
// Every run is a real session: the probe level is injected and the game is
// opened on it, because the game has no reset entry point. A probe carries the
// current model's blocks clipped to the columns it exercises, and no coins, no
// enemies and no pipes - an enemy's position would only make a probe lie.

import 'dart:async';
import 'dart:typed_data';

import 'package:mirror_core_ffi/mirror_core_ffi.dart';

import 'jump_level.dart';
import 'jumpman_spec.dart';
import 'playtest.dart';
import 'validate.dart';
import 'wire.dart';

/// The jump holds a run sweeps: a tap, a medium press, a long press and a full
/// one, which is the game's whole range of jump heights.
const List<int> kScanHolds = [4, 12, 20, 28];

/// How long a probe is allowed to run. The game's run is a pixel and an eighth a
/// tick, so 150 ticks is a little under three screens of ground.
const int kScanTicks = 150;

/// What a scan produces: the findings it could not clear, and how many runs it
/// took to say so.
class ScanReport {
  const ScanReport({required this.findings, required this.runs});

  final List<Finding> findings;
  final int runs;
}

/// Sweep every pit and every step in [level]. [onProgress] is 0..1 across the
/// runs; [breathe] is awaited between runs so the UI can keep drawing.
Future<ScanReport> scanReachability({
  required JumpLevel level,
  required JumpmanSpec spec,
  void Function(double progress)? onProgress,
  Future<void> Function()? breathe,
}) async {
  final probes = _probes(level, spec);
  final total =
      probes.fold<int>(0, (n, p) => n + p.pressAt.length * kScanHolds.length);
  var runs = 0;
  final findings = <Finding>[];

  try {
    for (final probe in probes) {
      var cleared = false;
      for (final hold in kScanHolds) {
        for (final pressAt in probe.pressAt) {
          runs++;
          onProgress?.call(total == 0 ? 1 : runs / total);
          final ok = _runProbe(level, spec, probe, pressAt, hold);
          if (breathe != null) await breathe();
          if (ok) {
            cleared = true;
            break;
          }
        }
        if (cleared) break;
      }
      if (!cleared) {
        findings.add(Finding(
          severity: FindingSeverity.warning,
          message: probe.message,
          column: probe.column,
          fromScan: true,
        ));
      }
    }
  } finally {
    // The probe sessions are gone; put the editor's own level back so the next
    // playtest starts from what is on the map rather than from the last probe.
    GameEngine.setLevel(kJumpmanGameId, encodeWire(level));
  }

  return ScanReport(findings: sortFindings(findings), runs: runs);
}

/// One jump to prove: from a start column, over terrain [surfaceRow], pressing
/// Jump at any column in [pressAt] and holding it a swept number of ticks.
class _Probe {
  const _Probe({
    required this.column,
    required this.message,
    required this.startX,
    required this.target,
    required this.lo,
    required this.hi,
    required this.surfaceRow,
    required this.pressAt,
  });

  /// The column a finding names.
  final int column;

  /// What to warn about when no timing clears it.
  final String message;

  final int startX;
  final int target;
  final int lo;
  final int hi;
  final int Function(int x) surfaceRow;
  final List<int> pressAt;
}

List<_Probe> _probes(JumpLevel level, JumpmanSpec spec) {
  final probes = <_Probe>[];

  // Every maximal pit: from the column before its left edge to the column after
  // its right edge, with a jump pressed anywhere in the approach.
  var x = 0;
  while (x < spec.cols) {
    if (!level.isPit(x)) {
      x++;
      continue;
    }
    var b = x;
    while (b + 1 < spec.cols && level.isPit(b + 1)) {
      b++;
    }
    final a = x;
    final gL = a > 0 ? level.surfaceAt(a - 1) : spec.groundRow;
    final gR = b + 1 < spec.cols ? level.surfaceAt(b + 1) : spec.groundRow;
    final width = b - a + 1;
    probes.add(_Probe(
      column: a,
      message: 'pit of $width columns: no single-jump timing clears column '
          '$a to column ${b + 1}',
      startX: a - 8 < 0 ? 0 : a - 8,
      target: b + 1,
      lo: a - 4,
      hi: b + 4,
      surfaceRow: (col) => col < a ? gL : (col <= b ? kPit : gR),
      pressAt: [for (var c = a - 6; c <= a + 1; c++) c],
    ));
    x = b + 1;
  }

  // Every step up of two rows or more. A pit's edge is not a step: both sides
  // have to be ground, or the probe would start in mid-air over the hole.
  for (var col = 1; col < spec.cols; col++) {
    final left = level.surfaceAt(col - 1);
    final right = level.surfaceAt(col);
    if (left == kPit || right == kPit) continue;
    if (left - right < 2) continue;
    probes.add(_Probe(
      column: col,
      message: 'step up of ${left - right} rows at column $col: no single-jump '
          'timing climbs it',
      startX: col - 8 < 0 ? 0 : col - 8,
      target: col,
      lo: col - 8,
      hi: col + 8,
      surfaceRow: (c) => c < col ? left : right,
      pressAt: [for (var c = col - 7; c <= col; c++) c],
    ));
  }

  return probes;
}

/// One probe level, injected and played: hold Right, press Jump once at
/// [pressAt], release it [hold] ticks later, and see whether the player is past
/// the target with every life still in hand.
bool _runProbe(
  JumpLevel level,
  JumpmanSpec spec,
  _Probe probe,
  int pressAt,
  int hold,
) {
  final surface = Uint8List(spec.cols);
  for (var x = 0; x < spec.cols; x++) {
    surface[x] = probe.surfaceRow(x);
  }
  final blocks = Uint8List(spec.cols)..fillRange(0, spec.cols, kNoBlock);
  for (var x = probe.lo; x <= probe.hi; x++) {
    if (x < 0 || x >= spec.cols) continue;
    blocks[x] = level.blocks[x];
  }

  final blob = encodeWire(JumpLevel(
    surface: surface,
    blocks: blocks,
    startX: probe.startX,
    checkpointX: probe.startX,
    groundRow: spec.groundRow,
    pipeW: spec.pipeW,
    pipes: <JumpPipe>[],
    coins: <JumpCoin>[],
    enemies: <JumpEnemy>[],
  ));
  if (!GameEngine.setLevel(kJumpmanGameId, blob)) {
    throw PlaytestException(
      'the game refused a probe level (${blob.length} bytes). Check reachability '
      'reported a bug in the editor rather than a finding about the level.',
    );
  }

  final engine = GameEngine.open(
    gameId: kJumpmanGameId,
    panelWidth: kPanelWidth,
    panelHeight: kPanelHeight,
    seed: 1,
    players: 1,
  );
  try {
    final lives = engine.stateInt('lives');
    engine.input(code: kJumpmanRight, value: 1);

    var holding = false;
    var pressedAt = 0;
    for (var t = 0; t < kScanTicks; t++) {
      if (holding && t >= pressedAt + hold) {
        engine.input(code: kJumpmanJump, value: 0);
        holding = false;
      }
      if (!holding && engine.stateInt('player_x') >= pressAt) {
        engine.input(code: kJumpmanJump, value: 1);
        holding = true;
        pressedAt = t;
      }
      engine.step(spec.tickMs);
      if (engine.stateInt('lives') < lives) return false;
      if (engine.stateInt('player_x') > probe.target) {
        return engine.stateInt('lives') == lives;
      }
    }
    return false;
  } finally {
    engine.dispose();
  }
}
