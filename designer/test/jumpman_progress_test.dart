// The local campaign store: what a stored value means, and what a value that
// is missing or nonsense means.
//
// Two rules are worth pinning here rather than through the screen. A store that
// has never been written is a fresh install - course 1 - not an error, because
// the campaign has to start somewhere. And a value outside the campaign is
// pulled back into it rather than handed on: it is the number a Jumpman round
// is opened with, and the runtime refuses anything it does not have a course
// for.

import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/services/jumpman_progress.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('a store that was never written means course 1', () async {
    expect(await loadJumpmanUnlocked(), 1);
  });

  test('a stored ceiling survives a save and a reload', () async {
    await saveJumpmanUnlocked(3);
    expect(await loadJumpmanUnlocked(), 3);
  });

  test('replaying an earlier course never lowers saved access', () async {
    await saveJumpmanUnlocked(3);
    await saveJumpmanUnlocked(1);
    expect(await loadJumpmanUnlocked(), 3);
  });

  test('overlapping saves retain the highest earned course', () async {
    await Future.wait([saveJumpmanUnlocked(3), saveJumpmanUnlocked(2)]);
    expect(await loadJumpmanUnlocked(), 3);
  });
}
