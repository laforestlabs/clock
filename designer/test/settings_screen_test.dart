import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/controller.dart';
import 'package:mirror_designer/src/engine/engine.dart';
import 'package:mirror_designer/src/services/user_view.dart';
import 'package:mirror_designer/src/ui/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

MirrorEngine? _tryOpen() {
  try {
    return MirrorEngine.open();
  } catch (_) {
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  final probe = _tryOpen();
  final skip = probe == null;
  probe?.dispose();

  testWidgets('orientation toggle flips the panel preview', (tester) async {
    final engine = MirrorEngine.open();
    final controller = DesignerController(engine);
    addTearDown(controller.dispose);

    UserView? changed;
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          controller: controller,
          view: UserView.defaultView,
          onViewChanged: (v) => changed = v,
        ),
      ),
    );

    expect(controller.flip180, isFalse);
    await tester.tap(find.text('Upside down'));
    await tester.pumpAndSettle();

    expect(controller.flip180, isTrue);
    expect(changed, isNull, reason: 'orientation does not change the view');
  }, skip: skip);

  testWidgets('developer mode switch changes the view', (tester) async {
    final engine = MirrorEngine.open();
    final controller = DesignerController(engine);
    addTearDown(controller.dispose);

    UserView? changed;
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          controller: controller,
          view: UserView.defaultView,
          onViewChanged: (v) => changed = v,
        ),
      ),
    );

    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pumpAndSettle();

    expect(changed, UserView.developer);
  }, skip: skip);
}
