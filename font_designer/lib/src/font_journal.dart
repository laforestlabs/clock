// Journal every write to a .font, so a lost edit can be explained and undone.
//
// The art in fonts/ is hand-edited here and rewritten by tools/fontreview.py,
// tools/fontraster.py and tools/fontgen.py. Nothing recorded which of them
// wrote what, so when a glyph came back as a solid block the only evidence was
// a modification time: no writer, no reason, and no copy of what the file held
// a moment earlier, which is why an overwritten edit could not be recovered.
//
// Every save now appends one JSON object to out/font-journal/writes.jsonl and
// keeps the previous bytes in out/font-journal/blobs/<digest>. The format is
// the one tools/fontjournal.py writes -- same fields, same digest -- so one log
// covers both languages and `python3 tools/fontjournal.py log` reads the app's
// saves beside the tools' rewrites.
//
// The digest is FNV-1a 64, the one the golden images use: it names content, it
// does not protect it. Journalling must never fail a save, so a failure here
// says so on stderr and stops.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class FontJournal {
  /// Where the journal lives, beside the other tool output. out/ is
  /// gitignored, so a journal never turns up in a diff.
  static const String dirName = 'out/font-journal';

  static const String logName = 'writes.jsonl';

  /// A rewrite that touches more glyphs than this is a regeneration rather
  /// than an edit; the blob holds it, and a wall of rows in the log helps
  /// nobody.
  static const int glyphDetailMax = 24;

  /// Note one write to [file], repository-relative, keeping what it held.
  ///
  /// [before] and [after] are the file's whole text; [glyphs] is the changed
  /// glyphs with both spellings, when the caller knows them.
  static void record({
    required String root,
    required String file,
    required String tool,
    required String reason,
    required String before,
    required String after,
    List<Map<String, Object?>>? glyphs,
  }) {
    if (before == after) return;
    try {
      final dir = Directory(p.join(root, dirName))..createSync(recursive: true);
      final blobs = Directory(p.join(dir.path, 'blobs'))
        ..createSync(recursive: true);
      final beforeDigest = digest(before);
      final blob = File(p.join(blobs.path, beforeDigest));
      if (!blob.existsSync()) blob.writeAsStringSync(before);
      final entry = <String, Object?>{
        'ts': DateTime.now().toIso8601String(),
        'file': file,
        'tool': tool,
        'reason': reason,
        'before': beforeDigest,
        'after': digest(after),
        'bytes': [before.length, after.length],
        ...who(),
        if (glyphs != null)
          'glyphs': glyphs.length <= glyphDetailMax
              ? glyphs
              : <String, Object?>{'changed': glyphs.length},
      };
      File(p.join(dir.path, logName)).writeAsStringSync(
            '${jsonEncode(entry)}\n',
            mode: FileMode.append,
          );
    } catch (e) {
      stderr.writeln('fontjournal: could not record $file: $e');
    }
  }

  /// FNV-1a 64 of the text, as hex: it names content, it does not protect it.
  static String digest(String text) {
    final mask = BigInt.parse('ffffffffffffffff', radix: 16);
    final prime = BigInt.parse('100000001b3', radix: 16);
    var h = BigInt.parse('cbf29ce484222325', radix: 16);
    for (final b in utf8.encode(text)) {
      h = ((h ^ BigInt.from(b)) * prime) & mask;
    }
    return h.toRadixString(16).padLeft(16, '0');
  }

  /// The process making the write, and the one that asked for it.
  static Map<String, Object?> who() {
    final info = <String, Object?>{
      'pid': pid,
      'cwd': Directory.current.path,
      'argv': [Platform.resolvedExecutable, ...Platform.executableArguments],
      'user': Platform.environment['USER'] ?? '',
      'host': _hostname(),
    };
    try {
      // /proc/self/stat is "pid (comm) state ppid ...", and comm may hold
      // spaces and brackets, so the ppid is the field after the last ')'.
      final stat = File('/proc/self/stat').readAsStringSync();
      final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
      final parent = int.tryParse(fields.length > 1 ? fields[1] : '');
      if (parent != null) {
        info['ppid'] = parent;
        info['parent'] = String.fromCharCodes(
          File('/proc/$parent/cmdline').readAsBytesSync(),
        ).replaceAll('\u0000', ' ').trim();
      }
    } catch (_) {
      // Not Linux, or no /proc: the rest of the entry is still worth having.
    }
    return info;
  }

  static String _hostname() {
    try {
      return Platform.localHostname;
    } catch (_) {
      return '';
    }
  }
}
