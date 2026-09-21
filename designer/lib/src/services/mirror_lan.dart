// The mirror's LAN API client (dart:io only, no HTTP package).
//
// The firmware serves these endpoints on the station interface:
//   GET  /api/status   device state
//   GET  /api/layout   the current layout as JSON
//   PUT  /api/layout   push a new layout
//   POST /api/ota      upload a firmware image (the app partition .bin)
//   GET  /api/frame    one composited panel frame (MRF1 plus RGB888)
//   PUT  /api/mode     save the base display (clock or picture)
//   POST /api/image    upload the one picture the mirror shows
//
// The layout bytes are the designer's exportJson() output: the exact JSON
// the preview renders. The display endpoints' payloads are defined in
// mirror_display.dart, which the BLE transport reads back too. Plain HTTP on
// a home LAN, no authentication, which is the same trust model as the mirror
// itself.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'mirror_display.dart';

/// The parsed /api/status body.
class MirrorStatus {
  const MirrorStatus({
    required this.version,
    required this.core,
    required this.ip,
    required this.online,
    required this.rssi,
    // ignore: non_constant_identifier_names
    required this.uptime_s,
    required this.layout,
    required this.width,
    required this.height,
    required this.brightness,
    this.id,
    this.name,
    this.mode,
    this.baseMode,
    this.pictureReady,
    this.flip180,
    this.displayApi = 0,
  });

  /// The app image version (esp_app_get_description on the device); what an
  /// OTA changes.
  final String version;

  /// The render core version (ML_VERSION_STR), empty on firmware older than
  /// the field's introduction; useful for designer/firmware render drift.
  final String core;
  final String ip;
  final bool online;
  final int rssi;
  // The JSON key is uptime_s; the field keeps the wire name.
  // ignore: non_constant_identifier_names
  final int uptime_s;
  final String layout;
  final int width;
  final int height;
  final int brightness;

  /// The firmware identity (12 lowercase hex MAC digits), null on firmware
  /// that predates it. Reported identically over BLE; it is what makes two
  /// records the same physical device.
  final String? id;

  /// The owner's friendly name, null on older firmware.
  final String? name;

  /// The effective display ("games" while a game runs), or null when the
  /// firmware did not report one this build understands.
  final DisplayMode? mode;

  /// The saved base display, or null when unknown. Never `games`.
  final DisplayMode? baseMode;

  /// Whether a stored picture matches the current panel, or null when the
  /// firmware does not report it.
  final bool? pictureReady;

  /// Whether the panel is rotated 180 degrees, or null when unreported.
  final bool? flip180;

  /// The display API version, 0 when absent. Absent means the picture and
  /// fresh-preview features are unsupported, not that the device is
  /// unreachable.
  final int displayApi;

  factory MirrorStatus.fromJson(Map<String, dynamic> json) {
    int asInt(dynamic v, int fallback) => v is num ? v.toInt() : fallback;
    String? asString(dynamic v) => v is String && v.isNotEmpty ? v : null;
    bool? asBool(dynamic v) => v is bool ? v : null;
    return MirrorStatus(
      version: json['version'] as String? ?? '',
      core: json['core'] as String? ?? '',
      ip: json['ip'] as String? ?? '',
      online: json['online'] as bool? ?? false,
      rssi: asInt(json['rssi'], 0),
      uptime_s: asInt(json['uptime_s'], 0),
      layout: json['layout'] as String? ?? '',
      width: asInt(json['width'], 0),
      height: asInt(json['height'], 0),
      brightness: asInt(json['brightness'], 0),
      id: asString(json['id']),
      name: asString(json['name']),
      mode: parseDisplayMode(asString(json['mode'])),
      baseMode: parseBaseDisplayMode(asString(json['base_mode'])),
      pictureReady: asBool(json['picture_ready']),
      flip180: asBool(json['flip180']),
      displayApi: asInt(json['display_api'], 0),
    );
  }
}

/// Result of a layout push: the firmware's 200 carries parser warnings, the
/// 400 carries a single error message.
typedef PutLayoutResult = ({bool ok, List<String> diag, String? error});

/// Thrown when the device answers with an error status or an unreadable
/// body. [message] is human-facing.
class MirrorApiException implements Exception {
  MirrorApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class MirrorLan {
  MirrorLan(this.ip);

  final String ip;

  static const Duration _timeout = Duration(seconds: 8);
  // Flash writes take ~10-30s for a 1.3MB image; the 8s request timeout would
  // abort a legitimate OTA mid-write (the mirror answers only after it has
  // written and validated the whole image).
  static const Duration _otaTimeout = Duration(seconds: 120);
  // A picture upload ends with a SPIFFS write, a re-read and an NVS commit on
  // the device, so the 8s read deadline would abort a legitimate upload. This
  // bounds the whole exchange — connect, body, commit, reply — not each read.
  static const Duration _uploadTimeout = Duration(seconds: 30);
  // A display result document is a few dozen bytes. The bound is not the
  // document's size; it keeps a server that answers with the wrong body from
  // streaming into the app.
  static const int _resultJsonCap = 4096;
  // The whole MRF1 snapshot: header plus the largest payload the firmware can
  // send. A frame that declares more is malformed before it is read.
  static const int _frameBodyCap =
      mirrorFrameHeaderSize + mirrorFrameMaxPayloadBytes;

  Uri _uri(String path) => Uri.parse('http://$ip$path');

  /// One HttpClient per call, closed afterwards, so a screen full of devices
  /// cannot leak sockets while it sits idle.
  Future<HttpClient> _newClient() async {
    final client = HttpClient()..connectionTimeout = _timeout;
    return client;
  }

  /// Runs one display exchange on its own client under one [deadline].
  ///
  /// The deadline covers the whole request — connect, body, commit, reply —
  /// rather than each read, and it force-closes the client so a request parked
  /// in a read cannot outlive it. Every failure is normalised to
  /// [MirrorApiException]: a socket error, an HTTP error, a timeout and an
  /// unreadable body all reach the device screen as one type, and a rejection
  /// keeps the firmware's status code (409 `picture missing` is actionable,
  /// a bare failure is not).
  Future<T> _request<T>(
    String what,
    Duration deadline,
    Future<T> Function(HttpClient client) run,
  ) async {
    final client = await _newClient();
    try {
      return await run(client).timeout(deadline, onTimeout: () {
        client.close(force: true);
        throw TimeoutException(what);
      });
    } on MirrorApiException {
      rethrow;
    } on TimeoutException {
      throw MirrorApiException(
          '$what: the mirror did not answer within ${deadline.inSeconds}s');
    } on SocketException catch (e) {
      throw MirrorApiException('could not reach $ip: ${e.message}');
    } on HttpException catch (e) {
      throw MirrorApiException('$what: ${e.message}');
    } on FormatException {
      throw MirrorApiException(
          '$what: the mirror answered with unreadable data');
    } finally {
      client.close(force: true);
    }
  }

  /// Reads a response body, refusing to accumulate more than [cap] bytes.
  ///
  /// A declared Content-Length over the cap is rejected before a byte is read;
  /// the running total catches a chunked or lying peer. The display bodies
  /// (a frame, a result document) all have a known ceiling, so nothing here
  /// needs to trust the device to stop sending.
  static Future<Uint8List> _readBounded(
    HttpClientResponse resp,
    int cap,
    String what,
  ) async {
    final declared = resp.contentLength;
    if (declared > cap) {
      throw MirrorApiException(
          '$what: the mirror announced $declared bytes, more than $cap');
    }
    final out = BytesBuilder(copy: false);
    await for (final chunk in resp) {
      if (out.length + chunk.length > cap) {
        throw MirrorApiException('$what: the mirror sent more than $cap bytes');
      }
      out.add(chunk);
    }
    return out.takeBytes();
  }

  /// Decodes a body that must be a JSON object. A JSON array, a scalar or
  /// invalid UTF-8 is a format failure like any other, not a cast error that
  /// escapes the normalisation in [_request].
  static Map<String, dynamic> _jsonObject(String what, Uint8List body) {
    final decoded = jsonDecode(utf8.decode(body));
    if (decoded is! Map<String, dynamic>) {
      throw MirrorApiException(
          '$what: the mirror answered with an unexpected document');
    }
    return decoded;
  }

  /// Maps a non-200 response to a [MirrorApiException], keeping the status
  /// code and, when the firmware sent one, its own reason text from
  /// `{"ok":false,"error":"..."}`.
  static MirrorApiException _rejection(
    String what,
    int status,
    Uint8List body,
  ) {
    String? reason;
    try {
      final decoded = jsonDecode(utf8.decode(body));
      if (decoded is Map && decoded['error'] is String) {
        reason = decoded['error'] as String;
      }
    } on FormatException {
      // Not a JSON rejection body; fall back to its raw text.
    }
    final text = (reason ?? utf8.decode(body, allowMalformed: true)).trim();
    return MirrorApiException(
      '$what: HTTP $status${text.isEmpty ? '' : ' $text'}',
      statusCode: status,
    );
  }

  /// Whether a TCP connection to the mirror's HTTP port can be opened right
  /// now. The Bluetooth link and the WiFi path are independent: a phone can
  /// hold a BLE session to a mirror it cannot reach at its LAN address, which
  /// a VPN that routes local traffic into its tunnel does, and so does a phone
  /// on another network. Anything that sends a body over WiFi asks this first,
  /// so the failure is named instead of surfacing as a socket timeout.
  Future<bool> reachable(
      {Duration timeout = const Duration(seconds: 4)}) async {
    final uri = _uri('/');
    try {
      final socket = await Socket.connect(uri.host, uri.port, timeout: timeout);
      socket.destroy();
      return true;
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  Future<MirrorStatus> status() async {
    final client = await _newClient();
    try {
      final req = await client.getUrl(_uri('/api/status')).timeout(_timeout);
      final resp = await req.close().timeout(_timeout);
      final body = await resp.transform(utf8.decoder).join().timeout(_timeout);
      if (resp.statusCode != 200) {
        throw MirrorApiException(
          'status: HTTP ${resp.statusCode} $body',
          statusCode: resp.statusCode,
        );
      }
      return MirrorStatus.fromJson(jsonDecode(body) as Map<String, dynamic>);
    } on SocketException catch (e) {
      throw MirrorApiException('could not reach $ip: ${e.message}');
    } on FormatException {
      throw MirrorApiException(
          'status: the mirror answered with unreadable JSON');
    } finally {
      client.close(force: true);
    }
  }

  Future<String> getLayout() async {
    final client = await _newClient();
    try {
      final req = await client.getUrl(_uri('/api/layout')).timeout(_timeout);
      final resp = await req.close().timeout(_timeout);
      final body = await resp.transform(utf8.decoder).join().timeout(_timeout);
      if (resp.statusCode != 200) {
        throw MirrorApiException(
          'layout: HTTP ${resp.statusCode} $body',
          statusCode: resp.statusCode,
        );
      }
      return body;
    } on SocketException catch (e) {
      throw MirrorApiException('could not reach $ip: ${e.message}');
    } finally {
      client.close(force: true);
    }
  }

  Future<PutLayoutResult> putLayout(String json) async {
    final client = await _newClient();
    try {
      final req = await client.putUrl(_uri('/api/layout')).timeout(_timeout);
      req.headers.contentType = ContentType('application', 'json');
      // The length has to be declared. Without it dart:io frames the body with
      // Transfer-Encoding: chunked, and ESP-IDF's httpd does not de-chunk
      // requests: it reports content_len 0 and the mirror answers 400 "empty
      // body", which reads here as unreadable JSON. A Dart HttpServer
      // de-chunks transparently, so a loopback test cannot catch this — see
      // the raw-socket case in the tests.
      final bytes = utf8.encode(json);
      req.contentLength = bytes.length;
      req.add(bytes);
      final resp = await req.close().timeout(_timeout);
      final body = await resp.transform(utf8.decoder).join().timeout(_timeout);

      final decoded = (jsonDecode(body) as Map<String, dynamic>?) ?? const {};
      final ok = resp.statusCode == 200;
      if (ok) {
        final diag = (decoded['diag'] as List<dynamic>? ?? const [])
            .map((d) => d.toString())
            .toList();
        return (ok: true, diag: diag, error: null) as PutLayoutResult;
      }
      return (
        ok: false,
        diag: const <String>[],
        error: decoded['error'] as String? ?? 'HTTP ${resp.statusCode}',
      ) as PutLayoutResult;
    } on SocketException catch (e) {
      throw MirrorApiException('could not reach $ip: ${e.message}');
    } on FormatException {
      throw MirrorApiException(
          'layout: the mirror answered with unreadable JSON');
    } finally {
      client.close(force: true);
    }
  }

  /// GET /api/frame: one frame the panel really showed, as `MRF1` plus RGB888.
  ///
  /// The bytes are the composited output — gamma corrected, brightness scaled
  /// and already rotated for a flipped panel — so a preview draws them as they
  /// arrive. The body is bounded to one frame and decoded strictly; a 503 means
  /// this poll found no frame (the render task is busy or the snapshot is
  /// unavailable), which the caller treats as "keep the last preview".
  Future<MirrorFrame> frame() => _request('frame', _timeout, (client) async {
        final req = await client.getUrl(_uri('/api/frame'));
        final resp = await req.close();
        final body = await _readBounded(resp, _frameBodyCap, 'frame');
        if (resp.statusCode != 200) {
          throw _rejection('frame', resp.statusCode, body);
        }
        return decodeMirrorFrame(body);
      });

  /// PUT /api/mode: save [mode] as the base display and report what the panel
  /// is showing.
  ///
  /// Only clock and picture can be saved; a game is a temporary BLE override,
  /// so [DisplayMode.games] is refused here without a request. The device
  /// commits the change before answering, so a returned [DisplayResult] means
  /// the choice survives a reboot. A 409 means picture mode was asked for with
  /// no stored image; the caller offers to upload one first.
  Future<DisplayResult> setDisplayMode(DisplayMode mode) async {
    if (mode == DisplayMode.games) {
      throw MirrorApiException(
          'mode: games are started over Bluetooth, not saved as a display');
    }
    return _request('mode', _timeout, (client) async {
      final req = await client.putUrl(_uri('/api/mode'));
      req.headers.contentType = ContentType('application', 'json');
      // Declared, not chunked: ESP-IDF's httpd does not de-chunk request
      // bodies. See putLayout for the raw-peer test that pins this.
      final bytes = utf8.encode('{"mode":"${displayModeName(mode)}"}');
      req.contentLength = bytes.length;
      req.add(bytes);
      final resp = await req.close();
      final body = await _readBounded(resp, _resultJsonCap, 'mode');
      if (resp.statusCode != 200) {
        throw _rejection('mode', resp.statusCode, body);
      }
      return DisplayResult.fromJson(_jsonObject('mode', body));
    });
  }

  /// POST /api/image: replace the mirror's one picture with [rgb] and make it
  /// the base display.
  ///
  /// [rgb] is raw, row-major, top-left RGB888 *before* the firmware's gamma
  /// transform, exactly `width * height * 3` bytes for the panel it was framed
  /// for: the picture encoder's output, never an encoded PNG/JPEG. Geometry and
  /// size are checked here, before a socket opens, so a stale prepared image
  /// cannot be sent behind headers that describe a different panel. The device
  /// validates the same numbers against its own panel and answers 409 when they
  /// no longer match.
  ///
  /// No retry: the caller re-reads the device's state after an uncertain
  /// failure instead of sending the picture twice.
  Future<DisplayResult> uploadPicture(
    Uint8List rgb, {
    required int width,
    required int height,
  }) async {
    if (width <= 0 || height <= 0) {
      throw MirrorApiException('picture: invalid panel size ${width}x$height');
    }
    final expected = width * height * 3;
    if (expected > mirrorFrameMaxPayloadBytes) {
      throw MirrorApiException(
          'picture: ${width}x$height is larger than the panel payload cap');
    }
    if (rgb.length != expected) {
      throw MirrorApiException(
          'picture: expected $expected bytes for ${width}x$height, '
          'got ${rgb.length}');
    }
    return _request('picture', _uploadTimeout, (client) async {
      final req = await client.postUrl(_uri('/api/image'));
      req.headers.contentType = ContentType('application', 'octet-stream');
      req.headers.set('X-Mirror-Width', '$width');
      req.headers.set('X-Mirror-Height', '$height');
      // The length is the picture: the firmware refuses any other value before
      // reading a byte, and httpd ignores a chunked body entirely.
      req.contentLength = rgb.length;
      req.add(rgb);
      final resp = await req.close();
      final body = await _readBounded(resp, _resultJsonCap, 'picture');
      if (resp.statusCode != 200) {
        throw _rejection('picture', resp.statusCode, body);
      }
      return DisplayResult.fromJson(_jsonObject('picture', body));
    });
  }

  /// Upload a firmware image from a file to POST /api/ota (the "choose file"
  /// fallback). Delegates to [uploadFirmwareBytes].
  Future<void> uploadFirmware(
    File file, {
    void Function(int sent, int total)? onProgress,
  }) async {
    await uploadFirmwareBytes(await file.readAsBytes(), onProgress: onProgress);
  }

  /// Upload raw firmware bytes to POST /api/ota, streaming in 64KB chunks.
  /// [onProgress] is called with (sent, total) after each chunk. Throws
  /// [MirrorApiException] on any non-200 response.
  Future<void> uploadFirmwareBytes(
    Uint8List bytes, {
    void Function(int sent, int total)? onProgress,
  }) async {
    final client = await _newClient();
    try {
      final req = await client.postUrl(_uri('/api/ota')).timeout(_timeout);
      req.headers.contentType = ContentType('application', 'octet-stream');
      req.contentLength = bytes.length;

      const chunkSize = 64 * 1024;
      for (var sent = 0; sent < bytes.length; sent += chunkSize) {
        final end =
            sent + chunkSize < bytes.length ? sent + chunkSize : bytes.length;
        req.add(Uint8List.sublistView(bytes, sent, end));
        onProgress?.call(end, bytes.length);
      }

      final resp = await req.close().timeout(_otaTimeout);
      final body = await resp.transform(utf8.decoder).join().timeout(_timeout);
      if (resp.statusCode != 200) {
        throw MirrorApiException(
          'update failed: HTTP ${resp.statusCode} $body',
          statusCode: resp.statusCode,
        );
      }
    } on SocketException catch (e) {
      throw MirrorApiException('could not reach $ip: ${e.message}');
    } finally {
      client.close(force: true);
    }
  }
}
