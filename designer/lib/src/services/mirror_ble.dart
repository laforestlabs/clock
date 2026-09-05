// BLE session with the mirror: scan, connect, push layout/config.
//
// The wire protocol is defined in mirror_ble_protocol.dart and implemented
// by firmware/main/net/ble.c. This file only moves bytes over the air:
// command writes (with response) on the cmd characteristic, payload chunks on
// the data characteristic, and status lines that arrive as notifications.
//
// Chunk size is dynamic: the negotiated MTU decides how big a single ATT
// write can be, capped at 500. iOS reports no negotiated MTU, so it falls
// back to the 185-byte ATT default minus overhead (182).

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'mirror_ble_protocol.dart';
import 'mirror_ble_game.dart';
import 'mirror_ble_status.dart';
import 'mirror_wifi.dart';
import 'mirror_wifi_status.dart';

/// The BLE stack or adapter is not available (e.g. a desktop without
/// Bluetooth). The UI shows this as "unavailable" rather than crashing.
class BleUnavailableException implements Exception {
  BleUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A push was rejected by the mirror; [message] is the device's reason.
class BlePushException implements Exception {
  BlePushException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One mirror found by [scanForMirrors].
class BleScanEntry {
  BleScanEntry(this.device, this.name, this.rssi);

  final BluetoothDevice device;
  final String name;
  final int rssi;
}

/// Scan for devices whose advertised name starts with "Smart Mirror".
///
/// Throws [BleUnavailableException] when the platform cannot scan.
Future<List<BleScanEntry>> scanForMirrors({
  Duration timeout = const Duration(seconds: 6),
}) async {
  try {
    if (!await FlutterBluePlus.isSupported) {
      throw BleUnavailableException('Bluetooth is not available here');
    }
    if (FlutterBluePlus.adapterStateNow == BluetoothAdapterState.off) {
      await FlutterBluePlus.turnOn();
    }
  } on BleUnavailableException {
    rethrow;
  } catch (e) {
    throw BleUnavailableException('Bluetooth unavailable: $e');
  }

  final found = <BleScanEntry>[];
  final sub = FlutterBluePlus.scanResults.listen((results) {
    if (results.isEmpty) {
      // fbp pushes an empty list when a scan starts, and replays the last
      // scan's list to new subscribers; either way start from a clean slate.
      found.clear();
      return;
    }
    for (final r in results) {
      final name = r.device.advName;
      if (!name.startsWith('Smart Mirror')) continue;
      final already = found.any((e) => e.device.remoteId == r.device.remoteId);
      if (!already) found.add(BleScanEntry(r.device, name, r.rssi));
    }
  });

  try {
    await FlutterBluePlus.startScan(timeout: timeout);
    // startScan returns once the platform scan is running, not when it
    // finishes: results arrive asynchronously until the timeout timer stops
    // the scan. Block until the scan has actually stopped so every
    // advertisement is collected.
    await FlutterBluePlus.isScanning
        .firstWhere((scanning) => !scanning)
        .timeout(timeout + const Duration(seconds: 1));
  } on Exception catch (e) {
    throw BleUnavailableException('Bluetooth scan failed: $e');
  } finally {
    await sub.cancel();
    await FlutterBluePlus.stopScan();
  }
  return found;
}

/// A connected mirror. All writes are with-response and serialized through a
/// queue, so chunk order is preserved and the device's ATT backpressure is
/// respected.
class BleSession {
  BleSession._(this._device, this._cmd, this._data, this._gameIn);

  // Base 5f1b3c2a-9e74-4f6d-8a2b-1c3d5e7f9a01, suffixes ...02 cmd, ...03
  // data, ...04 status, ...05 game_in. Same UUIDs as
  // firmware/main/net/ble.c.
  static const String serviceUuid = '5f1b3c2a-9e74-4f6d-8a2b-1c3d5e7f9a01';
  static const String cmdUuid = '5f1b3c2a-9e74-4f6d-8a2b-1c3d5e7f9a02';
  static const String dataUuid = '5f1b3c2a-9e74-4f6d-8a2b-1c3d5e7f9a03';
  static const String statusUuid = '5f1b3c2a-9e74-4f6d-8a2b-1c3d5e7f9a04';
  static const String gameInUuid = '5f1b3c2a-9e74-4f6d-8a2b-1c3d5e7f9a05';

  final BluetoothDevice _device;
  final BluetoothCharacteristic _cmd;
  final BluetoothCharacteristic _data;

  /// The gamepad input characteristic, or null on firmware that predates
  /// game support. Without it the app shows the "update the firmware"
  /// message instead of a gamepad.
  final BluetoothCharacteristic? _gameIn;

  /// Whether the connected firmware exposes the gamepad input channel.
  BluetoothCharacteristic? get gameIn => _gameIn;

  final StreamController<String> _statusController =
      StreamController<String>.broadcast();
  StreamSubscription<List<int>>? _notifySub;

  /// Live status lines the mirror pushes (e.g. "game over <id>"). A
  /// broadcast stream: command replies are consumed by the command methods,
  /// and any number of listeners can watch for unsolicited lines.
  Stream<String> get statusLines => _statusController.stream;

  // Serialization tail for with-response writes.
  Future<void> _writeTail = Future<void>.value();

  /// Connect, discover the service and start listening for status
  /// notifications. Throws [BlePushException] when the service is missing.
  /// [timeout] bounds the link establishment; the caller decides how long a
  /// stuck connect attempt is worth waiting for (reconnecting at app launch
  /// wants a short one).
  static Future<BleSession> connect(BluetoothDevice device,
      {Duration timeout = const Duration(seconds: 35)}) async {
    // Personal home use: the nonprofit license covers it.
    await device.connect(mtu: 512, license: License.nonprofit, timeout: timeout);
    // Ask the central for a fast connection interval. Android HIGH maps to
    // 11.25-15 ms, which cuts the radio wait for a game input packet from the
    // 30-50 ms balanced default. The firmware requests the same interval via
    // ble_gap_update_params, so both ends agree. Not every adapter honours
    // it; the link still works at whatever interval the central chooses.
    try {
      await device.requestConnectionPriority(
          connectionPriorityRequest: ConnectionPriority.high);
    } catch (_) {
      // Unsupported on this platform/adapter; not fatal.
    }

    try {
      final services = await device.discoverServices();
      BluetoothCharacteristic? cmd, data, status, gameIn;
      for (final s in services) {
        for (final c in s.characteristics) {
          final u = c.uuid.str128;
          if (u == cmdUuid) {
            cmd = c;
          } else if (u == dataUuid) {
            data = c;
          } else if (u == statusUuid) {
            status = c;
          } else if (u == gameInUuid) {
            gameIn = c;
          }
        }
      }
      if (cmd == null || data == null || status == null) {
        throw BlePushException(
            'this device does not expose the mirror service');
      }

      // gameIn may be absent: older firmware predates game support and the
      // app degrades to the "update the firmware" message.
      final session = BleSession._(device, cmd, data, gameIn);
      await status.setNotifyValue(true);
      session._notifySub = status.onValueReceived.listen((bytes) {
        final line = utf8.decode(bytes, allowMalformed: true).trim();
        if (line.isNotEmpty) session._statusController.add(line);
      });
      return session;
    } catch (e) {
      await device.disconnect();
      rethrow;
    }
  }

  /// Bytes per data chunk: min(500, negotiatedMtu - 3), with 182 as the
  /// fallback when the platform reports no MTU (iOS).
  int get _chunkSize {
    final mtu = _device.mtuNow;
    return math.min(500, mtu > 0 ? mtu - 3 : 182);
  }

  /// Queue a write so with-response operations never overlap.
  Future<void> _serialized(Future<void> Function() op) {
    final result = _writeTail.then((_) => op());
    _writeTail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<void> _writeCmd(String line) {
    return _serialized(() => _cmd.write(ascii.encode(line)));
  }

  /// The next [n] status lines, or throw after [timeout]. The caller must
  /// subscribe BEFORE the writes that trigger them: Android delivers a
  /// notification (e.g. the pong) before the write-response callback, so
  /// subscribing after the write misses the line on a broadcast stream.
  Future<List<String>> _takeStatuses(int n,
      {Duration timeout = const Duration(seconds: 10)}) {
    final lines = <String>[];
    return _statusController.stream
        .take(n)
        .forEach(lines.add)
        .timeout(timeout)
        .then((_) => lines);
  }

  /// Write a command and wait for its one status line, subscribing first so
  /// the response can never be missed.
  Future<String> _sendAndWait(String line,
      {Duration timeout = const Duration(seconds: 10)}) async {
    final status = _takeStatuses(1, timeout: timeout);
    await _writeCmd(line);
    return (await status).single;
  }

  /// Raw pong payload, e.g. "pong 0.2.0 192.168.1.5 mini 64 32".
  Future<String> ping() => _sendAndWait('ping');

  /// The raw "config {...}" line, or null when the mirror has none.
  Future<String?> getConfigRaw() => _sendAndWait('get config');

  /// Push a layout and return the device's commit status text.
  /// Throws [BlePushException] with the device's reason on rejection.
  Future<String> pushLayout(String json) {
    return _push('layout', utf8.encode(json));
  }

  /// Push a config object and return the device's commit status text.
  Future<String> pushConfig(Map<String, dynamic> json) {
    return _push('config', utf8.encode(jsonEncode(json)));
  }

  /// The live panel brightness and whether a manual override is set, or null
  /// when the mirror does not answer a brightness line (an older firmware
  /// that does not know the command).
  Future<BleBrightness?> getBrightness() async {
    return parseBrightnessStatus(await _sendAndWait('get brightness'));
  }

  /// The mirror's measured input-to-render latency and negotiated
  /// connection interval, or null when the firmware does not answer the
  /// command (an older build). See [BleLatency].
  Future<BleLatency?> getLatency() async {
    return parseLatencyStatus(await _sendAndWait('get latency'));
  }

  /// Round-trip time of a command write plus its status notification. A
  /// proxy for the phone-to-mirror link latency, dominated by the
  /// connection interval; no clock sync is needed since both timestamps
  /// live on the phone.
  Future<Duration> measureRoundTrip() async {
    final sw = Stopwatch()..start();
    await _sendAndWait('ping');
    sw.stop();
    return sw.elapsed;
  }


  /// Set a manual brightness override, or clear it (back to following the
  /// layout) when [value] is null. Returns the device's status line; throws
  /// [BlePushException] with the device's reason on rejection.
  Future<String> setBrightness(int? value) async {
    final status = await _sendAndWait(
        value == null ? 'set brightness auto' : 'set brightness $value');
    if (status.startsWith('brightness error')) {
      throw BlePushException(status.substring('brightness error'.length).trim());
    }
    return status;
  }

  /// The mirror's WiFi state, or null when the firmware does not answer the
  /// command (an older build).
  Future<BleWifiStatus?> getWifi() async {
    return parseWifiStatus(await _sendAndWait('get wifi'));
  }

  /// Scan for nearby networks and return them strongest-first. Sends
  /// "wifi scan" and collects wifi-net lines until the wifi-scan done/error
  /// terminator. An empty list with no error means the mirror is still
  /// scanning or found nothing.
  Future<List<BleWifiNetwork>> scanWifi({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final nets = <BleWifiNetwork>[];
    final done = _statusController.stream
        .firstWhere((l) =>
            l.startsWith('wifi-scan done') || l.startsWith('wifi-scan error'))
        .timeout(timeout);
    final sub = _statusController.stream.listen((line) {
      final n = parseWifiNet(line);
      if (n != null) nets.add(n);
    });
    try {
      await _writeCmd('wifi scan');
      await done;
    } finally {
      await sub.cancel();
    }
    return nets;
  }

  /// Push WiFi credentials and return the device's commit status text.
  /// Throws [BlePushException] with the device's reason on rejection.
  Future<String> pushWifi(WifiConfig wifi) {
    return _push('wifi', utf8.encode(jsonEncode(wifi.toJson())));
  }

  /// Forget the saved network; the mirror reopens its setup portal.
  Future<String> forgetWifi() => _sendAndWait('wifi forget');

  /// Await the asynchronous connect outcome after a [pushWifi]. Subscribe
  /// before pushing, then call this. Returns null when no outcome arrives
  /// within [timeout].
  Future<BleWifiResult?> awaitWifiResult({
    Duration timeout = const Duration(seconds: 40),
  }) async {
    try {
      final line = await _statusController.stream
          .firstWhere((l) =>
              l.startsWith('wifi connect ok') ||
              l.startsWith('wifi connect error'))
          .timeout(timeout);
      return parseWifiResult(line);
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Ask the mirror to restart. The device answers "reboot ok" first, then
  /// drops the connection; the caller should not expect more traffic.
  Future<String> reboot() => _sendAndWait('reboot');

  /// Wipe everything the owner has set on the mirror: the device config
  /// (location, timezone, display settings, brightness override), the saved
  /// WiFi credentials, and the stored layout. The device erases its stores,
  /// answers "factory reset ok", and reboots unprovisioned, dropping the
  /// link; the caller should not expect more traffic. The generous timeout
  /// covers the flash erases before the answer. Throws
  /// [BlePushException] with the device's reason when the reset fails or
  /// the firmware is too old to know the command.
  Future<String> factoryReset() async {
    final line = await _sendAndWait('factory reset',
        timeout: const Duration(seconds: 15));
    if (line != 'factory reset ok') {
      if (line == 'unknown command') {
        throw BlePushException('this firmware does not support factory reset');
      }
      final reason = line.startsWith('factory reset error')
          ? line.substring('factory reset error'.length).trim()
          : 'unexpected reply: $line';
      throw BlePushException(reason);
    }
    return line;
  }

  /// The mirror's game ids, or null when the firmware does not support
  /// games (it answers "unknown command" to "game list").
  Future<List<String>?> listGames() async =>
      parseGameList(await _sendAndWait('game list'));

  /// Start a game on the mirror and return its control labels for the
  /// gamepad. Throws [BlePushException] with the device's reason when the
  /// mirror rejects the start.
  Future<MirrorGame> startGame(String id) async {
    final line = await _sendAndWait('game start $id');
    final g = parseGameOk(line);
    if (g == null) {
      if (line.startsWith('game error')) {
        throw BlePushException(line.substring('game error'.length).trim());
      }
      throw BlePushException('unexpected reply: $line');
    }
    return g;
  }

  /// Stop the running game. The reply ("game stopped" or an error) is
  /// consumed and its value ignored; a stop on a mirror with no game running
  /// is harmless.
  Future<void> stopGame() async {
    await _sendAndWait('game stop');
  }

  /// Stream the full input state to the mirror, one packet per frame.
  ///
  /// [values] carries one i16 per control in code order: 0/1 for buttons,
  /// -32768..32767 for axes. Deliberately bypasses the with-response write
  /// queue so gamepad input never queues behind a layout push. A dead link
  /// is surfaced by MirrorConnection's connection-state listener, so write
  /// failures are swallowed here.
  Future<void> sendGameInput(List<int> values) async {
    final w = _gameIn;
    if (w == null) return;
    try {
      await w.write(encodeGameInput(values), withoutResponse: true);
    } catch (_) {
      // Link died; MirrorConnection's listener surfaces it.
    }
  }

  Future<String> _push(String kind, List<int> payload) async {
    final writer = BlePayloadWriter(chunkSize: _chunkSize);
    // The mirror answers "begin ok" to the begin write and the commit status
    // to the commit write; subscribe for both before writing anything so
    // neither can arrive into a stream with no listener.
    final statuses = _takeStatuses(2);
    for (final frame in writer.frames(kind, payload)) {
      if (frame.kind == BleFrameKind.cmd) {
        await _writeCmd(ascii.decode(frame.bytes));
      } else {
        await _serialized(() => _data.write(frame.bytes));
      }
    }

    final lines = await statuses;
    final commit = lines.length > 1 ? lines[1] : lines.single;
    if (commit.startsWith('commit error')) {
      throw BlePushException(commit.substring('commit error'.length).trim());
    }
    return commit;
  }

  Future<void> close() async {
    await _notifySub?.cancel();
    _notifySub = null;
    await _statusController.close();
    try {
      await _device.disconnect();
    } on Exception {
      // The device may already be gone; nothing to do.
    }
  }
}
