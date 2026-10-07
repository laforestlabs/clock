"""Asset regressions for the merged display catalogue (no device verification)."""
import unittest
from pathlib import Path

from tools.fontreview import Font, components, holes

ROOT = Path(__file__).resolve().parent.parent


class DisplayFontsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fonts = [Font(p) for p in (ROOT / 'fonts').glob('display*.font')]

    def test_catalogue_and_coverage(self):
        self.assertFalse(list((ROOT / 'fonts').glob('digits*.font')))
        self.assertFalse(list((ROOT / 'core/src/fonts').glob('font_digits*.c')))
        self.assertTrue((ROOT / 'fonts/display48.font').exists())
        for font in self.fonts:
            with self.subTest(font=font.name):
                self.assertEqual(font.role, 'text')
                self.assertEqual(font.cps, list(range(32, 128)))
                for glyph in font.glyphs:
                    self.assertEqual(len(glyph.rows), font.height)
                    if glyph.cp != 32:
                        self.assertTrue(any('#' in row for row in glyph.rows))

    def test_compact_descenders(self):
        for font in self.fonts:
            with self.subTest(font=font.name):
                self.assertEqual(font.height - font.baseline, max(1, font.height // 8))
                for cp in map(ord, 'gjpqy'):
                    self.assertTrue(any('#' in row for row in font.glyph(cp).rows[font.baseline:]))

    def test_numerals_align_and_hold_clock_width(self):
        def extent(rows):
            ys = [y for y, row in enumerate(rows) if '#' in row]
            return min(ys), max(ys)

        for font in self.fonts:
            if font.family != 'display':
                continue
            with self.subTest(font=font.name):
                cap = extent(font.glyph(ord('H')).rows)
                widths = {font.glyph(cp).width for cp in range(48, 58)}
                self.assertEqual(len(widths), 1)
                self.assertEqual(font.glyph(ord('-')).width, widths.pop())
                for cp in range(48, 58):
                    self.assertEqual(extent(font.glyph(cp).rows), cap)
                for char, minimum in [('0', 1), ('6', 1), ('8', 2), ('9', 1)]:
                    matrix = [[v == '#' for v in row] for row in font.glyph(ord(char)).rows]
                    self.assertGreaterEqual(len(holes(matrix)), minimum)

    def test_g_has_connected_bowl_and_distinct_hook(self):
        for font in self.fonts:
            with self.subTest(font=font.name):
                g = font.glyph(ord('g')).rows
                matrix = [[v == '#' for v in row] for row in g]
                self.assertEqual(len(components(matrix)), 1)
                self.assertGreaterEqual(len(holes(matrix)), 1)
                self.assertNotEqual(g, font.glyph(ord('q')).rows)
                self.assertNotEqual(g, font.glyph(ord('9')).rows)
                self.assertGreater(g[-1].count('#'), font.glyph(ord('q')).rows[-1].count('#'))

    def test_capitals_and_figures_fill_the_cap_height(self):
        for font in self.fonts:
            for char in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789':
                with self.subTest(font=font.name, glyph=char):
                    rows = font.glyph(ord(char)).rows
                    self.assertIn('#', rows[0])
                    self.assertIn('#', rows[font.baseline - 1])
                    if char != 'Q':
                        self.assertFalse(any('#' in row for row in rows[font.baseline:]))

    def test_expected_symmetry(self):
        # Check the ink bounds: tabular padding may differ by one pixel when
        # an odd-width figure occupies an even-width clock advance.
        for font in self.fonts:
            for axis, chars in [('horizontal', 'AHIMOTUVWXYovwx08!+-:=^_|'),
                                ('vertical', 'HIOXox0+-:=|')]:
                for char in chars:
                    with self.subTest(font=font.name, glyph=char, axis=axis):
                        rows = font.glyph(ord(char)).rows
                        xs = [x for row in rows for x, v in enumerate(row) if v == '#']
                        ys = [y for y, row in enumerate(rows) if '#' in row]
                        box = [row[min(xs):max(xs) + 1] for row in rows[min(ys):max(ys) + 1]]
                        reflected = [row[::-1] for row in box] if axis == 'horizontal' else box[::-1]
                        self.assertEqual(box, reflected)

    def test_strokes_and_counters_survive_every_cut(self):
        for font in self.fonts:
            for char in 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghklmnopqrstuvwxyz0123456789':
                with self.subTest(font=font.name, glyph=char):
                    matrix = [[v == '#' for v in row] for row in font.glyph(ord(char)).rows]
                    self.assertEqual(len(components(matrix)), 1)
                    if char in 'ABDOPQRabdgopq0689':
                        self.assertTrue(holes(matrix), 'bowl lost its counter')

    def test_capital_i_keeps_its_serifs(self):
        for font in self.fonts:
            with self.subTest(font=font.name):
                rows = font.glyph(ord('I')).rows
                self.assertGreater(rows[0].count('#'), rows[font.baseline // 2].count('#'))
                self.assertEqual(rows[0], rows[font.baseline - 1])


if __name__ == '__main__':
    unittest.main()
