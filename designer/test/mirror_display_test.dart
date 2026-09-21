// The display vocabulary shared by GET /api/status
// (firmware/main/net/api_server.c) and the BLE `device {...}` reply
// (firmware/main/net/ble.c), plus the status body's new capability fields.
//
// The property under test is the clock/games/picture distinction: unknown
// words must not be guessed as the clock, and "games" — a temporary override
// the renderer restores from — must never be read as a saved base display.
// No device needed.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/services/mirror_display.dart';
import 'package:mirror_designer/src/services/mirror_lan.dart';

void main() {
  group('parseDisplayMode', () {
    test('reads the three firmware words', () {
      expect(parseDisplayMode('clock'), DisplayMode.clock);
      expect(parseDisplayMode('games'), DisplayMode.games);
      expect(parseDisplayMode('picture'), DisplayMode.picture);
    });

    test('an unknown or missing word is null, not clock', () {
      expect(parseDisplayMode('slideshow'), isNull);
      expect(parseDisplayMode('Clock'), isNull);
      expect(parseDisplayMode(''), isNull);
      expect(parseDisplayMode(null), isNull);
    });
  });

  group('parseBaseDisplayMode', () {
    test('clock and picture are base displays', () {
      expect(parseBaseDisplayMode('clock'), DisplayMode.clock);
      expect(parseBaseDisplayMode('picture'), DisplayMode.picture);
    });

    test('a game is never a base display', () {
      expect(parseBaseDisplayMode('games'), isNull);
    });

    test('an unknown base word is null', () {
      expect(parseBaseDisplayMode('photo'), isNull);
      expect(parseBaseDisplayMode(null), isNull);
    });
  });

  group('parseDeviceInfoLine', () {
    test('parses the identity reply', () {
      final info = parseDeviceInfoLine(
          'device {"id":"a1b2c3d4e5f6","display_api":1,'
          '"mode":"games","base_mode":"picture","picture_ready":true}');
      expect(info, isNotNull);
      expect(info!.id, 'a1b2c3d4e5f6');
      expect(info.displayApi, 1);
      expect(info.mode, DisplayMode.games);
      expect(info.baseMode, DisplayMode.picture);
      expect(info.pictureReady, isTrue);
    });

    test('reports an unknown mode as null, and games never as the base', () {
      final info = parseDeviceInfoLine(
          'device {"id":"a1b2c3d4e5f6","display_api":1,'
          '"mode":"hologram","base_mode":"games"}');
      expect(info!.mode, isNull);
      expect(info.baseMode, isNull);
    });

    test('a missing capability field reads as an older firmware', () {
      final info = parseDeviceInfoLine('device {"id":"a1b2c3d4e5f6"}');
      expect(info!.displayApi, 0);
      expect(info.mode, isNull);
      expect(info.baseMode, isNull);
      expect(info.pictureReady, isFalse);
    });

    test('other status lines are not an identity', () {
      expect(parseDeviceInfoLine('pong 0.2.30 10.0.0.5 mini 64 32'), isNull);
      expect(parseDeviceInfoLine('game over 3'), isNull);
      expect(parseDeviceInfoLine('unknown command'), isNull);
    });

    test('a reply without an id is not an identity', () {
      expect(parseDeviceInfoLine('device {"display_api":1}'), isNull);
      expect(parseDeviceInfoLine('device {"id":""}'), isNull);
      expect(parseDeviceInfoLine('device not json'), isNull);
    });
  });

  group('MirrorStatus capability fields', () {
    /// A pre-identity firmware body: the same fields the app has always read.
    Map<String, dynamic> legacyBody() => <String, dynamic>{
          'version': '0.2.30',
          'core': '0.4.1',
          'ip': '10.0.0.5',
          'online': true,
          'rssi': -55,
          'uptime_s': 120,
          'layout': '{"version":1}',
          'width': 64,
          'height': 32,
          'brightness': 200,
        };

    test('a body from firmware without the new fields still parses', () {
      final status = MirrorStatus.fromJson(legacyBody());
      expect(status.version, '0.2.30');
      expect(status.width, 64);
      expect(status.brightness, 200);
      expect(status.id, isNull);
      expect(status.name, isNull);
      expect(status.mode, isNull);
      expect(status.baseMode, isNull);
      expect(status.pictureReady, isNull);
      expect(status.flip180, isNull);
      // Absent display_api means "no picture or preview support", not a
      // connection failure.
      expect(status.displayApi, 0);
    });

    test('reads the identity and display fields when present', () {
      final status = MirrorStatus.fromJson(legacyBody()
        ..addAll(<String, dynamic>{
          'id': 'a1b2c3d4e5f6',
          'name': 'Hallway',
          'display_api': 1,
          'mode': 'games',
          'base_mode': 'picture',
          'picture_ready': true,
          'flip180': true,
        }));
      expect(status.id, 'a1b2c3d4e5f6');
      expect(status.name, 'Hallway');
      expect(status.displayApi, 1);
      expect(status.mode, DisplayMode.games);
      expect(status.baseMode, DisplayMode.picture);
      expect(status.pictureReady, isTrue);
      expect(status.flip180, isTrue);
    });

    test('an unknown mode is null and a game is never the base mode', () {
      final status = MirrorStatus.fromJson(legacyBody()
        ..addAll(<String, dynamic>{
          'mode': 'hologram',
          'base_mode': 'games',
        }));
      expect(status.mode, isNull);
      expect(status.baseMode, isNull);
    });
  });

  group('MRF1 frames', () {
    Uint8List pixels(int seed) => Uint8List.fromList(
          List<int>.generate(64 * 32 * 3, (i) => (i * 5 + seed) % 256),
        );

    /// A body written byte by byte, so the wire format itself is pinned to
    /// what firmware/main/frame_snapshot.c emits rather than to whatever the
    /// encoder happens to do.
    Uint8List handBuilt() {
      final rgb = pixels(0);
      final body = Uint8List(mirrorFrameHeaderSize + rgb.length);
      body.setRange(0, 4, <int>[0x4d, 0x52, 0x46, 0x31]);
      body[4] = 64;
      body[5] = 0;
      body[6] = 32;
      body[7] = 0;
      body[8] = 0x04;
      body[9] = 0x03;
      body[10] = 0x02;
      body[11] = 0x01;
      body[12] = 200;
      body[13] = 2;
      body[14] = 1;
      body[15] = 0;
      body.setRange(mirrorFrameHeaderSize, body.length, rgb);
      return body;
    }

    test('decodes the header layout the firmware writes', () {
      final frame = decodeMirrorFrame(handBuilt());
      expect(frame.width, 64);
      expect(frame.height, 32);
      expect(frame.sequence, 0x01020304);
      expect(frame.brightness, 200);
      expect(frame.mode, DisplayMode.picture);
      expect(frame.flip180, isTrue);
      expect(frame.rgb, pixels(0));
    });

    test('encodes the header at the same fixed offsets, little-endian', () {
      final bytes = encodeMirrorFrame(MirrorFrame(
        width: 64,
        height: 32,
        sequence: 0x01020304,
        brightness: 200,
        mode: DisplayMode.games,
        flip180: false,
        rgb: pixels(3),
      ));
      expect(bytes.sublist(0, 4), <int>[0x4d, 0x52, 0x46, 0x31]);
      expect(bytes.sublist(4, 16),
          <int>[64, 0, 32, 0, 4, 3, 2, 1, 200, 1, 0, 0]);
      expect(bytes.length, mirrorFrameHeaderSize + 64 * 32 * 3);
      expect(bytes.sublist(mirrorFrameHeaderSize), pixels(3));
    });

    test('a cached frame decodes back to the pixels the mirror sent', () {
      final frame = decodeMirrorFrame(handBuilt());
      final cached = decodeMirrorFrame(encodeMirrorFrame(frame));
      expect(cached.width, 64);
      expect(cached.height, 32);
      expect(cached.sequence, frame.sequence);
      expect(cached.brightness, frame.brightness);
      expect(cached.mode, frame.mode);
      expect(cached.flip180, isTrue);
      expect(cached.rgb, frame.rgb);
    });

    test('a body that is too short or not MRF1 is rejected', () {
      expect(() => decodeMirrorFrame(Uint8List(0)),
          throwsA(isA<MirrorApiException>()));
      expect(() => decodeMirrorFrame(Uint8List(mirrorFrameHeaderSize - 1)),
          throwsA(isA<MirrorApiException>()));
      final foreign = handBuilt()..[0] = 0x58;
      expect(() => decodeMirrorFrame(foreign),
          throwsA(isA<MirrorApiException>()));
    });

    test('the body must match the geometry the header declares', () {
      final whole = handBuilt();
      expect(
        () => decodeMirrorFrame(
            Uint8List.sublistView(whole, 0, whole.length - 3)),
        throwsA(isA<MirrorApiException>()),
        reason: 'a truncated preview must not decode to a whole panel',
      );
      final extra = Uint8List(whole.length + 1)..setRange(0, whole.length, whole);
      expect(() => decodeMirrorFrame(extra),
          throwsA(isA<MirrorApiException>()));
      final zero = handBuilt();
      zero[4] = 0;
      zero[5] = 0;
      expect(() => decodeMirrorFrame(zero),
          throwsA(isA<MirrorApiException>()),
        reason: 'a zero-width panel is a malformed header, not an empty frame');
      final oversized = handBuilt();
      // 300x300 needs 270000 bytes, past the 196608-byte cap.
      oversized[4] = 44;
      oversized[5] = 1;
      oversized[6] = 44;
      oversized[7] = 1;
      expect(() => decodeMirrorFrame(oversized),
          throwsA(isA<MirrorApiException>()));
    });

    test('an unknown mode, a non-boolean flip and a dirty reserved byte fail',
        () {
      final unknownMode = handBuilt()..[13] = 3;
      expect(() => decodeMirrorFrame(unknownMode),
          throwsA(isA<MirrorApiException>()));
      final badFlip = handBuilt()..[14] = 2;
      expect(() => decodeMirrorFrame(badFlip),
          throwsA(isA<MirrorApiException>()));
      final reserved = handBuilt()..[15] = 1;
      expect(() => decodeMirrorFrame(reserved),
          throwsA(isA<MirrorApiException>()));
    });

    test('a 256x256 frame sits exactly at the cap', () {
      final rgb = Uint8List(256 * 256 * 3);
      final bytes = encodeMirrorFrame(MirrorFrame(
        width: 256,
        height: 256,
        sequence: 0,
        brightness: 255,
        mode: DisplayMode.clock,
        flip180: false,
        rgb: rgb,
      ));
      expect(bytes.length, mirrorFrameHeaderSize + mirrorFrameMaxPayloadBytes);
      expect(decodeMirrorFrame(bytes).rgb.length, mirrorFrameMaxPayloadBytes);
    });

    test('the encoder refuses a frame a device could not have produced', () {
      expect(
        () => encodeMirrorFrame(MirrorFrame(
          width: 64,
          height: 32,
          sequence: 1,
          brightness: 128,
          mode: DisplayMode.clock,
          flip180: false,
          rgb: Uint8List(64 * 32 * 3 - 1),
        )),
        throwsA(isA<MirrorApiException>()),
      );
      expect(
        () => encodeMirrorFrame(MirrorFrame(
          width: 300,
          height: 300,
          sequence: 1,
          brightness: 128,
          mode: DisplayMode.clock,
          flip180: false,
          rgb: Uint8List(0),
        )),
        throwsA(isA<MirrorApiException>()),
      );
      expect(
        () => encodeMirrorFrame(MirrorFrame(
          width: 0,
          height: 32,
          sequence: 1,
          brightness: 128,
          mode: DisplayMode.clock,
          flip180: false,
          rgb: Uint8List(0),
        )),
        throwsA(isA<MirrorApiException>()),
      );
    });
  });

  group('DisplayResult.fromJson', () {
    test('reads the effective and saved displays', () {
      final result = DisplayResult.fromJson(<String, dynamic>{
        'ok': true,
        'mode': 'games',
        'base_mode': 'picture',
        'picture_ready': true,
      });
      expect(result.mode, DisplayMode.games);
      expect(result.baseMode, DisplayMode.picture);
      expect(result.pictureReady, isTrue);
    });

    test('a stored picture is not implied when the mirror says otherwise', () {
      final result = DisplayResult.fromJson(<String, dynamic>{
        'mode': 'clock',
        'base_mode': 'clock',
        'picture_ready': false,
      });
      expect(result.mode, DisplayMode.clock);
      expect(result.baseMode, DisplayMode.clock);
      expect(result.pictureReady, isFalse);
    });

    test('a game can never be the saved display', () {
      expect(
        () => DisplayResult.fromJson(<String, dynamic>{
          'mode': 'games',
          'base_mode': 'games',
          'picture_ready': false,
        }),
        throwsA(isA<MirrorApiException>()),
      );
    });

    test('an unknown or missing display is refused, never guessed', () {
      expect(
        () => DisplayResult.fromJson(<String, dynamic>{
          'mode': 'hologram',
          'base_mode': 'clock',
          'picture_ready': false,
        }),
        throwsA(isA<MirrorApiException>()),
      );
      expect(
        () => DisplayResult.fromJson(<String, dynamic>{
          'base_mode': 'clock',
          'picture_ready': false,
        }),
        throwsA(isA<MirrorApiException>()),
      );
      expect(
        () => DisplayResult.fromJson(<String, dynamic>{
          'mode': 'clock',
          'picture_ready': false,
        }),
        throwsA(isA<MirrorApiException>()),
      );
      expect(
        () => DisplayResult.fromJson(<String, dynamic>{
          'mode': 'clock',
          'base_mode': 'clock',
        }),
        throwsA(isA<MirrorApiException>()),
      );
    });
  });
}
