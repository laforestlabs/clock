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

import 'package:flutter_test/flutter_test.dart';
import 'package:jumpman_editor/src/autoplay.dart';
import 'package:jumpman_editor/src/jump_level.dart';
import 'package:jumpman_editor/src/jumpman_spec.dart';
import 'package:jumpman_editor/src/playtest.dart';

import 'support.dart';

/// The outcome of one auto playtest.
class _Run {
  _Run(this.report, this.bot);
  final PlaytestReport report;
  final AutoPlayer bot;
}

/// Play [level] with the bot until it wins, loses, or gets stuck: what the
/// playtest window does, without the window.
_Run _autoPlay(JumpLevel level, JumpmanSpec spec, {int maxTicks = 4000}) {
  final session = Playtest.open(level: level, spec: spec);
  final bot = AutoPlayer(level: level, spec: spec);
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

void main() {
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
      final input =
          bot.next(
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
