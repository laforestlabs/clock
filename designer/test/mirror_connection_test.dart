// The pong line is how the app learns the mirror's version, WiFi IP, layout
// and panel size over BLE, and the parse feeds both the Mirror screen and the
// device records. A break in it shows up as "no WiFi IP" on the OTA button and
// a blank status line, so it gets a test.
//
// The rest of the file pins the rules the registry and the device routes lean
// on: a connection built for a device only ever talks to that device's BLE
// target, panel size and name are per connection, and an attempt that is
// abandoned -- route exited, radio handed to another device, widget disposed --
// can never resurrect itself once its link lands.

import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/services/mirror_ble.dart';
import 'package:mirror_designer/src/services/mirror_connection.dart';

/// A session a connect attempt can land on. Only [ping] and [close] are
/// reached by MirrorConnection.
class _Session extends Fake implements BleSession {
  _Session();

  Object? pingError;
  int closes = 0;

  @override
  Future<String> ping() {
    final error = pingError;
    if (error != null) return Future<String>.error(error);
    return Future<String>.value('pong 0.2.0 192.168.1.5 mini 64 32');
  }

  @override
  Future<void> close() {
    closes++;
    return Future<void>.value();
  }
}

/// A connection whose radio is the test: [openLink] hands back a session, or
/// waits for [gate], so the attempt rules can be driven without Bluetooth.
class _Connection extends MirrorConnection {
  _Connection({
    super.deviceId,
    super.deviceName,
    super.panelWidth,
    super.panelHeight,
  });

  final List<String> opened = <String>[];

  /// When set, the link stays "coming up" until the test completes it.
  Completer<BleSession>? gate;

  /// When set, the link never comes up.
  Object? failure;

  @override
  Future<BleSession> openLink(String remoteId, Duration timeout) {
    opened.add(remoteId);
    final gate = this.gate;
    if (gate != null) return gate.future;
    final failure = this.failure;
    if (failure != null) return Future<BleSession>.error(failure);
    return Future<BleSession>.value(_Session());
  }
}

void main() {
  group('BlePong.parse', () {
    test('parses a full pong line', () {
      final pong = BlePong.parse('pong 0.2.0 192.168.1.5 mini 64 32');
      expect(pong, isNotNull);
      expect(pong!.version, '0.2.0');
      expect(pong.ip, '192.168.1.5');
      expect(pong.layout, 'mini');
      expect(pong.width, 64);
      expect(pong.height, 32);
    });

    test('returns null for anything that is not a pong', () {
      expect(BlePong.parse('brightness ok 128'), isNull);
      expect(BlePong.parse('pong'), isNull);
      expect(BlePong.parse('pong 0.2.0 192.168.1.5'), isNull);
    });

    test('tolerates non-numeric panel dimensions', () {
      final pong = BlePong.parse('pong 0.2.0 192.168.1.5 mini x y');
      expect(pong, isNotNull);
      expect(pong!.width, 0);
      expect(pong.height, 0);
    });
  });

  group('bound target', () {
    test('refuses an id other than the bound one before anything is sent',
        () async {
      final conn = _Connection(deviceId: 'AA:BB', deviceName: 'Kitchen');

      await expectLater(
        conn.connectDevice(id: 'CC:DD', name: 'Bedroom'),
        throwsStateError,
      );

      expect(conn.opened, isEmpty);
      expect(conn.deviceId, 'AA:BB');
      expect(conn.deviceName, 'Kitchen');
      expect(conn.status, MirrorConnectionStatus.disconnected);
      expect(conn.session, isNull);
      expect(conn.error, isNull);
    });

    test('adopts the target of the first successful connect', () async {
      final conn = _Connection();
      await conn.connectDevice(id: 'AA:BB', name: 'Kitchen');
      expect(conn.status, MirrorConnectionStatus.connected);
      expect(conn.deviceId, 'AA:BB');

      await expectLater(
        conn.connectDevice(id: 'CC:DD', name: 'Bedroom'),
        throwsStateError,
      );
      expect(conn.opened, <String>['AA:BB']);
    });

    test('a failed attempt binds nothing, so another device can be tried',
        () async {
      final conn = _Connection()..failure = Exception('no mirror there');
      await conn.connectDevice(id: 'AA:BB', name: 'Kitchen');
      expect(conn.status, MirrorConnectionStatus.failed);
      expect(conn.deviceId, isNull);

      conn.failure = null;
      await conn.connectDevice(id: 'CC:DD', name: 'Bedroom');
      expect(conn.status, MirrorConnectionStatus.connected);
      expect(conn.deviceId, 'CC:DD');
      expect(conn.opened, <String>['AA:BB', 'CC:DD']);
    });

    test('connect(entry) uses that entry, and refuses a different device',
        () async {
      final entry =
          BleScanEntry(BluetoothDevice.fromId('CC:DD'), 'Bedroom', -50);

      final other = _Connection(deviceId: 'AA:BB');
      await expectLater(other.connect(entry), throwsStateError);
      expect(other.opened, isEmpty);

      final own = _Connection(deviceId: 'CC:DD');
      await own.connect(entry);
      expect(own.opened, <String>['CC:DD']);
      expect(own.status, MirrorConnectionStatus.connected);
    });

    test('a foreign target is refused even while another connect is running',
        () async {
      final conn = _Connection(deviceId: 'AA:BB');
      final gate = Completer<BleSession>();
      conn.gate = gate;

      final pending = conn.connectDevice(id: 'AA:BB', name: 'Kitchen');
      await expectLater(
        conn.connectDevice(id: 'CC:DD', name: 'Bedroom'),
        throwsStateError,
      );
      // The running attempt is untouched: no second link was opened.
      expect(conn.opened, <String>['AA:BB']);

      gate.complete(_Session());
      await pending;
      expect(conn.deviceId, 'AA:BB');
      expect(conn.status, MirrorConnectionStatus.connected);
    });
  });

  group('panel size', () {
    test('ignores non-positive sizes and notifies only on a real change', () {
      final conn = _Connection(panelWidth: 64, panelHeight: 32);
      var notifications = 0;
      conn.addListener(() => notifications++);

      conn.updatePanelSize(0, 0);
      conn.updatePanelSize(64, 0);
      conn.updatePanelSize(64, 32);
      expect(notifications, 0);
      expect(conn.panelWidth, 64);
      expect(conn.panelHeight, 32);

      conn.updatePanelSize(128, 64);
      expect(notifications, 1);
      expect(conn.panelWidth, 128);
      expect(conn.panelHeight, 64);
    });

    test('is per connection', () {
      final first = _Connection();
      final second = _Connection();
      var secondNotifications = 0;
      second.addListener(() => secondNotifications++);

      first.updatePanelSize(64, 32);

      expect(first.panelWidth, 64);
      expect(second.panelWidth, 0);
      expect(second.panelHeight, 0);
      expect(secondNotifications, 0);
    });

    test('the live pong wins, and what it reports becomes the fallback',
        () async {
      final conn = _Connection(panelWidth: 128, panelHeight: 64);
      expect(conn.panelWidth, 128);

      await conn.connectDevice(id: 'AA:BB', name: 'Kitchen');
      expect(conn.panelWidth, 64);
      expect(conn.panelHeight, 32);

      await conn.disconnect();
      expect(conn.pong, isNull);
      expect(conn.panelWidth, 64);
      expect(conn.panelHeight, 32);
    });
  });

  group('reconnect', () {
    test('does nothing without a bound target', () async {
      final conn = _Connection();
      await conn.reconnect();
      expect(conn.opened, isEmpty);
      expect(conn.status, MirrorConnectionStatus.disconnected);
    });

    test('brings the bound target back up, and only once', () async {
      final conn = _Connection(deviceId: 'AA:BB');
      await conn.reconnect();
      expect(conn.status, MirrorConnectionStatus.connected);
      expect(conn.deviceId, 'AA:BB');
      expect(conn.session, isNotNull);

      await conn.reconnect();
      expect(conn.opened, <String>['AA:BB']);
    });

    test('a rename keeps the name for the reconnect and persists nothing',
        () async {
      final conn = _Connection(deviceId: 'AA:BB', deviceName: 'Kitchen');
      var notifications = 0;
      conn.addListener(() => notifications++);

      await conn.renameDevice('Hallway');
      expect(conn.deviceName, 'Hallway');
      expect(notifications, 1);

      await conn.renameDevice('');
      expect(conn.deviceName, 'Hallway');
      expect(notifications, 1);

      await conn.disconnect();
      expect(conn.deviceName, 'Hallway');

      await conn.reconnect();
      expect(conn.status, MirrorConnectionStatus.connected);
      expect(conn.deviceId, 'AA:BB');
    });
  });

  group('late links', () {
    test('a link that lands after disconnect is closed, not adopted', () async {
      final conn = _Connection(deviceId: 'AA:BB');
      final gate = Completer<BleSession>();
      conn.gate = gate;
      var notifications = 0;
      conn.addListener(() => notifications++);

      final attempt = conn.connectDevice(id: 'AA:BB', name: 'Kitchen');
      expect(conn.opened, <String>['AA:BB']);
      expect(conn.status, MirrorConnectionStatus.connecting);

      await conn.disconnect();
      notifications = 0;

      final late = _Session();
      gate.complete(late);
      await attempt;

      expect(late.closes, 1);
      expect(conn.session, isNull);
      expect(conn.pong, isNull);
      expect(conn.deviceId, 'AA:BB');
      expect(conn.status, MirrorConnectionStatus.disconnected);
      expect(conn.error, isNull);
      expect(notifications, 0);
    });

    test('a failure after disconnect is not reported into the new state',
        () async {
      final conn = _Connection(deviceId: 'AA:BB');
      final gate = Completer<BleSession>();
      conn.gate = gate;
      var notifications = 0;
      conn.addListener(() => notifications++);

      final attempt = conn.connectDevice(id: 'AA:BB', name: 'Kitchen');
      await conn.disconnect();
      notifications = 0;

      gate.completeError(Exception('mirror went away'));
      await attempt;

      expect(conn.status, MirrorConnectionStatus.disconnected);
      expect(conn.error, isNull);
      expect(conn.session, isNull);
      expect(notifications, 0);
    });

    test('a link that lands after dispose is closed without notifying',
        () async {
      final conn = _Connection(deviceId: 'AA:BB');
      final gate = Completer<BleSession>();
      conn.gate = gate;
      var notifications = 0;
      conn.addListener(() => notifications++);

      final attempt = conn.connectDevice(id: 'AA:BB', name: 'Kitchen');
      notifications = 0;
      conn.dispose();

      final late = _Session();
      gate.complete(late);
      await attempt;

      expect(late.closes, 1);
      expect(conn.session, isNull);
      expect(notifications, 0);
    });

    test('a dropped link drops the session and keeps the bound target',
        () async {
      final conn = _Connection(deviceId: 'AA:BB');
      final gate = Completer<BleSession>();
      conn.gate = gate;
      final live = _Session();

      final attempt = conn.connectDevice(id: 'AA:BB', name: 'Kitchen');
      gate.complete(live);
      await attempt;
      expect(conn.status, MirrorConnectionStatus.connected);

      conn.linkLost();

      expect(conn.status, MirrorConnectionStatus.disconnected);
      expect(conn.session, isNull);
      expect(conn.pong, isNull);
      expect(conn.deviceId, 'AA:BB');
      expect(live.closes, 1);

      // The same target comes back, and a drop with nothing connected is a
      // no-op rather than a second teardown.
      conn.gate = null;
      await conn.reconnect();
      expect(conn.status, MirrorConnectionStatus.connected);
      expect(conn.opened, <String>['AA:BB', 'AA:BB']);

      await conn.disconnect();
      conn.linkLost();
      expect(conn.status, MirrorConnectionStatus.disconnected);
      expect(conn.error, isNull);
    });
  });
}
