// Turns one still image into the panel-sized RGB888 bytes a mirror stores.
//
// The firmware has no image decoder. `firmware/main/display_store.c` takes raw,
// row-major, top-left RGB888 at exactly `panel_width()`×`panel_height()`, and
// it is handed to the canvas *before* `core/src/canvas.c` applies its gamma and
// brightness transform. So the decoding, framing and scaling all happen here,
// on the phone, and what leaves this file is already what the panel's canvas
// would receive from a designer layout: no gamma, no brightness, no flip, no
// channel swap. Applying any of that here would show the panel a picture it
// never had.
//
// Framing is only Fit and Fill, on purpose. Both scale uniformly: a mirror is a
// fixed pixel grid, and a picture stretched to reach both edges would be wrong
// on every panel whose aspect ratio differs from the file's. Fit keeps the
// whole image and lets the panel's black background show as letterboxing; Fill
// covers the panel and loses the overhanging edges. There is no crop editor and
// no dithering or palette reduction: the panel takes 24-bit colour.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'mirror_display.dart' show mirrorFrameMaxPayloadBytes;

/// How a picture is laid on a panel whose aspect ratio it does not match.
///
/// [fit] scales to the smaller factor — the whole image is visible, with black
/// bars on the two short sides. [fill] scales to the larger factor — the panel
/// is covered edge to edge and the source's overhanging edges are cropped.
/// Both preserve the source's aspect ratio; neither stretches.
enum PictureFit { fit, fill }

/// The largest file this app will read: 20 MiB.
///
/// A picture only has to survive a lossless decode and one rescale into a panel
/// of at most 256×256; anything past this is a mistake — a RAW file, a video, a
/// scanned poster — and reading it would waste the phone's memory before the
/// decoder got a chance to reject it.
const int pictureMaxFileBytes = 20 << 20;

/// The most source pixels the app will decode: 40 million.
///
/// A phone-camera photo is 12–50 megapixels, so the cap sits inside the range
/// the feature is for; the point is to refuse a decompression bomb before the
/// decoder allocates width×height×4 bytes of it.
const int pictureMaxSourcePixels = 40000000;

/// A picture the app cannot turn into panel pixels, worded as a sentence the
/// upload screen can show as-is.
///
/// Every failure inside this file — an oversized file, a foreign format, an
/// animated image, an impossible panel size and any error the codec raises —
/// arrives as this one type, so the screen has a single failure vocabulary and
/// can keep the user's prepared picture for another try.
class PictureEncodeException implements Exception {
  PictureEncodeException(this.message);

  /// Human-facing, complete sentence.
  final String message;

  @override
  String toString() => message;
}

/// Rejects a file whose size alone rules it out, before its bytes are read.
///
/// The upload screen checks `XFile.length()` with this so a 200 MB file is
/// refused without ever being held in memory; [encodePicture] applies the same
/// cap to the bytes it is handed, so a caller that skipped the check still
/// cannot make the app allocate past it.
void validatePictureFileSize(int bytes) {
  if (bytes > pictureMaxFileBytes) {
    throw PictureEncodeException(
        'That picture is ${_megabytes(bytes)} MB, and the largest a mirror '
        'takes is ${pictureMaxFileBytes >> 20} MB.');
  }
}

/// Whether [width]×[height] is a panel a picture can be prepared for.
///
/// Zero or negative means the device never reported a geometry — the app does
/// not guess 64×32, because a picture framed for a guessed panel would be sent
/// to hardware of an unknown shape. Past the payload cap the firmware does not
/// advertise the picture API at all, so preparing bytes for it is pointless.
bool pictureGeometrySupported(int width, int height) =>
    width > 0 && height > 0 && width * height * 3 <= mirrorFrameMaxPayloadBytes;

/// Decodes [encoded] and frames it for a [width]×[height] panel.
///
/// Returns exactly `width * height * 3` pre-gamma RGB888 bytes, row-major from
/// the top-left, ready for `POST /api/image`'s body.
///
/// The source must really be a PNG or a JPEG: the signature is checked before
/// the codec is asked to decode it, so a renamed file is refused with the
/// format's name rather than the codec's. Dimensions come from Flutter's image
/// descriptor, which reads the header only, so an image whose declared size is
/// absurd (or zero, or past [pictureMaxSourcePixels]) is refused before any
/// pixels are decoded.
///
/// Animation is refused twice over, because the codec's own support for it
/// varies: a PNG whose chunk stream declares animation is caught before the
/// codec runs, and anything the codec reports as having more than one frame is
/// refused once it has been opened — the mirror shows one still picture.
///
/// Orientation is the codec's, including JPEG EXIF, so a photo taken sideways
/// arrives at the panel the way the phone's gallery shows it; the descriptor's
/// dimensions and the decoded image agree because both include that rotation.
Future<Uint8List> encodePicture(
  Uint8List encoded, {
  required int width,
  required int height,
  required PictureFit fit,
}) async {
  validatePictureFileSize(encoded.length);
  _validateTarget(width, height);
  if (encoded.isEmpty) {
    throw PictureEncodeException('The selected file is empty.');
  }
  if (!_looksLikePng(encoded) && !_looksLikeJpeg(encoded)) {
    throw PictureEncodeException('That file is not a PNG or JPEG picture.');
  }
  if (_looksLikePng(encoded) && _pngDeclaresAnimation(encoded)) {
    throw PictureEncodeException(_animatedMessage);
  }

  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? source;
  ui.Picture? composed;
  ui.Image? scaled;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(encoded);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    _validateSource(descriptor.width, descriptor.height);
    codec = await descriptor.instantiateCodec();
    if (codec.frameCount != 1) {
      throw PictureEncodeException(_animatedMessage);
    }
    source = (await codec.getNextFrame()).image;
    composed = _compose(source, width, height, fit);
    scaled = await composed.toImage(width, height);
    final rgba = await scaled.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (rgba == null) {
      throw PictureEncodeException(
          'That picture could not be rasterised for the panel.');
    }
    return _packRgb(
      rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes),
      width,
      height,
    );
  } on PictureEncodeException {
    rethrow;
  } catch (_) {
    // A corrupt or unsupported file makes the codec throw a bare Exception
    // ("Invalid image data") with no type of its own, and its text is not
    // something to show a person; callers get a sentence instead.
    throw PictureEncodeException('That picture could not be decoded.');
  } finally {
    scaled?.dispose();
    composed?.dispose();
    source?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// The PNG signature: eight bytes no other format starts with.
const List<int> _pngSignature = <int>[
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
];

bool _looksLikePng(Uint8List bytes) {
  if (bytes.length < _pngSignature.length) return false;
  for (var i = 0; i < _pngSignature.length; i++) {
    if (bytes[i] != _pngSignature[i]) return false;
  }
  return true;
}

/// JPEG's SOI marker. The rest of the file is verified by decoding it.
bool _looksLikeJpeg(Uint8List bytes) =>
    bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xd8;

/// The one sentence both animation checks raise: the chunk-level one below and
/// the codec's own frame count. Animated content is refused whichever check
/// sees it first, and the screen cannot tell — and does not need to — which.
const String _animatedMessage =
    'That picture is animated; the mirror shows one still image.';

/// `acTL`, the animation control chunk an APNG carries and a still PNG does not.
const List<int> _pngAnimationChunk = <int>[0x61, 0x63, 0x54, 0x4c];

/// `IEND`, the last chunk of any PNG.
const List<int> _pngEndChunk = <int>[0x49, 0x45, 0x4e, 0x44];

/// Whether the PNG's chunk stream declares an animation.
///
/// The codec's frame count is the primary check, but Flutter's image decoding
/// support for APNG is a platform detail: a build whose codec treats an APNG as
/// one still frame would hand back the first frame and the mirror would store
/// that as if it were the picture the owner chose. So the chunk stream is
/// *walked* — 4-byte big-endian length, 4-byte type, payload, 4-byte CRC — and
/// only a chunk whose type field is exactly `acTL` counts. A byte scan for the
/// four letters would match inside IDAT pixel data or a tEXt comment instead.
///
/// A stream that stops making sense is left to the codec: this returns false and
/// the bytes still have to decode before anything is written to the device.
bool _pngDeclaresAnimation(Uint8List bytes) {
  var offset = _pngSignature.length;
  while (offset + 8 <= bytes.length) {
    final length = (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
    final type = offset + 4;
    if (_chunkIs(bytes, type, _pngAnimationChunk)) return true;
    if (_chunkIs(bytes, type, _pngEndChunk)) return false;
    // A length that runs past the end is a malformed stream, not an animation.
    if (offset + 12 + length > bytes.length) return false;
    offset += 12 + length;
  }
  return false;
}

bool _chunkIs(Uint8List bytes, int offset, List<int> type) {
  for (var i = 0; i < 4; i++) {
    if (bytes[offset + i] != type[i]) return false;
  }
  return true;
}

void _validateTarget(int width, int height) {
  if (width <= 0 || height <= 0) {
    throw PictureEncodeException(
        'The mirror has not reported its panel size yet, so there is nothing '
        'to frame the picture for.');
  }
  if (!pictureGeometrySupported(width, height)) {
    throw PictureEncodeException(
        'A $width×$height panel is larger than the picture API supports.');
  }
}

void _validateSource(int width, int height) {
  if (width <= 0 || height <= 0) {
    throw PictureEncodeException('That picture is empty ($width×$height).');
  }
  if (width * height > pictureMaxSourcePixels) {
    throw PictureEncodeException(
        'That picture is $width×$height, more than the '
        '${pictureMaxSourcePixels ~/ 1000000} megapixels the app decodes.');
  }
}

/// Draws [source] into a [width]×[height] frame under [fit].
///
/// Black is laid down first, for two reasons: the letterboxing [PictureFit.fit]
/// leaves has to be black (the panel has no alpha channel to show through), and
/// transparent pixels anywhere in the source composite onto the same black
/// rather than onto whatever undefined colour an offscreen surface starts as.
ui.Picture _compose(ui.Image source, int width, int height, PictureFit fit) {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xff000000),
  );

  final sourceWidth = source.width.toDouble();
  final sourceHeight = source.height.toDouble();
  final scale = switch (fit) {
    PictureFit.fit => math.min(width / sourceWidth, height / sourceHeight),
    PictureFit.fill => math.max(width / sourceWidth, height / sourceHeight),
  };
  final drawnWidth = sourceWidth * scale;
  final drawnHeight = sourceHeight * scale;
  canvas.drawImageRect(
    source,
    ui.Rect.fromLTWH(0, 0, sourceWidth, sourceHeight),
    ui.Rect.fromLTWH(
      (width - drawnWidth) / 2,
      (height - drawnHeight) / 2,
      drawnWidth,
      drawnHeight,
    ),
    // Medium (bilinear with mipmaps) rather than nearest: a photo squashed to
    // panel size by point sampling aliases into noise. The workspace preview
    // uses nearest-neighbour for the opposite reason — it must show *exactly*
    // the panel's pixels, not a nicer version of them.
    ui.Paint()..filterQuality = ui.FilterQuality.medium,
  );
  return recorder.endRecording();
}

/// Drops the alpha channel: `rawRgba` is premultiplied, so a pixel's red is
/// already `red × alpha` — exactly what compositing it onto black gives. Since
/// [_compose] painted black behind everything, alpha is 255 throughout and this
/// copy is lossless.
Uint8List _packRgb(Uint8List rgba, int width, int height) {
  final pixels = width * height;
  if (rgba.length < pixels * 4) {
    throw PictureEncodeException(
        'The decoded picture is shorter than its $width×$height frame.');
  }
  final rgb = Uint8List(pixels * 3);
  for (var i = 0, j = 0; j < rgb.length; i += 4, j += 3) {
    rgb[j] = rgba[i];
    rgb[j + 1] = rgba[i + 1];
    rgb[j + 2] = rgba[i + 2];
  }
  return rgb;
}

/// The size in MB, rounded *up* to a tenth: a file reported as "20.0 MB" when
/// the cap is 20 MB would read as a bug in the check rather than in the file.
String _megabytes(int bytes) =>
    ((bytes * 10 / (1 << 20)).ceil() / 10).toStringAsFixed(1);
