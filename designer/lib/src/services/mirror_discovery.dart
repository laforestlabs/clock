// mDNS discovery of mirrors on the LAN.
//
// The mirror advertises _smartmirror._tcp (port 80) when it is on the
// station network, so a desktop designer can find it without typing an IP.
// The chain is PTR -> SRV -> A, each answered by the same device. Discovery
// failing (no multicast on the network, the service not advertised) yields
// an empty stream; the Mirror screen falls back to manual IP entry, which is
// also how you point at the fake mirror during development.

import 'dart:async';

import 'package:multicast_dns/multicast_dns.dart';

/// A mirror found on the LAN.
class LanDevice {
  LanDevice(this.name, this.ip, this.port);

  final String name;
  final String ip;
  final int port;

  @override
  String toString() => '$name ($ip:$port)';
}

/// Browse for mirrors until [timeout] elapses without a new record.
///
/// Emits each distinct mirror once. Errors (e.g. no multicast interface)
/// surface through the stream; the caller shows "discovery unavailable".
Stream<LanDevice> browseMdns({
  Duration timeout = const Duration(seconds: 5),
}) async* {
  final client = MDnsClient();
  await client.start();
  try {
    final ptrs = client.lookup<PtrResourceRecord>(
      ResourceRecordQuery.serverPointer('_smartmirror._tcp.local'),
      timeout: timeout,
    );

    await for (final ptr in ptrs) {
      SrvResourceRecord? srv;
      try {
        srv = await client
            .lookup<SrvResourceRecord>(
              ResourceRecordQuery.service(ptr.domainName),
              timeout: timeout,
            )
            .first
            .timeout(timeout);
      } catch (_) {
        continue; // no SRV answer; skip this advertisement
      }

      IPAddressResourceRecord? a;
      try {
        a = await client
            .lookup<IPAddressResourceRecord>(
              ResourceRecordQuery.addressIPv4(srv.target),
              timeout: timeout,
            )
            .first
            .timeout(timeout);
      } catch (_) {
        continue; // no A answer; skip
      }

      yield LanDevice(ptr.domainName, a.address.address, srv.port);
    }
  } finally {
    client.stop();
  }
}
