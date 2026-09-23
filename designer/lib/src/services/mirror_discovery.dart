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
  LanDevice(this.name, this.ip, this.port);

  /// The device one answered SRV/A pair describes.
  ///
  /// The name is the SRV target — the mirror's hostname on the LAN
  /// (`smart-mirror-e072a1f66570.local`), one per board and the same string
  /// the manual address field accepts. The PTR name is deliberately not used:
  /// it is the service *instance* FQDN, and a board whose firmware predates
  /// the identity fields calls itself "Smart Mirror", so its tile would be
  /// named `Smart Mirror._smartmirror._tcp.local` rather than a device. A
  /// record with no target leaves the name empty; the registry then lists the
  /// address.
  factory LanDevice.fromRecords(
    SrvResourceRecord service,
    IPAddressResourceRecord address,
  ) =>
      LanDevice(service.target, address.address.address, service.port);

  /// What the mirror is listed under until its own status names it: the SRV
  /// target, or empty when the advertisement carried no hostname.
  final String name;
  final String ip;
  final int port;

  @override
  String toString() => '$name ($ip:$port)';
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

      yield LanDevice.fromRecords(srv, a);
    }
  } finally {
    client?.stop();
    for (final socket in sockets) {
      socket.close();
    }
    await _setMulticastLock(false);
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
