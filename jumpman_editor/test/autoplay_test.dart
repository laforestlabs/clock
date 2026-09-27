// The auto playtest: the computer playing a level to test it.
//
// Two things are worth pinning. A level the game ships and the bot has to be
// able to walk is one: if the bot cannot finish the shipped level, either the
// bot is wrong (and it would report nonsense about every other level) or the
// level is. And an honest report is the other: a level the bot cannot get past
// has to come back as the column it came unstuck at, not as a quiet success.
//
// Needs the native core, like the fidelity test:
//
//   cd jumpman_editor && flutter build linux --debug
//   LD_LIBRARY_PATH=build/linux/x64/debug/bundle/lib flutter test

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jumpman_editor/src/autoplay.dart';
import 'package:jumpman_editor/src/jump_level.dart';
import 'package:jumpman_editor/src/jumpman_spec.dart';
import 'package:jumpman_editor/src/playtest.dart';
import 'package:jumpman_editor/src/validate.dart';
import 'package:mirror_core_ffi/mirror_core_ffi.dart';

import 'support.dart';

/// The outcome of one auto playtest.
class _Run {
  _Run(this.report, this.bot);
  final PlaytestReport report;
  final AutoPlayer bot;
}

/// Play [level] with the bot until it wins, loses, or gets stuck: what the
/// playtest window does, without the window.
_Run _autoPlay(JumpLevel level, JumpmanSpec spec,
    {int maxTicks = 4000, AutoSkill skill = AutoSkill.high}) {
  final session = Playtest.open(level: level, spec: spec);
  final bot = AutoPlayer(level: level, spec: spec, skill: skill);
  var reached = 0;
  var deaths = 0;
  var diedAt = -1;
  try {
    while (session.tick < maxTicks) {
      if (!bot.isStuck) {
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
      if (session.playerX > reached) reached = session.playerX;
      final death = session.deathColumn;
      if (death != null && death != diedAt) {
        deaths++;
        diedAt = death;
      }
      if (session.isOver || bot.isStuck) break;
    }

    return _Run(
      PlaytestReport(
        tick: session.tick,
        playerX: session.playerX,
        playerY: session.playerY,
        camera: session.camera,
        lives: session.lives,
        status: session.status,
        auto: true,
        reached: reached,
        deaths: deaths,
        diedAt: diedAt < 0 ? null : diedAt,
        stuckAt: bot.stuckAt,
      ),
      bot,
    );
  } finally {
    session.dispose();
  }
}

/// Runs compiled courses, not injected editor data. A fresh bot on each course
/// follows the same per-course simulation profile as the editor.
({bool won, int course, int unlocked, int lives}) _campaignPlay(
    List<JumpLevel> levels, JumpmanSpec spec,
    {int start = 1,
    int unlocked = 1,
    AutoSkill skill = AutoSkill.high,
    bool stopAfterCourse = false}) {
  final engine = GameEngine.open(
    gameId: 'jumpman',
    panelWidth: 64,
    panelHeight: 32,
    course: start,
    unlockedCourse: unlocked,
  );
  var course = start;
  var bot = AutoPlayer(level: levels[course - 1], spec: spec, skill: skill);
  try {
    while (engine.tick < 4000 && !engine.isOver) {
      // JM_TRANS shows the next course's title over the previous course's
      // frozen state. It is not a playable frame for that course's bot.
      final input = engine.stateInt('status') == 4
          ? const AutoInput(right: false, jump: false)
          : bot.next(
              playerX: engine.stateInt('player_x'),
              onGround: engine.stateInt('on_ground') > 0,
              enemyGap: engine.stateInt('enemy_gap'),
              enemyKind: engine.stateInt('enemy_kind'),
              plantOut: engine.stateInt('plant_out'),
            );
      engine.input(code: kJumpmanRight, value: input.right ? 1 : 0);
      engine.input(code: kJumpmanJump, value: input.jump ? 1 : 0);
      engine.step(spec.tickMs);
      if (engine.course != course) {
        if (stopAfterCourse) {
          return (
            won: true,
            course: engine.course,
            unlocked: engine.unlockedCourse,
            lives: engine.stateInt('lives')
          );
        }
        course = engine.course;
        bot = AutoPlayer(level: levels[course - 1], spec: spec, skill: skill);
      }
      if (bot.isStuck) break;
    }
    return (
      won: engine.stateInt('status') == kStatusWon,
      course: engine.course,
      unlocked: engine.unlockedCourse,
      lives: engine.stateInt('lives')
    );
  } finally {
    engine.dispose();
  }
}

void main() {
  test('three courses meet the user-simulation difficulty target', () {
    final spec = readSpec();
    final levels = <String, JumpLevel>{
      'Original': readAuthoredLevel(spec),
      for (final name in ['pipe-garden', 'koopa-quarry'])
        name: JumpLevel.fromJson(
          jsonDecode(File('${repoRoot.path}/jumpman_editor/levels/$name.json')
              .readAsStringSync()) as Map<String, Object?>,
          spec,
          path: '$name.json',
        ),
    };
    var mediumWins = 0;
    final highFailures = <String>[];
    for (final entry in levels.entries) {
      expect(validateLevel(entry.value, spec), isEmpty, reason: entry.key);
      for (final skill in AutoSkill.values) {
        final run = _autoPlay(entry.value, spec, skill: skill);
        final report = run.report;
        print('${entry.key} ${skill.name}: '
            '${report.isWon ? "WIN" : "FAIL"} '
            'ticks=${report.tick} lives=${report.lives} '
            'reached=${report.reached} stuck=${report.stuckAt}');
        final compiled = _campaignPlay(levels.values.toList(), spec,
            start: levels.keys.toList().indexOf(entry.key) + 1,
            unlocked: 3,
            skill: skill,
            stopAfterCourse: true);
        expect(compiled.won, report.isWon,
            reason:
                '${entry.key} ${skill.name}: compiled/editor outcome differs');
        print('  compiled: ${compiled.won ? "CLEAR" : "FAIL"} '
            'course=${compiled.course} lives=${compiled.lives}');
        if (skill == AutoSkill.medium && report.isWon) mediumWins++;
        if (skill == AutoSkill.high && !report.isWon) {
          highFailures.add(entry.key);
        }
      }
    }
    expect(highFailures, isEmpty, reason: 'Every course must be completable');
    expect(mediumWins, greaterThanOrEqualTo(2),
        reason: 'Medium must finish at least two of the three courses');
    final firstClear =
        _campaignPlay(levels.values.toList(), spec, stopAfterCourse: true);
    expect(firstClear.course, 2);
    expect(firstClear.unlocked, 2,
        reason: 'Course 2 must unlock before the campaign ends');
    final resumed = _campaignPlay(levels.values.toList(), spec,
        start: 2, unlocked: firstClear.unlocked, stopAfterCourse: true);
    expect(resumed.won, isTrue,
        reason: 'A fresh session must be able to start at the earned course');
    expect(resumed.unlocked, 3);
    final campaign = _campaignPlay(levels.values.toList(), spec);
    expect(campaign.won, isTrue,
        reason: 'High must finish the entire campaign');
    expect(campaign.course, 3);
    expect(campaign.unlocked, 3);
  });

  test('all skills can finish an unobstructed level', () {
    final spec = readSpec();
    for (final skill in AutoSkill.values) {
      final run = _autoPlay(JumpLevel.empty(spec), spec, skill: skill);
      expect(run.report.isWon, isTrue, reason: skill.name);
      expect(run.report.lives, 3, reason: skill.name);
    }
  });

  test('lower skills take off earlier and reach lower jump heights', () {
    final spec = readSpec();
    final level = JumpLevel.empty(spec);
    level.surface.fillRange(40, 43, kPit);
    final takeoffs = <AutoSkill, int>{};
    final peaks = <AutoSkill, int>{};
    for (final skill in AutoSkill.values) {
      final session = Playtest.open(level: level, spec: spec);
      final bot = AutoPlayer(level: level, spec: spec, skill: skill);
      var peak = session.playerY;
      try {
        while (session.tick < 100) {
          final input = bot.next(
            playerX: session.playerX,
            onGround: session.onGround,
            enemyGap: session.enemyGap,
            enemyKind: session.enemyKind,
            plantOut: session.plantOut,
          );
          if (input.jump) takeoffs.putIfAbsent(skill, () => session.playerX);
          session.setRight(input.right);
          if (input.jump) {
            session.pressJump();
          } else {
            session.releaseJump();
          }
          session.step();
          if (session.playerY < peak) peak = session.playerY;
          if (takeoffs.containsKey(skill) && session.onGround) break;
        }
        peaks[skill] = peak;
      } finally {
        session.dispose();
      }
    }
    for (final skill in [AutoSkill.medium, AutoSkill.low]) {
      expect(takeoffs[skill], lessThan(takeoffs[AutoSkill.high]!));
      // Screen rows increase downwards: a larger row is a lower apex.
      expect(peaks[skill], greaterThan(peaks[AutoSkill.high]!));
    }
  });

  test('low skill can lose to enemies that High clears, repeatably', () {
    final spec = readSpec();
    final level = readAuthoredLevel(spec);
    final high = _autoPlay(level, spec);
    final low = _autoPlay(level, spec, skill: AutoSkill.low);
    final repeat = _autoPlay(level, spec, skill: AutoSkill.low);
    expect(high.report.isWon, isTrue);
    expect(low.report.lives, lessThan(high.report.lives));
    expect(low.report.diedAt, lessThan(105),
        reason: 'the missed enemy is before the first pit');
    expect(repeat.report.toJson(), low.report.toJson());
  });

  test('the computer plays the shipped level to the flagpole', () {
    final spec = readSpec();
    final level = readAuthoredLevel(spec);

    final run = _autoPlay(level, spec);

    expect(run.report.stuckAt, isNull,
        reason: 'the bot came unstuck at column ${run.report.stuckAt}');
    expect(run.report.isWon, isTrue,
        reason: 'the run ended at column ${run.report.playerX} with '
            '${run.report.lives} lives: ${run.report.summary()}');
    // The flag is won by the player's right edge reaching the pole, so the
    // furthest column a winning run is in is a body's width short of it.
    expect(run.report.reached, greaterThanOrEqualTo(spec.flagX - spec.playerW));
    expect(run.bot.isStuck, isFalse);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('the computer plays the shipped level without dying', () {
    final spec = readSpec();
    final level = readAuthoredLevel(spec);

    final run = _autoPlay(level, spec);

    // A run that reaches the flag on its first three lives is the level saying
    // something, not the bot: every beat of the shipped level - the goombas, the
    // pipe with its plant, the koopas, the three pits, the wide chasm and the
    // stone staircase - can be played by running right and jumping where the
    // terrain says to. If this ever fails, the bot's rules and the level have
    // stopped agreeing, and one of them needs reading.
    expect(run.report.deaths, 0, reason: run.report.summary());
    expect(run.report.isWon, isTrue, reason: run.report.summary());
    expect(run.report.lives, 3);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a level the computer cannot cross is reported, not passed', () {
    final spec = readSpec();
    final level = readAuthoredLevel(spec).clone();
    // Thirty columns of nothing, with no block to land on: no single jump
    // carries that far, and the bot has no second jump.
    for (var x = 40; x < 70; x++) {
      level.surface[x] = kPit;
    }

    final run = _autoPlay(level, spec);

    expect(run.report.isWon, isFalse);
    expect(run.report.diedAt, isNotNull,
        reason: 'the bot has to fall in the pit, not walk over it');
    expect(run.report.diedAt, inInclusiveRange(40, 70));
    expect(run.report.summary(), contains('died'));
    expect(run.report.reached, lessThan(70 + 12));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('the bot only presses the jump when it is standing', () {
    final spec = readSpec();
    final level = readAuthoredLevel(spec);
    final bot = AutoPlayer(level: level, spec: spec);

    // In the air the game throws a press away, so the bot must not spend one.
    var presses = 0;
    for (var i = 0; i < 50; i++) {
      final input = bot.next(
          playerX: 10,
          onGround: false,
          enemyGap: -1,
          enemyKind: -1,
          plantOut: 0);
      if (input.jump) presses++;
      expect(input.right, isTrue);
    }
    expect(presses, 0);

    // And it does jump at the level's own ground: the first pit is at 105.
    final atPit = AutoPlayer(level: level, spec: spec);
    final input = atPit.next(
        playerX: 103, onGround: true, enemyGap: -1, enemyKind: -1, plantOut: 0);
    expect(input.jump, isTrue);
  });
}
