import 'package:shared_preferences/shared_preferences.dart';

enum UserView { defaultView, developer }

const String kUserViewPrefsKey = 'user_view';

/// Missing or unrecognised value means [UserView.defaultView].
Future<UserView> loadUserView() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(kUserViewPrefsKey) == 'developer'
      ? UserView.developer
      : UserView.defaultView;
}

Future<void> saveUserView(UserView view) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    kUserViewPrefsKey,
    view == UserView.developer ? 'developer' : 'default',
  );
}
