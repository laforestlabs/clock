// Raw dart:ffi bindings to the gamekit FFI layer.
//
// A mechanical mirror of gamekit/ffi/game_ffi.h, following the same pattern as
// bindings.dart: no logic, just lookups. The game session is an opaque handle;
// Dart never touches a C struct.
//
// Shares the same DynamicLibrary as the layout engine, so the symbols land in
// the already-opened libmirror_core_ffi.so.

import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

// ---------------------------------------------------------------- typedefs

typedef _VoidPtr = Pointer<Void>;
typedef _VoidPtrC = _VoidPtr Function();
typedef _VoidPtrD = _VoidPtr Function();

typedef _DestroyC = Void Function(_VoidPtr);
typedef _DestroyD = void Function(_VoidPtr);

typedef _GameOpenC = _VoidPtr Function(Pointer<Utf8>, Int, Int, Uint32, Int);
typedef _GameOpenD = _VoidPtr Function(Pointer<Utf8>, int, int, int, int);

typedef _PtrToIntC = Int Function(_VoidPtr);
typedef _PtrToIntD = int Function(_VoidPtr);

typedef _PtrToUint8C = Pointer<Uint8> Function(_VoidPtr);
typedef _PtrToUint8D = Pointer<Uint8> Function(_VoidPtr);

typedef _PtrToBoolC = Uint8 Function(_VoidPtr);
typedef _PtrToBoolD = int Function(_VoidPtr);

typedef _ButtonC = Void Function(_VoidPtr, Uint16, Uint16, Int16);
typedef _ButtonD = void Function(_VoidPtr, int, int, int);

typedef _StepC = Void Function(_VoidPtr, Uint32);
typedef _StepD = void Function(_VoidPtr, int);

typedef _IntToIntC = Int Function(Int);
typedef _IntToIntD = int Function(int);

typedef _IntToStrC = Pointer<Utf8> Function(Int);
typedef _IntToStrD = Pointer<Utf8> Function(int);

typedef _VoidToIntC = Int Function();
typedef _VoidToIntD = int Function();

typedef _IntIntToStrC = Pointer<Utf8> Function(Int, Int);
typedef _IntIntToStrD = Pointer<Utf8> Function(int, int);

/// Thrown when the game symbols are missing, which means the CMake build did
/// not compile gamekit/ into the shared library.
class GameLibraryException implements Exception {
  final String message;
  GameLibraryException(this.message);
  @override
  String toString() => 'GameLibraryException: $message';
}

class GameBindings {
  GameBindings._(DynamicLibrary lib)
      : gameCount = lib.lookupFunction<_VoidToIntC, _VoidToIntD>('ml_game_count'),
        gameId = lib.lookupFunction<_IntToStrC, _IntToStrD>('ml_game_id'),
        gameName = lib.lookupFunction<_IntToStrC, _IntToStrD>('ml_game_name'),
        gameMaxPlayers =
            lib.lookupFunction<_IntToIntC, _IntToIntD>('ml_game_max_players'),
        gameControlCount =
            lib.lookupFunction<_IntToIntC, _IntToIntD>('ml_game_control_count'),
        gameControlLabel =
            lib.lookupFunction<_IntIntToStrC, _IntIntToStrD>('ml_game_control_label'),
        gameOpen =
            lib.lookupFunction<_GameOpenC, _GameOpenD>('ml_game_open'),
        gameClose =
            lib.lookupFunction<_DestroyC, _DestroyD>('ml_game_close'),
        gameWidth =
            lib.lookupFunction<_PtrToIntC, _PtrToIntD>('ml_game_width'),
        gameHeight =
            lib.lookupFunction<_PtrToIntC, _PtrToIntD>('ml_game_height'),
        gameTick =
            lib.lookupFunction<_PtrToIntC, _PtrToIntD>('ml_game_tick'),
        gameButton =
            lib.lookupFunction<_ButtonC, _ButtonD>('ml_game_button'),
        gameStep =
            lib.lookupFunction<_StepC, _StepD>('ml_game_step'),
        gameIsOver =
            lib.lookupFunction<_PtrToBoolC, _PtrToBoolD>('ml_game_is_over'),
        gameRenderRgba =
            lib.lookupFunction<_PtrToUint8C, _PtrToUint8D>('ml_game_render_rgba'),
        gameRgbaSize =
            lib.lookupFunction<_PtrToIntC, _PtrToIntD>('ml_game_rgba_size');

  final int Function() gameCount;
  final Pointer<Utf8> Function(int) gameId;
  final Pointer<Utf8> Function(int) gameName;
  final int Function(int) gameMaxPlayers;
  final int Function(int) gameControlCount;
  final Pointer<Utf8> Function(int, int) gameControlLabel;
  final _VoidPtr Function(Pointer<Utf8>, int, int, int, int) gameOpen;
  final void Function(_VoidPtr) gameClose;
  final int Function(_VoidPtr) gameWidth;
  final int Function(_VoidPtr) gameHeight;
  final int Function(_VoidPtr) gameTick;
  final void Function(_VoidPtr, int, int, int) gameButton;
  final void Function(_VoidPtr, int) gameStep;
  final int Function(_VoidPtr) gameIsOver;
  final Pointer<Uint8> Function(_VoidPtr) gameRenderRgba;
  final int Function(_VoidPtr) gameRgbaSize;

  static GameBindings? _instance;

  /// Opens the same library the layout engine uses, once per process.
  static GameBindings instance() {
    final existing = _instance;
    if (existing != null) return existing;

    DynamicLibrary lib;
    if (Platform.isIOS || Platform.isMacOS) {
      lib = DynamicLibrary.process();
    } else if (Platform.isAndroid || Platform.isLinux) {
      lib = DynamicLibrary.open('libmirror_core_ffi.so');
    } else if (Platform.isWindows) {
      lib = DynamicLibrary.open('mirror_core_ffi.dll');
    } else {
      throw GameLibraryException(
        '${Platform.operatingSystem} is not supported for games.',
      );
    }

    try {
      final created = GameBindings._(lib);
      _instance = created;
      return created;
    } on ArgumentError catch (e) {
      throw GameLibraryException(
        'The game symbols are missing from the native library ($e). '
        'Rebuild it: gamekit/ must be compiled into the shared library.',
      );
    }
  }
}

/// One game the build knows about, for the game picker.
@immutable
class GameInfo {
  const GameInfo(this.id, this.name, this.maxPlayers, this.controls);
  final String id;
  final String name;
  final int maxPlayers;
  final List<String> controls;
}