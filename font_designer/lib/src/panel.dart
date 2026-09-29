// The physical panel, and the two corrections the hardware applies.
//
// Everything the tools say about small text comes down to one fact: this is
// not a display with sub-pixel edges. Each cell is a full-size emitter with
// dead space around it, and a partly lit cell is a dimmer emitter rather than
// a softer edge. So the preview draws a field of emitters at a real pitch,
// with a real gap, at a real viewing distance -- otherwise it is a picture of
// a different device and useless for deciding whether a cut reads.
//
// Three numbers come from the hardware rather than from taste:
//
//   Pitch. P2.5 is 2.5mm between cell centres, so a 64x32 panel is 160x80mm.
//   The gap between emitters is a share of that pitch, 50% by default.
//
//   Gamma. The driver applies a CIE 1931 lightness curve at scan-out, then
//   scales linearly for brightness -- gamma first, then a linear dim, because
//   dimming shortens LED on-time after the LUT. core/src/canvas.c does the
//   same at export, and the table it uses is generated from the same formula
//   tools/gen_gamma.py uses. Reimplemented here so the preview dims the way
//   the device does; test/gamma_test.dart holds it against the committed C
//   table so the two cannot drift.
//
//   Acuity. The eye resolves about one arcminute, so at a viewing distance
//   the panel is blurred by that much and no less. At 1m a 2.5mm cell
//   subtends 8.6 arcminutes -- plainly resolvable, which is exactly why the
//   bitmap matters and why a fractional scale would show as dim cells.

import 'dart:math' as math;
import 'dart:typed_data';

/// The CIE 1931 curve tools/gen_gamma.py emits, as ml_gamma8 looks it up.
Uint8List buildGammaTable() {
  final table = Uint8List(256);
  for (var v = 0; v < 256; v++) {
    final lightness = v / 255.0 * 100.0;
    final y = lightness <= 8.0
        ? lightness / 903.3
        : math.pow((lightness + 16.0) / 116.0, 3).toDouble();
    table[v] = (y * 255.0).round().clamp(0, 255);
  }
  return table;
}

final Uint8List kGammaTable = buildGammaTable();

/// core/src/color.h's ml_gamma8.
int gamma8(int value) => kGammaTable[value.clamp(0, 255)];

/// core/src/canvas.c's scale8, byte for byte: a full brightness is left alone
/// so the unmodified case is exactly the input.
int scale8(int value, int by) {
  if (by >= 255) return value;
  return (value * by + 127) ~/ 255;
}

/// The emitter's outline. A round die loses the corners of a cell and a
/// square one does not, which is the difference that decides whether a
/// diagonal stroke reads.
enum EmitterShape { round, square }

/// The panel being simulated, in the units the hardware comes in.
class PanelSpec {
  const PanelSpec({
    this.columns = 64,
    this.rows = 32,
    this.pitchMm = 2.5,
    this.gapShare = 0.5,
    this.brightness = 255,
    this.distanceM = 1.0,
    this.shape = EmitterShape.round,
  });

  final int columns;
  final int rows;

  /// Millimetres between cell centres: the panel's pitch, P2.5 by default.
  final double pitchMm;

  /// Dead space as a share of the pitch, 0 to 1. The emitter takes the rest.
  final double gapShare;

  /// Panel brightness, 0 to 255, applied after gamma as the driver does.
  final int brightness;

  /// How far the eye is from the panel, in metres.
  final double distanceM;

  final EmitterShape shape;

  double get widthMm => columns * pitchMm;
  double get heightMm => rows * pitchMm;

  /// The lit part of a cell, in millimetres.
  double get emitterMm => pitchMm * (1 - gapShare);

  /// The angle one cell subtends at [distanceM], in arcminutes. Above one the
  /// eye can see the pixels themselves; well below it the panel reads as an
  /// even surface and only the emitters' average light survives.
  double get cellArcmin {
    final distanceMm = math.max(1e-6, distanceM) * 1000.0;
    return math.atan(pitchMm / distanceMm) * 180.0 / math.pi * 60.0;
  }

  /// Half an arcminute of visual angle, as a share of a cell: what the eye's
  /// own blur is worth at this pitch and distance, in cells. Applied as a
  /// Gaussian blur in the view, in cell units so it follows the zoom.
  double get eyeBlurCells {
    const halfArcminRadians = 1.4544410433285186e-4; // tan(0.5 arcminute)
    final blurMm = math.max(0.0, distanceM) * 1000.0 * halfArcminRadians;
    return blurMm / math.max(0.01, pitchMm);
  }

  /// One channel as the LED's on-time: the panel's gamma curve, then the
  /// linear dim the driver applies after it. This is the physical quantity.
  int duty(int channel) => scale8(gamma8(channel), brightness);

  /// A canvas colour as the panel shows it, re-encoded for a sRGB screen.
  ///
  /// The duty is proportional to emitted light, while a framebuffer byte is
  /// sRGB encoded, so writing the duty straight in would emit the wrong
  /// amount: an 18% duty is a 46% byte. Encoding it back is what makes this a
  /// simulation of the panel rather than a picture of its bytes.
  int displayed(int rgb) {
    if (rgb == 0) return 0;
    final r = _screenByte(duty((rgb >> 16) & 0xFF));
    final g = _screenByte(duty((rgb >> 8) & 0xFF));
    final b = _screenByte(duty(rgb & 0xFF));
    return (r << 16) | (g << 8) | b;
  }

  /// The sRGB transfer function, applied to a linear light value in 0..255.
  static int _screenByte(int duty) {
    final linear = duty / 255.0;
    if (linear <= 0.0) return 0;
    final encoded = linear <= 0.0031308
        ? 12.92 * linear
        : 1.055 * math.pow(linear, 1 / 2.4) - 0.055;
    return (encoded * 255.0).round().clamp(0, 255);
  }

  @override
  bool operator ==(Object other) =>
      other is PanelSpec &&
      other.columns == columns &&
      other.rows == rows &&
      other.pitchMm == pitchMm &&
      other.gapShare == gapShare &&
      other.brightness == brightness &&
      other.distanceM == distanceM &&
      other.shape == shape;

  @override
  int get hashCode => Object.hash(
      columns, rows, pitchMm, gapShare, brightness, distanceM, shape);

  PanelSpec copyWith({
    int? columns,
    int? rows,
    double? pitchMm,
    double? gapShare,
    int? brightness,
    double? distanceM,
    EmitterShape? shape,
  }) =>
      PanelSpec(
        columns: columns ?? this.columns,
        rows: rows ?? this.rows,
        pitchMm: pitchMm ?? this.pitchMm,
        gapShare: gapShare ?? this.gapShare,
        brightness: brightness ?? this.brightness,
        distanceM: distanceM ?? this.distanceM,
        shape: shape ?? this.shape,
      );

  /// One line describing the geometry, for the panel's caption.
  String get summary => '$columns\u00d7$rows at P${pitchMm.toStringAsFixed(1)}'
      ' · ${widthMm.toStringAsFixed(0)}\u00d7${heightMm.toStringAsFixed(0)}mm'
      ' · gap ${(gapShare * 100).round()}%'
      ' · a cell subtends ${cellArcmin.toStringAsFixed(1)}′ at '
      '${distanceM.toStringAsFixed(distanceM < 1 ? 2 : 1)}m';
}
