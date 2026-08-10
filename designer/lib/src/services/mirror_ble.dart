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
    for (final r in results) {
      final name = r.device.advName;
      if (!name.startsWith('Smart Mirror')) continue;
      final already = found.any((e) => e.device.remoteId == r.device.remoteId);
      if (!already) found.add(BleScanEntry(r.device, name, r.rssi));
    }
  });

  try {
    await FlutterBluePlus.startScan(timeout: timeout);
  } on Exception catch (e) {
    throw BleUnavailableException('Bluetooth scan failed: $e');
  } finally {
    await sub.cancel();
  }
  return found;
}

/// A connected mirror. All writes are with-response and serialized through a
/// queue, so chunk order is preserved and the device's ATT backpressure is
/// respected.
class BleSession {
  BleSession._(this._device, this._cmd, this._data);

  // Base 5f1b3c2a-9e74-4f6d-8a2b-1c3d5e7f9a01, suffixes ...02 cmd, ...03
  // data, ...04 status. Same UUIDs as firmware/main/net/ble.c.
  static const String serviceUuid = '5f1b3c2a-9e74-4f6d-8a2b-1c3d5e7f9a01';
  static const String cmdUuid = '5f1b3c2a-9e74-4f6d-8a2b-1c3d5e7f9a02';
  static const String dataUuid = '5f1b3c2a-9e74-4f6d-8a2b-1c3d5e7f9a03';
  static const String statusUuid = '5f1b3c2a-9e74-4f6d-8a2b-1c3d5e7f9a04';

  final BluetoothDevice _device;
  final BluetoothCharacteristic _cmd;
  final BluetoothCharacteristic _data;

  final StreamController<String> _statusController =
      StreamController<String>.broadcast();
  StreamSubscription<List<int>>? _notifySub;

  // Serialization tail for with-response writes.
  Future<void> _writeTail = Future<void>.value();

  /// Connect, discover the service and start listening for status
  /// notifications. Throws [BlePushException] when the service is missing.
  static Future<BleSession> connect(BluetoothDevice device) async {
    // Personal home use: the nonprofit license covers it.
    await device.connect(mtu: 512, license: License.nonprofit);
    try {
      final services = await device.discoverServices();
      BluetoothCharacteristic? cmd, data, status;
      for (final s in services) {
        for (final c in s.characteristics) {
          final u = c.uuid.str128;
          if (u == cmdUuid) {
            cmd = c;
          } else if (u == dataUuid) {
            data = c;
          } else if (u == statusUuid) {
            status = c;
          }
        }
      }
      if (cmd == null || data == null || status == null) {
        throw BlePushException(
            'this device does not expose the mirror service');
      }

      final session = BleSession._(device, cmd, data);
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

  /// The next status line, or throw after [timeout].
  Future<String> _nextStatus({Duration timeout = const Duration(seconds: 10)}) {
    return _statusController.stream.first.timeout(timeout);
  }

  /// Raw pong payload, e.g. "pong 0.1.0 192.168.1.5 mini 64 32".
  Future<String> ping() async {
    await _writeCmd('ping');
    return _nextStatus();
  }

  /// The raw "config {...}" line, or null when the mirror has none.
  Future<String?> getConfigRaw() async {
    await _writeCmd('get config');
    return _nextStatus();
  }

  /// Push a layout and return the device's commit status text.
  /// Throws [BlePushException] with the device's reason on rejection.
  Future<String> pushLayout(String json) {
    return _push('layout', utf8.encode(json));
  }

  /// Push a config object and return the device's commit status text.
  Future<String> pushConfig(Map<String, dynamic> json) {
    return _push('config', utf8.encode(jsonEncode(json)));
  }

  Future<String> _push(String kind, List<int> payload) async {
    final writer = BlePayloadWriter(chunkSize: _chunkSize);
    for (final frame in writer.frames(kind, payload)) {
      if (frame.kind == BleFrameKind.cmd) {
        await _writeCmd(ascii.decode(frame.bytes));
      } else {
        await _serialized(() => _data.write(frame.bytes));
      }
    }

    final status = await _nextStatus();
    if (status.startsWith('commit error')) {
      throw BlePushException(status.substring('commit error'.length).trim());
    }
    return status;
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
