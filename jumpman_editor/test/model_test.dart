// The model, its edits, and what the checks say about them.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jumpman_editor/src/editor_state.dart';
import 'package:jumpman_editor/src/game_source.dart';
import 'package:jumpman_editor/src/jump_level.dart';
import 'package:jumpman_editor/src/validate.dart';

import 'support.dart';

EditorState _state() => EditorState(
      spec: readSpec(),
      gameSource: GameSource.fromFile(gameSourceFile.path),
      level: readAuthoredLevel(readSpec()),
    );

void main() {
  test('surfaceAt follows a pipe over the ground under it', () {
    final spec = readSpec();
    final level = readAuthoredLevel(spec);

    // The pipe's columns keep their ground: the game applies the pipe on top.
    expect(level.surface[66], spec.groundRow);
    expect(level.surfaceAt(66), spec.groundRow - 5);
    expect(level.surfaceAt(68), spec.groundRow - 5);
    expect(level.surfaceAt(65), spec.groundRow);
    expect(level.surfaceAt(69), spec.groundRow);
    expect(level.pipeAt(69), isNull);
    expect(level.pipeTopAt(67), spec.groundRow - 5);
  });

  test('a terrain stroke changes exactly the dragged columns, and is one undo',
      () {
    final state = _state();
    final before = Uint8List.fromList(state.level.surface);
    final cols = state.spec.cols;

    state.setTool(EditorTool.terrain);
    state.beginStroke();
    for (var x = 10; x < 15; x++) {
      state.setSurface(x, 15);
    }
    state.endStroke();

    final after = Uint8List.fromList(state.level.surface);
    for (var x = 0; x < cols; x++) {
      expect(after[x], x >= 10 && x < 15 ? 15 : before[x], reason: 'column $x');
    }
    expect(state.dirty, isTrue);
    expect(state.canUndo, isTrue);
    expect(state.canRedo, isFalse);

    state.undo();
    expect(state.level.surface, before);
    expect(state.dirty, isFalse);

    state.redo();
    expect(state.level.surface, after);

    // One stroke, one undo entry: a second undo has nothing left to do.
    state.undo();
    expect(state.canUndo, isFalse);
  });

  test('an edit that changes nothing leaves no undo entry', () {
    final state = _state();
    state.beginStroke();
    state.endStroke();
    expect(state.canUndo, isFalse);

    // Painting a column the row it already has is not an edit either.
    final row = state.level.surface[10];
    state.setSurface(10, row);
    expect(state.canUndo, isFalse);
    expect(state.dirty, isFalse);
  });

  test('placing a pipe replaces the one it overlaps', () {
    final state = _state();
    expect(state.level.pipes, hasLength(1));

    state.setPipeH(4);
    state.placePipe(67); // the shipped pipe covers 66..68
    expect(state.level.pipes, hasLength(1));
    expect(state.level.pipes.single.x, 67);
    expect(state.level.pipes.single.h, 4);
  });

  test('the pit and ground tools are each other\'s way out', () {
    final state = _state();
    state.makePit(20);
    expect(state.level.surface[20], kPit);
    expect(state.level.isPit(20), isTrue);
    state.makeGround(20);
    expect(state.level.surfaceAt(20), state.spec.groundRow);
  });

  test('the checks call out what the game would refuse', () {
    final spec = readSpec();

    final onPit = readAuthoredLevel(spec).clone();
    onPit.startX = 105; // a pit column in the shipped level
    final findings = validateLevel(onPit, spec);
    expect(
      findings.any((f) =>
          f.severity == FindingSeverity.error &&
          f.message.contains('starts on a pit') &&
          f.column == 105),
      isTrue,
    );

    final flagPit = readAuthoredLevel(spec).clone();
    flagPit.surface[spec.flagX] = kPit;
    expect(
      validateLevel(flagPit, spec)
          .any((f) => f.message.contains('flagpole') && f.column == spec.flagX),
      isTrue,
    );

    final tooManyCoins = readAuthoredLevel(spec).clone();
    while (tooManyCoins.coins.length <= spec.coinSlots) {
      tooManyCoins.coins.add(JumpCoin(x: 1, y: 1));
    }
    expect(
      validateLevel(tooManyCoins, spec)
          .any((f) => f.message.contains('and the game holds')),
      isTrue,
    );
  });

  test('the checks warn about what will not play as intended', () {
    final spec = readSpec();
    final level = JumpLevel.empty(spec);

    level.coins.add(JumpCoin(x: 10, y: spec.groundRow - 1)); // inside the ground
    level.enemies.add(JumpEnemy(x: 5, row: spec.groundRow, dir: -1, kind: 0));
    level.enemies.add(JumpEnemy(x: 5, row: spec.groundRow, dir: -1, kind: 0));
    level.pipes.add(JumpPipe(x: 30, h: 4, plant: 0));
    level.blocks[30] = packBlock(spec.blockKindBySuffix('BRICK')!.value, 6);

    final findings = validateLevel(level, spec);
    expect(findings.any((f) => f.message.contains('inside terrain')), isTrue);
    expect(findings.any((f) => f.message.contains('share a column')), isTrue);
    expect(findings.any((f) => f.message.contains('inside a pipe')), isTrue);

    // Worst first: no error may follow a warning.
    var seenWarning = false;
    for (final f in findings) {
      if (f.severity == FindingSeverity.warning) seenWarning = true;
      if (f.severity == FindingSeverity.error) {
        expect(seenWarning, isFalse, reason: 'an error after a warning');
      }
    }
  });

  test('the shipped level has no structural findings', () {
    final spec = readSpec();
    final findings = validateLevel(readAuthoredLevel(spec), spec);
    expect(findings, isEmpty, reason: findings.map((f) => f.toString()).join('\n'));
  });

  test('the new-level template is a level the checks accept', () {
    final spec = readSpec();
    final findings = validateLevel(JumpLevel.empty(spec), spec);
    expect(findings, isEmpty, reason: findings.map((f) => f.toString()).join('\n'));
  });

  test('an over-cap ground run count is an error, not a silent drop', () {
    final spec = readSpec();
    final level = JumpLevel.empty(spec);
    // One pit every other column is far more runs than the wire can carry.
    for (var x = 0; x < spec.groundMax * 2 + 4 && x < spec.cols; x += 2) {
      level.surface[x] = kPit;
    }
    expect(
      validateLevel(level, spec).any((f) =>
          f.severity == FindingSeverity.error &&
          f.message.contains('ground runs')),
      isTrue,
    );
  });

  test('deleting the selected element removes it from the level', () {
    final state = _state();
    state.selectAt(66, 14); // the shipped pipe's columns
    expect(state.selection!.kind, SelectionKind.pipe);
    state.deleteSelected();
    expect(state.level.pipes, isEmpty);
    expect(state.selection, isNull);
  });
}
