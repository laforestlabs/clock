// mDNS discovery of mirrors on the LAN.
//
// The mirror advertises _smartmirror._tcp (port 80) when it is on the
// station network, so a desktop designer can find it without typing an IP.
// The chain is PTR -> SRV -> A, each answered by the same device. Discovery
// failing (no multicast on the network, the service not advertised) yields
// an empty stream; the Mirror screen falls back to manual IP entry, which is
// also how you point at the fake mirror during development.
//
// Android needs one extra step. Its Wi-Fi stack drops IPv4 multicast whenever
// no app holds a `WifiManager.MulticastLock`: the framework programs the Wi-Fi
// firmware's packet filter with `Multicast: DROP` when client mode starts and
// only a lock clears it (`ClientModeImpl.setupClientMode` ->
// `WifiMulticastLockManager`). mDNS answers are multicast, so discovery finds
// nothing there while unicast HTTP to the same mirror works. MainActivity owns
// the lock; this file holds it for exactly one browse and releases it even when
// starting the client fails.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;
import 'package:multicast_dns/multicast_dns.dart';

/// The Android half of [browseMdns]: MainActivity turns the
/// `WifiManager.MulticastLock` on and off. Absent on every other platform
/// (and in tests), where multicast needs no permission, so both calls are
/// best-effort.
const MethodChannel _multicastChannel = MethodChannel(
  'com.example.mirror_designer/multicast',
);

/// A mirror found on the LAN.
class LanDevice {
  LanDevice(this.ip, this.port, {this.name = '', this.bleAddress = ''});

  /// The device one answered SRV/A/TXT set describes.
  ///
  /// The address is where the mirror is. What it calls itself, and the
  /// Bluetooth address it answers on, come from the service's TXT record: the
  /// advertisement's own names are hardware-derived discovery keys (the SRV
  /// target, the instance FQDN) and are not carried here at all.
  factory LanDevice.fromRecords(
    SrvResourceRecord service,
    IPAddressResourceRecord address,
    Map<String, String> txt,
  ) =>
      LanDevice(address.address.address, service.port,
          name: txt['name'] ?? '', bleAddress: txt['ble'] ?? '');

  final String ip;
  final int port;

  /// The mirror's own friendly name, empty for firmware that predates the TXT
  /// record. A name, not a key: it is what the owner sees on the device and
  /// what a rename changes.
  final String name;

  /// The Bluetooth address this mirror advertises under, empty when it does
  /// not say.
  ///
  /// This is the one thing that can join a mirror found on the LAN to the
  /// record a Bluetooth scan made for the same hardware: identity is reported
  /// per transport, and a Bluetooth record that has not confirmed an identity
  /// carries nothing else in common with it. The claim is the mirror's own,
  /// and it is checked the first time the link is used (a session that reports
  /// another mirror's identity is dropped).
  final String bleAddress;

  @override
  String toString() => '$ip:$port';
}

/// Browse for mirrors for at most [timeout] in total.
///
/// The browse is bounded twice over: the PTR window is [timeout], and every
/// SRV/A answer has to fit in what is left of that budget. So one browse can
/// never stretch into a series of per-record timeouts, and the caller's
/// "discovery is already running" gate always opens again soon.
///
/// Errors (e.g. no multicast interface) surface through the stream; the caller
/// shows "discovery unavailable". Every socket the client binds is closed and
/// the Android multicast lock is released before the stream ends, including
/// when the client fails to start halfway through.
///
/// [socketFactory] and [interfacesFactory] exist to point the client at a
/// deterministic socket in tests; production always uses the defaults.
Stream<LanDevice> browseMdns({
  Duration timeout = const Duration(seconds: 5),
  RawDatagramSocketFactory socketFactory = _bindMdnsSocket,
  NetworkInterfacesFactory? interfacesFactory,
}) async* {
  await _setMulticastLock(true);
  final elapsed = Stopwatch()..start();
  final sockets = <RawDatagramSocket>[];
  MDnsClient? client;
  try {
    client = MDnsClient(
      rawDatagramSocketFactory: (
        dynamic host,
        int port, {
        bool reuseAddress = true,
        bool reusePort = true,
        int ttl = 255,
      }) async {
        final socket = await socketFactory(
          host,
          port,
          reuseAddress: reuseAddress,
          reusePort: reusePort,
          ttl: ttl,
        );
        // `MDnsClient.stop()` only closes the sockets it finished starting
        // with, so keep our own handle: a bind that succeeds and then fails
        // while joining multicast would otherwise leave the mDNS port open
        // for the rest of the process.
        sockets.add(socket);
        return socket;
      },
    );
    await client.start(interfacesFactory: interfacesFactory);

    final ptrs = client.lookup<PtrResourceRecord>(
      ResourceRecordQuery.serverPointer('_smartmirror._tcp.local'),
      timeout: timeout,
    );

    await for (final ptr in ptrs) {
      final remaining = timeout - elapsed.elapsed;
      if (remaining <= Duration.zero) break;

      SrvResourceRecord? srv;
      try {
        srv = await client
            .lookup<SrvResourceRecord>(
              ResourceRecordQuery.service(ptr.domainName),
              timeout: remaining,
            )
            .first
            .timeout(remaining);
      } catch (_) {
        continue; // no SRV answer; skip this advertisement
      }

      final left = timeout - elapsed.elapsed;
      if (left <= Duration.zero) break;

      IPAddressResourceRecord? a;
      try {
        a = await client
            .lookup<IPAddressResourceRecord>(
              ResourceRecordQuery.addressIPv4(srv.target),
              timeout: left,
            )
            .first
            .timeout(left);
      } catch (_) {
        continue; // no A answer; skip
      }

      yield LanDevice.fromRecords(
        srv,
        a,
        await _txtOf(client, ptr.domainName, timeout - elapsed.elapsed),
      );
    }
  } finally {
    client?.stop();
    for (final socket in sockets) {
      socket.close();
    }
    await _setMulticastLock(false);
  }
}

/// The key/value pairs of one TXT record.
///
/// Its own function because this is the part that would break silently:
/// `TxtResourceRecord.text` is the record's character-strings joined with
/// newlines (`name=Hall mirror\nble=E0:72:A1:F6:65:72\n`), which is this
/// package's shape rather than the wire format's. A line without an `=`, or
/// with an empty key, is not a pair and is skipped.
@visibleForTesting
Map<String, String> parseTxtRecord(String text) {
  final txt = <String, String>{};
  for (final line in text.split('\n')) {
    final at = line.indexOf('=');
    if (at <= 0) continue;
    txt[line.substring(0, at)] = line.substring(at + 1);
  }
  return txt;
}

/// The TXT record of one advertisement, as key/value pairs.
///
/// A mirror whose firmware predates the record answers none, and a lookup that
/// does not come back in time is not a discovery failure either: the address
/// is what makes the mirror reachable, and it is already in hand.
Future<Map<String, String>> _txtOf(
  MDnsClient client,
  String instance,
  Duration timeout,
) async {
  try {
    final record = await client
        .lookup<TxtResourceRecord>(
          ResourceRecordQuery.text(instance),
          timeout: timeout,
        )
        .first
        .timeout(timeout);
    return parseTxtRecord(record.text);
  } catch (_) {
    return <String, String>{};
  }
}

/// Binds one mDNS socket, asking for the socket options the platform has.
///
/// Dart's Android build compiles `SO_REUSEPORT` out: asking for it only prints
/// `reusePort not supported on this platform` to logcat and binds exactly the
/// same socket, so skip the flag where it cannot be granted. `reuseAddress`
/// still lets the shared mDNS port be bound there.
Future<RawDatagramSocket> _bindMdnsSocket(
  dynamic host,
  int port, {
  bool reuseAddress = true,
  bool reusePort = true,
  int ttl = 255,
}) {
  return RawDatagramSocket.bind(
    host,
    port,
    reuseAddress: reuseAddress,
    reusePort: Platform.isAndroid ? false : reusePort,
    ttl: ttl,
  );
}

Future<void> _setMulticastLock(bool held) async {
  try {
    await _multicastChannel.invokeMethod<void>(
      held ? 'acquireMulticastLock' : 'releaseMulticastLock',
    );
  } on MissingPluginException {
    // Desktop, iOS, tests: nothing filters multicast, so there is no lock.
  } on PlatformException {
    // Android build without the handler. Discovery still runs; the stack just
    // delivers whatever multicast it decides to, and manual IP entry remains.
  }
}
