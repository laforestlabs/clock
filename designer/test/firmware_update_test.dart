// Which mirror gets offered an update, and the upload that follows it.
//
// The comparison decides whether the app prompts at all, so it is pinned here
// and not only through the prompt: a wrong answer either nags a mirror that is
// already current or silently never offers the update the app was built to
// carry.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/services/firmware_update.dart';

void main() {
  group('compareFirmwareVersions', () {
    test('orders dotted versions numerically, not as text', () {
      expect(compareFirmwareVersions('0.2.32', '0.2.33'), lessThan(0));
      expect(compareFirmwareVersions('0.2.33', '0.2.32'), greaterThan(0));
      expect(compareFirmwareVersions('0.2.33', '0.2.33'), 0);
      // Text order would put 0.2.9 above 0.2.10.
      expect(compareFirmwareVersions('0.2.9', '0.2.10'), lessThan(0));
      expect(compareFirmwareVersions('0.10.0', '0.9.9'), greaterThan(0));
      expect(compareFirmwareVersions('1.0.0', '0.99.99'), greaterThan(0));
    });

    test('a missing field counts as zero', () {
      expect(compareFirmwareVersions('0.2', '0.2.0'), 0);
      expect(compareFirmwareVersions('0.2', '0.2.1'), lessThan(0));
      expect(compareFirmwareVersions('1', '0.9.9'), greaterThan(0));
    });
  });

  group('firmwareUpdateAvailable', () {
    test('offers the update to a mirror that is behind', () {
      expect(
        firmwareUpdateAvailable(
            deviceVersion: '0.2.32', bundledVersion: '0.2.33'),
        isTrue,
      );
      expect(
        firmwareUpdateAvailable(
            deviceVersion: '0.1.9', bundledVersion: '0.2.33'),
        isTrue,
      );
    });

    test('leaves a current or newer mirror alone', () {
      expect(
        firmwareUpdateAvailable(
            deviceVersion: '0.2.33', bundledVersion: '0.2.33'),
        isFalse,
      );
      expect(
        firmwareUpdateAvailable(
            deviceVersion: '0.3.0', bundledVersion: '0.2.33'),
        isFalse,
      );
    });

    test('refuses a version it cannot read instead of guessing', () {
      // A mirror whose version does not parse is unknown, not old: offering to
      // replace it would be a claim about which build is newer.
      for (final unknown in <String>['', 'dev', '0.2.33-rc1', 'v0.2.33']) {
        expect(
          firmwareUpdateAvailable(
              deviceVersion: unknown, bundledVersion: '0.2.33'),
          isFalse,
          reason: 'device "$unknown"',
        );
        expect(
          firmwareUpdateAvailable(
              deviceVersion: '0.2.0', bundledVersion: unknown),
          isFalse,
          reason: 'bundled "$unknown"',
        );
      }
    });
  });

  group('uploadFirmwareAndWait', () {
    late _FakeMirror mirror;
    setUp(() async {
      mirror = _FakeMirror();
      await mirror.start();
    });
    tearDown(() => mirror.close());

    Uint8List image([int length = 200000]) =>
        Uint8List.fromList(List<int>.generate(length, (i) => i & 0xFF));

    test('sends every byte and returns the version the mirror comes back on',
        () async {
      final bytes = image();
      final progress = <double>[];

      final status = await uploadFirmwareAndWait(
        mirror.address,
        bytes,
        onProgress: (sent, total) => progress.add(sent / total),
        rebootTimeout: const Duration(seconds: 5),
        pollInterval: const Duration(milliseconds: 20),
      );

      expect(mirror.receivedOta, bytes,
          reason: 'the whole image, byte for byte');
      expect(progress, isNotEmpty);
      expect(progress.last, 1.0);
      expect(status?.version, '9.9.9',
          reason: 'the version read back after the reboot');
    });

    test('reports no answer when the mirror never comes back', () async {
      mirror.statusFails = true;

      final status = await uploadFirmwareAndWait(
        mirror.address,
        image(1024),
        rebootTimeout: const Duration(milliseconds: 300),
        pollInterval: const Duration(milliseconds: 50),
      );

      expect(status, isNull);
      expect(mirror.receivedOta, isNotEmpty,
          reason: 'the image was still written');
    });
  });
}

/// A mirror on the LAN: the two endpoints the update path uses, and the image
/// it was sent. The same contract as firmware/main/net/ota.c and api_server.c.
class _FakeMirror {
  late final HttpServer server;
  final List<int> receivedOta = <int>[];
  String version = '9.9.9';
  bool statusFails = false;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      switch ('${req.method} ${req.uri.path}') {
        case 'POST /api/ota':
          receivedOta.addAll(await req.fold<List<int>>(
              <int>[], (all, chunk) => all..addAll(chunk)));
          req.response.write(jsonEncode(<String, bool>{'ok': true}));
        case 'GET /api/status':
          if (statusFails) {
            req.response.statusCode = 500;
          } else {
            req.response.headers.contentType =
                ContentType('application', 'json');
            req.response.write(jsonEncode(<String, dynamic>{'version': version}));
          }
        default:
          req.response.statusCode = 404;
      }
      await req.response.close();
    });
  }

  String get address => '127.0.0.1:${server.port}';

  Future<void> close() => server.close(force: true);
}
