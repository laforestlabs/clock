// The project file: the editor's own format, and what it refuses.
//
// The format is stated in the editor's documentation and written by Save, so it
// is a contract rather than an implementation detail: a level saved today opens
// tomorrow, a kind is written by the name the game uses, and a file that does
// not describe this game's level is a load error naming what is wrong rather
// than a level the editor quietly reshapes.

import 'package:flutter_test/flutter_test.dart';
import 'package:jumpman_editor/src/jump_level.dart';

import 'support.dart';

void main() {
  test('a level survives the project file, kinds by their names', () {
    final spec = readSpec();
    final level = readAuthoredLevel(spec);
    final json = level.toJson(spec, 'authored');
    final again = JumpLevel.fromJson(json, spec, path: 'authored.json');

    expect(again, level);
    expect(json['format'], 'jumpman-level');
    expect(json['version'], 1);
    expect(json['cols'], spec.cols);
    expect(json['start_x'], level.startX);
    expect(json['checkpoint_x'], level.checkpointX);
    expect((json['surface'] as List).length, spec.cols);
    expect((json['blocks'] as List).length, spec.cols);

    final enemy = (json['enemies'] as List).first as Map<String, Object?>;
    expect(enemy['kind'], 'GOOMBA');
    final pipe = (json['pipes'] as List).single as Map<String, Object?>;
    expect(pipe['x'], 66);
    expect(pipe['h'], 5);
    expect(pipe['plant'], 1);
  });

  test('an enemy kind the game does not declare is a load error', () {
    final spec = readSpec();
    final json = readAuthoredLevel(spec).toJson(spec, 'authored');
    final enemies = json['enemies'] as List;
    (enemies.first as Map<String, Object?>)['kind'] = 'DRAGON';

    expect(
      () => JumpLevel.fromJson(json, spec, path: 'broken.json'),
      throwsA(isA<LevelFormatException>().having(
        (e) => e.message,
        'message',
        allOf(contains('DRAGON'), contains('broken.json')),
      )),
    );
  });

  test('a level of the wrong width is refused, not truncated', () {
    final spec = readSpec();
    final json = readAuthoredLevel(spec).toJson(spec, 'authored');
    json['cols'] = 64;

    expect(
      () => JumpLevel.fromJson(json, spec, path: 'broken.json'),
      throwsA(isA<LevelFormatException>()
          .having((e) => e.message, 'message', contains('64'))),
    );
  });

  test('a column array of the wrong length is refused', () {
    final spec = readSpec();
    final json = readAuthoredLevel(spec).toJson(spec, 'authored');
    (json['surface'] as List).removeLast();

    expect(
      () => JumpLevel.fromJson(json, spec, path: 'broken.json'),
      throwsA(isA<LevelFormatException>()
          .having((e) => e.message, 'message', contains('surface'))),
    );
  });

  test('a block byte whose kind is not one of the game\'s is refused', () {
    final spec = readSpec();
    final json = readAuthoredLevel(spec).toJson(spec, 'authored');
    (json['blocks'] as List)[2] = packBlock(7, 6);

    expect(
      () => JumpLevel.fromJson(json, spec, path: 'broken.json'),
      throwsA(isA<LevelFormatException>()
          .having((e) => e.message, 'message', contains('kind 7'))),
    );
  });
}
