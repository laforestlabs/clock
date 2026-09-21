// The two views offer different surfaces, and games are the difference that
// matters most to a user: the default view plays without the developer
// workspace's controls. These tests drive the workspace itself, so the entry
// point is proven from the app bar rather than from the screen it opens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mirror_designer/src/engine/engine.dart';
import 'package:mirror_designer/src/services/user_view.dart';
import 'package:mirror_designer/src/ui/app.dart';

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

  /// Pump until [finder] matches. The workspace lays itself out asynchronously
  /// and none of that schedules a frame, so settling is not the same as ready.
  Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(finder, findsWidgets, reason: 'the workspace never settled');
  }

  /// The workspace on a fresh preference store: the default view, and no
  /// device bound - the local simulator a user reaches without picking one.
  Future<void> bootWorkspace(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      kUserViewPrefsKey: 'default',
    });
    final engine = MirrorEngine.open();
    addTearDown(engine.dispose);
    await tester.pumpWidget(MaterialApp(home: WorkspaceScreen(engine: engine)));
    // The default view's own Settings button: the workspace is up.
    await pumpUntil(tester, find.byTooltip('Settings'));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  }

  testWidgets('the default view reaches games without developer mode',
      (tester) async {
    await bootWorkspace(tester);

    final games = find.byTooltip('Games');
    expect(games, findsOneWidget,
        reason: 'the default view must reach games without going through '
            'Settings');
    await tester.tap(games);
    await tester.pumpAndSettle();
    expect(find.text('Games'), findsOneWidget, reason: 'the screen opened');

    // The default view plays: no mode to pick, and no display or diagnostics
    // sheet to open.
    expect(find.byKey(const ValueKey<String>('mode-motion')), findsNothing);
    expect(find.byKey(const ValueKey<String>('mode-manual')), findsNothing);
    await tester.tap(find.byKey(const ValueKey<String>('game-menu')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey<String>('menu-diagnostics')), findsNothing);
  });

  testWidgets('the developer view keeps the controls the default view drops',
      (tester) async {
    await bootWorkspace(tester);
    // The user's own way into the workspace view: Settings, Developer mode,
    // back. Nothing here waits on the persisted value being read.
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Default view'), findsOneWidget,
        reason: 'the workspace is in developer mode');

    await tester.tap(find.byTooltip('Games'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('game-menu')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey<String>('menu-diagnostics')), findsOneWidget,
        reason: 'the workspace keeps the panel size and diagnostics');
  });
}
