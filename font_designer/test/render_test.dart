// The pen rules are the engine's (core/src/font.c), so they are pinned here
// rather than left to the eye: if this tool advances differently from the
// renderer the device runs, every judgement made with it is about a different
// font.

import 'package:flutter_test/flutter_test.dart';
import 'package:font_designer/src/font_source.dart';
import 'package:font_designer/src/frame.dart';
import 'package:font_designer/src/panel.dart';

/// Three glyphs: 'A' two wide, 'B' one wide, 'C' three wide, none of them
/// touching each other, so an advance can be read straight off the frame.
const String _three =
    '@name     t\n'
    '@role     text\n'
    '@height   3\n'
    '@baseline 3\n'
    '@gap      1\n'
    '@family   t\n'
    '\n'
    '65\n'
    '  |#.|\n'
    '  |##|\n'
    '  |#.|\n'
    '\n'
    '66\n'
    '  |#|\n'
    '  |#|\n'
    '  |#|\n'
    '\n'
    '67\n'
    '  |###|\n'
    '  |#..|\n'
    '  |###|\n';

FontSource font(String text) => FontSource.parse('t.font', text);

const int _white = 0xFFFFFF;

void main() {
  test('the pen puts the gap between glyphs and never at the ends', () {
    final f = font(_three);
    final frame = Frame(32, 8);
    final advance = drawText(frame, f, 'ABC', rgb: _white);

    // 2 + 1 + 1 + 1 + 3 = 8.
    expect(advance, 8);
    expect(textWidth(f, 'ABC'), 8);

    // A at 0, B at 3, C at 5.
    expect(frame.at(0, 0), _white);
    expect(frame.at(3, 0), _white);
    expect(frame.at(5, 0), _white);
    expect(frame.at(7, 0), _white);
    expect(frame.at(8, 0), 0);
  });

  test('an integer scale replicates a pixel into a block', () {
    final f = font(_three);
    final frame = Frame(32, 16);
    expect(drawText(frame, f, 'B', scale: 2, rgb: _white), 2);
    for (var y = 0; y < 6; y++) {
      for (var x = 0; x < 2; x++) {
        expect(frame.at(x, y), _white, reason: 'block at $x,$y');
      }
    }
    expect(frame.at(2, 0), 0, reason: 'one column is the whole ink at 2x');
    // The gap scales too.
    expect(textWidth(f, 'AB', scale: 3), (2 + 1 + 1) * 3);
  });

  test('a byte with no glyph is skipped without moving the pen', () {
    final f = font(_three);
    final frame = Frame(32, 8);
    // 0x80 is not in the font; it must cost nothing, exactly as glyph_index
    // returning -1 costs nothing in the engine.
    final advance = drawText(frame, f, 'A\u{80}B', rgb: _white);
    expect(advance, 4, reason: 'A 2 + gap 1 + B 1');
    expect(frame.at(3, 0), _white, reason: 'B sits where it would alone');
  });

  test('ink outside the panel is dropped, not wrapped', () {
    final f = font(_three);
    final frame = Frame(4, 3);
    drawText(frame, f, 'ABC', rgb: _white);
    expect(frame.at(0, 0), _white);
    expect(frame.at(3, 0), _white);
    expect(frame.litCount, 7, reason: 'A 4 ink + B 3 ink, C is entirely off');
  });

  test('a clipped draw drops a glyph it cannot fit whole', () {
    final f = font(_three);
    final frame = Frame(16, 3);
    // A budget of 4 fits A (2) + gap (1) + B (1) = 4 and not C.
    final used = drawText(frame, f, 'ABC', maxWidth: 4, rgb: _white);
    expect(used, 4);
    expect(frame.at(5, 0), 0, reason: 'C was dropped rather than halved');
  });

  test('the sheet packs every glyph and pages what does not fit', () {
    final f = font(_three);
    const panel = PanelSpec();
    final order = sheetOrder(f);
    expect(order, <int>[65, 66, 67], reason: 'A-Z before the rest');

    final pages = paginateSheet(f, panel, order);
    expect(pages.length, 1);
    expect(pages.single.codepoints, order);
    for (final placed in pages.single.placed) {
      final glyph = f.glyph(placed.codepoint)!;
      expect(placed.x + glyph.width, lessThanOrEqualTo(panel.columns));
      expect(placed.y + f.height, lessThanOrEqualTo(panel.rows));
    }

    final frame = sheetFrame(f, panel, pages.single, rgb: _white);
    expect(frame.litCount, 14, reason: 'A 4 + B 3 + C 7');
  });

  test('a character set taller than the panel is split across pages', () {
    final f = font(_three);
    // Two lines of 3 rows plus a line gap fit 32 rows at most: ask for a panel
    // of six rows and every line gets its own page.
    const panel = PanelSpec(rows: 3);
    final pages = paginateSheet(f, panel, sheetOrder(f));
    expect(pages.length, 1, reason: 'one line of 3 rows exactly fills 3 rows');

    const small = PanelSpec(rows: 2);
    final split = paginateSheet(f, small, sheetOrder(f));
    expect(split.length, 3, reason: 'one glyph per page at two rows a page');
    for (final page in split) {
      expect(page.placed.length, 1);
    }
  });
}
