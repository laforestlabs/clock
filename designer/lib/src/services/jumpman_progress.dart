// The local Jumpman campaign progress: the highest course this phone has
// unlocked, remembered across app runs.
//
// The campaign itself lives in the game runtime, which is told which course to
// start and how much the player has already unlocked (see
// GameEngine.open(course:, unlockedCourse:)). What is stored here is that
// ceiling and nothing else: the runtime decides when a course has been beaten
// and reports the new ceiling back, and this file is only how that number
// survives leaving the app. A stored value is never lowered - a replay of an
// earlier course leaves the ceiling where it was - and a value that is missing
// or outside the campaign is read as its nearest real course rather than
// failing the screen.
//
// A mirror keeps its own progress; this store is never consulted for one. The
// device is the authority on how far its own campaign has got (see
// `game progress jumpman` in mirror_ble_game.dart), and a phone that has never
// played Jumpman locally does not gate what a mirror may start.

import 'package:shared_preferences/shared_preferences.dart';

/// Where the highest unlocked course is stored.
const String kJumpmanUnlockedPrefsKey = 'jumpman_unlocked_course';

/// How many courses the built-in campaign has. Mirrors ML_JUMPMAN_COURSES in
/// gamekit's jumpman.h: courses are one-based, 1..this.
const int kJumpmanCourseCount = 3;

/// The campaign's courses in play order, one-based by index. Presentation copy
/// only - the wire and the runtime speak the numbers.
const List<String> kJumpmanCourseNames = <String>[
  'Original',
  'Pipe Garden',
  'Koopa Quarry',
];

/// The game id the campaign belongs to.
const String kJumpmanGameId = 'jumpman';

/// The name of one course, or null for a number the campaign does not have.
String? jumpmanCourseName(int course) =>
    course >= 1 && course <= kJumpmanCourseCount
        ? kJumpmanCourseNames[course - 1]
        : null;

/// A course number the campaign actually has: a missing value is course 1, and
/// anything else is clamped into range. The one place that decides what counts
/// as a course, so a stored zero, an out-of-range value, or an unlock the
/// runtime reports past the last course all land on a real course.
int clampJumpmanCourse(int? course) {
  if (course == null || course < 1) return 1;
  return course > kJumpmanCourseCount ? kJumpmanCourseCount : course;
}

/// The highest course this phone has unlocked. Missing means course 1: the
/// campaign always starts somewhere, so a fresh install plays Original.
///
/// Throws when the preference store cannot be read, so the caller can say so
/// instead of gating the campaign on a progress it did not load.
Future<int> loadJumpmanUnlocked() async {
  final prefs = await SharedPreferences.getInstance();
  return clampJumpmanCourse(prefs.getInt(kJumpmanUnlockedPrefsKey));
}

Future<void> _saveTail = Future<void>.value();

/// Remember [unlocked] as the highest course this phone has unlocked.
///
/// Written only when the ceiling rises (the caller compares), and never
/// written lower: what a campaign player has earned is not something an
/// earlier course can take back. Throws when the store cannot be written, so
/// an unlock that could not be saved is visible rather than silently lost.
Future<void> saveJumpmanUnlocked(int unlocked) {
  final save = _saveTail.then((_) async {
    final prefs = await SharedPreferences.getInstance();
    final previous = clampJumpmanCourse(prefs.getInt(kJumpmanUnlockedPrefsKey));
    final requested = clampJumpmanCourse(unlocked);
    final highest = requested > previous ? requested : previous;
    if (!await prefs.setInt(kJumpmanUnlockedPrefsKey, highest)) {
      throw StateError('The preference store refused the course progress');
    }
  });
  // A failed write still reaches its caller, but must not poison later retries.
  _saveTail = save.catchError((Object _) {});
  return save;
}
