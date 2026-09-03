import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mirror_designer/src/services/panel_orientation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('defaults to upright when unset', () async {
    expect(await loadPanelFlip180(), isFalse);
  });
  test('round-trips flipped', () async {
    await savePanelFlip180(true);
    expect(await loadPanelFlip180(), isTrue);
  });
  test('round-trips upright', () async {
    await savePanelFlip180(false);
    expect(await loadPanelFlip180(), isFalse);
  });
}
