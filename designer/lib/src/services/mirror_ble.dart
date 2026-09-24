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
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'mirror_ble_protocol.dart';
import 'mirror_ble_game.dart';
import 'mirror_ble_status.dart';
import 'mirror_display.dart';
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

/// The user-facing text for a BLE failure.
///
/// An exception this file raises already carries a sentence written for the
/// user, so it is passed through as-is. Anything else came from the plugin or
/// the platform, where Dart's `Exception: ` prefix is noise on a toast.
String bleErrorMessage(Object e) {
  if (e is BleUnavailableException || e is BlePushException) {
    return e.toString();
  }
  return e.toString().replaceFirst('Exception: ', '');
}

/// One mirror found by [scanForMirrors].
class BleScanEntry {
  BleScanEntry(this.device, this.name, this.rssi);

  final BluetoothDevice device;
  final String name;
  final int rssi;
}

/// Scan for mirrors: devices advertising the mirror GATT service.
///
/// The advertised name is an identity, not a marker: a verb-and-animal pair
/// the device generates from its MAC ("Dashing Dolphin"), or whatever the
/// owner typed during setup. Discovery therefore keys on the 128-bit service
/// UUID the firmware places in its scan response; Android concatenates the
/// scan response into the advertisement record and iOS merges its service
/// list, so `advertisementData.serviceUuids` carries it on both.
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
      if (!r.advertisementData.serviceUuids
          .any((u) => u.str128 == BleSession.serviceUuid)) {
        continue;
      }
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

/// Whether [line] can answer a `ping`: the pong payload every firmware
/// build sends. Anything else (a `game over <id>` push, say) must not be
/// mistaken for the reply.
bool _isPongReply(String line) => line.startsWith('pong ');

/// Whether [line] can answer a `get latency` diagnostic.
bool _isLatencyReply(String line) => line.startsWith('latency ');

/// Whether [line] can answer a `get device` identity query: the reply itself,
/// or the "unknown command" firmware predating it answers. Nothing else may
/// satisfy the request — a `game ok` push arriving mid-flight would otherwise
/// be parsed as an identity line.
bool _isDeviceReply(String line) =>
    line.startsWith('device ') || line == unknownCommandReply;

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

  // Serialization tail for game commands. Separate from [_writeTail]: a
  // transaction owns this slot for the whole subscribe/write/wait cycle,
  // while [_writeCmd] only queues the write itself. A transaction that fails
  // must not hold up the next one, hence the error-swallowing tail.
  Future<void> _gameTail = Future<void>.value();

  // Serialization tail for whole pushes, which is coarser than [_writeTail]:
  // a push is a begin/data/commit handshake whose status lines are matched to
  // it by arrival order, so two transfers in the air at once would race for
  // both the wire and the reply. The device answers "commit error busy" to
  // whichever loses, and the user would be told a push failed for a reason
  // that was not its own. A push that failed must not hold up the next one,
  // hence the error-swallowing tail.
  Future<void> _pushTail = Future<void>.value();

  /// Connect, discover the service and start listening for status
  /// notifications. Throws [BlePushException] when the service is missing.
  /// [timeout] bounds the link establishment; the caller decides how long a
  /// stuck connect attempt is worth waiting for (reconnecting at app launch
  /// wants a short one).
  static Future<BleSession> connect(BluetoothDevice device,
      {Duration timeout = const Duration(seconds: 35)}) async {
    // Personal home use: the nonprofit license covers it.
    await device.connect(
        mtu: 512, license: License.nonprofit, timeout: timeout);
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
  ///
  /// With [accepts], wait for the first line the predicate approves instead
  /// of the next line to arrive, and give up on [timeout]. Game and
  /// diagnostic commands use it so an unsolicited line — a `game over <id>`
  /// push during a latency poll, say — cannot be mistaken for the answer.
  Future<String> _sendAndWait(String line,
      {Duration timeout = const Duration(seconds: 10),
      bool Function(String)? accepts}) async {
    if (accepts != null) {
      return waitForGameReply(
        statuses: _statusController.stream,
        write: () => _writeCmd(line),
        accepts: accepts,
        timeout: timeout,
      );
    }
    final status = _takeStatuses(1, timeout: timeout);
    await _writeCmd(line);
    return (await status).single;
  }

  /// One game command transaction: subscribe for the reply, write, and await
  /// it inside a single slot, so a reply can never be matched to a different
  /// game command and the write keeps its place in the low-level queue.
  Future<String> _gameCommand(String line,
      {required bool Function(String) accepts,
      Duration timeout = const Duration(seconds: 10)}) {
    final result = _gameTail
        .then((_) => _sendAndWait(line, accepts: accepts, timeout: timeout));
    _gameTail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// Raw pong payload, e.g. "pong 0.2.0 192.168.1.5 mini 64 32".
  Future<String> ping() => _sendAndWait('ping', accepts: _isPongReply);

  /// The raw "config {...}" line, or null when the mirror has none.
  Future<String?> getConfigRaw() => _sendAndWait('get config');

  /// The mirror's firmware identity and display capabilities, or null when
  /// the firmware predates `get device`.
  ///
  /// Queued on [_pushTail] for the whole request/reply lifetime, not just the
  /// write: the reply is an unsolicited status line like a push's begin and
  /// commit, so an identity query running alongside a transfer would let one
  /// exchange's reply be read as the other's. Holding the slot for the whole
  /// wait keeps each exchange whole; the predicate below keeps an unsolicited
  /// game line from ending this one.
  Future<MirrorDeviceInfo?> getDeviceInfo() {
    final result = _pushTail.then((_) async => parseDeviceInfoLine(
        await _sendAndWait('get device', accepts: _isDeviceReply)));
    _pushTail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// Push a layout and return the device's commit status text.
  /// Throws [BlePushException] with the device's reason on rejection.
  Future<String> pushLayout(String json) {
    return _push('layout', utf8.encode(json));
  }

  /// Persist the base display; games remain a temporary controller override.
  Future<String> setDisplayMode(DisplayMode mode) {
    if (mode == DisplayMode.games) {
      throw ArgumentError.value(mode, 'mode', 'Games are not a base display');
    }
    return _push('display', utf8.encode(jsonEncode({'mode': mode.name})));
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
    return parseLatencyStatus(
        await _sendAndWait('get latency', accepts: _isLatencyReply));
  }

  /// The mirror's open OTA session, or null on older firmware.
  Future<BleOtaStatus?> getOtaStatus() async =>
      BleOtaStatus.parse(await _sendAndWait('get ota',
          accepts: (line) =>
              line.startsWith('ota ') || line == unknownCommandReply));

  /// Stream a firmware image, resuming at [offset].
  Future<void> pushFirmware(
    Uint8List bytes, {
    int offset = 0,
    void Function(int sent, int total)? onProgress,
  }) {
    final result = _pushTail.then((_) =>
        _pushFirmwareTransfer(bytes, offset: offset, onProgress: onProgress));
    _pushTail = result.then<void>((_) {}, onError: (_) {});
    return result;
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
      throw BlePushException(
          status.substring('brightness error'.length).trim());
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

  /// The mirror's game ids, or null when the firmware does not support games
  /// (it answers "unknown command" to "game list"). An empty list means a
  /// mirror that supports games and has none installed — not an unsupported
  /// one. A malformed reply is an error, not a claim about the firmware.
  Future<List<String>?> listGames() async {
    final line = await _gameCommand('game list', accepts: isGameListReply);
    final ids = parseGameList(line);
    if (ids != null) return ids;
    if (line == unknownCommandReply) return null;
    if (line.startsWith('$gameErrorPrefix ')) {
      throw BlePushException(gameErrorReason(line));
    }
    throw FormatException('unexpected game list reply: $line');
  }

  /// Start a game on the mirror and return its control labels for the
  /// gamepad. [players] above 1 asks for a round that waits for that many
  /// seats before it runs, so the starter is seated as player 1 and the round
  /// stays waiting until the other phone joins.
  ///
  /// Throws [BlePushException] with the device's reason when the mirror
  /// rejects the start, and [FormatException] when the mirror answers for a
  /// different game — the device is then running something the app did not
  /// ask for, so the caller has to treat the session as unknown.
  Future<MirrorGame> startGame(String id, {int players = 1}) async {
    final line = await _gameCommand(encodeGameStart(id, players),
        accepts: isGameStartReply);
    final g = parseGameOk(line);
    if (g != null) {
      if (g.id != id) {
        throw FormatException(
            'mirror answered "game ok ${g.id}" for "game start $id"');
      }
      return g;
    }
    if (line == unknownCommandReply) {
      throw BlePushException(unknownCommandReply);
    }
    if (line.startsWith('$gameErrorPrefix ')) {
      throw BlePushException(gameErrorReason(line));
    }
    throw FormatException('unexpected game start reply: $line');
  }

  /// Take a seat in the round already running on the mirror and return its
  /// control labels for the gamepad. Idempotent on the device: a link that
  /// already holds a seat is answered with its own seat again, so joining
  /// after a reconnect is harmless.
  ///
  /// Throws [BlePushException] with the device's reason when the mirror
  /// refuses (no round, a full one, or old firmware's "unknown command") and
  /// [FormatException] on an unparseable reply. The seat says nothing about
  /// how far the round has got; [gameSession] answers that, one command
  /// later, on the same serialized tail.
  Future<MirrorGame> joinGame() async {
    final line = await _gameCommand('game join', accepts: isGameJoinReply);
    final joined = parseGameJoined(line);
    if (joined != null) return joined.game;
    if (line == unknownCommandReply) {
      throw BlePushException(unknownCommandReply);
    }
    if (line.startsWith('$gameErrorPrefix ')) {
      throw BlePushException(gameErrorReason(line));
    }
    throw FormatException('unexpected game join reply: $line');
  }

  /// The round the mirror is running, or null when there is none — including
  /// when the firmware predates the command, which the caller reads as "this
  /// device cannot tell me" and behaves like a mirror without sessions.
  /// Throws [BlePushException] with the device's reason on a refusal and
  /// [FormatException] on an unparseable reply.
  Future<MirrorSessionInfo?> gameSession() async {
    final line =
        await _gameCommand('game session', accepts: isGameSessionReply);
    final session = parseGameSession(line);
    if (session != null) return session.id == null ? null : session;
    if (line == unknownCommandReply) return null;
    if (line.startsWith('$gameErrorPrefix ')) {
      throw BlePushException(gameErrorReason(line));
    }
    throw FormatException('unexpected game session reply: $line');
  }

  /// Stop the running game. "game stopped" and "game error no game" both mean
  /// no game is running now, so stopping an idle mirror is harmless. Any other
  /// device error, and the `unknown command` of firmware without games, throws
  /// [BlePushException] with the device's reason.
  Future<void> stopGame() async {
    final line = await _gameCommand('game stop', accepts: isGameStopReply);
    if (line == 'game stopped' || line == 'game error no game') return;
    if (line == unknownCommandReply) {
      throw BlePushException(unknownCommandReply);
    }
    throw BlePushException(gameErrorReason(line));
  }

  /// Freeze the remote simulation without discarding its board.
  Future<void> pauseGame() => _changeGamePause('pause', 'game paused');

  /// Continue a paused remote simulation, with all controls released.
  Future<void> resumeGame() => _changeGamePause('resume', 'game resumed');

  Future<void> _changeGamePause(String command, String acknowledgment) async {
    final line = await _gameCommand('game $command',
        accepts: (line) =>
            line == acknowledgment ||
            line.startsWith('$gameErrorPrefix ') ||
            line == unknownCommandReply);
    if (line == acknowledgment) return;
    if (line == unknownCommandReply) {
      throw BlePushException('Update the mirror firmware to use Pause.');
    }
    throw BlePushException(gameErrorReason(line));
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

  /// One transfer, queued behind any other in flight.
  ///
  /// The queue is what makes a push that was accepted the only thing that
  /// happened on the link: see [_pushTail].
  Future<String> _push(String kind, List<int> payload) {
    final result = _pushTail.then((_) => _pushTransfer(kind, payload));
    _pushTail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<String> _pushTransfer(String kind, List<int> payload) async {
    final writer = BlePayloadWriter(chunkSize: _chunkSize);
    final begin = await _sendAndWait(beginCommand(kind, payload.length),
        accepts: (line) => line.startsWith('begin '));
    if (begin != 'begin ok') {
      throw BlePushException(begin.startsWith('begin error')
          ? begin.substring('begin error'.length).trim()
          : begin);
    }
    for (final frame in writer.frames(kind, payload)) {
      if (frame.kind == BleFrameKind.data) {
        await _serialized(() => _data.write(frame.bytes));
      }
    }
    final commit = await _sendAndWait('commit',
        accepts: (line) => line.startsWith('commit '));
    if (commit != 'commit ok' && !commit.startsWith('commit ok ')) {
      throw BlePushException(commit.startsWith('commit error')
          ? commit.substring('commit error'.length).trim()
          : commit);
    }
    return commit;
  }

  /// Bytes that may be in flight ahead of what the mirror has committed.
  ///
  /// Half the mirror's 8 KiB receive ring: the writes below are
  /// unacknowledged, so nothing else bounds how far the phone can run ahead,
  /// and overrunning the ring would drop chunks and corrupt the image.
  static const int _firmwareWindow = 4096;

  /// Consecutive [getOtaStatus]-style polls with no newly committed byte
  /// before the stream is treated as stalled rather than merely behind.
  static const int _firmwareStallPolls = 60;

  Future<void> _pushFirmwareTransfer(
    Uint8List bytes, {
    required int offset,
    void Function(int sent, int total)? onProgress,
  }) async {
    final begin = await _sendAndWait(
        beginCommand('firmware', bytes.length, offset: offset),
        timeout: const Duration(seconds: 30),
        accepts: (line) => line.startsWith('begin '));
    if (begin != 'begin ok') throw BlePushException(_beginReason(begin));

    // Unacknowledged writes with read-back pacing. A with-response write waits
    // for the mirror to answer, and the mirror's flash writes freeze its cache
    // while they run, so that answer costs several connection intervals: ~3
    // minutes for a 1.3 MB image. Without a response the stream is limited only
    // by the link, and asking the mirror how much it has committed keeps the
    // phone from outrunning the ring.
    final total = bytes.length;
    var sent = offset;
    var committed = offset;
    var stalled = 0;
    while (sent < total) {
      if (sent >= committed + _firmwareWindow) {
        final status = await _sendAndWait('get ota',
            accepts: (line) => line.startsWith('ota '));
        final written = BleOtaStatus.parse(status)?.written;
        if (written == null) {
          throw BlePushException('the mirror stopped reporting its update');
        }
        if (written > committed) {
          committed = written;
          stalled = 0;
        } else if (++stalled > _firmwareStallPolls) {
          throw BlePushException('the mirror stopped accepting the image');
        }
        continue;
      }
      final limit = sent + _chunkSize < total ? sent + _chunkSize : total;
      await _serialized(() => _data.write(
          Uint8List.sublistView(bytes, sent, limit),
          withoutResponse: true));
      sent = limit;
      onProgress?.call(sent, total);
    }

    final commit = await _sendAndWait('commit',
        timeout: const Duration(seconds: 60),
        accepts: (line) => line == 'ota ok' || line.startsWith('ota error '));
    if (commit != 'ota ok') throw BlePushException(_commitReason(commit));
  }

  String _beginReason(String line) {
    switch (line) {
      case 'begin error bad offset':
        return 'the mirror refused to resume this update; connect again to start it over';
      case 'begin error busy':
        return 'the mirror is already receiving an image';
      case 'begin error too large':
        return 'the image is larger than the mirror\'s update partition';
      case 'begin error unavailable':
        return 'the mirror could not start an update';
      case 'unknown command':
        return 'this mirror\'s firmware is too old for an update over Bluetooth';
      default:
        return line;
    }
  }

  String _commitReason(String line) {
    switch (line) {
      case 'ota error incomplete':
        return 'the mirror received fewer bytes than the image contains';
      case 'ota error rejected':
        return 'the mirror rejected the image';
      case 'ota error write':
        return 'the mirror could not write the image to flash';
      default:
        return line;
    }
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
