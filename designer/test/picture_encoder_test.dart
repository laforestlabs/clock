// Tests for the picture encoder: the step between "the owner picked a file" and
// the pre-gamma RGB888 the mirror's `POST /api/image` body carries.
//
// Every case asserts what a consumer of the returned buffer sees — which panel
// pixel got which source colour, where the black bars landed, whether the
// aspect ratio survived, whether a transparent source pixel came out black —
// rather than which canvas calls happened. The expectations are derived from
// the source geometry, so a regression in the framing maths moves a colour to
// the wrong coordinate and fails here.
//
// PNG sources are painted at runtime and encoded through `dart:ui`, which keeps
// the asserted colours next to the code that makes them. The JPEGs and the APNG
// are base64 below: `dart:ui` encodes PNG only, and no test should be building
// an animation. Both JPEGs come from the same quadrant pattern, one of them
// carrying EXIF orientation 6.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/services/picture_encoder.dart';

/// An 8×4 JPEG of the quadrant pattern.
const String _jpegQuadB64 =
    '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgK'
    'CgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/2wBDAQMDAwQDBAgEBAgQCwkL'
    'EBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBD/wAAR'
    'CAAEAAgDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAA'
    'AgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkK'
    'FhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWG'
    'h4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl'
    '5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREA'
    'AgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYk'
    'NOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOE'
    'hYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk'
    '5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwCp/wAE0tMsviP/AMLH/wCE0g/tH+zv7H+z'
    'fMYfL8z7Zv8A9WVznYvXPTjvRRRX8ofTDpw4f8ac6y7KUqFCH1blp0/chG+EoSfLGNoq8m5O'
    'y1bberOijkmWcUwWbZ7hqeJxNT46taEalSXL7seac1KUuWMVFXbtFJLRI//Z';

/// The same 8×4 image with EXIF orientation 6 (displayed rotated 90°
/// clockwise, so the picture is really a 4×8 portrait).
const String _jpegExifB64 =
    '/9j/4AAQSkZJRgABAQAAAQABAAD/4QAiRXhpZgAATU0AKgAAAAgAAQESAAMAAAABAAYAAAAA'
    'AAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDREN'
    'Dg8QEBEQCgwSExIQEw8QEBD/2wBDAQMDAwQDBAgEBAgQCwkLEBAQEBAQEBAQEBAQEBAQEBAQ'
    'EBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBD/wAARCAAEAAgDASIAAhEBAxEB/8QA'
    'HwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQID'
    'AAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6'
    'Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWm'
    'p6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QA'
    'HwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAEC'
    'AxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5'
    'OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOk'
    'paanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oA'
    'DAMBAAIRAxEAPwCp/wAE0tMsviP/AMLH/wCE0g/tH+zv7H+zfMYfL8z7Zv8A9WVznYvXPTjv'
    'RRRX8ofTDpw4f8ac6y7KUqFCH1blp0/chG+EoSfLGNoq8m5Oy1bberOijkmWcUwWbZ7hqeJx'
    'NT46taEalSXL7seac1KUuWMVFXbtFJLRI//Z';

/// A two-frame animated PNG (APNG) of the quadrant pattern.
const String _apngB64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAECAYAAACzzX7wAAAACGFjVEwAAAACAAAAAPONk3AA'
    'AAAaZmNUTAAAAAAAAAAIAAAABAAAAAAAAAAAAMgD6AAA620yDAAAACxJREFUeJxjZGBgYPjP'
    'wPCfAQoY4SwIYEKWxAZYGNHk/zMwopqATzcDAwMDAJ97BwYD/suuAAAAGmZjVEwAAAABAAAA'
    'AQAAAAEAAAAAAAAAAADIA+gAAJ3a+44AAAARZmRBVAAAAAJ4nGP4z8DwHwAFAAH/mpWTZAAA'
    'AABJRU5ErkJggg==';

/// A still PNG whose IHDR declares 8000×6000 — 48 megapixels — but whose body
/// holds the 8×4 image the header was rewritten from. Small enough to check in
/// precisely because nothing may decode it.
const String _bombB64 =
    'iVBORw0KGgoAAAANSUhEUgAAH0AAABdwCAIAAAC+BnNpAAAAHUlEQVR4nGP8z4AAjEgcJgYc'
    'gJGBAaHs/39GwjoAMhoFBIQo5SUAAAAASUVORK5CYII=';

/// JPEG is lossy, so a sampled pixel is near its source colour, not equal to
/// it. The quadrants are large flat areas and the samples sit well inside them,
/// so the error stays in the low tens of 8-bit steps.
const int _jpegTolerance = 40;

const List<int> _red = <int>[255, 0, 0];
const List<int> _green = <int>[0, 255, 0];
const List<int> _blue = <int>[0, 0, 255];
const List<int> _yellow = <int>[255, 255, 0];
const List<int> _cyan = <int>[0, 255, 255];
const List<int> _magenta = <int>[255, 0, 255];
const List<int> _grey = <int>[128, 128, 128];
const List<int> _white = <int>[255, 255, 255];

/// Red top-left, green top-right, blue bottom-left, yellow bottom-right.
void _quadrants(Uint8List rgba, int width, int height) {
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final left = x < width ~/ 2;
      final top = y < height ~/ 2;
      final colour = top ? (left ? _red : _green) : (left ? _blue : _yellow);
      _set(rgba, width, x, y, colour, 255);
    }
  }
}

/// One distinctive colour per edge row, so a crop shows up as a colour that is
/// missing rather than as a shifted gradient that is hard to read.
void _markedRows(Uint8List rgba, int width, int height) {
  for (var y = 0; y < height; y++) {
    final row = y == 0
        ? _cyan
        : y == height - 1
            ? _magenta
            : (y == 1 || y == height - 2)
                ? _grey
                : _white;
    for (var x = 0; x < width; x++) {
      _set(rgba, width, x, y, row, 255);
    }
  }
}

void _set(
    Uint8List rgba, int width, int x, int y, List<int> colour, int alpha) {
  final i = (y * width + x) * 4;
  rgba[i] = colour[0];
  rgba[i + 1] = colour[1];
  rgba[i + 2] = colour[2];
  rgba[i + 3] = alpha;
}

/// Paints [paint] into an RGBA buffer and encodes it as PNG through `dart:ui`.
Future<Uint8List> _png(
  int width,
  int height,
  void Function(Uint8List rgba, int width, int height) paint,
) async {
  final rgba = Uint8List(width * height * 4);
  paint(rgba, width, height);
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
      rgba, width, height, ui.PixelFormat.rgba8888, completer.complete);
  final image = await completer.future;
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

List<int> _pixel(Uint8List rgb, int width, int x, int y) {
  final i = (y * width + x) * 3;
  return <int>[rgb[i], rgb[i + 1], rgb[i + 2]];
}

/// Asserts one panel pixel. The failure names the coordinates, so a framing
/// regression reads as "the green is at (3,2)" instead of as a byte offset.
void _expectPixel(
  Uint8List rgb,
  int width,
  int x,
  int y,
  List<int> expected, {
  int tolerance = 0,
}) {
  final actual = _pixel(rgb, width, x, y);
  final matches = List<bool>.generate(
    3,
    (i) => (actual[i] - expected[i]).abs() <= tolerance,
  ).every((ok) => ok);
  expect(
    matches,
    isTrue,
    reason: 'pixel ($x,$y) is $actual, expected $expected'
        '${tolerance == 0 ? '' : ' within $tolerance'}',
  );
}

/// How many frames Flutter's own image codec sees in [bytes].
///
/// Used once, to show that a rejection came from the encoder's PNG chunk walk
/// and not from the codec's frame count.
Future<int> _codecFrameCount(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  final codec = await descriptor.instantiateCodec();
  final frames = codec.frameCount;
  final frame = await codec.getNextFrame();
  frame.image.dispose();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  return frames;
}

/// [png] with an `acTL` chunk declaring a single frame, inserted before the
/// first `IDAT` the way a real APNG carries it, CRC and all.
///
/// One frame is the point: the codec then reports a still image, so only the
/// encoder's own animation check can refuse the file.
Uint8List _withAnimationChunk(Uint8List png) {
  final out = BytesBuilder(copy: false);
  out.add(png.sublist(0, 8));
  var offset = 8;
  var inserted = false;
  while (offset + 8 <= png.length) {
    final length = (png[offset] << 24) |
        (png[offset + 1] << 16) |
        (png[offset + 2] << 8) |
        png[offset + 3];
    final type = String.fromCharCodes(png.sublist(offset + 4, offset + 8));
    if (type == 'IDAT' && !inserted) {
      inserted = true;
      const payload = <int>[0, 0, 0, 1, 0, 0, 0, 0];
      final check = _crc32(<int>[...'acTL'.codeUnits, ...payload]);
      out.add(<int>[
        (payload.length >> 24) & 0xff,
        (payload.length >> 16) & 0xff,
        (payload.length >> 8) & 0xff,
        payload.length & 0xff,
        ...'acTL'.codeUnits,
        ...payload,
        (check >> 24) & 0xff,
        (check >> 16) & 0xff,
        (check >> 8) & 0xff,
        check & 0xff,
      ]);
    }
    out.add(png.sublist(offset, offset + 12 + length));
    offset += 12 + length;
  }
  return out.toBytes();
}

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return crc ^ 0xffffffff;
}

void main() {
  group('framing', () {
    test('Fit shows the whole picture with black bars, unstretched', () async {
      // A 2:1 source in a square frame: Fit scales to the width, so the picture
      // is 8 wide and 4 tall with a black row pair above and below it. A
      // stretched picture would have no bars at all.
      final source = await _png(8, 4, _quadrants);
      final out =
          await encodePicture(source, width: 8, height: 8, fit: PictureFit.fit);

      expect(out.length, 8 * 8 * 3);
      for (final y in <int>[0, 1, 6, 7]) {
        for (var x = 0; x < 8; x++) {
          _expectPixel(out, 8, x, y, const <int>[0, 0, 0]);
        }
      }
      // The quadrants keep their source positions: the vertical boundary is
      // still halfway across, and red/green stay above blue/yellow.
      _expectPixel(out, 8, 3, 2, _red);
      _expectPixel(out, 8, 4, 2, _green);
      _expectPixel(out, 8, 3, 5, _blue);
      _expectPixel(out, 8, 4, 5, _yellow);
    });

    test('Fill covers the panel and crops the overhanging edges', () async {
      // The same 2:1 source in a square frame: Fill scales to the height, so
      // the picture is 16 wide behind an 8-wide frame and the outer columns are
      // lost. Nothing is letterboxed and nothing is stretched.
      final source = await _png(8, 4, _quadrants);
      final out = await encodePicture(source,
          width: 8, height: 8, fit: PictureFit.fill);

      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          expect(
            _pixel(out, 8, x, y),
            isNot(const <int>[0, 0, 0]),
            reason: 'Fill left a letterbox pixel at ($x,$y)',
          );
        }
      }
      _expectPixel(out, 8, 1, 1, _red);
      _expectPixel(out, 8, 6, 1, _green);
      _expectPixel(out, 8, 1, 6, _blue);
      _expectPixel(out, 8, 6, 6, _yellow);
    });

    test('Fit of a square picture leaves black columns at the sides', () async {
      // The 80×80-into-64×32 case from the plan, scaled down: an 8×8 source in
      // a 16×8 frame is drawn 8×8 in the middle, so four black columns sit on
      // each side and no source row is cropped.
      final source = await _png(8, 8, _markedRows);
      final out = await encodePicture(source,
          width: 16, height: 8, fit: PictureFit.fit);

      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 4; x++) {
          _expectPixel(out, 16, x, y, const <int>[0, 0, 0]);
          _expectPixel(out, 16, 12 + x, y, const <int>[0, 0, 0]);
        }
      }
      for (var y = 0; y < 8; y++) {
        _expectPixel(out, 16, 8, y, _markedRowColour(y));
      }
    });

    test('Fill crops a square picture top and bottom, symmetrically', () async {
      final source = await _png(8, 8, _markedRows);
      final out = await encodePicture(source,
          width: 16, height: 8, fit: PictureFit.fill);

      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 16; x++) {
          final pixel = _pixel(out, 16, x, y);
          expect(pixel, isNot(_cyan),
              reason: 'Fill kept the clipped top row at ($x,$y)');
          expect(pixel, isNot(_magenta),
              reason: 'Fill kept the clipped bottom row at ($x,$y)');
        }
      }
      // What is left is the middle of the picture, cropped evenly: the first
      // and last rows come from the same distance into the source.
      expect(_pixel(out, 16, 5, 0), _pixel(out, 16, 5, 7));
      _expectPixel(out, 16, 5, 3, _white);
    });

    test('Fit and Fill agree when the aspect ratio already matches', () async {
      final source = await _png(8, 4, _quadrants);
      final fit = await encodePicture(source,
          width: 16, height: 8, fit: PictureFit.fit);
      final fill = await encodePicture(source,
          width: 16, height: 8, fit: PictureFit.fill);

      expect(fit, fill);
    });

    test('channel values reach the panel unchanged', () async {
      // 128 must arrive as 128. The firmware gamma-corrects whatever it is
      // given, so a transform applied here would be applied twice and a mid
      // grey would come out visibly lighter. The frame is the source's own size
      // so no resampling can move a value either.
      final source = await _png(4, 2, (rgba, width, height) {
        const columns = <List<int>>[
          <int>[128, 128, 128, 255],
          <int>[255, 255, 255, 255],
          <int>[0, 0, 0, 255],
          <int>[64, 32, 16, 255],
        ];
        for (var y = 0; y < height; y++) {
          for (var x = 0; x < width; x++) {
            final column = columns[x];
            _set(rgba, width, x, y, column, column[3]);
          }
        }
      });
      final out =
          await encodePicture(source, width: 4, height: 2, fit: PictureFit.fit);

      _expectPixel(out, 4, 0, 0, const <int>[128, 128, 128]);
      _expectPixel(out, 4, 1, 0, const <int>[255, 255, 255]);
      _expectPixel(out, 4, 2, 0, const <int>[0, 0, 0]);
      _expectPixel(out, 4, 3, 0, const <int>[64, 32, 16]);
      expect(_pixel(out, 4, 0, 1), _pixel(out, 4, 0, 0));
    });
  });

  group('alpha', () {
    test('transparent pixels become black, not undefined', () async {
      final source = await _png(4, 2, (rgba, width, height) {
        for (var y = 0; y < height; y++) {
          for (var x = 0; x < width; x++) {
            final transparent = x == 0 && y == 0;
            _set(rgba, width, x, y, _red, transparent ? 0 : 255);
          }
        }
      });
      final out =
          await encodePicture(source, width: 4, height: 2, fit: PictureFit.fit);

      _expectPixel(out, 4, 0, 0, const <int>[0, 0, 0]);
      _expectPixel(out, 4, 1, 0, _red);
      _expectPixel(out, 4, 0, 1, _red);
    });
  });

  group('jpeg', () {
    test('a JPEG is framed from its decoded pixels', () async {
      final jpeg = Uint8List.fromList(base64.decode(_jpegQuadB64));
      final out =
          await encodePicture(jpeg, width: 8, height: 8, fit: PictureFit.fill);

      _expectPixel(out, 8, 0, 0, _red, tolerance: _jpegTolerance);
      _expectPixel(out, 8, 7, 0, _green, tolerance: _jpegTolerance);
      _expectPixel(out, 8, 0, 7, _blue, tolerance: _jpegTolerance);
      _expectPixel(out, 8, 7, 7, _yellow, tolerance: _jpegTolerance);
    });

    test('EXIF orientation decides which way the picture is framed', () async {
      // The stored image is 8×4 landscape with EXIF orientation 6, so the
      // picture is really a 4×8 portrait: Fit into a square frame leaves black
      // columns, not black rows. A decoder that ignored EXIF would have
      // produced the transpose and the bars would be horizontal.
      final jpeg = Uint8List.fromList(base64.decode(_jpegExifB64));
      final out =
          await encodePicture(jpeg, width: 8, height: 8, fit: PictureFit.fit);

      for (var y = 0; y < 8; y++) {
        for (final x in <int>[0, 1, 6, 7]) {
          _expectPixel(out, 8, x, y, const <int>[0, 0, 0]);
        }
      }
      // Displayed, the picture's top-left quadrant is blue and its bottom-left
      // yellow: the rotation reached the frame.
      _expectPixel(out, 8, 2, 0, _blue, tolerance: _jpegTolerance);
      _expectPixel(out, 8, 5, 0, _red, tolerance: _jpegTolerance);
      _expectPixel(out, 8, 2, 7, _yellow, tolerance: _jpegTolerance);
      _expectPixel(out, 8, 5, 7, _green, tolerance: _jpegTolerance);
    });
  });

  group('rejection', () {
    test('a file above the size cap is refused before it is read', () async {
      expect(
          () => validatePictureFileSize(pictureMaxFileBytes), returnsNormally);
      expect(() => validatePictureFileSize(pictureMaxFileBytes + 1),
          throwsA(isA<PictureEncodeException>()));

      // The cap applies to the bytes too, so a caller that skipped the guard
      // cannot make the app hand 21 MB to the decoder. The message has to be a
      // size complaint rather than a decode one: "too big" and "not a picture"
      // are different problems for the owner to fix.
      final oversized = Uint8List(pictureMaxFileBytes + 1);
      await expectLater(
        encodePicture(oversized, width: 64, height: 32, fit: PictureFit.fit),
        throwsA(isA<PictureEncodeException>().having(
          (e) => e.message,
          'message',
          allOf(contains('MB'), isNot(contains('decoded'))),
        )),
      );
    });

    test('a picture past the decode cap is refused on its declared size',
        () async {
      // The header declares 8000×6000 — 48 megapixels — around a tiny body.
      // Refusing it proves the descriptor's dimensions are checked before the
      // pixels are decoded, rather than after the decoder allocated 48M×4
      // bytes of them.
      final bomb = Uint8List.fromList(base64.decode(_bombB64));
      await expectLater(
        encodePicture(bomb, width: 64, height: 32, fit: PictureFit.fit),
        throwsA(isA<PictureEncodeException>().having(
            (e) => e.message,
            'message',
            contains('${pictureMaxSourcePixels ~/ 1000000} megapixels'))),
      );
    });

    test('a PNG that only declares an animation is refused', () async {
      // Flutter's APNG support is a platform detail: a codec that reports one
      // frame would hand back the first frame of an animation, and the mirror
      // would store that as the picture the owner chose. This file carries the
      // animation chunk beside a still image, and the codec here sees exactly
      // one frame — so the encoder's own check is what refuses it.
      final still = await _png(8, 4, _quadrants);
      final declaring = _withAnimationChunk(still);
      expect(await _codecFrameCount(declaring), 1);

      await expectLater(
        encodePicture(declaring, width: 8, height: 4, fit: PictureFit.fit),
        throwsA(isA<PictureEncodeException>()
            .having((e) => e.message, 'message', contains('animated'))),
      );
    });

    test('an animated PNG is refused', () async {
      final apng = Uint8List.fromList(base64.decode(_apngB64));
      await expectLater(
        encodePicture(apng, width: 8, height: 4, fit: PictureFit.fit),
        throwsA(isA<PictureEncodeException>()
            .having((e) => e.message, 'message', contains('animated'))),
      );
    });

    test('a file that is not a picture is refused', () async {
      Future<void> expectRefused(List<int> bytes, String expected) =>
          expectLater(
            encodePicture(Uint8List.fromList(bytes),
                width: 64, height: 32, fit: PictureFit.fit),
            throwsA(isA<PictureEncodeException>()
                .having((e) => e.message, 'message', contains(expected))),
          );

      await expectRefused(utf8.encode('this is a text file'), 'PNG or JPEG');
      await expectRefused(
          <int>[...'GIF89a'.codeUnits, 0, 0, 0, 0], 'PNG or JPEG');
      await expectRefused(const <int>[], 'empty');
      // A PNG that stops inside its header: the signature is right, so only the
      // codec can reject it.
      final truncated = (await _png(8, 4, _quadrants)).sublist(0, 24);
      await expectRefused(truncated, 'decoded');
    });

    test('panel geometry is validated rather than guessed', () async {
      final source = await _png(8, 4, _quadrants);
      Future<void> expectRefused(int width, int height) => expectLater(
            encodePicture(source,
                width: width, height: height, fit: PictureFit.fit),
            throwsA(isA<PictureEncodeException>()),
          );

      // No geometry at all: a picture framed for a guessed 64×32 would be sent
      // to a panel of an unknown shape.
      await expectRefused(0, 32);
      await expectRefused(64, 0);
      await expectRefused(-8, -4);
      // Past the payload cap the firmware does not offer the picture API.
      await expectRefused(300, 300);

      expect(pictureGeometrySupported(0, 32), isFalse);
      expect(pictureGeometrySupported(64, 0), isFalse);
      expect(pictureGeometrySupported(64, 32), isTrue);
      expect(pictureGeometrySupported(256, 256), isTrue);
      expect(pictureGeometrySupported(257, 256), isFalse);

      // A real panel produces exactly one RGB triple per pixel, up to and
      // including the 256×256 boundary of what the firmware will accept.
      final panel = await encodePicture(source,
          width: 64, height: 32, fit: PictureFit.fit);
      expect(panel.length, 64 * 32 * 3);
      final largest = await encodePicture(source,
          width: 256, height: 256, fit: PictureFit.fit);
      expect(largest.length, 256 * 256 * 3);
    });
  });

  group('decode', () {
    test('hands back the decoded picture with the limits still applied',
        () async {
      final source = await _png(8, 8, _quadrants);
      final image = await decodePicture(source);

      expect(image.width, 8);
      expect(image.height, 8);
      // The pixels are the source's own, in the orientation the frame draws
      // from: red top-left, yellow bottom-right.
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final rgba =
          data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      expect(rgba.sublist(0, 4), const <int>[255, 0, 0, 255]);
      const last = (8 * 8 - 1) * 4;
      expect(rgba.sublist(last, last + 4), const <int>[255, 255, 0, 255]);
      image.dispose();

      // The decode half still enforces what encodePicture enforces: a
      // decompression bomb is refused on its header before the pixels exist,
      // and an animation is refused rather than handing out its first frame.
      await expectLater(
        decodePicture(Uint8List.fromList(base64.decode(_bombB64))),
        throwsA(isA<PictureEncodeException>().having(
            (e) => e.message,
            'message',
            contains('${pictureMaxSourcePixels ~/ 1000000} '
                'megapixels'))),
      );
      await expectLater(
        decodePicture(Uint8List.fromList(base64.decode(_apngB64))),
        throwsA(isA<PictureEncodeException>()
            .having((e) => e.message, 'message', contains('animated'))),
      );
    });
  });

  group('crop', () {
    test('an off-centre crop samples only the selected region', () async {
      // The bottom-right quadrant of an 8×8 source is yellow; the other three
      // quadrants are red, green and blue. Framed at the crop's own size, every
      // panel pixel has to come from that quarter, so a crop that was ignored,
      // or taken from the wrong corner, shows another colour here.
      final source = await _png(8, 8, _quadrants);
      final out = await encodePicture(source,
          width: 4,
          height: 4,
          fit: PictureFit.fit,
          crop: const ui.Rect.fromLTWH(0.5, 0.5, 0.5, 0.5));

      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          _expectPixel(out, 4, x, y, _yellow);
        }
      }
    });

    test('the crop\'s own shape decides the letterboxing', () async {
      // The top half of the square source is 2:1, so Fit into the square frame
      // letterboxes it — framing the whole square source would have left no
      // bars at all. The bottom half's blue and yellow must not survive.
      final source = await _png(8, 8, _quadrants);
      final out = await encodePicture(source,
          width: 8,
          height: 8,
          fit: PictureFit.fit,
          crop: const ui.Rect.fromLTWH(0, 0, 1, 0.5));

      for (final y in <int>[0, 1, 6, 7]) {
        for (var x = 0; x < 8; x++) {
          _expectPixel(out, 8, x, y, const <int>[0, 0, 0]);
        }
      }
      _expectPixel(out, 8, 3, 2, _red);
      _expectPixel(out, 8, 4, 2, _green);
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          expect(_pixel(out, 8, x, y), isNot(_blue),
              reason: 'the cropped-out blue quadrant reached ($x,$y)');
          expect(_pixel(out, 8, x, y), isNot(_yellow),
              reason: 'the cropped-out yellow quadrant reached ($x,$y)');
        }
      }
    });

    test('Fill covers the panel from the crop, not from the picture', () async {
      // The right half of the source is green above yellow, and is 1:2 tall.
      // Fill into the square frame uses that shape — scale 2, so the panel sees
      // source rows 2..5 — and the red and blue halves never appear.
      final source = await _png(8, 8, _quadrants);
      final out = await encodePicture(source,
          width: 8,
          height: 8,
          fit: PictureFit.fill,
          crop: const ui.Rect.fromLTWH(0.5, 0, 0.5, 1));

      _expectPixel(out, 8, 3, 0, _green);
      _expectPixel(out, 8, 3, 7, _yellow);
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          expect(_pixel(out, 8, x, y), isNot(_red),
              reason: 'the cropped-out red quadrant reached ($x,$y)');
          expect(_pixel(out, 8, x, y), isNot(_blue),
              reason: 'the cropped-out blue quadrant reached ($x,$y)');
        }
      }
    });

    test('a cropped transparent region still composites onto black', () async {
      // The left half of the source is transparent red and the right half is
      // opaque red. Cropping takes one half at a time; the transparent one has
      // to arrive black, the opaque one red.
      final source = await _png(4, 4, (rgba, width, height) {
        for (var y = 0; y < height; y++) {
          for (var x = 0; x < width; x++) {
            _set(rgba, width, x, y, _red, x < 2 ? 0 : 255);
          }
        }
      });
      final left = await encodePicture(source,
          width: 2,
          height: 4,
          fit: PictureFit.fit,
          crop: const ui.Rect.fromLTWH(0, 0, 0.5, 1));
      final right = await encodePicture(source,
          width: 2,
          height: 4,
          fit: PictureFit.fit,
          crop: const ui.Rect.fromLTWH(0.5, 0, 0.5, 1));

      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 2; x++) {
          _expectPixel(left, 2, x, y, const <int>[0, 0, 0]);
          _expectPixel(right, 2, x, y, _red);
        }
      }
    });

    test('a crop that leaves the picture is refused', () async {
      final source = await _png(8, 4, _quadrants);
      Future<void> expectRefused(ui.Rect crop, String expected) => expectLater(
            encodePicture(source,
                width: 8, height: 4, fit: PictureFit.fit, crop: crop),
            throwsA(isA<PictureEncodeException>()
                .having((e) => e.message, 'message', contains(expected))),
          );

      // A region that reaches past an edge is not in the picture at all.
      await expectRefused(const ui.Rect.fromLTWH(0.5, 0, 0.75, 1), 'outside');
      await expectRefused(const ui.Rect.fromLTWH(-0.25, 0, 0.5, 1), 'outside');
      await expectRefused(const ui.Rect.fromLTWH(0, -0.25, 1, 0.5), 'outside');
      await expectRefused(const ui.Rect.fromLTWH(0, 0.75, 1, 0.5), 'outside');
      // An inverted rectangle has a negative width, so it takes in no part of
      // the picture whichever way it is reasoned about.
      await expectRefused(const ui.Rect.fromLTRB(0.75, 0, 0.25, 1), 'no part');
      // Not numbers at all: these would otherwise reach the canvas as a NaN
      // source rectangle, and `NaN > 1` is false, so nothing else catches them.
      await expectRefused(const ui.Rect.fromLTWH(double.nan, 0, 1, 1), 'outside');
      await expectRefused(const ui.Rect.fromLTWH(0, double.nan, 1, 1), 'outside');
      await expectRefused(
          const ui.Rect.fromLTWH(0, 0, double.infinity, 1), 'outside');
      await expectRefused(
          const ui.Rect.fromLTWH(0, 0, double.negativeInfinity, 1), 'outside');
      // No area: there is nothing to sample and nothing to scale.
      await expectRefused(const ui.Rect.fromLTWH(0, 0, 0, 1), 'no part');
      await expectRefused(const ui.Rect.fromLTWH(0.5, 0, 0.5, 0), 'no part');

      // The bounds are the whole picture, so a crop that touches every edge is
      // the same picture as no crop at all.
      final whole = await encodePicture(source,
          width: 8,
          height: 4,
          fit: PictureFit.fit,
          crop: const ui.Rect.fromLTWH(0, 0, 1, 1));
      final uncropped =
          await encodePicture(source, width: 8, height: 4, fit: PictureFit.fit);
      expect(whole, uncropped);
    });
  });
}

/// The colour [_markedRows] paints into row [y] of an 8-row source.
List<int> _markedRowColour(int y) {
  if (y == 0) return _cyan;
  if (y == 7) return _magenta;
  if (y == 1 || y == 6) return _grey;
  return _white;
}
