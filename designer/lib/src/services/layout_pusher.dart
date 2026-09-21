// Sending a tapped preset to the mirror.
//
// A tap on a stock layout has to reach the panel immediately, which turns the
// picker into a source of requests that outpace the radio: one push is a
// chunked transfer with a begin/commit handshake, so it takes a fraction of a
// second on a good link and longer on a poor one. Two rules follow, and this
// class is both of them:
//
//   - One push at a time. BleSession serializes whole transfers so two of them
//     never share the wire, and this is what keeps the second tap from being
//     started at all while the first is still committing.
//   - Newest wins. A request that arrives while a push is in flight replaces
//     any other that is waiting instead of lining up behind it: only the
//     layout the user picked last is worth showing, and replaying a burst of
//     taps would leave the panel showing a preset the finger left some
//     seconds ago.

import 'dart:async';

import 'mirror_ble.dart';
import 'mirror_connection.dart';

/// A layout that went out over the link, and what the mirror made of it.
///
/// [error] is null when the device took it; otherwise it is the device's own
/// reason for refusing, or the reason the link gave.
typedef LayoutPushOutcome = ({String label, String? error});

/// Pushes layouts to the connected mirror as fast as they are picked.
class LayoutPusher {
  LayoutPusher({required this.connection, this.onOutcome});

  /// The link to push over. Read when a push is sent, not when it is asked
  /// for: a queued request can outlive the connection it was made on.
  final MirrorConnection connection;

  /// Called once for every push that actually went out, when it is done.
  ///
  /// A request replaced by a newer tap never gets here: nothing was sent, so
  /// there is nothing to report.
  final void Function(LayoutPushOutcome outcome)? onOutcome;

  /// The newest request that has not started yet. A newer tap overwrites
  /// whatever is here, which is the whole of the "newest wins" rule.
  ({String label, String json})? _pending;

  bool _running = false;

  /// Send [json] as the layout called [label].
  ///
  /// Returns as soon as it is queued; the outcome arrives through [onOutcome]
  /// once the mirror has answered.
  void push(String label, String json) {
    _pending = (label: label, json: json);
    // Running up to its first await already, so this tap is either this
    // loop's next item or a replacement for one that has not started.
    if (_running) return;
    unawaited(_drain());
  }

  /// Send queued requests one at a time, always taking the newest that is
  /// waiting. Only one of these runs at a time.
  Future<void> _drain() async {
    _running = true;
    try {
      while (_pending != null) {
        final request = _pending!;
        _pending = null;

        final session = connection.session;
        if (session == null) {
          onOutcome?.call(
              (label: request.label, error: 'the mirror is not connected'));
          continue;
        }
        try {
          await session.pushLayout(request.json);
          onOutcome?.call((label: request.label, error: null));
        } catch (e) {
          onOutcome?.call((label: request.label, error: bleErrorMessage(e)));
        }
      }
    } finally {
      _running = false;
    }
  }
}
