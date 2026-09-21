// Sending a tapped preset to a mirror.
//
// A tap on a stock layout has to reach the panel immediately, which turns the
// picker into a source of requests that outpace the radio: one push is a
// chunked transfer with a begin/commit handshake, so it takes a fraction of a
// second on a good link and longer on a poor one. Two rules follow, and this
// class is both of them:
//
//   - One push at a time. The transport serializes whole transfers so two of
//     them never share the wire, and this is what keeps the second tap from
//     being started at all while the first is still committing.
//   - Newest wins. A request that arrives while a push is in flight replaces
//     any other that is waiting instead of lining up behind it: only the
//     layout the user picked last is worth showing, and replaying a burst of
//     taps would leave the panel showing a preset the finger left some
//     seconds ago.
//
// The transport is a caller's closure, not a connection: the workspace binds
// it to one device record's own send, so the queue cannot be retargeted while
// a transfer is in flight. Resolution to a live Bluetooth session or the LAN
// endpoint happens inside that closure when each send begins, and a failed
// send is never retried over the other transport.

import 'dart:async';

/// A layout that went out over the link, and what the mirror made of it.
///
/// [error] is null when the device took it; otherwise it is the device's own
/// reason for refusing, or the reason the transport gave.
typedef LayoutPushOutcome = ({String label, String? error});

/// Pushes layouts to one device as fast as they are picked.
class LayoutPusher {
  LayoutPusher({required this.send, this.onOutcome});

  /// Sends one layout, completing when the device has taken it or throwing
  /// with the reason it did not. Called once per request that actually goes
  /// out, and only one call is ever in flight.
  final Future<void> Function(String json) send;

  /// Called once for every push that actually went out, when it is done.
  ///
  /// A request replaced by a newer tap never gets here: nothing was sent, so
  /// there is nothing to report. Neither does anything at all once the owning
  /// route has been disposed.
  final void Function(LayoutPushOutcome outcome)? onOutcome;

  /// The newest request that has not started yet. A newer tap overwrites
  /// whatever is here, which is the whole of the "newest wins" rule.
  ({String label, String json})? _pending;

  bool _running = false;
  bool _disposed = false;

  /// Send [json] as the layout called [label].
  ///
  /// Returns as soon as it is queued; the outcome arrives through [onOutcome]
  /// once the device has answered.
  void push(String label, String json) {
    if (_disposed) return;
    _pending = (label: label, json: json);
    // Running up to its first await already, so this tap is either this
    // loop's next item or a replacement for one that has not started.
    if (_running) return;
    unawaited(_drain());
  }

  /// Drops what has not been sent and stops reporting.
  ///
  /// A transfer already on the wire finishes against the device it was
  /// captured for - its closure cannot be retargeted - but nothing is said
  /// about it, because the route that would have read the outcome is gone.
  void dispose() {
    _disposed = true;
    _pending = null;
  }

  /// Send queued requests one at a time, always taking the newest that is
  /// waiting. Only one of these runs at a time.
  Future<void> _drain() async {
    _running = true;
    try {
      while (_pending != null && !_disposed) {
        final request = _pending!;
        _pending = null;
        try {
          await send(request.json);
          if (_disposed) return;
          onOutcome?.call((label: request.label, error: null));
        } catch (e) {
          if (_disposed) return;
          onOutcome?.call((label: request.label, error: _message(e)));
        }
      }
    } finally {
      _running = false;
    }
  }
}

/// The user-facing text for a failed push.
///
/// A reason this app writes (a registry refusal, a device rejection) is
/// already a sentence for the user; anything else came from the platform,
/// where Dart's `Exception: ` prefix is noise on a toast.
String _message(Object e) => e.toString().replaceFirst('Exception: ', '');
