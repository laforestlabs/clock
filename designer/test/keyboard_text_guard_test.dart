// The workspace-level keyboard shortcuts (delete widget, nudge with arrows,
// undo) must not fire while a text field in the inspector has focus. That is
// decided by hasTextEditingFocus(); these pin the detection against the two
// flavours of text input the inspector builds on (TextField and TextFormField),
// and that a plain focus target does not trip it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/ui/app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpField(WidgetTester tester, Widget field) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: field)));
    await tester.pump();
  }

  testWidgets('a focused TextField is detected as text editing',
      (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    await pumpField(tester, TextField(focusNode: node));
    node.requestFocus();
    await tester.pump();
    expect(hasTextEditingFocus(), isTrue);
  });

  testWidgets('a focused TextFormField is detected as text editing',
      (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    await pumpField(tester, TextFormField(focusNode: node));
    node.requestFocus();
    await tester.pump();
    expect(hasTextEditingFocus(), isTrue);
  });

  testWidgets('a non-text focus target is not detected as text editing',
      (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    await pumpField(
      tester,
      Focus(focusNode: node, autofocus: true, child: const SizedBox()),
    );
    expect(hasTextEditingFocus(), isFalse);
  });

  testWidgets('no focused field is not detected as text editing',
      (tester) async {
    await pumpField(tester, const SizedBox());
    expect(hasTextEditingFocus(), isFalse);
  });
}
