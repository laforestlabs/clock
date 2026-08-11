// parseGameList / parseGameOk / encodeGameInput: the BLE game protocol from
// firmware/main/net/ble.c. Kept pure so the app's gamepad is testable
// without a device.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/services/mirror_ble_game.dart';

void main() {
  group('parseGameList', () {
    test('parses the full list', () {
      expect(parseGameList('games rally,snake,tetris,breakout,invaders'),
          <String>['rally', 'snake', 'tetris', 'breakout', 'invaders']);
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
    test('parses a two-control game', () {
      final g = parseGameOk('game ok rally Up Down');
      expect(g, isNotNull);
      expect(g!.id, 'rally');
      expect(g.controls, <String>['Up', 'Down']);
    });

    test('parses a four-control game', () {
      final g = parseGameOk('game ok snake Up Down Left Right');
      expect(g, isNotNull);
      expect(g!.id, 'snake');
      expect(g.controls, <String>['Up', 'Down', 'Left', 'Right']);
    });

    test('parses a game with a fire button', () {
      final g = parseGameOk('game ok invaders Left Right Shoot');
      expect(g, isNotNull);
      expect(g!.controls, <String>['Left', 'Right', 'Shoot']);
    });

    test('rejects error, truncated and unrelated lines', () {
      expect(parseGameOk('game error unknown game'), isNull);
      expect(parseGameOk('game error busy'), isNull);
      expect(parseGameOk('game ok'), isNull);
      expect(parseGameOk('unknown command'), isNull);
      expect(parseGameOk(''), isNull);
    });
  });

  group('encodeGameInput', () {
    void expectBytes(List<bool> held, List<int> expected) {
      expect(encodeGameInput(held), Uint8List.fromList(expected));
    }

    test('encodes a two-control held state', () {
      expectBytes(<bool>[false, true], <int>[2, 0, 0, 0, 1, 1, 0]);
    });

    test('encodes all-released as a zeroed packet', () {
      expectBytes(<bool>[false, false], <int>[2, 0, 0, 0, 1, 0, 0]);
    });

    test('encodes an empty held state as an empty packet', () {
      expect(encodeGameInput(const <bool>[]), isEmpty);
    });

    test('encodes byte-exact for a pressed high index', () {
      expectBytes(<bool>[false, true, false],
          <int>[3, 0, 0, 0, 1, 1, 0, 2, 0, 0]);
    });

    test('encodes all pressed', () {
      expectBytes(<bool>[true, true],
          <int>[2, 0, 1, 0, 1, 1, 0]);
    });
  });
}
