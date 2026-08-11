// MirrorLan against a real HttpServer on loopback: status parsing, layout
// GET/PUT round-trip (with a real stock layout, the same file the firmware
// embeds), diag/error mapping, and OTA upload byte-identity with monotonic
// progress. The fake server implements the same contract as
// firmware/main/net/api_server.c and net/ota.c.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/services/mirror_lan.dart';

class FakeMirror {
  FakeMirror();

  late final HttpServer server;
  String storedLayout = '';
  final List<int> receivedOta = <int>[];
  int putCount = 0;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
  }

  int get port => server.port;

  Future<void> close() async => server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    switch ('${req.method} ${req.uri.path}') {
      case 'GET /api/status':
        req.response.headers.contentType = ContentType('application', 'json');
        req.response.write(
          '{"version":"0.1.0","core":"v0.4.1","ip":"127.0.0.1","online":true,'
          '"rssi":-45,"uptime_s":1234,"layout":"mini","width":64,"height":32,'
          '"brightness":120}',
        );
        break;

      case 'GET /api/layout':
        req.response.headers.contentType = ContentType('application', 'json');
        req.response.write(storedLayout);
        break;

      case 'PUT /api/layout':
        final body = await utf8.decoder.bind(req).join();
        putCount++;
        try {
          jsonDecode(body); // the firmware rejects malformed JSON
        } on FormatException {
          req.response.statusCode = 400;
          req.response.headers.contentType =
              ContentType('application', 'json');
          req.response.write('{"ok":false,"error":"bad json"}');
          break;
        }
        storedLayout = body;
        req.response.headers.contentType = ContentType('application', 'json');
        req.response.write('{"ok":true,"diag":["note 1"]}');
        break;

      case 'POST /api/ota':
        await for (final chunk in req) {
          receivedOta.addAll(chunk);
        }
        req.response.headers.contentType = ContentType('application', 'json');
        req.response.write('{"ok":true}');
        break;

      default:
        req.response.statusCode = 404;
        break;
    }
    await req.response.close();
  }
}

// The layout file is the same mini.json the firmware embeds. Read from disk
// (no TestWidgetsFlutterBinding: its mocked HttpClient returns 400 for every
// request, which would defeat the real loopback server below).
const String miniLayoutPath = 'assets/layouts/mini.json';

Future<String> readMiniLayout() => File(miniLayoutPath).readAsString();

void main() {

  late FakeMirror fake;
  late MirrorLan lan;

  setUp(() async {
    fake = FakeMirror();
    await fake.start();
    lan = MirrorLan('127.0.0.1:${fake.port}');
  });

  tearDown(() async {
    await fake.close();
  });

  group('status', () {
    test('parses every field', () async {
      final s = await lan.status();
      expect(s.version, '0.1.0');
      expect(s.core, 'v0.4.1');
      expect(s.ip, '127.0.0.1');
      expect(s.online, isTrue);
      expect(s.rssi, -45);
      expect(s.uptime_s, 1234);
      expect(s.layout, 'mini');
      expect(s.width, 64);
      expect(s.height, 32);
      expect(s.brightness, 120);
    });
  });

  group('MirrorStatus.fromJson', () {
    test('tolerates a missing core field (older firmware)', () {
      final s = MirrorStatus.fromJson(<String, dynamic>{
        'version': '0.1.0',
        'ip': '127.0.0.1',
        'brightness': 120,
      });
      expect(s.version, '0.1.0');
      expect(s.core, '');
    });

    test('parses the core field when present', () {
      final s = MirrorStatus.fromJson(<String, dynamic>{
        'version': '0.2.0',
        'core': 'v0.5.0',
        'ip': '127.0.0.1',
      });
      expect(s.version, '0.2.0');
      expect(s.core, 'v0.5.0');
    });
  });

  group('layout', () {
    test('PUT sends the exact bytes of a real stock layout', () async {
      final mini = await readMiniLayout();

      final result = await lan.putLayout(mini);
      expect(result.ok, isTrue);
      expect(result.diag, <String>['note 1']);
      expect(result.error, isNull);
      expect(fake.storedLayout, mini, reason: 'server must store what was sent');
    });

    test('GET returns what was pushed', () async {
      final mini = await readMiniLayout();
      await lan.putLayout(mini);
      expect(await lan.getLayout(), mini);
    });

    test('malformed layout maps to ok:false with the server error', () async {
      final result = await lan.putLayout('{not json');
      expect(result.ok, isFalse);
      expect(result.error, 'bad json');
      expect(fake.putCount, 1);
    });
  });

  group('OTA', () {
    test('uploads byte-identical content with monotonic progress', () async {
      final dir = await Directory.systemTemp.createTemp('mirror_lan_test');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/smart_mirror.bin');
      // A distinctive pattern, larger than one 64KB chunk.
      final bytes = Uint8List(200 * 1024);
      for (var i = 0; i < bytes.length; i++) {
        bytes[i] = (i * 31 + 7) % 256;
      }
      await file.writeAsBytes(bytes, flush: true);

      final progress = <(int, int)>[];
      await lan.uploadFirmware(
        file,
        onProgress: (sent, total) => progress.add((sent, total)),
      );

      expect(fake.receivedOta, bytes, reason: 'server must receive the file verbatim');
      expect(progress, isNotEmpty);
      expect(progress.first.$1, greaterThan(0));
      expect(progress.last, (bytes.length, bytes.length));
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i].$1, greaterThan(progress[i - 1].$1),
            reason: 'progress must be monotonic');
        expect(progress[i].$2, bytes.length);
      }
    });
  });
}
