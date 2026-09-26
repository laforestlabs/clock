// The reachability sweeps, run against the real game.
//
// The shipped level is the acceptance case in both directions: every pit it has
// (3, 5 and 8 columns wide) and every step in it must be clearable, so a
// four-column pit that reported as unclearable would be the editor being wrong
// rather than the level. A thirty-column pit, in contrast, must be reported - and
// reported once, at the pit, because the sweep is the only thing standing between
// an unwinnable level and a flash to the mirror.
//
// Needs the native core, like the fidelity test:
//
//   cd jumpman_editor && flutter build linux --debug
//   LD_LIBRARY_PATH=build/linux/x64/debug/bundle/lib flutter test

import 'package:flutter_test/flutter_test.dart';
import 'package:jumpman_editor/src/jump_level.dart';
import 'package:jumpman_editor/src/playtest.dart';
import 'package:jumpman_editor/src/scan.dart';

import 'support.dart';

void main() {
  test('every pit and step in the shipped level is clearable', () async {
    final spec = readSpec();
    final level = readAuthoredLevel(spec);

    final report = await scanReachability(level: level, spec: spec);

    expect(report.runs, greaterThan(0));
    expect(
      report.findings,
      isEmpty,
      reason: report.findings
          .map((f) => 'column ${f.column}: ${f.message}')
          .join('\n'),
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a pit no single jump clears is reported once, at the pit', () async {
    final spec = readSpec();
    final level = readAuthoredLevel(spec).clone();
    for (var x = 40; x < 70; x++) {
      level.surface[x] = kPit;
    }

    final report = await scanReachability(level: level, spec: spec);

    expect(report.findings, hasLength(1));
    final finding = report.findings.single;
    expect(finding.column, 40);
    expect(finding.fromScan, isTrue);
    expect(finding.message, contains('30 columns'));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a playtest plays the level it was handed', () {
    final spec = readSpec();
    // Nothing in the way: this is about the session driving the real game, not
    // about how far a run gets before the first goomba.
    final level = readAuthoredLevel(spec).clone()
      ..enemies.clear()
      ..coins.clear();

    final session = Playtest.open(level: level, spec: spec);
    try {
      expect(session.playerX, level.startX);
      expect(session.lives, 3);
      expect(session.status, kStatusPlaying);

      session.setRight(true);
      for (var i = 0; i < 40; i++) {
        session.step();
      }
      expect(session.playerX, greaterThan(level.startX + 30));
      expect(session.lives, 3);

      // The jump is a press: the player leaves the ground and lands again.
      final reached = session.playerX;
      session.pressJump();
      session.step();
      session.step();
      session.releaseJump();
      for (var i = 0; i < 30; i++) {
        session.step();
      }
      expect(session.tick, greaterThan(70));
      expect(session.playerX, greaterThan(reached));
      expect(session.lives, 3);
    } finally {
      session.dispose();
    }
  });

  test('a run cannot be started on a pit column', () {
    final spec = readSpec();
    final level = readAuthoredLevel(spec);
    expect(
      () => Playtest.open(level: level, spec: spec, startX: 105),
      throwsA(isA<PlaytestException>()),
    );
    expect(
      () => Playtest.open(level: level, spec: spec, startX: 999),
      throwsA(isA<PlaytestException>()),
    );
  });

  test('playing from here starts a session at the given column', () {
    final spec = readSpec();
    final level = readAuthoredLevel(spec);
    final session = Playtest.open(level: level, spec: spec, startX: 50);
    try {
      expect(session.playerX, 50);
      expect(session.level.startX, 50);
    } finally {
      session.dispose();
    }
  });
}
