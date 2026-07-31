// A safe Dart face over the C render core.
//
// Owns the native handle and every allocation that crosses the boundary. The
// rest of the app never touches dart:ffi.
//
// The contract worth remembering: [renderImage] returns exactly what the LED
// panel would display. No selection highlight, no mirror dimming, no editor
// chrome of any kind. Those are drawn on top by the view layer, because the
// moment they leak into these pixels the preview stops being trustworthy and
// the whole shared-renderer design is pointless.

import 'dart:async';

import 'dart:ui' as ui;

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'bindings.dart';

/// One item from the engine's font catalogue.
@immutable
class FontInfo {
  const FontInfo(this.name, this.height);
  final String name;
  final int height;
}

/// Geometry of a widget as the engine understands it, in canvas pixels.
@immutable
class WidgetInfo {
  const WidgetInfo({
    required this.index,
    required this.type,
    required this.id,
    required this.rect,
  });

  final int index;
  final String type;
  final String id;
  final ui.Rect rect;

  /// What to show in a list: the author's id when they gave one, else the type.
  String get label => id.isNotEmpty ? id : type;
}

class MirrorEngine {
  MirrorEngine._(this._b, this._sim);

  final MirrorBindings _b;
  final Pointer<Void> _sim;
  bool _disposed = false;

  /// Opens the native library and creates an engine instance.
  /// Throws [MirrorLibraryException] if the library is missing or stale.
  factory MirrorEngine.open() {
    final bindings = MirrorBindings.instance();
    final sim = bindings.simCreate();
    if (sim == nullptr) {
      throw MirrorLibraryException('ml_sim_create returned null (out of memory)');
    }
    return MirrorEngine._(bindings, sim);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _b.simDestroy(_sim);
  }

  void _assertLive() {
    if (_disposed) {
      throw StateError('MirrorEngine used after dispose()');
    }
  }

  // ------------------------------------------------------------------ load

  /// Loads a layout from JSON. Returns true on success.
  ///
  /// A failed load deliberately leaves the previously loaded layout in place,
  /// so the preview keeps showing the last good render while the user is
  /// midway through breaking their JSON rather than flashing black.
  bool load(String json) {
    _assertLive();
    final native = json.toNativeUtf8();
    try {
      return _b.simLoad(_sim, native) == 1;
    } finally {
      calloc.free(native);
    }
  }

  /// Serializes the engine's view of the layout, through the same writer the
  /// device serves `GET /api/layout` from.
  ///
  /// This is deliberately *not* the designer's save path. [LayoutController]
  /// writes the Dart document instead, so that keys this build does not
  /// understand survive an open-edit-save cycle rather than being dropped to
  /// whatever the C struct happens to model. Use this to see what the device
  /// would report, not to persist a layout.
  String toJson() {
    _assertLive();
    return _b.simToJson(_sim).toDartString();
  }

  String get lastError => _b.simError(_sim).toDartString();

  List<String> get diagnostics {
    _assertLive();
    final count = _b.simDiagCount(_sim);
    return List<String>.generate(
      count,
      (i) => _b.simDiagAt(_sim, i).toDartString(),
      growable: false,
    );
  }

  // -------------------------------------------------------------- geometry

  int get width => _b.simWidth(_sim);
  int get height => _b.simHeight(_sim);
  String get name => _b.simName(_sim).toDartString();
  int get widgetCount => _b.simWidgetCount(_sim);

  ui.Size get canvasSize => ui.Size(width.toDouble(), height.toDouble());

  /// Geometry for every widget, for the list panel and the drag handles.
  List<WidgetInfo> widgets() {
    _assertLive();
    final count = widgetCount;
    if (count == 0) return const <WidgetInfo>[];

    // One allocation for all four out-parameters, reused across the loop.
    final box = calloc<Int>(4);
    try {
      final result = <WidgetInfo>[];
      for (var i = 0; i < count; i++) {
        final ok = _b.simWidgetRect(_sim, i, box + 0, box + 1, box + 2, box + 3);
        if (ok != 1) continue;
        result.add(
          WidgetInfo(
            index: i,
            type: _b.simWidgetType(_sim, i).toDartString(),
            id: _b.simWidgetId(_sim, i).toDartString(),
            rect: ui.Rect.fromLTWH(
              box[0].toDouble(),
              box[1].toDouble(),
              box[2].toDouble(),
              box[3].toDouble(),
            ),
          ),
        );
      }
      return result;
    } finally {
      calloc.free(box);
    }
  }

  /// Index of the topmost widget covering a canvas pixel, or -1.
  ///
  /// Done natively rather than against the Dart model so a tap always selects
  /// whatever is actually drawn at that pixel.
  int hitTest(int x, int y) {
    _assertLive();
    return _b.simHitTest(_sim, x, y);
  }

  // ------------------------------------------------------------- rendering

  /// Selects which mock data fixture to render against.
  void setVariant(int variant) {
    _assertLive();
    _b.simSetVariant(_sim, variant);
  }

  /// Overrides the layout's brightness. Pass null to use the layout's value.
  ///
  /// This belongs in native code rather than in a view filter because the
  /// panel really does dim, by shortening LED on-time after its gamma LUT.
  /// The engine models that as a linear scale applied after gamma, so the
  /// preview dims the way the hardware does.
  void setBrightness(int? brightness) {
    _assertLive();
    _b.simSetBrightness(_sim, brightness ?? -1);
  }

  /// Copies the current frame out as RGBA8888.
  ///
  /// The native buffer is reused on every render, so this must copy. Returns
  /// null when no layout has loaded successfully yet.
  Uint8List? renderBytes() {
    _assertLive();
    final ptr = _b.simRenderRgba(_sim);
    if (ptr == nullptr) return null;

    final size = _b.simRgbaSize(_sim);
    if (size <= 0) return null;

    return Uint8List.fromList(ptr.asTypedList(size));
  }

  /// Renders to an image ready for the canvas.
  ///
  /// Callers must draw this with [ui.FilterQuality.none]. Any smoothing turns
  /// crisp 5x7 glyphs into grey mush and stops the preview predicting the
  /// panel.
  Future<ui.Image?> renderImage() async {
    final bytes = renderBytes();
    if (bytes == null) return null;

    final w = width;
    final h = height;
    if (w <= 0 || h <= 0) return null;

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      bytes,
      w,
      h,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  // ------------------------------------------------------------- catalogue

  /// Fonts compiled into this build. Read from the engine rather than
  /// hardcoded, so adding a .font file shows up in the picker with no Dart
  /// change.
  List<FontInfo> get fonts {
    final count = _b.fontCount();
    return List<FontInfo>.generate(
      count,
      (i) => FontInfo(_b.fontName(i).toDartString(), _b.fontHeight(i)),
      growable: false,
    );
  }

  List<String> get widgetTypes => List<String>.generate(
        _b.typeCount(),
        (i) => _b.typeName(i).toDartString(),
        growable: false,
      );

  List<String> get bindPaths => List<String>.generate(
        _b.bindCount(),
        (i) => _b.bindAt(i).toDartString(),
        growable: false,
      );

  List<String> get variants => List<String>.generate(
        _b.variantCount(),
        (i) => _b.variantName(i).toDartString(),
        growable: false,
      );

  /// Bumped whenever rendering changes in a way that invalidates golden
  /// images. Compared against a connected mirror to warn about a mismatch
  /// before the user trusts a preview that will not match the hardware.
  int get renderVersion => _b.renderVersion();

  String get coreVersion => _b.versionString().toDartString();
}
