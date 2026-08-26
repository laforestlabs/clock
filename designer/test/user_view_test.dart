import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mirror_designer/src/services/user_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('defaults to defaultView when unset', () async {
    expect(await loadUserView(), UserView.defaultView);
  });
  test('round-trips developer', () async {
    await saveUserView(UserView.developer);
    expect(await loadUserView(), UserView.developer);
  });
  test('round-trips defaultView', () async {
    await saveUserView(UserView.defaultView);
    expect(await loadUserView(), UserView.defaultView);
  });
  test('unrecognised value falls back to defaultView', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'user_view': 'nonsense',
    });
    expect(await loadUserView(), UserView.defaultView);
  });
}
