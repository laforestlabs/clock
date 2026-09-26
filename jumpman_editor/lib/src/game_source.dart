// Finding the repository, and the game source inside it.
//
// The editor is a tool that lives in the checkout and edits a file in it, so
// everything it does starts from one path: gamekit/examples/jumpman/
// game_jumpman.c. That file is the level (see jumpman_spec.dart) and it is what
// an export rewrites, so the repository is found by looking for it rather than
// by trusting the working directory the launcher happened to use.
//
// Three sources, in order: MIRROR_REPO, the ancestors of the running executable
// (that is where a launch from a desktop entry or a bundle puts us), and the
// ancestors of the current directory. When none of them matches, the app says so
// and offers a file picker; the choice is remembered.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Where the game's source lives inside the repository.
const String kGameRelativePath = 'gamekit/examples/jumpman/game_jumpman.c';

/// Where level projects are kept, relative to the repository root. Deliberately
/// not under gamekit/: that directory is hashed as a firmware input, and saving
/// a level must not report a firmware change.
const String kLevelsRelativePath = 'levels/jumpman';

/// The key the file picker's answer is remembered under.
const String kRememberedGameFileKey = 'jumpman_editor.game_file';

/// The key the level directory the picker opened last is remembered under.
const String kRememberedLevelDirKey = 'jumpman_editor.level_dir';

/// The repository, as the editor needs it: a root to hang levels off, and the
/// absolute path of the game source the level comes from and goes back to.
class GameSource {
  const GameSource({required this.root, required this.gameFile});

  /// The repository root, or an empty string when the game file was picked by
  /// hand and no repository could be derived from it.
  final String root;

  /// Absolute path of game_jumpman.c.
  final String gameFile;

  /// Where level projects live. Null when there is no repository to put them in;
  /// the editor then asks for a directory at save time.
  String? get levelsDir => root.isEmpty ? null : p.join(root, kLevelsRelativePath);

  /// Read the game source. Throws [FileSystemException] when it has gone away
  /// since it was resolved, which the caller reports rather than hiding.
  String readGameSource() => File(gameFile).readAsStringSync();

  /// Resolve the repository. Null when nothing matched and nothing was
  /// remembered: the app then opens on the picker page.
  static Future<GameSource?> resolve() async {
    final env = Platform.environment['MIRROR_REPO'];
    if (env != null && env.isNotEmpty) {
      final found = _fromRoot(env);
      if (found != null) return found;
    }

    final exe = _fromAncestors(File(Platform.resolvedExecutable).parent.path);
    if (exe != null) return exe;

    final cwd = _fromAncestors(Directory.current.path);
    if (cwd != null) return cwd;

    final prefs = await SharedPreferences.getInstance();
    final remembered = prefs.getString(kRememberedGameFileKey);
    if (remembered != null && File(remembered).existsSync()) {
      return GameSource(root: _rootAbove(remembered) ?? '', gameFile: remembered);
    }
    return null;
  }

  /// Remember a game file the user picked, and the repository it sits in when
  /// one can be derived from its path.
  static Future<GameSource> remember(String gameFile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kRememberedGameFileKey, gameFile);
    return GameSource(root: _rootAbove(gameFile) ?? '', gameFile: gameFile);
  }

  /// A source built from a game file the user picked, with whatever repository
  /// root its path implies.
  static GameSource fromFile(String gameFile) =>
      GameSource(root: _rootAbove(gameFile) ?? '', gameFile: gameFile);

  static GameSource? _fromRoot(String root) {
    final file = p.join(root, kGameRelativePath);
    return File(file).existsSync() ? GameSource(root: root, gameFile: file) : null;
  }

  static GameSource? _fromAncestors(String start) {
    var dir = start;
    while (true) {
      final found = _fromRoot(dir);
      if (found != null) return found;
      final parent = p.dirname(dir);
      if (parent == dir) return null;
      dir = parent;
    }
  }

  /// The ancestor of [file] that holds a gamekit/examples/jumpman directory,
  /// which is what makes it a repository of ours rather than just a path.
  static String? _rootAbove(String file) {
    var dir = p.dirname(file);
    while (true) {
      if (Directory(p.join(dir, 'gamekit', 'examples', 'jumpman')).existsSync()) {
        return dir;
      }
      final parent = p.dirname(dir);
      if (parent == dir) return null;
      dir = parent;
    }
  }
}
