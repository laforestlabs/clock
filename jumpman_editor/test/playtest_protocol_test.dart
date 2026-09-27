// The playtest window's protocol, which is the editor and a second process
// agreeing about what to play and what happened.
//
// It is small and it is worth pinning: the two sides are in different processes,
// so a disagreement shows up as a window that plays nothing, or a map that
// follows a run that is not there.

import 'package:flutter_test/flutter_test.dart';
import 'package:jumpman_editor/src/autoplay.dart';
import 'package:jumpman_editor/src/playtest.dart';
import 'package:jumpman_editor/src/playtest_window.dart';

void main() {
  test('the window and the editor state the same command line', () {
    const options = PlaytestOptions(
      levelPath: '/tmp/level.json',
      auto: true,
      fromColumn: 42,
      reportPath: '/tmp/report.json',
    );
    final args = options.toArgs();
    expect(args, contains('--playtest'));
    expect(args, contains('/tmp/level.json'));
    expect(args, contains('--auto'));

    final read = PlaytestOptions.fromArgs(args)!;
    expect(read.levelPath, options.levelPath);
    expect(read.auto, isTrue);
    expect(read.fromColumn, 42);
    expect(read.reportPath, options.reportPath);
  });

  test('a plain editor launch is not a playtest window', () {
    expect(PlaytestOptions.fromArgs(const []), isNull);
    expect(PlaytestOptions.fromArgs(const ['--some', 'thing']), isNull);
  });

  test('the optional parts are optional', () {
    final read = PlaytestOptions.fromArgs(const ['--playtest', '/tmp/l.json'])!;
    expect(read.levelPath, '/tmp/l.json');
    expect(read.auto, isFalse);
    expect(read.fromColumn, isNull);
    expect(read.reportPath, isNull);
    expect(read.toArgs(), const ['--playtest', '/tmp/l.json']);
  });

  test('every skill survives the command line, and no skill means high', () {
    for (final skill in AutoSkill.values) {
      final options = PlaytestOptions(
        levelPath: '/tmp/level.json',
        auto: true,
        skill: skill,
      );
      final read = PlaytestOptions.fromArgs(options.toArgs())!;
      expect(read.auto, isTrue);
      expect(read.skill, skill, reason: 'skill ${skill.name} did not survive');
    }
    // A command line from before the skills existed is the high one.
    final old = PlaytestOptions.fromArgs(
        const ['--playtest', '/tmp/level.json', '--auto'])!;
    expect(old.skill, AutoSkill.high);
  });

  test('a skill that is not one of the three is rejected, not guessed', () {
    expect(
      () => PlaytestOptions.fromArgs(const [
        '--playtest',
        '/tmp/level.json',
        '--auto',
        '--skill',
        'sideways',
      ]),
      throwsFormatException,
    );
    expect(
      () => PlaytestOptions.fromArgs(
          const ['--playtest', '/tmp/level.json', '--auto', '--skill']),
      throwsFormatException,
    );
  });

  test('a report survives the file it is written to', () {
    const report = PlaytestReport(
      tick: 812,
      playerX: 152,
      playerY: 13,
      camera: 120,
      lives: 2,
      status: kStatusPlaying,
      auto: true,
      reached: 152,
      deaths: 1,
      diedAt: 90,
      stuckAt: null,
    );
    final read = PlaytestReport.fromJson(report.toJson())!;

    expect(read.tick, 812);
    expect(read.playerX, 152);
    expect(read.camera, 120);
    expect(read.lives, 2);
    expect(read.auto, isTrue);
    expect(read.reached, 152);
    expect(read.deaths, 1);
    expect(read.diedAt, 90);
    expect(read.stuckAt, isNull);
    expect(read.summary(), contains('152'));
    expect(read.summary(), contains('died 1×'));
  });

  test('a file that is not a report is not one', () {
    expect(PlaytestReport.fromJson(null), isNull);
    expect(PlaytestReport.fromJson('{'), isNull);
    expect(PlaytestReport.fromJson(const <String, Object?>{}), isNull);
    expect(PlaytestReport.fromJson(const {'tick': 1}), isNull);
  });

  test('a completed run says so', () {
    const won = PlaytestReport(
      tick: 100,
      playerX: 252,
      playerY: 13,
      camera: 192,
      lives: 3,
      status: kStatusWon,
      auto: true,
      reached: 252,
      deaths: 0,
    );
    expect(won.isWon, isTrue);
    expect(won.isOver, isTrue);
    expect(won.summary(), contains('won'));
  });
}
