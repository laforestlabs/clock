// A fake mirror for exercising the Mirror screen without hardware.
//
// Implements the same LAN contract as firmware/main/net/api_server.c and
// ota.c: GET /api/status, GET|PUT /api/layout, POST /api/ota. Layouts are
// kept in memory; OTA reads the body and reports how many bytes arrived.
//
// Usage (from the designer directory):
//   dart run tool/fake_mirror.dart [port] [12-digit-device-id]
// Add its manual host:port through Add device. This is not hardware proof.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const String _miniJson = '''
{
  "name": "mini",
  "canvas": {"width": 64, "height": 32, "bg": "#000000", "brightness": 120},
  "widgets": []
}
''';

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? (int.tryParse(args.first) ?? 8080) : 8080;
  final id =
      args.length > 1 ? args[1] : port.toRadixString(16).padLeft(12, '0');
  if (!RegExp(r'^[0-9a-f]{12}$').hasMatch(id)) {
    throw ArgumentError(
        'Device ID must contain 12 lowercase hexadecimal digits');
  }
  var mode = 'clock';
  Uint8List? picture;
  var sequence = 0;

  Map<String, Object> displayResult() => {
        'ok': true,
        'mode': mode,
        'base_mode': mode,
        'picture_ready': picture != null,
      };
  void reply(HttpRequest req, int code, Object body) {
    req.response.statusCode = code;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
  }

  void reject(HttpRequest req, int code, String message) {
    req.response.persistentConnection = false;
    reply(req, code, {'ok': false, 'error': message});
  }

  String storedLayout = _miniJson;
  // Mutable panel brightness, mirroring panel_set_brightness on the device:
  // set at boot from the layout, updated when a layout push arrives.
  int brightness = 120;
  for (final candidate in <String>[
    'assets/layouts/mini.json', // run from the designer directory
    'layouts/mini.json', // run from the repository root
  ]) {
    try {
      final fromDisk = File(candidate);
      if (await fromDisk.exists()) {
        storedLayout = await fromDisk.readAsString();
        break;
      }
    } catch (_) {
      // Keep trying; the built-in fallback covers everything.
    }
  }

  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stdout.writeln('fake mirror listening on http://127.0.0.1:${server.port}');

  await for (final req in server) {
    try {
      switch ('${req.method} ${req.uri.path}') {
        case 'GET /api/status':
          reply(req, 200, {
            'version': 'fake',
            'core': 'fake-core',
            'ip': '127.0.0.1',
            'online': true,
            'rssi': -40,
            'uptime_s': 123,
            'layout': 'mini',
            'width': 64,
            'height': 32,
            'brightness': brightness,
            'id': id,
            'name': 'Mirror $id',
            'display_api': 1,
            'mode': mode,
            'base_mode': mode,
            'picture_ready': picture != null,
            'flip180': false,
          });
          break;

        case 'PUT /api/mode':
          if (req.contentLength <= 0 || req.contentLength > 64) {
            reject(req, 400, 'invalid mode body');
            break;
          }
          final body = jsonDecode(await utf8.decoder.bind(req).join());
          final requested = body is Map ? body['mode'] : null;
          if (requested != 'clock' && requested != 'picture') {
            reject(req, 400, 'unsupported mode');
          } else if (requested == 'picture' && picture == null) {
            reject(req, 409, 'picture missing');
          } else {
            mode = requested as String;
            reply(req, 200, displayResult());
          }
          break;

        case 'POST /api/image':
          if (req.headers.contentType?.mimeType != 'application/octet-stream') {
            reject(req, 415, 'wrong content type');
            break;
          }
          int? dimension(String name) {
            final value = req.headers.value(name) ?? '';
            return RegExp(r'^[0-9]+$').hasMatch(value)
                ? int.tryParse(value)
                : null;
          }
          final w = dimension('X-Mirror-Width');
          final h = dimension('X-Mirror-Height');
          if (w == null || h == null || w <= 0 || h <= 0) {
            reject(req, 400, 'invalid dimensions');
            break;
          }
          if (req.contentLength > 196608 || w * h * 3 > 196608) {
            reject(req, 413, 'image too large');
            break;
          }
          if (w != 64 || h != 32) {
            reject(req, 409, 'panel dimensions changed');
            break;
          }
          if (req.contentLength != w * h * 3) {
            reject(req, req.contentLength > w * h * 3 ? 413 : 400,
                'invalid body length');
            break;
          }
          final bytes = BytesBuilder(copy: false);
          await for (final chunk in req.timeout(const Duration(seconds: 30))) {
            bytes.add(chunk);
            if (bytes.length > w * h * 3) {
              throw const FormatException('image too large');
            }
          }
          if (bytes.length != w * h * 3) {
            reject(req, 400, 'truncated image');
            break;
          }
          picture = bytes.takeBytes();
          mode = 'picture';
          reply(req, 200, displayResult());
          break;

        case 'GET /api/frame':
          final frame = Uint8List(16 + 64 * 32 * 3);
          frame.setRange(0, 4, ascii.encode('MRF1'));
          final header = ByteData.sublistView(frame);
          header.setUint16(4, 64, Endian.little);
          header.setUint16(6, 32, Endian.little);
          header.setUint32(8, sequence++, Endian.little);
          frame[12] = brightness;
          frame[13] = mode == 'picture' ? 2 : 0;
          for (var y = 0; y < 32; y++) {
            for (var x = 0; x < 64; x++) {
              final offset = (y * 64 + x) * 3;
              for (var c = 0; c < 3; c++) {
                final input = mode == 'picture'
                    ? picture![offset + c]
                    : ((c == 0 && x < 21) ||
                            (c == 1 && y < 16) ||
                            (c == 2 && x >= 32 && y >= 16)
                        ? 255
                        : 0);
                final lightness = input / 255 * 100;
                final v = (lightness + 16) / 116;
                final gamma =
                    ((lightness <= 8 ? lightness / 903.3 : v * v * v) * 255)
                        .round();
                frame[16 + offset + c] = (gamma * brightness + 127) ~/ 255;
              }
            }
          }
          req.response.headers.contentType = ContentType.binary;
          req.response.headers.set('Cache-Control', 'no-store');
          req.response.contentLength = frame.length;
          req.response.add(frame);
          break;

        case 'GET /api/layout':
          req.response.headers.contentType = ContentType('application', 'json');
          req.response.write(storedLayout);
          break;

        case 'PUT /api/layout':
          final body = await utf8.decoder.bind(req).join();
          bool bad = false;
          try {
            final decoded = jsonDecode(body);
            if (decoded is! Map<String, dynamic>) {
              bad = true;
            } else {
              // Like the firmware: the layout's canvas brightness is applied
              // to the panel (the fake has no manual override, so the layout
              // always wins).
              final canvas = decoded['canvas'];
              final b =
                  canvas is Map<String, dynamic> ? canvas['brightness'] : null;
              if (b is int) brightness = b;
            }
          } on FormatException {
            bad = true;
          }
          if (bad) {
            req.response.statusCode = 400;
            req.response.headers.contentType =
                ContentType('application', 'json');
            req.response.write('{"ok":false,"error":"bad json"}');
            break;
          }
          storedLayout = body;
          stdout.writeln('received layout (${body.length} bytes): $body');
          req.response.headers.contentType = ContentType('application', 'json');
          req.response.write('{"ok":true,"diag":[]}');
          break;

        default:
          req.response.statusCode = 404;
          req.response.write('not found');
          break;
      }
    } on FormatException catch (e) {
      reject(req, 400, e.message);
    } catch (e) {
      stdout.writeln('error handling ${req.method} ${req.uri.path}: $e');
      reject(req, 500, 'request failed');
    } finally {
      await req.response.close();
    }
  }
}
