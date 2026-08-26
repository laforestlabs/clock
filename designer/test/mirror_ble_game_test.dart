// parseGameList / parseGameOk / parseGameOver / encodeGameInput: the BLE
// game protocol from firmware/main/net/ble.c. Kept pure so the app's gamepad
// is testable without a device.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/services/mirror_ble_game.dart';

void main() {
  group('parseGameList', () {
    test('parses the full list', () {
      expect(parseGameList('games rally,snake,tetris,breakout,invaders,probe'),
          <String>['rally', 'snake', 'tetris', 'breakout', 'invaders', 'probe']);
    });

    test('parses an empty list', () {
      expect(parseGameList('games '), isEmpty);
    });

    test('rejects a missing space (games without a list)', () {
      expect(parseGameList('games'), isNull);
    });

    test('rejects old firmware and unrelated lines', () {
      expect(parseGameList('unknown command'), isNull);
      expect(parseGameList('pong 0.2.0 192.168.1.5 mini 64 32'), isNull);
      expect(parseGameList(''), isNull);
    });
  });

  group('parseGameOk', () {
    List<String> labels(MirrorGame g) =>
        g.controls.map((c) => c.label).toList();

    test('parses a two-control game with no type suffix', () {
      final g = parseGameOk('game ok rally Up Down');
      expect(g, isNotNull);
      expect(g!.id, 'rally');
      expect(labels(g), <String>['Up', 'Down']);
      expect(
          g.controls.every((c) => c.type == MirrorControlType.button), isTrue);
    });

    test('parses a four-control game', () {
      final g = parseGameOk('game ok snake Up Down Left Right');
      expect(g, isNotNull);
      expect(g!.id, 'snake');
      expect(labels(g), <String>['Up', 'Down', 'Left', 'Right']);
    });

    test('parses a game with a fire button', () {
      final g = parseGameOk('game ok invaders Left Right Shoot');
      expect(g, isNotNull);
      expect(labels(g!), <String>['Left', 'Right', 'Shoot']);
    });

    test('parses explicit button and axis type suffixes', () {
      final g = parseGameOk('game ok probe Up:b Down:b TiltX:a TiltY:a');
      expect(g, isNotNull);
      expect(labels(g!), <String>['Up', 'Down', 'TiltX', 'TiltY']);
      expect(g.controls.map((c) => c.type).toList(), <MirrorControlType>[
        MirrorControlType.button,
        MirrorControlType.button,
        MirrorControlType.axis,
        MirrorControlType.axis,
      ]);
    });

    test('rejects error, truncated and unrelated lines', () {
      expect(parseGameOk('game error unknown game'), isNull);
      expect(parseGameOk('game error busy'), isNull);
      expect(parseGameOk('game ok'), isNull);
      expect(parseGameOk('unknown command'), isNull);
      expect(parseGameOk(''), isNull);
    });
  });

  group('parseGameOver', () {
    test('parses a game over line', () {
      expect(parseGameOver('game over tetris'), 'tetris');
    });

    test('parses any game id', () {
      expect(parseGameOver('game over invaders'), 'invaders');
    });

    test('rejects truncated, error and unrelated lines', () {
      expect(parseGameOver('game over'), isNull);
      expect(parseGameOver('game error unknown game'), isNull);
      expect(parseGameOver('game ok snake Up Down Left Right'), isNull);
      expect(parseGameOver('game stopped'), isNull);
      expect(parseGameOver('unknown command'), isNull);
      expect(parseGameOver(''), isNull);
    });
  });

  group('encodeGameInput', () {
    void expectBytes(List<int> values, List<int> expected) {
      expect(encodeGameInput(values), Uint8List.fromList(expected));
    }

    test('encodes a two-control held state', () {
      expectBytes(<int>[0, 1], <int>[2, 0, 0, 0, 1, 1, 0]);
    });

    test('encodes all-released as a zeroed packet', () {
      expectBytes(<int>[0, 0], <int>[2, 0, 0, 0, 1, 0, 0]);
    });

    test('encodes an empty state as an empty packet', () {
      expect(encodeGameInput(const <int>[]), isEmpty);
    });

    test('encodes byte-exact for a pressed high index', () {
      expectBytes(
          <int>[0, 1, 0], <int>[3, 0, 0, 0, 1, 1, 0, 2, 0, 0]);
    });

    test('encodes all pressed', () {
      expectBytes(<int>[1, 1], <int>[2, 0, 1, 0, 1, 1, 0]);
    });

    test('encodes a negative axis value little-endian', () {
      expectBytes(<int>[-1], <int>[1, 0, 0xff, 0xff]);
    });

    test('encodes a positive axis value little-endian', () {
      expectBytes(<int>[32767], <int>[1, 0, 0xff, 0x7f]);
    });
  });
}
