// MirrorLan against a real HttpServer on loopback: status parsing, layout
// GET/PUT round-trip (with a real stock layout, the same file the firmware
// embeds), diag/error mapping, and OTA upload byte-identity with monotonic
// progress. The fake server implements the same contract as
// firmware/main/net/api_server.c and net/ota.c.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/services/mirror_display.dart';
import 'package:mirror_designer/src/services/mirror_lan.dart';

class FakeMirror {
  FakeMirror();

  late final HttpServer server;
  String storedLayout = '';
  final List<int> receivedOta = <int>[];
  int putCount = 0;

  /// What ESP-IDF's httpd computes from the request head. A chunked body has
  /// no length, and httpd_parse.c maps that to content_len 0, which the layout
  /// handler answers with 400 "empty body". Dart's HttpServer de-chunks
  /// transparently, so these are recorded rather than inferred.
  int? putContentLength;
  String? putTransferEncoding;

  // --- the display contract: /api/mode, /api/image, /api/frame ---
  //
  // The same shape as firmware/main/net/api_server.c: clock/picture only,
  // picture mode needs a stored image, uploads must declare the exact frame,
  // and a frame is served only when one exists.

  int panelWidth = 64;
  int panelHeight = 32;
  String baseMode = 'clock';
  bool gameActive = false;
  Uint8List? picture;
  Uint8List? frameBody;
  int modeCalls = 0;
  int imageCalls = 0;
  int frameCalls = 0;
  int? modeContentLength;
  String? modeTransferEncoding;
  int? imageContentLength;
  String? imageTransferEncoding;
  String? imageContentType;
  String? imageWidthHeader;
  String? imageHeightHeader;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
  }

  int get port => server.port;

  Future<void> close() async => server.close(force: true);

  /// The effective display is games while one is live, the saved base
  /// otherwise — the distinction the app relies on to avoid claiming a game
  /// changed the saved picture.
  String displayResult() =>
      '{"ok":true,"mode":"${gameActive ? 'games' : baseMode}",'
      '"base_mode":"$baseMode","picture_ready":${picture != null}}';

  static String jsonError(String reason) => '{"ok":false,"error":"$reason"}';

  Future<void> _reject(HttpRequest req, int status, String reason) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType('application', 'json');
    req.response.write(jsonError(reason));
  }

  Future<void> _handle(HttpRequest req) async {
    // A test that checks early rejection closes the connection while this
    // handler is still writing the body (an oversized frame, a refused
    // upload). That is the client behaving correctly, not a fixture failure.
    try {
      await _dispatch(req);
      await req.response.close();
    } on SocketException {
      // peer went away mid-response
    } on HttpException {
      // peer went away mid-response
    }
  }

  Future<void> _dispatch(HttpRequest req) async {
    switch ('${req.method} ${req.uri.path}') {
      case 'GET /api/status':
        req.response.headers.contentType = ContentType('application', 'json');
        req.response.write(
          '{"version":"0.1.0","core":"v0.4.1","ip":"127.0.0.1","online":true,'
          '"rssi":-45,"uptime_s":1234,"layout":"mini",'
          '"width":$panelWidth,"height":$panelHeight,'
          '"brightness":120,"id":"aabbccddeeff","name":"Mirror",'
          '"display_api":1,"mode":"${gameActive ? 'games' : baseMode}",'
          '"base_mode":"$baseMode","picture_ready":${picture != null},'
          '"flip180":false}',
        );
        break;

      case 'GET /api/layout':
        req.response.headers.contentType = ContentType('application', 'json');
        req.response.write(storedLayout);
        break;

      case 'PUT /api/layout':
        putContentLength = req.contentLength;
        putTransferEncoding = req.headers.value('transfer-encoding');
        final body = await utf8.decoder.bind(req).join();
        putCount++;
        try {
          jsonDecode(body); // the firmware rejects malformed JSON
        } on FormatException {
          await _reject(req, 400, 'bad json');
          break;
        }
        storedLayout = body;
        req.response.headers.contentType = ContentType('application', 'json');
        req.response.write('{"ok":true,"diag":["note 1"]}');
        break;

      case 'PUT /api/mode':
        modeCalls++;
        modeContentLength = req.contentLength;
        modeTransferEncoding = req.headers.value('transfer-encoding');
        if (req.contentLength > 64) {
          await _reject(req, 400, 'mode body must be at most 64 bytes');
          break;
        }
        final modeBody = await utf8.decoder.bind(req).join();
        String? mode;
        try {
          final decoded = jsonDecode(modeBody);
          if (decoded is Map) mode = decoded['mode'] as String?;
        } on FormatException {
          mode = null;
        }
        if (mode != 'clock' && mode != 'picture') {
          await _reject(req, 400, 'unsupported mode');
          break;
        }
        if (mode == 'picture' && picture == null) {
          await _reject(req, 409, 'picture missing');
          break;
        }
        baseMode = mode!;
        req.response.headers.contentType = ContentType('application', 'json');
        req.response.write(displayResult());
        break;

      case 'POST /api/image':
        imageCalls++;
        imageContentLength = req.contentLength;
        imageTransferEncoding = req.headers.value('transfer-encoding');
        imageContentType = req.headers.contentType?.mimeType;
        imageWidthHeader = req.headers.value('X-Mirror-Width');
        imageHeightHeader = req.headers.value('X-Mirror-Height');
        final width = int.tryParse(imageWidthHeader ?? '');
        final height = int.tryParse(imageHeightHeader ?? '');
        if (imageContentType != 'application/octet-stream') {
          await _reject(
              req, 415, 'content type must be application/octet-stream');
          break;
        }
        if (width == null || width < 1 || height == null || height < 1) {
          await _reject(req, 400, 'invalid dimensions');
          break;
        }
        final expected = width * height * 3;
        if (expected > 196608) {
          await _reject(req, 413, 'picture exceeds the 256x256 payload cap');
          break;
        }
        if (width != panelWidth || height != panelHeight) {
          await _reject(req, 409, 'panel dimensions changed');
          break;
        }
        if (req.contentLength <= 0) {
          await _reject(req, 400, 'empty body');
          break;
        }
        if (req.contentLength > expected) {
          await _reject(
              req, 413, 'body is longer than the declared dimensions');
          break;
        }
        if (req.contentLength < expected) {
          await _reject(
              req, 400, 'body is shorter than the declared dimensions');
          break;
        }
        final received = <int>[];
        await for (final chunk in req) {
          received.addAll(chunk);
        }
        if (received.length != expected) {
          await _reject(req, 400, 'incomplete request');
          break;
        }
        picture = Uint8List.fromList(received);
        baseMode = 'picture';
        req.response.headers.contentType = ContentType('application', 'json');
        req.response.write(displayResult());
        break;

      case 'GET /api/frame':
        frameCalls++;
        final frame = frameBody;
        if (frame == null) {
          await _reject(req, 503, 'snapshot unavailable');
          break;
        }
        req.response.headers.contentType =
            ContentType('application', 'octet-stream');
        req.response.headers.set('Cache-Control', 'no-store');
        req.response.add(frame);
        break;

      default:
        req.response.statusCode = 404;
        break;
    }
  }
}

/// One request exactly as it arrived on the wire, before any HTTP library
/// de-chunks or re-frames it.
class RawRequest {
  RawRequest(this.requestLine, this.headers, this.body);

  final String requestLine;
  final Map<String, String> headers;
  final Uint8List body;
}

int _headEnd(List<int> bytes) {
  for (var i = 0; i + 3 < bytes.length; i++) {
    if (bytes[i] == 13 &&
        bytes[i + 1] == 10 &&
        bytes[i + 2] == 13 &&
        bytes[i + 3] == 10) {
      return i + 4;
    }
  }
  return -1;
}

/// Reads one HTTP/1.1 request from [socket]: the head, then exactly the
/// declared Content-Length bytes of body.
///
/// A Dart HttpServer de-chunks request bodies transparently, so it cannot show
/// that a client framed one at all. ESP-IDF's httpd does not de-chunk: a
/// chunked upload arrives with content_len 0 and is refused as empty. Only a
/// raw peer can see which of the two the app did.
Future<RawRequest> readRawRequest(Socket socket) {
  final all = <int>[];
  final done = Completer<RawRequest>();
  late StreamSubscription<Uint8List> sub;
  sub = socket.listen((chunk) {
    all.addAll(chunk);
    if (done.isCompleted) return;
    final headEnd = _headEnd(all);
    if (headEnd < 0) return;
    final lines = ascii.decode(all.sublist(0, headEnd)).split('\r\n');
    final headers = <String, String>{};
    for (final line in lines.skip(1)) {
      final colon = line.indexOf(':');
      if (colon > 0) {
        headers[line.substring(0, colon).trim().toLowerCase()] =
            line.substring(colon + 1).trim();
      }
    }
    final length = int.tryParse(headers['content-length'] ?? '') ?? 0;
    if (all.length < headEnd + length) return;
    done.complete(RawRequest(
      lines.first,
      headers,
      Uint8List.fromList(all.sublist(headEnd, headEnd + length)),
    ));
    sub.cancel();
  }, onError: (Object error) {
    if (!done.isCompleted) done.completeError(error);
  });
  return done.future;
}

/// Answers the next connection on [server] with [response] after recording how
/// the request was framed.
Future<RawRequest> serveOnce(ServerSocket server, String response) async {
  final socket = await server.first;
  final request = await readRawRequest(socket);
  socket.write(response);
  await socket.flush();
  await socket.close();
  return request;
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

  test('unknown display modes never imply clock or a games base', () {
    final unknown = MirrorStatus.fromJson(<String, dynamic>{
      'mode': 'future-mode',
      'base_mode': 'games',
    });
    expect(unknown.mode, isNull);
    expect(unknown.baseMode, isNull);
    expect(unknown.displayApi, 0);
  });

  group('layout', () {
    test('PUT sends the exact bytes of a real stock layout', () async {
      final mini = await readMiniLayout();

      final result = await lan.putLayout(mini);
      expect(result.ok, isTrue);
      expect(result.diag, <String>['note 1']);
      expect(result.error, isNull);
      expect(fake.storedLayout, mini,
          reason: 'server must store what was sent');
    });

    // The mirror's httpd does not de-chunk request bodies: a chunked PUT
    // arrives with content_len 0 and is refused as an empty body, which reads
    // in the app as unreadable JSON. Assert the framing, not just the bytes —
    // a loopback Dart server de-chunks and would hide it.
    test('PUT declares its length instead of using chunked encoding', () async {
      final mini = await readMiniLayout();
      await lan.putLayout(mini);

      expect(fake.putTransferEncoding, isNull);
      expect(fake.putContentLength, utf8.encode(mini).length);
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

  group('reachable', () {
    test('true against a mirror that answers', () async {
      expect(await lan.reachable(), isTrue);
    });

    test('false when nothing is listening on that port', () async {
      // Learn a free port, then close it: a closed loopback port refuses
      // immediately, which is the "wrong address, or the mirror is down" case.
      final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final dead = MirrorLan('127.0.0.1:${probe.port}');
      await probe.close(force: true);

      expect(
          await dead.reachable(timeout: const Duration(seconds: 2)), isFalse);
    });

    test('false when the packets go nowhere', () async {
      // TEST-NET-1 (RFC 5737) routes nowhere, so the connect fails or times
      // out — both mean unreachable. This is the shape of the failure a VPN
      // that captures the LAN produces: the phone is connected, the Bluetooth
      // link works, and the SYN disappears into the tunnel.
      final tunneled = MirrorLan('192.0.2.1:80');

      expect(
        await tunneled.reachable(timeout: const Duration(milliseconds: 500)),
        isFalse,
      );
    });
  });

  group('frame', () {
    test('decodes a real MRF1 body from the device', () async {
      final expected = sampleFrame(sequence: 42);
      fake.frameBody = encodeMirrorFrame(expected);

      final frame = await lan.frame();

      expect(frame.width, 64);
      expect(frame.height, 32);
      expect(frame.sequence, 42);
      expect(frame.brightness, 200);
      expect(frame.mode, DisplayMode.picture);
      expect(frame.flip180, isTrue);
      expect(frame.rgb, expected.rgb);
      expect(fake.frameCalls, 1);
    });

    test('takes its geometry from the frame header, not a status body',
        () async {
      // The status describes a 64x32 panel; this frame is an 8x8 one. Reading
      // the pixels with the status geometry would show invented data.
      fake.frameBody = encodeMirrorFrame(sampleFrame(width: 8, height: 8));

      expect((await lan.status()).width, 64);
      final frame = await lan.frame();

      expect(frame.width, 8);
      expect(frame.height, 8);
      expect(frame.rgb.length, 8 * 8 * 3);
    });

    test('maps a missing snapshot to a 503 with the firmware reason', () async {
      fake.frameBody = null;

      await expectLater(
        lan.frame(),
        throwsA(isA<MirrorApiException>()
            .having((e) => e.statusCode, 'statusCode', 503)
            .having(
                (e) => e.message, 'message', contains('snapshot unavailable'))),
      );
      expect(fake.frameCalls, 1, reason: 'a preview poll is never retried');
    });

    test('rejects a truncated body', () async {
      final full = encodeMirrorFrame(sampleFrame());
      fake.frameBody = Uint8List.sublistView(full, 0, full.length - 4);

      await expectLater(lan.frame(), throwsA(isA<MirrorApiException>()));
    });

    test('rejects a body that is not MRF1', () async {
      final full = encodeMirrorFrame(sampleFrame());
      fake.frameBody = Uint8List.fromList(full)..[0] = 0x00;

      await expectLater(lan.frame(), throwsA(isA<MirrorApiException>()));
    });

    test('rejects an unknown display mode byte', () async {
      final full = encodeMirrorFrame(sampleFrame());
      fake.frameBody = Uint8List.fromList(full)..[13] = 9;

      await expectLater(lan.frame(), throwsA(isA<MirrorApiException>()));
    });

    test('refuses a frame past the payload cap without reading it all',
        () async {
      // 300x300 declares 270016 bytes, past the 256x256 cap. The announced
      // length is refused before the pixels are buffered.
      final body = Uint8List(16 + 300 * 300 * 3);
      final data = ByteData.sublistView(body);
      data.setUint8(0, 0x4d);
      data.setUint8(1, 0x52);
      data.setUint8(2, 0x46);
      data.setUint8(3, 0x31);
      data.setUint16(4, 300, Endian.little);
      data.setUint16(6, 300, Endian.little);
      fake.frameBody = body;

      await expectLater(lan.frame(), throwsA(isA<MirrorApiException>()));
    });

    test('normalises an unreachable mirror to its own failure type', () async {
      final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final dead = MirrorLan('127.0.0.1:${probe.port}');
      await probe.close(force: true);

      await expectLater(dead.frame(), throwsA(isA<MirrorApiException>()));
    });
  });

  group('mode', () {
    test('sends a declared small body and reports the committed display',
        () async {
      final result = await lan.setDisplayMode(DisplayMode.clock);

      expect(result.mode, DisplayMode.clock);
      expect(result.baseMode, DisplayMode.clock);
      expect(result.pictureReady, isFalse);
      expect(fake.modeTransferEncoding, isNull,
          reason: 'httpd does not de-chunk a request body');
      expect(fake.modeContentLength, utf8.encode('{"mode":"clock"}').length);
      expect(fake.modeCalls, 1);
    });

    test('reports games as effective while the base display stays clock',
        () async {
      fake.gameActive = true;

      final result = await lan.setDisplayMode(DisplayMode.clock);

      expect(result.mode, DisplayMode.games);
      expect(result.baseMode, DisplayMode.clock);
    });

    test('picture without a stored image is a 409 that changes nothing',
        () async {
      await expectLater(
        lan.setDisplayMode(DisplayMode.picture),
        throwsA(isA<MirrorApiException>()
            .having((e) => e.statusCode, 'statusCode', 409)
            .having((e) => e.message, 'message', contains('picture missing'))),
      );
      expect(fake.baseMode, 'clock');
      expect(fake.modeCalls, 1, reason: 'a mutation is never retried');
    });

    test('selects a stored picture', () async {
      fake.picture = Uint8List(64 * 32 * 3);
      fake.baseMode = 'clock';

      final result = await lan.setDisplayMode(DisplayMode.picture);

      expect(result.mode, DisplayMode.picture);
      expect(result.baseMode, DisplayMode.picture);
      expect(result.pictureReady, isTrue);
      expect(fake.baseMode, 'picture');
    });

    test('never asks the device to save a game as the base display', () async {
      await expectLater(lan.setDisplayMode(DisplayMode.games),
          throwsA(isA<MirrorApiException>()));

      expect(fake.modeCalls, 0);
    });

    test('maps an unreadable result document to a format failure', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close());
      final served = serveOnce(
        server,
        'HTTP/1.1 200 OK\r\n'
        'Content-Type: application/json\r\n'
        'Content-Length: 5\r\n'
        'Connection: close\r\n'
        '\r\n'
        '{oops',
      );

      await expectLater(
        MirrorLan('127.0.0.1:${server.port}').setDisplayMode(DisplayMode.clock),
        throwsA(isA<MirrorApiException>()),
      );
      final request = await served;
      expect(request.requestLine, 'PUT /api/mode HTTP/1.1');
      expect(request.headers['content-length'], '16');
    });
  });

  group('image', () {
    test('uploads the exact frame with declared geometry', () async {
      final rgb = pictureBytes(64, 32);

      final result = await lan.uploadPicture(rgb, width: 64, height: 32);

      expect(result.mode, DisplayMode.picture);
      expect(result.baseMode, DisplayMode.picture);
      expect(result.pictureReady, isTrue);
      expect(fake.picture, rgb,
          reason: 'the device must receive the pixels verbatim');
      expect(fake.imageContentLength, rgb.length);
      expect(fake.imageTransferEncoding, isNull);
      expect(fake.imageContentType, 'application/octet-stream');
      expect(fake.imageWidthHeader, '64');
      expect(fake.imageHeightHeader, '32');
      expect(fake.imageCalls, 1);
    });

    test('rejects geometry that does not match the bytes before sending',
        () async {
      final rgb = pictureBytes(64, 32);

      await expectLater(lan.uploadPicture(Uint8List(10), width: 64, height: 32),
          throwsA(isA<MirrorApiException>()));
      await expectLater(lan.uploadPicture(rgb, width: 0, height: 32),
          throwsA(isA<MirrorApiException>()));
      await expectLater(lan.uploadPicture(rgb, width: 64, height: -1),
          throwsA(isA<MirrorApiException>()));
      // Past the 256x256 cap: a picture prepared for a larger panel must not
      // reach a device that cannot hold it.
      await expectLater(
        lan.uploadPicture(Uint8List(400 * 400 * 3), width: 400, height: 400),
        throwsA(isA<MirrorApiException>()),
      );

      expect(fake.imageCalls, 0,
          reason: 'a stale prepared picture must not be sent at all');
    });

    test('a panel that changed under the app is a 409 the caller can act on',
        () async {
      fake.panelWidth = 80;
      fake.panelHeight = 40;

      await expectLater(
        lan.uploadPicture(pictureBytes(64, 32), width: 64, height: 32),
        throwsA(isA<MirrorApiException>()
            .having((e) => e.statusCode, 'statusCode', 409)
            .having((e) => e.message, 'message',
                contains('panel dimensions changed'))),
      );
      expect(fake.picture, isNull, reason: 'nothing was stored');
      expect(fake.imageCalls, 1, reason: 'an upload is never retried');
    });

    test('declares the exact Content-Length instead of chunked encoding',
        () async {
      // The raw peer sees the framing ESP-IDF's httpd sees. A chunked body
      // would arrive with content_len 0 and be refused as an empty upload,
      // which a Dart HttpServer would hide.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close());
      const result =
          '{"ok":true,"mode":"picture","base_mode":"picture","picture_ready":true}';
      final served = serveOnce(
        server,
        'HTTP/1.1 200 OK\r\n'
        'Content-Type: application/json\r\n'
        'Content-Length: ${utf8.encode(result).length}\r\n'
        'Connection: close\r\n'
        '\r\n'
        '$result',
      );
      final rgb = pictureBytes(64, 32);

      final display = await MirrorLan('127.0.0.1:${server.port}')
          .uploadPicture(rgb, width: 64, height: 32);
      final request = await served;

      expect(request.requestLine, 'POST /api/image HTTP/1.1');
      expect(request.headers['transfer-encoding'], isNull,
          reason: 'the mirror cannot de-chunk a request body');
      expect(request.headers['content-length'], '${rgb.length}');
      expect(request.headers['x-mirror-width'], '64');
      expect(request.headers['x-mirror-height'], '32');
      expect(request.body, rgb);
      expect(display.mode, DisplayMode.picture);
      expect(display.baseMode, DisplayMode.picture);
    });
  });
}

/// An asymmetric RGB888 frame, the shape a panel actually sends.
MirrorFrame sampleFrame({int width = 64, int height = 32, int sequence = 5}) {
  final rgb = Uint8List(width * height * 3);
  for (var i = 0; i < rgb.length; i++) {
    rgb[i] = i % 251;
  }
  return MirrorFrame(
    width: width,
    height: height,
    sequence: sequence,
    brightness: 200,
    mode: DisplayMode.picture,
    flip180: true,
    rgb: rgb,
  );
}

/// Distinctive pre-gamma RGB888 for a [width]x[height] panel.
Uint8List pictureBytes(int width, int height) {
  final rgb = Uint8List(width * height * 3);
  for (var i = 0; i < rgb.length; i++) {
    rgb[i] = (i * 7) % 256;
  }
  return rgb;
}
