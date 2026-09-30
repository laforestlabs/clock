// The right-hand side: choosing a glyph, seeing the cut's whole character
// set, and editing the chosen glyph a pixel at a time.

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';

import '../designer_state.dart';
import '../font_source.dart';
import 'panel_view.dart';

/// A glyph drawn as plain blocks, for the pickers. Not the emitter view: at
/// 30 screen pixels there is no room for dead space, and the point of a
/// picker is to recognise the letter.
class GlyphThumb extends StatelessWidget {
  const GlyphThumb({
    super.key,
    required this.glyph,
    required this.size,
    this.selected = false,
  });

  final GlyphSource glyph;
  final double size;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _GlyphThumbPainter(glyph),
        isComplex: false,
        size: Size(size, size),
      ),
    );
  }
}

class _GlyphThumbPainter extends CustomPainter {
  _GlyphThumbPainter(this.glyph);

  final GlyphSource glyph;

  @override
  void paint(Canvas canvas, Size size) {
    if (glyph.rows.isEmpty || glyph.width == 0) return;
    final cell = <double>[
      size.width / glyph.width,
      size.height / glyph.rows.length,
    ].reduce((a, b) => a < b ? a : b);
    final rect = cellRect(size, glyph.width, glyph.rows.length, cell);
    final paint = Paint();
    for (var y = 0; y < glyph.rows.length; y++) {
      for (var x = 0; x < glyph.width; x++) {
        final ink = glyph.rows[y][x];
        if (ink == '.') continue;
        final plane = kInkChars.indexOf(ink);
        paint.color = plane >= 0 && plane < kPlaneColours.length
            ? kPlaneColours[plane]
            : const Color(0xFFFFFFFF);
        canvas.drawRect(
          Rect.fromLTWH(rect.left + x * cell, rect.top + y * cell, cell, cell),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_GlyphThumbPainter old) =>
      old.glyph.rows != glyph.rows || old.glyph.width != glyph.width;
}

/// Every glyph in the open font, as a grid of buttons.
class GlyphStrip extends StatelessWidget {
  const GlyphStrip({super.key, required this.state});

  final DesignerState state;

  @override
  Widget build(BuildContext context) {
    final font = state.font;
    if (font == null) return const SizedBox.shrink();
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: <Widget>[
        for (final glyph in font.glyphs)
          Tooltip(
            message: '${glyph.codepoint}  ${glyph.label}  '
                '${glyph.width}\u00d7${font.height}',
            waitDuration: const Duration(milliseconds: 400),
            child: InkWell(
              onTap: () => state.selectGlyph(glyph.codepoint),
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: const Color(0xFF0E1116),
                  border: Border.all(
                    color: glyph.codepoint == state.selected
                        ? Theme.of(context).colorScheme.primary
                        : const Color(0x22FFFFFF),
                  ),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: GlyphThumb(glyph: glyph, size: 30),
              ),
            ),
          ),
      ],
    );
  }
}

/// The pixel grid for the selected glyph.
///
/// Click paints, drag paints a stroke, and the value painted is decided once,
/// on the press: a toggle that re-decided per cell would flicker a dragged
/// stroke between ink and background.
///
/// The right button opens the column menu on the cell it was pressed on, so a
/// column is widened or dropped where it is rather than at a distance: the
/// menu carries the pixel erase the right button used to do for the one cell
/// it was opened on, and the left button's toggle already clears a pixel it is
/// pressed on.
class GlyphEditor extends StatefulWidget {
  const GlyphEditor({super.key, required this.state, required this.zoom});

  final DesignerState state;
  final double zoom;

  @override
  State<GlyphEditor> createState() => _GlyphEditorState();
}

/// What the grid's right-click menu was answered with.
enum _CellAction { insertLeft, insertRight, deleteColumn, trimGlyph, clearPixel }

class _GlyphEditorState extends State<GlyphEditor> {
  String _painting = '.';
  bool _drawing = false;
  Offset? _hover;

  (int, int)? _cell(Offset local) {
    final column = (local.dx / widget.zoom).floor();
    final row = (local.dy / widget.zoom).floor();
    if (!widget.state.inBounds(row, column)) return null;
    return (row, column);
  }

  void _paint(Offset local) {
    final cell = _cell(local);
    if (cell == null) return;
    final (row, column) = cell;
    widget.state.setPixel(row, column, _painting);
  }

  /// The menu the right button opens. Its items name the column and the row
  /// they are about, because the point of opening it on a cell is not having
  /// to guess which one the tool will act on.
  Future<void> _openCellMenu(
    PointerDownEvent event,
    int row,
    int column,
  ) async {
    final state = widget.state;
    final glyph = state.glyph;
    final overlay = Overlay.of(context).context.findRenderObject();
    if (glyph == null || overlay is! RenderBox) return;
    final at = RelativeRect.fromRect(
      event.position & Size.zero,
      Offset.zero & overlay.size,
    );
    final choice = await showMenu<_CellAction>(
      context: context,
      position: at,
      items: <PopupMenuEntry<_CellAction>>[
        PopupMenuItem<_CellAction>(
          value: _CellAction.insertLeft,
          child: Text('Insert a column before column ${column + 1}'),
        ),
        PopupMenuItem<_CellAction>(
          value: _CellAction.insertRight,
          child: Text('Insert a column after column ${column + 1}'),
        ),
        PopupMenuItem<_CellAction>(
          value: _CellAction.deleteColumn,
          enabled: glyph.width > 1,
          child: Text('Delete column ${column + 1}'),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<_CellAction>(
          value: _CellAction.trimGlyph,
          enabled: state.canTrimGlyph,
          child: const Text('Trim the blank edge columns'),
        ),
        PopupMenuItem<_CellAction>(
          value: _CellAction.clearPixel,
          enabled: state.inkAt(row, column) != '.',
          child: Text('Clear the pixel at row ${row + 1}'),
        ),
      ],
    );
    if (choice == null || !mounted) return;
    state.setCursorColumn(column);
    switch (choice) {
      case _CellAction.insertLeft:
        state.insertColumn(column);
      case _CellAction.insertRight:
        state.insertColumn(column + 1);
      case _CellAction.deleteColumn:
        state.deleteColumn(column);
      case _CellAction.trimGlyph:
        state.trimGlyph();
      case _CellAction.clearPixel:
        state.setPixel(row, column, '.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final glyph = state.glyph;
    if (glyph == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('No glyph selected.'),
      );
    }

    final width = glyph.width * widget.zoom;
    final height = glyph.rows.length * widget.zoom;

    return SingleChildScrollView(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: width,
          height: height,
          child: MouseRegion(
            cursor: SystemMouseCursors.precise,
            onHover: (event) {
              final cell = _cell(event.localPosition);
              setState(() {
                _hover = cell == null
                    ? null
                    : Offset(cell.$2.toDouble(), cell.$1.toDouble());
                if (cell != null) state.setCursorColumn(cell.$2);
              });
            },
            onExit: (_) => setState(() => _hover = null),
            child: Listener(
              onPointerDown: (event) {
                final cell = _cell(event.localPosition);
                if (cell == null) return;
                state.setCursorColumn(cell.$2);
                if (event.buttons == kSecondaryButton) {
                  _openCellMenu(event, cell.$1, cell.$2);
                  return;
                }
                _drawing = true;
                _painting = state.inkAt(cell.$1, cell.$2) == '.'
                    ? state.paintInk
                    : '.';
                _paint(event.localPosition);
              },
              onPointerMove: (event) {
                if (!_drawing) return;
                _paint(event.localPosition);
              },
              onPointerUp: (_) => _drawing = false,
              onPointerCancel: (_) => _drawing = false,
              child: CustomPaint(
                painter: GlyphEditorPainter(
                  glyph: glyph,
                  spec: state.panel,
                  zoom: widget.zoom,
                  cursor: _hover,
                  marked: state.cursorColumn,
                  baseline: state.font?.baseline ?? 0,
                  gap: state.font?.gap ?? 1,
                ),
                size: Size(width, height),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
