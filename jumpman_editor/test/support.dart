// Shared plumbing for the editor's tests: the repository, the game source, and
// the level the game ships today.
//
// The tests read the real game_jumpman.c rather than a fixture, deliberately:
// the editor's whole contract is that it reads the game's own source, so a
// change to that file has to show up here.

import 'dart:io';

import 'package:jumpman_editor/src/jump_level.dart';
import 'package:jumpman_editor/src/jumpman_spec.dart';
import 'package:jumpman_editor/src/level_source.dart';
import 'package:path/path.dart' as p;

/// The repository root, found by walking up from the test's working directory
/// (which `flutter test` sets to this package's directory).
Directory get repoRoot {
  var dir = Directory.current;
  while (true) {
    if (File(p.join(dir.path, 'gamekit', 'examples', 'jumpman',
            'game_jumpman.c'))
        .existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('no smart-mirror repository above ${Directory.current.path}');
    }
    dir = parent;
  }
}

File get gameSourceFile => File(p.join(
    repoRoot.path, 'gamekit', 'examples', 'jumpman', 'game_jumpman.c'));

String readGameSource() => gameSourceFile.readAsStringSync();

JumpmanSpec readSpec() =>
    JumpmanSpec.parse(readGameSource(), path: gameSourceFile.path);

JumpLevel readAuthoredLevel(JumpmanSpec spec) => LevelSource.importFrom(
      source: readGameSource(),
      spec: spec,
      path: gameSourceFile.path,
    );
