import 'package:shared_preferences/shared_preferences.dart';

const String kPanelFlip180PrefsKey = 'panel_flip_180';

/// Missing or unrecognised value means upright ([false]).
Future<bool> loadPanelFlip180() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(kPanelFlip180PrefsKey) ?? false;
}

Future<void> savePanelFlip180(bool flipped) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(kPanelFlip180PrefsKey, flipped);
}
