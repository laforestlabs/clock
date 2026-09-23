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

  group('a discovered mirror is an address, not a name', () {
    SrvResourceRecord service(String target, {int port = 80}) =>
        SrvResourceRecord(
          'Smart Mirror._smartmirror._tcp.local',
          0,
          target: target,
          port: port,
          priority: 0,
          weight: 0,
        );

    IPAddressResourceRecord deviceAddress(String ip) =>
        IPAddressResourceRecord('smart-mirror.local', 0,
            address: InternetAddress(ip));

    test('the advertisement names a service, so no name is taken from it', () {
      // It carries two strings a tile could be labelled with — the SRV target
      // (`smart-mirror-e072a1f66570.local`) and the service instance FQDN
      // (`Smart Mirror._smartmirror._tcp.local`) — and neither is the mirror's
      // name: both are discovery keys, hardware-derived and unchanged by an
      // owner rename.
      final device = LanDevice.fromRecords(
        service('smart-mirror-e072a1f66570.local', port: 8080),
        deviceAddress('192.168.0.173'),
        const <String, String>{},
      );

      expect(device.ip, '192.168.0.173');
      expect(device.port, 8080);
      expect(device.name, isEmpty);
      expect(device.bleAddress, isEmpty);
      expect(device.toString(), '192.168.0.173:8080');
    });

    test('the friendly name and the Bluetooth address come from the TXT',
        () {
      // What the mirror says about itself, rather than what the address it
      // advertises under happens to spell. The Bluetooth address is what lets
      // the registry join this mirror to the record a scan made for it.
      final device = LanDevice.fromRecords(
        service('smart-mirror-3030f9183654.local'),
        deviceAddress('192.168.0.137'),
        <String, String>{
          'id': '3030f9183654',
          'name': 'Twirling Elephant',
          'ble': '30:30:F9:18:36:56',
        },
      );

      expect(device.name, 'Twirling Elephant');
      expect(device.bleAddress, '30:30:F9:18:36:56');
    });
  });

  group('TXT parsing', () {
    test('reads the record as the client hands it over', () {
      // `TxtResourceRecord.text` is the character-strings the package joined
      // with newlines: `id=...\nname=...\nble=...\n`. A package that ever
      // changes that shape must fail here rather than quietly leave every
      // discovered mirror unnamed and unpaired.
      final txt = parseTxtRecord('id=3030f9183654\nname=Twirling Elephant\n'
          'ble=30:30:F9:18:36:56\n');

      expect(txt['id'], '3030f9183654');
      expect(txt['name'], 'Twirling Elephant');
      expect(txt['ble'], '30:30:F9:18:36:56');
    });

    test('skips what is not a pair, and keeps the rest', () {
      // A record without the identity items, a keyless line and a truncated
      // one: the parts that do parse still work.
      final txt = parseTxtRecord('name=Hall mirror\nflag\n=orphan\n');

      expect(txt, <String, String>{'name': 'Hall mirror'});
    });

    test('a value keeps its own equals signs and spaces', () {
      final txt = parseTxtRecord('note=a=b\nname=Hall mirror\n');

      expect(txt['note'], 'a=b');
      expect(txt['name'], 'Hall mirror');
    });
  });
}
