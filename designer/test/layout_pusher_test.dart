// The queue between a preset tap and the mirror.
//
// A tap has to reach the panel immediately, and taps are faster than the
// radio, so what is worth pinning here is not the happy path but the two rules
// that decide what the panel ends up showing: one transfer at a time, and a
// pick made during one replacing whatever else is waiting. What the caller is
// told when the mirror refuses, or when the link has gone, is the other half.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/services/layout_pusher.dart';
import 'package:mirror_designer/src/services/mirror_ble.dart';
import 'package:mirror_designer/src/services/mirror_connection.dart';

/// A session that records what it was handed and holds each push open until
/// the test lets it go, so "in flight" is a state a test can be in rather than
/// a race it has to catch.
class _Session extends Fake implements BleSession {
  final List<String> pushed = <String>[];

  /// One gate per push, taken in order. A push with no gate left answers
  /// "commit ok" straight away.
  final List<Completer<String>> gates = <Completer<String>>[];

  int inFlight = 0;

  /// The most transfers that were ever in the air at once. Anything above one
  /// is two pushes sharing the link.
  int peakInFlight = 0;

  @override
  Future<String> pushLayout(String json) async {
    pushed.add(json);
    inFlight++;
    peakInFlight = math.max(peakInFlight, inFlight);
    try {
      if (gates.isEmpty) return 'commit ok 3 widgets';
      return await gates.removeAt(0).future;
    } finally {
      inFlight--;
    }
  }
}

/// The link, with a session the test puts there.
class _Connection extends MirrorConnection {
  _Connection(this.live);

  _Session? live;

  @override
  BleSession? get session => live;
}

void main() {
  const quad = '{"name":"quad"}';
  const weather = '{"name":"weather"}';
  const mini = '{"name":"mini"}';

  late _Session session;
  late _Connection connection;
  late List<LayoutPushOutcome> outcomes;
  late LayoutPusher pusher;

  setUp(() {
    session = _Session();
    connection = _Connection(session);
    outcomes = <LayoutPushOutcome>[];
    pusher = LayoutPusher(connection: connection, onOutcome: outcomes.add);
  });

  test('sends the layout it was given, and reports it committed', () async {
    pusher.push('quad', quad);
    await pumpEventQueue();

    expect(session.pushed, <String>[quad],
        reason: 'the bytes are the caller\'s, unaltered');
    expect(outcomes, <LayoutPushOutcome>[(label: 'quad', error: null)]);
  });

  test('a pick made during a push replaces the one that was waiting',
      () async {
    final first = Completer<String>();
    session.gates.add(first);

    pusher.push('weather', weather);
    await pumpEventQueue();
    expect(session.pushed, <String>[weather], reason: 'on its way at once');

    pusher.push('quad', quad);
    pusher.push('mini', mini);

    first.complete('commit ok 3 widgets');
    await pumpEventQueue();

    expect(session.pushed, <String>[weather, mini],
        reason: 'the pick the user landed on goes out; the one it replaced '
            'never left');
    expect(session.peakInFlight, 1, reason: 'one transfer at a time');
    expect(outcomes.map((o) => o.label), <String>['weather', 'mini'],
        reason: 'a replaced pick is not reported: nothing was sent');
  });

  test('reports the mirror\'s own reason for refusing', () async {
    final gate = Completer<String>();
    session.gates.add(gate);

    pusher.push('quad', quad);
    await pumpEventQueue();
    gate.completeError(
        BlePushException('layout is 128x64 but this panel is 64x32'));
    await pumpEventQueue();

    expect(outcomes, <LayoutPushOutcome>[
      (label: 'quad', error: 'layout is 128x64 but this panel is 64x32'),
    ]);
  });

  test('reports a link failure without Dart\'s exception wrapper', () async {
    final gate = Completer<String>();
    session.gates.add(gate);

    pusher.push('mini', mini);
    await pumpEventQueue();
    gate.completeError(Exception('the device is not connected'));
    await pumpEventQueue();

    expect(outcomes.single.error, 'the device is not connected');
  });

  test('a refused push does not hold up the pick behind it', () async {
    final first = Completer<String>();
    session.gates.add(first);

    pusher.push('quad', quad);
    await pumpEventQueue();
    pusher.push('mini', mini);

    first.completeError(BlePushException('busy'));
    await pumpEventQueue();

    expect(session.pushed, <String>[quad, mini]);
    expect(outcomes.map((o) => o.error), <String?>['busy', null]);
  });

  test('says so when the link has gone by the time the push goes out',
      () async {
    connection.live = null;

    pusher.push('quad', quad);
    await pumpEventQueue();

    expect(session.pushed, isEmpty);
    expect(outcomes, <LayoutPushOutcome>[
      (label: 'quad', error: 'the mirror is not connected'),
    ]);
  });
}
