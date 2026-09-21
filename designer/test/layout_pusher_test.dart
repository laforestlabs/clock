// The queue between a preset tap and the device.
//
// A tap has to reach the panel immediately, and taps are faster than the
// radio, so what is worth pinning here is not the happy path but the two rules
// that decide what the panel ends up showing: one transfer at a time, and a
// pick made during one replacing whatever else is waiting. What the caller is
// told when the device refuses, when the transport fails, and when the route
// that asked has already gone is the other half.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/services/layout_pusher.dart';
import 'package:mirror_designer/src/services/mirror_ble.dart';

/// The transport a workspace binds the pusher to: one device's own send. It
/// records what it was handed and holds each transfer open until the test lets
/// it go, so "in flight" is a state a test can be in rather than a race it has
/// to catch.
class _Transport {
  final List<String> sent = <String>[];

  /// One gate per send, taken in order. A send with no gate left succeeds
  /// straight away; a gate completed with an error is a device refusal or a
  /// transport failure.
  final List<Completer<void>> gates = <Completer<void>>[];

  int inFlight = 0;

  /// The most transfers that were ever in the air at once. Anything above one
  /// is two pushes sharing the link.
  int peakInFlight = 0;

  Future<void> call(String json) async {
    sent.add(json);
    inFlight++;
    peakInFlight = math.max(peakInFlight, inFlight);
    try {
      if (gates.isEmpty) return;
      await gates.removeAt(0).future;
    } finally {
      inFlight--;
    }
  }
}

void main() {
  const quad = '{"name":"quad"}';
  const weather = '{"name":"weather"}';
  const mini = '{"name":"mini"}';

  late _Transport transport;
  late List<LayoutPushOutcome> outcomes;
  late LayoutPusher pusher;

  setUp(() {
    transport = _Transport();
    outcomes = <LayoutPushOutcome>[];
    pusher = LayoutPusher(send: transport.call, onOutcome: outcomes.add);
  });

  test('sends the layout it was given, and reports it committed', () async {
    pusher.push('quad', quad);
    await pumpEventQueue();

    expect(transport.sent, <String>[quad],
        reason: 'the bytes are the caller\'s, unaltered');
    expect(outcomes, <LayoutPushOutcome>[(label: 'quad', error: null)]);
  });

  test('a pick made during a push replaces the one that was waiting', () async {
    final first = Completer<void>();
    transport.gates.add(first);

    pusher.push('weather', weather);
    await pumpEventQueue();
    expect(transport.sent, <String>[weather], reason: 'on its way at once');

    pusher.push('quad', quad);
    pusher.push('mini', mini);

    first.complete();
    await pumpEventQueue();

    expect(transport.sent, <String>[weather, mini],
        reason: 'the pick the user landed on goes out; the one it replaced '
            'never left');
    expect(transport.peakInFlight, 1, reason: 'one transfer at a time');
    expect(outcomes.map((o) => o.label), <String>['weather', 'mini'],
        reason: 'a replaced pick is not reported: nothing was sent');
  });

  test('reports the device\'s own reason for refusing', () async {
    final gate = Completer<void>();
    transport.gates.add(gate);

    pusher.push('quad', quad);
    await pumpEventQueue();
    gate.completeError(
        BlePushException('layout is 128x64 but this panel is 64x32'));
    await pumpEventQueue();

    expect(outcomes, <LayoutPushOutcome>[
      (label: 'quad', error: 'layout is 128x64 but this panel is 64x32'),
    ]);
  });

  test('reports a transport failure without Dart\'s exception wrapper',
      () async {
    final gate = Completer<void>();
    transport.gates.add(gate);

    pusher.push('mini', mini);
    await pumpEventQueue();
    gate.completeError(Exception('the device is not connected'));
    await pumpEventQueue();

    expect(outcomes.single.error, 'the device is not connected');
  });

  test('a refused push does not hold up the pick behind it', () async {
    final first = Completer<void>();
    transport.gates.add(first);

    pusher.push('quad', quad);
    await pumpEventQueue();
    pusher.push('mini', mini);

    first.completeError(BlePushException('busy'));
    await pumpEventQueue();

    expect(transport.sent, <String>[quad, mini]);
    expect(outcomes.map((o) => o.error), <String?>['busy', null]);
  });

  test('dispose drops what is waiting and reports nothing about what was sent',
      () async {
    final gate = Completer<void>();
    transport.gates.add(gate);

    pusher.push('quad', quad);
    await pumpEventQueue();
    pusher.push('mini', mini);
    await pumpEventQueue();

    pusher.dispose();
    gate.complete();
    await pumpEventQueue();

    expect(transport.sent, <String>[quad],
        reason: 'the transfer already on the wire finishes on the device it '
            'was captured for; the one queued behind it never goes out');
    expect(outcomes, isEmpty,
        reason: 'nothing reports back into a route that has gone');
  });

  test('a push after dispose is not sent', () async {
    pusher.dispose();

    pusher.push('quad', quad);
    await pumpEventQueue();

    expect(transport.sent, isEmpty);
    expect(outcomes, isEmpty);
  });
}
