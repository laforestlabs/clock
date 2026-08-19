// The mirror's LAN API client (dart:io only, no HTTP package).
//
// The firmware serves three endpoints on the station interface:
//   GET  /api/status   device state
//   GET  /api/layout   the current layout as JSON
//   PUT  /api/layout   push a new layout
//   POST /api/ota      upload a firmware image (the app partition .bin)
//
// The layout bytes are the designer's exportJson() output: the exact JSON
// the preview renders. Plain HTTP on a home LAN, no authentication, which is
// the same trust model as the mirror itself.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  factory MirrorStatus.fromJson(Map<String, dynamic> json) {
    int asInt(dynamic v, int fallback) =>
        v is num ? v.toInt() : fallback;
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

  Uri _uri(String path) => Uri.parse('http://$ip$path');

  /// One HttpClient per call, closed afterwards, so a screen full of devices
  /// cannot leak sockets while it sits idle.
  Future<HttpClient> _newClient() async {
    final client = HttpClient()
      ..connectionTimeout = _timeout;
    return client;
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
      throw MirrorApiException('status: the mirror answered with unreadable JSON');
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
      req.add(utf8.encode(json));
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
      throw MirrorApiException('layout: the mirror answered with unreadable JSON');
    } finally {
      client.close(force: true);
    }
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
