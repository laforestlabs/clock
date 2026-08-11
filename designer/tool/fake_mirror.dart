// A fake mirror for exercising the Mirror screen without hardware.
//
// Implements the same LAN contract as firmware/main/net/api_server.c and
// ota.c: GET /api/status, GET|PUT /api/layout, POST /api/ota. Layouts are
// kept in memory; OTA reads the body and reports how many bytes arrived.
//
// Usage (from the designer directory):
//   dart run tool/fake_mirror.dart [port]     # default 8080
// then in the app's Mirror screen: add manual IP 127.0.0.1:8080.

import 'dart:convert';
import 'dart:io';

const String _miniJson = '''
{
  "name": "mini",
  "canvas": {"width": 64, "height": 32, "bg": "#000000", "brightness": 120},
  "widgets": []
}
''';

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? (int.tryParse(args.first) ?? 8080) : 8080;

  String storedLayout = _miniJson;
  // Mutable panel brightness, mirroring panel_set_brightness on the device:
  // set at boot from the layout, updated when a layout push arrives.
  int brightness = 120;
  for (final candidate in <String>[
    'assets/layouts/mini.json', // run from the designer directory
    'layouts/mini.json',        // run from the repository root
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
          req.response.headers.contentType = ContentType('application', 'json');
          req.response.write(
            '{"version":"fake","core":"fake-core","ip":"127.0.0.1",'
            '"online":true,"rssi":-40,"uptime_s":123,"layout":"mini",'
            '"width":64,"height":32,"brightness":$brightness}',
          );
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
              final b = canvas is Map<String, dynamic> ? canvas['brightness'] : null;
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

        case 'POST /api/ota':
          var count = 0;
          await for (final chunk in req) {
            count += chunk.length;
          }
          stdout.writeln('received firmware, $count bytes');
          req.response.headers.contentType = ContentType('application', 'json');
          req.response.write('{"ok":true}');
          break;

        default:
          req.response.statusCode = 404;
          req.response.write('not found');
          break;
      }
    } catch (e) {
      stdout.writeln('error handling ${req.method} ${req.uri.path}: $e');
      req.response.statusCode = 500;
    } finally {
      await req.response.close();
    }
  }
}
