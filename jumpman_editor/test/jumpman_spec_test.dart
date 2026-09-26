// The level's shape, as read out of the game's own source.

import 'package:flutter_test/flutter_test.dart';
import 'package:jumpman_editor/src/jumpman_spec.dart';

import 'support.dart';

void main() {
  test('the shipped game states the level\'s shape', () {
    final spec = readSpec();

    expect(spec.cols, 256);
    expect(spec.rows, 22);
    expect(spec.groundRow, 19);
    expect(spec.flagX, 252);
    expect(spec.pipeW, 3);
    expect(spec.blockH, 4);
    expect(spec.pipeSlots, 6);
    expect(spec.coinSlots, 24);
    expect(spec.enemySlots, 12);
    expect(spec.groundMax, 128);
    expect(spec.blockMax, 128);
    expect(spec.playerW, 4);
    expect(spec.playerHSmall, 6);
    expect(spec.startX, 3);
    expect(spec.checkpointX, 116);
    expect(spec.tickMs, 25);

    expect(spec.blockKinds, hasLength(6));
    expect(
      spec.blockKinds.map((k) => k.symbol),
      ['BM_BRICK', 'BM_COIN', 'BM_MUSH', 'BM_STONE', 'BM_USED', 'BM_BROKEN'],
    );
    expect(spec.blockKinds.map((k) => k.value), [1, 2, 3, 4, 5, 6]);
    expect(spec.blockKindBySuffix('MUSH')!.display, 'Mushroom');
    expect(spec.blockKindByValue(4)!.display, 'Stone');

    expect(spec.enemyKinds, hasLength(3));
    expect(spec.enemyKinds.map((k) => k.suffix), ['GOOMBA', 'KOOPA', 'SHELL']);
    expect(spec.enemyKinds.map((k) => k.value), [0, 1, 2]);
    expect(spec.enemyKindBySuffix('KOOPA')!.symbol, 'EK_KOOPA');
  });

  test('the flag column follows the level width', () {
    // FLAG_X is written as (JUMP_COLS - 4), so the spec evaluates it rather than
    // pinning the answer: a wider level moves its own flagpole.
    final widened =
        readGameSource().replaceFirst('#define JUMP_COLS    256', '#define JUMP_COLS    512');
    final spec = JumpmanSpec.parse(widened, path: 'game_jumpman.c');
    expect(spec.cols, 512);
    expect(spec.flagX, 508);
  });

  test('a macro the editor needs and cannot find is a hard error', () {
    final text =
        readGameSource().replaceFirst('#define JUMP_GROUND_ROW 19', '');
    expect(
      () => JumpmanSpec.parse(text, path: '/tmp/game_jumpman.c'),
      throwsA(
        isA<JumpmanSpecException>().having(
          (e) => e.message,
          'message',
          allOf(contains('JUMP_GROUND_ROW'), contains('/tmp/game_jumpman.c')),
        ),
      ),
    );
  });

  test('a macro that cannot be evaluated is a hard error too', () {
    final text = readGameSource().replaceFirst(
        '#define JM_LEVEL_START_X      3', '#define JM_LEVEL_START_X      ');
    expect(
      () => JumpmanSpec.parse(text, path: 'game_jumpman.c'),
      throwsA(isA<JumpmanSpecException>()
          .having((e) => e.message, 'message', contains('JM_LEVEL_START_X'))),
    );
  });

  test('the game\'s tick is read from its vtable, not assumed', () {
    final text =
        readGameSource().replaceFirst('.tick_ms       = 25', '.tick_ms       = 40');
    expect(JumpmanSpec.parse(text, path: 'game_jumpman.c').tickMs, 40);
  });
}
