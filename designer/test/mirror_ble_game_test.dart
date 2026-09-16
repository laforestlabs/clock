// parseGameList / parseGameOk / parseGameOver / encodeGameInput and the game
// reply predicates + waitForGameReply: the BLE game protocol from
// firmware/main/net/ble.c. Kept pure so the app's gamepad is testable without
// a device.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/services/mirror_ble_game.dart';

void main() {
  group('parseGameList', () {
    test('parses the full list', () {
      expect(
          parseGameList('games rally,snake,tetris,breakout,invaders,probe'),
          <String>[
            'rally',
            'snake',
            'tetris',
            'breakout',
            'invaders',
            'probe'
          ]);
    });

    test('parses an empty list', () {
      expect(parseGameList('games '), isEmpty);
    });

    test('parses a bare games line as a supported empty catalogue', () {
      expect(parseGameList('games'), isEmpty);
    });

    test('rejects old firmware and unrelated lines', () {
      expect(parseGameList('unknown command'), isNull);
      expect(parseGameList('pong 0.2.0 192.168.1.5 mini 64 32'), isNull);
      expect(parseGameList(''), isNull);
    });
  });

  group('game reply predicates', () {
    test('isGameListReply accepts a catalogue, a rejection and old firmware',
        () {
      expect(isGameListReply('games'), isTrue);
      expect(isGameListReply('games snake,tetris'), isTrue);
      expect(isGameListReply('game error busy'), isTrue);
      expect(isGameListReply(unknownCommandReply), isTrue);
      expect(isGameListReply('game ok snake Up Down'), isFalse);
      expect(isGameListReply('game stopped'), isFalse);
      expect(isGameListReply('pong 0.2.0 192.168.1.5 mini 64 32'), isFalse);
    });

    test('isGameStartReply accepts any game ok, a rejection and old firmware',
        () {
      expect(isGameStartReply('game ok snake Up Down Left Right'), isTrue);
      // Another game's id is accepted here so the caller fails at once
      // instead of timing out while the mirror runs something else.
      expect(isGameStartReply('game ok tetris Left Right'), isTrue);
      expect(isGameStartReply('game error busy'), isTrue);
      expect(isGameStartReply(unknownCommandReply), isTrue);
      expect(isGameStartReply('game stopped'), isFalse);
      expect(isGameStartReply('game over snake'), isFalse);
    });

    test('isGameStopReply accepts the two success lines and failures', () {
      expect(isGameStopReply('game stopped'), isTrue);
      expect(isGameStopReply('game error no game'), isTrue);
      expect(isGameStopReply(unknownCommandReply), isTrue);
      expect(isGameStopReply('game ok snake Up Down'), isFalse);
      expect(isGameStopReply('game over snake'), isFalse);
    });

    test('gameErrorReason strips the prefix, or keeps a bare line', () {
      expect(gameErrorReason('game error no game'), 'no game');
      expect(gameErrorReason('game error'), 'game error');
      expect(gameErrorReason(unknownCommandReply), unknownCommandReply);
    });
  });

  group('waitForGameReply', () {
    test('ignores an unsolicited line and leaves other listeners alone',
        () async {
      final statuses = StreamController<String>.broadcast();
      final seen = <String>[];
      final terminal = statuses.stream.listen(seen.add);

      final reply = waitForGameReply(
        statuses: statuses.stream,
        write: () async {
          // The previous round's terminal push, then the real answer.
          statuses.add('game over snake');
          await Future<void>.delayed(Duration.zero);
          statuses.add('game stopped');
        },
        accepts: isGameStopReply,
      );

      expect(await reply, 'game stopped');
      expect(seen, <String>['game over snake', 'game stopped']);

      await terminal.cancel();
      await Future<void>.delayed(Duration.zero);
      // The wait's own subscription is gone; only the terminal listener was
      // cancelled by hand.
      expect(statuses.hasListener, isFalse);
      await statuses.close();
    });

    test('accepts a reply delivered while the write is still in flight',
        () async {
      // Sync controller: the device answers inside the write, before its
      // future completes, the way a notification beats the write response.
      final statuses = StreamController<String>.broadcast(sync: true);
      final reply = waitForGameReply(
        statuses: statuses.stream,
        write: () async {
          statuses.add('game stopped');
          await Future<void>.delayed(Duration.zero);
        },
        accepts: isGameStopReply,
      );

      expect(await reply, 'game stopped');
      await statuses.close();
    });

    test('propagates a write failure and releases its subscription', () async {
      final statuses = StreamController<String>.broadcast();
      final reply = waitForGameReply(
        statuses: statuses.stream,
        write: () => throw StateError('link down'),
        accepts: isGameStopReply,
      );

      await expectLater(reply, throwsA(isA<StateError>()));
      await Future<void>.delayed(Duration.zero);
      expect(statuses.hasListener, isFalse);
      await statuses.close();
    });

    testWidgets('timeout bounds a stalled write and cleans up', (tester) async {
      final statuses = StreamController<String>.broadcast();
      final write = Completer<void>();
      final reply = waitForGameReply(
        statuses: statuses.stream,
        write: () => write.future,
        accepts: isGameStopReply,
      );
      final failure = expectLater(reply, throwsA(isA<TimeoutException>()));
      expect(statuses.hasListener, isTrue);
      await tester.pump(const Duration(seconds: 10));
      await failure;
      expect(statuses.hasListener, isFalse);
      // A late transport error must be handled, not escape into the app zone.
      write.completeError(StateError('late link failure'));
      await tester.pump();
      await statuses.close();
    });

    test('write failure after a synchronous reply is still a failure',
        () async {
      final statuses = StreamController<String>.broadcast(sync: true);
      final reply = waitForGameReply(
        statuses: statuses.stream,
        write: () async {
          statuses.add('game stopped');
          throw StateError('write failed');
        },
        accepts: isGameStopReply,
      );
      await expectLater(reply, throwsA(isA<StateError>()));
      expect(statuses.hasListener, isFalse);
      await statuses.close();
    });

    test('fails when the status stream closes', () async {
      final statuses = StreamController<String>.broadcast();
      final reply = waitForGameReply(
        statuses: statuses.stream,
        write: () async {},
        accepts: isGameStopReply,
      );

      await statuses.close();
      await expectLater(reply, throwsA(isA<StateError>()));
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
      expect(parseGameOk('game ok '), isNull);
      expect(parseGameOk('game ok snake Up:z'), isNull);
      expect(parseGameOk('game ok snake  Up:b'), isNull);
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
      expectBytes(<int>[0, 1, 0], <int>[3, 0, 0, 0, 1, 1, 0, 2, 0, 0]);
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
