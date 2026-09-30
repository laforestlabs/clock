// The interactive path, end to end: pick a glyph, click a pixel, undo it,
// click it again and save, and check that what landed on disk is the file the
// author had plus the one row that changed.
//
// Everything here runs against a throwaway checkout in the system temp
// directory. The tool edits real fonts/*.font files, so a test that pointed
// at the working tree would be one bug away from rewriting the product's art.

import 'dart:io';

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:font_designer/src/designer_state.dart';
import 'package:font_designer/src/ui/app.dart';
import 'package:font_designer/src/ui/glyph_inspector.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A three-row text face with three glyphs, in the generated block spelling.
const String _display12 = '''
@name     display12
@role     text
@height   3
@baseline 3
@gap      1
@family   display
@smooth   no

65
  |#.|
  |##|
  |#.|

66
  |#|
  |#|
  |#|

67
  |##|
  |#.|
  |##|
''';

/// A decoy that sorts before [display12], so the open-a-text-face rule is
/// actually being exercised rather than falling through to the first file.
const String _aaa1 = '''
@name     aaa1
@role     digits
@height   3
@baseline 3
@gap      1
@family   aaa

48
  |##|
  |#.#|
  |##|
''';

late Directory repo;
late DesignerState state;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    repo = Directory.systemTemp.createTempSync('font-designer-test');
    Directory('${repo.path}/fonts').createSync();
    Directory('${repo.path}/tools').createSync();
    // fontgen is asked whether the tables are stale; a stub is enough, and it
    // keeps the test from compiling the real catalogue.
    File('${repo.path}/tools/fontgen.py').writeAsStringSync('raise SystemExit(0)\n');
    File('${repo.path}/fonts/aaa1.font').writeAsStringSync(_aaa1);
    File('${repo.path}/fonts/display12.font').writeAsStringSync(_display12);

    state = DesignerState();
    await state.open(repo.path);
  });

  tearDown(() {
    repo.deleteSync(recursive: true);
  });

  test('opening the tool lands on a face that can draw a sentence', () {
    expect(state.refs.length, 2);
    expect(state.font!.name, 'display12',
        reason: 'aaa1 sorts first and is a digits face');
    expect(state.selected, 65);
  });

  testWidgets('a click paints a pixel, undo takes it back, save writes one line',
      (tester) async {
    final glyph = state.glyph!;
    const zoom = 12.0;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Center(child: GlyphEditor(state: state, zoom: zoom))),
    ));

    // 'A' has no ink at row 0, column 1; click it on.
    expect(state.inkAt(0, 1), '.');
    state.setPaintInk('#');
    final origin = tester.getTopLeft(find.byType(GlyphEditor));
    await tester.tapAt(origin + const Offset(1.5 * zoom, 0.5 * zoom));
    await tester.pump();

    expect(state.inkAt(0, 1), '#');
    expect(glyph.rows[0], '##');
    expect(state.dirty, isTrue);
    expect(state.canUndo, isTrue);

    state.undo();
    await tester.pump();
    expect(state.inkAt(0, 1), '.');
    expect(state.dirty, isFalse, reason: 'undo returns the glyph to the file');

    state.redo();
    await tester.pump();
    expect(state.inkAt(0, 1), '#');
    expect(state.dirty, isTrue);

    // Writing the file is real work, so it goes through runAsync: the test
    // binding's clock drives timers and microtasks, not the event loop a
    // dart:io future completes on, and awaiting one outside this hangs.
    await tester.runAsync(() => state.save());
    expect(state.dirty, isFalse);

    final written = File('${repo.path}/fonts/display12.font').readAsStringSync();
    final before = _display12.split('\n');
    final after = written.split('\n');
    expect(after.length, before.length);
    final changed = <int>[
      for (var i = 0; i < before.length; i++)
        if (before[i] != after[i]) i,
    ];
    expect(changed.length, 1);
    expect(after[changed.single], '  |##|');
    expect(written, _display12.replaceFirst('  |#.|', '  |##|'));

    // Painting it back to what the file now holds is what makes a glyph clean:
    // the dirty test compares rows with what was written, not edits counted.
    state.togglePixel(0, 1);
    expect(state.inkAt(0, 1), '.');
    expect(state.dirty, isTrue);
    state.togglePixel(0, 1);
    expect(state.inkAt(0, 1), '#');
    expect(state.dirty, isFalse);
    final again = await tester.runAsync(() => state.save());
    expect(again, isFalse, reason: 'nothing to write');
  });

  testWidgets('the right button opens the column menu on the cell it marked',
      (tester) async {
    final glyph = state.glyph!;
    const zoom = 12.0;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Center(child: GlyphEditor(state: state, zoom: zoom))),
    ));

    // Column 1 of 'A', which is '.#' with no ink under it.
    final origin = tester.getTopLeft(find.byType(GlyphEditor));
    await tester.tapAt(origin + const Offset(1.5 * zoom, 0.5 * zoom),
        buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(find.text('Insert a column before column 2'), findsOneWidget);
    expect(find.text('Delete column 2'), findsOneWidget);
    expect(find.text('Insert a column after column 2'), findsOneWidget);
    expect(state.inkAt(0, 1), '.',
        reason: 'the right button opens the menu, it does not erase');

    await tester.tap(find.text('Delete column 2'));
    await tester.pumpAndSettle();

    expect(glyph.width, 1);
    expect(glyph.rows, <String>['#', '#', '#']);
    expect(state.canUndo, isTrue);

    // The menu carries the erase the right button used to do, for the cell it
    // was opened on.
    final marked = tester.getTopLeft(find.byType(GlyphEditor));
    await tester.tapAt(marked + const Offset(0.5 * zoom, 1.5 * zoom),
        buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear the pixel at row 2'));
    await tester.pumpAndSettle();

    expect(glyph.rows[1], '.');
  });

  testWidgets('the column tools name the column the pointer marked',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(home: Workspace(state: state)));
    await tester.pumpAndSettle();

    expect(find.text('Column 1 of 2'), findsOneWidget);

    // The workspace's own editor zoom.
    const zoom = 18.0;
    final origin = tester.getTopLeft(find.byType(GlyphEditor));
    await tester.tapAt(origin + const Offset(1.5 * zoom, 0.5 * zoom));
    await tester.pumpAndSettle();

    expect(state.cursorColumn, 1);
    expect(find.text('Column 2 of 2'), findsOneWidget,
        reason: 'the buttons act on the column they name');
  });

  testWidgets('the window builds, and the sheet view renders every glyph',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(home: Workspace(state: state)));
    await tester.pumpAndSettle();

    expect(find.text('Font Designer'), findsOneWidget);
    expect(find.byType(GlyphStrip), findsOneWidget);

    // Nothing is dirty, so there is nothing to save yet.
    final save = find.widgetWithText(FilledButton, 'Save + build');
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    state.togglePixel(1, 0);
    await tester.pump();
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);

    // The character sheet is the whole set, packed onto pages of the panel.
    state.setMode(PreviewMode.sheet);
    await tester.pumpAndSettle();
    expect(state.sheetPages.single.codepoints, <int>[65, 66, 67]);
    expect(find.textContaining('3 of 3 glyphs'), findsOneWidget);

    state.setScale(2);
    state.setMode(PreviewMode.text);
    await tester.pumpAndSettle();
    expect(state.sampleWidth, greaterThan(0));
  });

  testWidgets('a font that fontgen would refuse is reported, not loaded',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: Workspace(state: state)));
    await tester.pumpAndSettle();

    // Reading the file and running fontgen are real work, so they go through
    // runAsync: the test binding's clock does not drive the event loop that
    // dart:io futures need, and awaiting one outside this hangs the test.
    await tester.runAsync(() async {
      File('${repo.path}/fonts/broken.font').writeAsStringSync(
          '@name broken\n@role text\n@height 2\n65\n  |#|\n  |##|\n');
      await state.open(repo.path);
      await state.selectFont(
          state.refs.firstWhere((r) => r.name == 'broken'));
    });
    await tester.pumpAndSettle();

    expect(state.font, isNull);
    expect(state.error, contains('ragged'));
    expect(find.textContaining('ragged'), findsOneWidget);
  });
}
