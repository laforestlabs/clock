// A bot that plays a level to test it.
//
// This is not the reachability scan. The scan proves that a single jump can
// clear a gap in isolation, one probe at a time, with the level reduced to the
// terrain the jump actually touches. This plays the level from its start with
// the game's own physics, so it tests the level as it will be played: the pits,
// the walls, the enemies and the running start all at once, and it reports how
// far it got and where it came unstuck.
//
// Its rules are few, and each is something a person would say about the level:
//
//   - jump when the ground runs out just ahead;
//   - jump when something stops the walk (a step, a pipe, a wall of stone);
//   - jump at an enemy close in front, which is a stomp and the only way past
//     one at this size.
//
// It holds right the whole time, because the run has to be played at the speed
// the game runs. What it cannot do is a finding about the level, not a failure
// of the bot: a level it never gets past is reported as stuck at that column.

import 'jump_level.dart';
import 'jumpman_spec.dart';

/// What the bot presses for one tick.
class AutoInput {
  const AutoInput({required this.right, required this.jump});

  /// The run: the bot always holds right.
  final bool right;

  /// Whether the jump button is down. The game reads the press, not the level,
  /// so a jump is a press and then a release.
  final bool jump;

  @override
  String toString() => 'AutoInput(right: $right, jump: $jump)';
}

/// The bot: a decision per tick, and what it has seen so far.
class AutoPlayer {
  AutoPlayer({required this.level, required this.spec});

  final JumpLevel level;
  final JumpmanSpec spec;

  /// How long one jump is held: the whole rise, so the jump is the biggest the
  /// game allows. The game cuts it short when the button goes up early, which is
  /// the one thing this bot never wants.
  static const int holdTicks = 20;

  /// How many columns ahead a pit's edge makes the bot jump. A jump carries about
  /// twenty columns at the game's speed, so three is early enough to clear a gap
  /// and late enough not to waste the jump before it.
  static const int pitLookahead = 3;

  /// How early a jump at an enemy has to start, in columns, by the enemy's own
  /// kind: the taller the thing, the further out the jump has to begin.
  ///
  /// These are the game's own physics, not taste. The player rises about two
  /// pixels on its first tick and a little less each tick after, while closing
  /// on an approaching enemy at a pixel and a half a tick; a body has to be
  /// clear of the enemy's top before the two meet, or the touch is a hit rather
  /// than a stomp. A goomba is three rows and needs a pixel and a bit of rise
  /// (two or three columns of warning), a koopa is six rows and needs two and a
  /// half times that. The enemy kinds come from the game's source, like every
  /// other kind in the editor.
  int jumpAtKind(int kind) {
    if (kind == koopaKind) return 9;
    return 6;
  }

  /// The game's koopa kind, read from the source's enum.
  late final int koopaKind =
      spec.enemyKindBySuffix('KOOPA')?.value ?? spec.enemyKinds.last.value;

  /// How many ticks without progress count as stuck: about two screens of a run
  /// at the game's speed, which is longer than any jump, or than waiting out a
  /// plant's whole cycle, which is the longest this bot ever stands still.
  static const int stuckAfter = 240;

  /// How many columns ahead a planted pipe is close enough that walking on would
  /// be walking into the plant.
  static const int plantLookahead = 6;

  int _hold = 0;
  int _lastX = -1;
  int _still = 0;

  /// Ticks the bot has driven for.
  int ticks = 0;

  /// The furthest column the player has reached.
  int reached = 0;

  /// The column the bot stopped making progress at, once it has. A level the bot
  /// never gets past is exactly the kind of thing an auto playtest is for.
  int? stuckAt;

  /// Whether the bot has given up, which is the driver's cue to report rather
  /// than keep pressing.
  bool get isStuck => stuckAt != null;

  /// Let go of the jump: what happens when a person takes the controls back from
  /// the bot, so its held press does not fire the moment it is given them again.
  void release() => _hold = 0;

  /// The bot's press for this tick, from what the game says about the player.
  AutoInput next({
    required int playerX,
    required bool onGround,
    required int enemyGap,
    required int enemyKind,
    required int plantOut,
  }) {
    ticks++;
    if (playerX > reached) reached = playerX;
    if (playerX <= _lastX) {
      _still++;
    } else {
      _still = 0;
    }
    _lastX = playerX;
    if (_still >= stuckAfter) stuckAt ??= playerX;

    // A press runs its course: the game reads the edge, and the rise is the
    // button's, so the bot holds it for the whole of it. Two things end it: the
    // hold running out, and landing - the flight is over, and the next thing
    // ahead needs the button up before it can be pressed, because the game reads
    // the press and not the level. A button held through a landing is what makes
    // a bot stop jumping without noticing.
    if (_hold > 0) {
      _hold--;
      // Landing ends the press early: the flight is over, and the hold has to be
      // finished with, not just paused, or the bot would keep the button up for
      // the rest of it and miss the next thing it has to jump at.
      if (onGround) _hold = 0;
      if (_hold == 0) {
        return const AutoInput(right: true, jump: false);
      }
      return const AutoInput(right: true, jump: true);
    }

    // In the air the game throws a press away, so waiting is the whole job.
    if (!onGround) return const AutoInput(right: true, jump: false);

    // A plant that is out of its pipe, just ahead: stand still until it sinks.
    // Walking on would be walking into it, and the game only holds a plant down
    // once the player is over the pipe already - so the waiting has to happen
    // here, short of it.
    if (plantOut > 0 && _plantAhead(playerX)) {
      return const AutoInput(right: false, jump: false);
    }

    if (_wantsJump(playerX, enemyGap, enemyKind)) {
      _hold = holdTicks - 1;
      return const AutoInput(right: true, jump: true);
    }
    return const AutoInput(right: true, jump: false);
  }

  /// Whether a pipe with a plant in it is close enough ahead to matter.
  bool _plantAhead(int x) {
    for (var ahead = 1; ahead <= plantLookahead; ahead++) {
      final pipe = level.pipeAt(x + ahead);
      if (pipe != null && pipe.plant != 0) return true;
    }
    return false;
  }

  /// Whether something ahead calls for a jump.
  bool _wantsJump(int x, int enemyGap, int enemyKind) {
    // The ground runs out: a pit's edge within a few columns.
    for (var ahead = 1; ahead <= pitLookahead; ahead++) {
      if (level.surfaceAt(x + ahead) == kPit) return true;
    }
    // Something stopped the walk, which is what a step, a pipe or a wall of
    // stone looks like from inside the run.
    if (_still >= 2) return true;
    // An enemy far enough out to clear. Jumping later would meet it while still
    // rising, which is a hit rather than a stomp; the distance depends on how
    // tall it is.
    if (enemyGap >= 0 && enemyKind >= 0 && enemyGap >= jumpAtKind(enemyKind)) {
      return true;
    }
    return false;
  }
}
