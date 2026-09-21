// What LAN discovery guarantees.
//
// The two failures worth pinning only show up on a phone: Android's Wi-Fi stack
// drops every mDNS answer while no app holds a `WifiManager.MulticastLock`, and
// a client that fails to start used to leave its mDNS socket bound for the rest
// of the process. Both are invisible in a healthy desktop browse, so they get
// their own tests here.
//
// The browse is driven with loopback sockets: nothing here talks to a real
// mirror, competes for the host's mDNS port, or reaches the LAN.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:multicast_dns/multicast_dns.dart';

import 'package:mirror_designer/src/services/mirror_discovery.dart';

/// `IPPROTO_IP` / `IP_MULTICAST_IF`, used to keep the query on loopback.
const int _ipProtoIp = 0;
const int _ipMulticastIf = 32;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.example.mirror_designer/multicast');
  const browseTimeout = Duration(milliseconds: 400);
  final calls = <String>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  /// Binds loopback sockets and egresses multicast there, so a browse under
  /// test never reaches the LAN and never needs the real mDNS port.
  RawDatagramSocketFactory loopbackSockets(List<RawDatagramSocket> bound) {
    return (host, port,
        {reuseAddress = true, reusePort = true, ttl = 255}) async {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        reuseAddress: reuseAddress,
        reusePort: reusePort,
        ttl: ttl,
      );
      socket.setRawOption(
        RawSocketOption.fromInt(
          _ipProtoIp,
          _ipMulticastIf,
          0x0100007F, // 127.0.0.1, network byte order
        ),
      );
      bound.add(socket);
      return socket;
    };
  }

  /// True once the socket is closed: Dart rejects socket options on a dead
  /// socket, and `send` on one silently does nothing.
  bool isClosed(RawDatagramSocket socket) {
    try {
      socket.broadcastEnabled = true;
      return false;
    } on SocketException {
      return true;
    }
  }

  test('holds the multicast lock for one browse and releases it', () async {
    final bound = <RawDatagramSocket>[];
    final elapsed = Stopwatch()..start();
    List<LanDevice> found;
    var unreachable = false;
    try {
      found = await browseMdns(
        timeout: browseTimeout,
        socketFactory: loopbackSockets(bound),
        interfacesFactory: (type) async => const <NetworkInterface>[],
      ).toList();
    } on SocketException {
      // A host with no multicast route cannot even send the query; the
      // cleanup guarantees below are the point of this test.
      unreachable = true;
      found = <LanDevice>[];
    }
    elapsed.stop();

    expect(found, isEmpty); // nothing answers on loopback
    if (!unreachable) {
      // The window is spent waiting for answers, and the browse still ends
      // right after it instead of hanging on.
      expect(elapsed.elapsed, greaterThanOrEqualTo(browseTimeout));
    }
    expect(elapsed.elapsed, lessThan(const Duration(seconds: 2)));
    expect(calls, ['acquireMulticastLock', 'releaseMulticastLock']);
    expect(isClosed(bound.single), isTrue);
  });

  test('closes its socket when the client cannot start', () async {
    final bound = <RawDatagramSocket>[];

    await expectLater(
      browseMdns(
        timeout: browseTimeout,
        socketFactory: loopbackSockets(bound),
        // The client binds first and enumerates interfaces second, which is how
        // a failed start leaves a socket behind.
        interfacesFactory: (type) async =>
            throw const SocketException('no interfaces'),
      ).toList(),
      throwsA(isA<SocketException>()),
    );

    expect(bound, hasLength(1));
    expect(isClosed(bound.single), isTrue);
    expect(calls, ['acquireMulticastLock', 'releaseMulticastLock']);
  });

  test('browses where the platform has no multicast lock', () async {
    // Desktop, iOS and tests: the channel does not exist, and discovery must
    // not care.
    messenger.setMockMethodCallHandler(channel, null);
    final bound = <RawDatagramSocket>[];

    Object? failure;
    try {
      await browseMdns(
        timeout: browseTimeout,
        socketFactory: loopbackSockets(bound),
        interfacesFactory: (type) async => const <NetworkInterface>[],
      ).toList();
    } catch (e) {
      failure = e;
    }

    expect(failure, isNull);
    expect(calls, isEmpty);
    expect(isClosed(bound.single), isTrue);
  });

  test('keeps browsing when the platform refuses the lock', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      throw PlatformException(code: 'wifi_unavailable');
    });
    final bound = <RawDatagramSocket>[];

    Object? failure;
    try {
      await browseMdns(
        timeout: browseTimeout,
        socketFactory: loopbackSockets(bound),
        interfacesFactory: (type) async => const <NetworkInterface>[],
      ).toList();
    } catch (e) {
      failure = e;
    }

    expect(failure, isNull);
    expect(calls, ['acquireMulticastLock', 'releaseMulticastLock']);
  });
}
