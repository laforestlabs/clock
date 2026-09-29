// Turning glyph art into panel pixels.
//
// The layout rules here are the engine's, not this app's: tools/font_designer
// is a view of the same glyphs the device draws, and a preview that advances
// the pen differently from ml_text_draw would be lying about the one thing it
// exists to show. So the pen walks the same way (core/src/font.c):
//
//   pen starts at x; for each byte with a glyph, the gap is added *between*
//   glyphs and never before the first or after the last, then the glyph is
//   drawn with its top-left at the pen and the pen advances by its width;
//   every step is multiplied by the integer scale.
//
// The bit order is the packed table's: row-major, MSB first. Iteration is
// over UTF-8 bytes because that is what the engine sees, and a byte with no
// glyph is skipped without advancing -- which is why a name with an accent in
// it draws short rather than wrong.
//
// Multi-plane art draws as one colour here, which is what ml_text_draw does
// for a layout that supplies no palette: every plane takes the same colour.

import 'dart:convert';
import 'dart:typed_data';

import 'font_source.dart';
import 'panel.dart';

/// A panel-sized field of canvas colours, before gamma.
///
/// These are the values the layout author typed, not what the panel shows:
/// gamma and brightness are applied when the frame is painted, exactly as
/// ml_canvas_export_rgb888 applies them after compositing.
class Frame {
  Frame(this.width, this.height) : pixels = Uint32List(width * height);

  final int width;
  final int height;

  /// 0xRRGGBB per cell, row-major. Zero is an unlit cell.
  final Uint32List pixels;

  int at(int x, int y) {
    if (x < 0 || y < 0 || x >= width || y >= height) return 0;
    return pixels[y * width + x];
  }

  void set(int x, int y, int rgb) {
    if (x < 0 || y < 0 || x >= width || y >= height) return;
    pixels[y * width + x] = rgb;
  }

  int get litCount {
    var n = 0;
    for (final p in pixels) {
      if (p != 0) n++;
    }
    return n;
  }
}

/// The ink width [text] needs at [scale], computed the way ml_text_width
/// does: gaps between glyphs, then the whole thing scaled and rounded once.
int textWidth(FontSource font, String text, {int scale = 1}) {
  var total = 0;
  var first = true;
  for (final byte in utf8.encode(text)) {
    final glyph = font.glyph(byte);
    if (glyph == null) continue;
    if (!first) total += font.gap;
    total += glyph.width;
    first = false;
  }
  // scale_q8 is scale * 256, so the engine's (total * scale_q8 + 128) / 256
  // is exact for a whole multiple, which is all this tool draws.
  return total * scale;
}

/// Draw [text] with its top-left at (x, y). Returns the pen's advance.
///
/// [maxWidth], when given, is the clipped variant's budget: the first glyph
/// that would not fit whole is dropped rather than drawn cut in half.
int drawText(
  Frame frame,
  FontSource font,
  String text, {
  int x = 0,
  int y = 0,
  int scale = 1,
  required int rgb,
  int? maxWidth,
}) {
  var pen = x;
  var first = true;
  for (final byte in utf8.encode(text)) {
    final glyph = font.glyph(byte);
    if (glyph == null) continue;
    final advance = (glyph.width + (first ? 0 : font.gap)) * scale;
    if (maxWidth != null && pen - x + advance > maxWidth) break;
    if (!first) pen += font.gap * scale;
    _drawGlyph(frame, glyph, pen, y, scale, rgb);
    pen += glyph.width * scale;
    first = false;
  }
  return pen - x;
}

/// One glyph's rows, one set bit expanded into a scale by scale block.
void _drawGlyph(Frame frame, GlyphSource glyph, int x, int y, int scale, int rgb) {
  for (var row = 0; row < glyph.rows.length; row++) {
    final bits = glyph.rows[row];
    for (var col = 0; col < bits.length; col++) {
      if (bits[col] == '.') continue;
      for (var dy = 0; dy < scale; dy++) {
        for (var dx = 0; dx < scale; dx++) {
          frame.set(x + col * scale + dx, y + row * scale + dy, rgb);
        }
      }
    }
  }
}

/// One glyph already placed on a sheet page.
class PlacedGlyph {
  const PlacedGlyph(this.codepoint, this.x, this.y);

  final int codepoint;
  final int x;
  final int y;
}

/// A page of the character sheet: the glyphs that fit one panel, in the order
/// they are drawn.
class SheetPage {
  const SheetPage(this.placed);

  final List<PlacedGlyph> placed;

  List<int> get codepoints => placed.map((p) => p.codepoint).toList();
}

/// The order the sheet shows a font's characters in.
///
/// Capitals and digits first, because they are what a panel mostly draws and
/// what a legibility question is usually about, then lower case, then
/// everything else in codepoint order. A space is left out: it has no picture
/// to judge.
List<int> sheetOrder(FontSource font) {
  final present = font.glyphs.map((g) => g.codepoint).toSet();
  final order = <int>[];
  void take(bool Function(int) test) {
    final picked = present.where(test).toList()..sort();
    order.addAll(picked);
    present.removeAll(picked);
  }

  take((c) => c >= 0x41 && c <= 0x5A); // A-Z
  take((c) => c >= 0x30 && c <= 0x39); // 0-9
  take((c) => c >= 0x61 && c <= 0x7A); // a-z
  take((c) => c != 32);                // punctuation, symbols, degree
  return order;
}

/// Lay [codepoints] out across as many panel pages as they need.
///
/// Packed by advance, wrapping at the panel's width and starting a page when a
/// line would run past its height. A glyph wider than the panel gets a line to
/// itself and is drawn clipped, which is what the engine would do.
List<SheetPage> paginateSheet(
  FontSource font,
  PanelSpec panel,
  List<int> codepoints,
) {
  const lineGap = 1;
  final lineHeight = font.height + lineGap;
  final pages = <SheetPage>[];
  var placed = <PlacedGlyph>[];
  var x = 0;
  var y = 0;

  for (final cp in codepoints) {
    final glyph = font.glyph(cp);
    if (glyph == null) continue;
    if (x > 0 && x + glyph.width > panel.columns) {
      x = 0;
      y += lineHeight;
    }
    if (y + font.height > panel.rows) {
      // A page with content is finished; a page with nothing on it means the
      // glyph is taller than the panel, and it is drawn anyway rather than
      // looping forever looking for room that does not exist. The frame
      // clips it, exactly as the engine's canvas would.
      if (placed.isNotEmpty) {
        pages.add(SheetPage(placed));
        placed = <PlacedGlyph>[];
        x = 0;
        y = 0;
      }
    }
    placed.add(PlacedGlyph(cp, x, y));
    x += glyph.width + font.gap;
  }
  if (placed.isNotEmpty || pages.isEmpty) pages.add(SheetPage(placed));
  return pages;
}

/// Draw one laid-out page of the sheet.
void drawSheetPage(Frame frame, FontSource font, SheetPage page, int rgb) {
  for (final item in page.placed) {
    final glyph = font.glyph(item.codepoint);
    if (glyph == null) continue;
    _drawGlyph(frame, glyph, item.x, item.y, 1, rgb);
  }
}

/// A frame holding one line of text, for the panel view.
Frame textFrame(
  FontSource font,
  PanelSpec panel,
  String text, {
  int scale = 1,
  int rgb = 0xFFFFFF,
}) {
  final frame = Frame(panel.columns, panel.rows);
  drawText(frame, font, text, scale: scale, rgb: rgb);
  return frame;
}

/// A frame holding one page of the character sheet.
Frame sheetFrame(
  FontSource font,
  PanelSpec panel,
  SheetPage page, {
  int rgb = 0xFFFFFF,
}) {
  final frame = Frame(panel.columns, panel.rows);
  drawSheetPage(frame, font, page, rgb);
  return frame;
}
