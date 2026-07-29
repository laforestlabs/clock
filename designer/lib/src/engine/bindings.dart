// Raw dart:ffi bindings to the C render core.
//
// This file is a mechanical mirror of core/ffi/mirror_ffi.h and should contain
// no logic. Everything with a decision in it belongs in engine.dart.
//
// The whole reason this binding is so small is that the C side takes JSON and
// returns pixels. Binding ml_layout directly would mean replicating C struct
// padding in Dart, which breaks silently the first time a field is added.

import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------- typedefs

typedef _CreateC = Pointer<Void> Function();
typedef _DestroyC = Void Function(Pointer<Void>);
typedef _DestroyD = void Function(Pointer<Void>);

typedef _LoadC = Int Function(Pointer<Void>, Pointer<Utf8>);
typedef _LoadD = int Function(Pointer<Void>, Pointer<Utf8>);

typedef _SimToStrC = Pointer<Utf8> Function(Pointer<Void>);
typedef _SimToIntC = Int Function(Pointer<Void>);
typedef _SimToIntD = int Function(Pointer<Void>);

typedef _SimIntToStrC = Pointer<Utf8> Function(Pointer<Void>, Int);
typedef _SimIntToStrD = Pointer<Utf8> Function(Pointer<Void>, int);

typedef _SimSetIntC = Void Function(Pointer<Void>, Int);
typedef _SimSetIntD = void Function(Pointer<Void>, int);

typedef _HitTestC = Int Function(Pointer<Void>, Int, Int);
typedef _HitTestD = int Function(Pointer<Void>, int, int);

typedef _WidgetRectC = Int Function(
    Pointer<Void>, Int, Pointer<Int>, Pointer<Int>, Pointer<Int>, Pointer<Int>);
typedef _WidgetRectD = int Function(
    Pointer<Void>, int, Pointer<Int>, Pointer<Int>, Pointer<Int>, Pointer<Int>);

typedef _RenderC = Pointer<Uint8> Function(Pointer<Void>);

typedef _IntToStrC = Pointer<Utf8> Function(Int);
typedef _IntToStrD = Pointer<Utf8> Function(int);

typedef _IntToIntC = Int Function(Int);
typedef _IntToIntD = int Function(int);

typedef _VoidToIntC = Int Function();
typedef _VoidToIntD = int Function();

typedef _VoidToStrC = Pointer<Utf8> Function();

/// Thrown when the native library cannot be located or is missing a symbol,
/// which in practice means the platform build did not compile core/.
class MirrorLibraryException implements Exception {
  MirrorLibraryException(this.message);
  final String message;
  @override
  String toString() => 'MirrorLibraryException: $message';
}

class MirrorBindings {
  MirrorBindings._(this._lib)
      : simCreate = _lib.lookupFunction<_CreateC, _CreateC>('ml_sim_create'),
        simDestroy = _lib.lookupFunction<_DestroyC, _DestroyD>('ml_sim_destroy'),
        simLoad = _lib.lookupFunction<_LoadC, _LoadD>('ml_sim_load'),
        simToJson =
            _lib.lookupFunction<_SimToStrC, _SimToStrC>('ml_sim_to_json'),
        simError = _lib.lookupFunction<_SimToStrC, _SimToStrC>('ml_sim_error'),
        simDiagCount =
            _lib.lookupFunction<_SimToIntC, _SimToIntD>('ml_sim_diag_count'),
        simDiagAt =
            _lib.lookupFunction<_SimIntToStrC, _SimIntToStrD>('ml_sim_diag_at'),
        simWidth = _lib.lookupFunction<_SimToIntC, _SimToIntD>('ml_sim_width'),
        simHeight =
            _lib.lookupFunction<_SimToIntC, _SimToIntD>('ml_sim_height'),
        simName = _lib.lookupFunction<_SimToStrC, _SimToStrC>('ml_sim_name'),
        simWidgetCount = _lib
            .lookupFunction<_SimToIntC, _SimToIntD>('ml_sim_widget_count'),
        simWidgetRect = _lib
            .lookupFunction<_WidgetRectC, _WidgetRectD>('ml_sim_widget_rect'),
        simWidgetType = _lib
            .lookupFunction<_SimIntToStrC, _SimIntToStrD>('ml_sim_widget_type'),
        simWidgetId = _lib
            .lookupFunction<_SimIntToStrC, _SimIntToStrD>('ml_sim_widget_id'),
        simHitTest =
            _lib.lookupFunction<_HitTestC, _HitTestD>('ml_sim_hit_test'),
        simSetVariant = _lib
            .lookupFunction<_SimSetIntC, _SimSetIntD>('ml_sim_set_variant'),
        simSetBrightness = _lib
            .lookupFunction<_SimSetIntC, _SimSetIntD>('ml_sim_set_brightness'),
        simRenderRgba =
            _lib.lookupFunction<_RenderC, _RenderC>('ml_sim_render_rgba'),
        simRgbaSize =
            _lib.lookupFunction<_SimToIntC, _SimToIntD>('ml_sim_rgba_size'),
        variantCount = _lib
            .lookupFunction<_VoidToIntC, _VoidToIntD>('ml_sim_variant_count'),
        variantName = _lib
            .lookupFunction<_IntToStrC, _IntToStrD>('ml_sim_variant_name'),
        fontCount =
            _lib.lookupFunction<_VoidToIntC, _VoidToIntD>('ml_sim_font_count'),
        fontName =
            _lib.lookupFunction<_IntToStrC, _IntToStrD>('ml_sim_font_name'),
        fontHeight =
            _lib.lookupFunction<_IntToIntC, _IntToIntD>('ml_sim_font_height'),
        typeCount =
            _lib.lookupFunction<_VoidToIntC, _VoidToIntD>('ml_sim_type_count'),
        typeName =
            _lib.lookupFunction<_IntToStrC, _IntToStrD>('ml_sim_type_name'),
        bindCount =
            _lib.lookupFunction<_VoidToIntC, _VoidToIntD>('ml_sim_bind_count'),
        bindAt = _lib.lookupFunction<_IntToStrC, _IntToStrD>('ml_sim_bind_at'),
        renderVersion = _lib
            .lookupFunction<_VoidToIntC, _VoidToIntD>('ml_sim_render_version'),
        versionString = _lib
            .lookupFunction<_VoidToStrC, _VoidToStrC>('ml_sim_version_string');

  final DynamicLibrary _lib;

  final Pointer<Void> Function() simCreate;
  final void Function(Pointer<Void>) simDestroy;
  final int Function(Pointer<Void>, Pointer<Utf8>) simLoad;
  final Pointer<Utf8> Function(Pointer<Void>) simToJson;
  final Pointer<Utf8> Function(Pointer<Void>) simError;
  final int Function(Pointer<Void>) simDiagCount;
  final Pointer<Utf8> Function(Pointer<Void>, int) simDiagAt;
  final int Function(Pointer<Void>) simWidth;
  final int Function(Pointer<Void>) simHeight;
  final Pointer<Utf8> Function(Pointer<Void>) simName;
  final int Function(Pointer<Void>) simWidgetCount;
  final int Function(Pointer<Void>, int, Pointer<Int>, Pointer<Int>,
      Pointer<Int>, Pointer<Int>) simWidgetRect;
  final Pointer<Utf8> Function(Pointer<Void>, int) simWidgetType;
  final Pointer<Utf8> Function(Pointer<Void>, int) simWidgetId;
  final int Function(Pointer<Void>, int, int) simHitTest;
  final void Function(Pointer<Void>, int) simSetVariant;
  final void Function(Pointer<Void>, int) simSetBrightness;
  final Pointer<Uint8> Function(Pointer<Void>) simRenderRgba;
  final int Function(Pointer<Void>) simRgbaSize;
  final int Function() variantCount;
  final Pointer<Utf8> Function(int) variantName;
  final int Function() fontCount;
  final Pointer<Utf8> Function(int) fontName;
  final int Function(int) fontHeight;
  final int Function() typeCount;
  final Pointer<Utf8> Function(int) typeName;
  final int Function() bindCount;
  final Pointer<Utf8> Function(int) bindAt;
  final int Function() renderVersion;
  final Pointer<Utf8> Function() versionString;

  static MirrorBindings? _instance;

  /// Opens the native library once per process.
  static MirrorBindings instance() {
    final existing = _instance;
    if (existing != null) return existing;

    try {
      final created = MirrorBindings._(_openLibrary());
      _instance = created;
      return created;
    } on ArgumentError catch (e) {
      // lookupFunction throws ArgumentError for a missing symbol, which almost
      // always means an older prebuilt library is being picked up.
      throw MirrorLibraryException(
        'The native library loaded but is missing a symbol ($e). '
        'Rebuild it: the app and core/ffi/mirror_ffi.h are out of step.',
      );
    }
  }

  static DynamicLibrary _openLibrary() {
    // iOS and macOS link the core statically into the runner, so its symbols
    // are already in the process. Everything else loads a shared object.
    if (Platform.isIOS || Platform.isMacOS) return DynamicLibrary.process();

    // Name matches the CMake target in designer/packages/mirror_core_ffi/src.
    const soName = 'libmirror_core_ffi.so';
    try {
      if (Platform.isAndroid || Platform.isLinux) {
        return DynamicLibrary.open(soName);
      }
      if (Platform.isWindows) return DynamicLibrary.open('mirror_core_ffi.dll');
    } on ArgumentError catch (e) {
      throw MirrorLibraryException(
        'Could not load $soName ($e). Run designer/setup.sh so the platform '
        'build compiles core/, then rebuild the app.',
      );
    }

    throw MirrorLibraryException(
      '${Platform.operatingSystem} is not supported. dart:ffi covers Android, '
      'iOS, Linux, macOS and Windows, but not Flutter web.',
    );
  }
}
