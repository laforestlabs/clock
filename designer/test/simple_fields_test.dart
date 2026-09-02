// The simplified view promotes only a small set of inputs: the background,
// a "main" colour, at most one accent, up to two literal text strings, and a
// countdown target time. These pure functions choose *which* widget backs each
// of those, so they are unit tested against LayoutDoc directly (no native
// engine required).

import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/model/layout.dart';
import 'package:mirror_designer/src/ui/app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  LayoutDoc decode(String widgets) => LayoutDoc.decode(
        '{"canvas":{"width":64,"height":64},"background":"#000000",'
        '"widgets":[$widgets]}',
      );

  test('literalTextWidgets returns only literal text widgets in order', () {
    final doc = decode(
      '{"type":"text","id":"a","rect":[0,0,60,8],"text":"HELLO","color":"#FFFFFF"},'
      '{"type":"text","id":"b","rect":[0,10,60,8],"bind":"weather.temp","color":"#00E5FF"},'
      '{"type":"icon","id":"drop","rect":[0,20,12,12],"text":":","color":"#5AA0E0"},'
      '{"type":"text","id":"c","rect":[0,30,60,8],"text":"WORLD","color":"#E06C5A"}',
    );

    final texts = literalTextWidgets(doc);
    expect(texts.map((e) => e.widget.id).toList(), ['a', 'c']);
  });

  test('mainColourTarget picks the largest content widget and skips decoration',
      () {
    final doc = decode(
      '{"type":"rect","id":"frame","rect":[0,0,64,64],"color":"#1E2A33"},'
      '{"type":"text","id":"small","rect":[0,0,60,8],"text":"HI","color":"#FF0000"},'
      '{"type":"agenda","id":"big","rect":[0,10,64,40],"color":"#00FF00","accent":"#0000FF"}',
    );

    final main = mainColourTarget(doc);
    expect(main, isNotNull);
    expect(main!.widget.id, 'big');
    expect(main.widget.getString('color'), '#00FF00');
  });

  test('accentTarget picks the largest widget carrying an accent', () {
    final doc = decode(
      '{"type":"agenda","id":"small","rect":[0,0,64,10],"color":"#FFFFFF","accent":"#111111"},'
      '{"type":"todo","id":"big","rect":[0,12,64,40],"color":"#DDDDDD","accent":"#222222"}',
    );

    final accent = accentTarget(doc);
    expect(accent, isNotNull);
    expect(accent!.widget.id, 'big');
    expect(accent.widget.getString('accent'), '#222222');
  });

  test('mainColourTarget and accentTarget are null when absent', () {
    final doc = decode(
      '{"type":"line","id":"rule","rect":[0,0,64,1],"color":"#1E2A33"}',
    );

    expect(mainColourTarget(doc), isNull);
    expect(accentTarget(doc), isNull);
  });

  test('countdownTarget finds the countdown widget or null', () {
    final withCd = decode(
      '{"type":"countdown","id":"cd","rect":[0,7,64,18],"until":1798761600,"color":"#FFFFFF"}',
    );
    expect(countdownTarget(withCd)!.widget.id, 'cd');

    final withoutCd = decode(
      '{"type":"clock","id":"clock","rect":[0,0,64,16],"color":"#00E5FF"}',
    );
    expect(countdownTarget(withoutCd), isNull);
  });

  test('equal-area ties break by paint order', () {
    final doc = decode(
      '{"type":"text","id":"first","rect":[0,0,60,8],"text":"A","color":"#111111"},'
      '{"type":"text","id":"second","rect":[0,10,60,8],"text":"B","color":"#222222"}',
    );

    expect(mainColourTarget(doc)!.widget.id, 'first');
  });
}
