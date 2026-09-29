// Finding the checkout, and the two things outside this app it has to touch:
// the .font sources, and tools/fontgen.py which compiles them.

import 'dart:io';

import 'package:path/path.dart' as p;

import 'font_source.dart';

/// One source file in the catalogue.
class FontRef {
  const FontRef({required this.path, required this.group});

  /// Repository-relative, forward-slashed, e.g. `fonts/display8.font`.
  final String path;

  /// Which source directory it came from, for the picker's headers.
  final String group;

  String get name => p.basenameWithoutExtension(path);
}

/// The result of running a tool, kept whole so the app can show a failure
/// rather than swallow it.
class ToolRun {
  const ToolRun(this.exitCode, this.output);

  final int exitCode;
  final String output;

  bool get ok => exitCode == 0;
}

/// The source directories a font may live in, in picker order. The game faces
/// are separate on purpose: fontgen compiles them, but they never enter the
/// layout registry, so a compact HUD digit cannot be picked as body text.
const List<(String, String)> kFontRoots = <(String, String)>[
  ('fonts', 'Mirror fonts'),
  ('gamekit/fonts', 'Game fonts'),
];

class Repository {
  Repository(this.root);

  /// Absolute path to the checkout root.
  final String root;

  /// The checkout the tool is editing, or null when there is none to be found
  /// and the caller should ask.
  ///
  /// Looked for rather than assumed: the release bundle starts from any
  /// working directory, so the search walks up from there and then from the
  /// executable, and only accepts a directory that has both the sources and
  /// the compiler that consumes them.
  static String? locate({String? from}) {
    bool looksLikeRepo(String dir) =>
        File(p.join(dir, 'tools', 'fontgen.py')).existsSync() &&
        Directory(p.join(dir, 'fonts')).existsSync();

    final seeds = <String?>[
      Platform.environment['MIRROR_ROOT'],
      from ?? Directory.current.path,
      p.dirname(Platform.resolvedExecutable),
      p.dirname(p.dirname(Platform.resolvedExecutable)),
    ];

    for (final seed in seeds) {
      if (seed == null || seed.isEmpty) continue;
      var dir = p.normalize(p.absolute(seed));
      while (true) {
        if (looksLikeRepo(dir)) return dir;
        final parent = p.dirname(dir);
        if (parent == dir) break;
        dir = parent;
      }
    }
    return null;
  }

  String absolute(String relative) => p.join(root, p.joinAll(p.split(relative)));

  /// Every .font in the catalogue, sorted by file name within its group.
  List<FontRef> fonts() {
    final refs = <FontRef>[];
    for (final (dir, group) in kFontRoots) {
      final found = Directory(p.join(root, p.joinAll(p.split(dir))));
      if (!found.existsSync()) continue;
      final names = found
          .listSync()
          .whereType<File>()
          .map((f) => p.basename(f.path))
          .where((n) => n.endsWith('.font'))
          .toList()
        ..sort();
      for (final name in names) {
        refs.add(FontRef(path: '$dir/$name', group: group));
      }
    }
    return refs;
  }

  Future<FontSource> load(FontRef ref) async =>
      FontSource.read(File(absolute(ref.path)), ref.path);

  /// Write [font] back. Only the rows that changed are different from what was
  /// read, so a one-pixel fix is a one-line diff.
  Future<void> save(FontSource font) async {
    await File(absolute(font.path)).writeAsString(font.serialize());
  }

  /// Compile every source into the C tables the engine links.
  Future<ToolRun> regenerate() => _python(<String>['tools/fontgen.py']);

  /// Whether the generated tables match the sources, asked of fontgen itself
  /// rather than guessed here.
  Future<bool> generatedIsStale() async {
    final run = await _python(<String>['tools/fontgen.py', '--check']);
    return !run.ok;
  }

  Future<ToolRun> _python(List<String> args) async {
    final python = Platform.environment['PYTHON'] ?? 'python3';
    try {
      final result = await Process.run(python, args, workingDirectory: root);
      final out = '${result.stdout}${result.stderr}'.trim();
      return ToolRun(result.exitCode, out);
    } on ProcessException catch (e) {
      return ToolRun(127, 'could not run $python: ${e.message}');
    }
  }
}
