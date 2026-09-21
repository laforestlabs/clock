// What the picture screen guarantees before it writes to a mirror.
//
// The screen composes a picture on the phone and sends it over Wi-Fi, so the
// failures worth pinning are the ones that either touch the device without
// being asked or lose the user's work: a cancel or a failed decode reaching
// the panel, a late decode drawing over a newer selection, bytes framed for a
// panel size the mirror no longer has, an upload landing on another record,
// and an unanswered upload being reported as a definite success or failure.
//
// The device's own preview is the bytes the mirror actually sent, so it is
// checked to stay untouched by everything that happens locally on this screen.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mirror_designer/src/services/mirror_ble.dart';
import 'package:mirror_designer/src/services/mirror_connection.dart';
import 'package:mirror_designer/src/services/mirror_devices.dart';
import 'package:mirror_designer/src/services/mirror_display.dart';
import 'package:mirror_designer/src/services/mirror_lan.dart';
import 'package:mirror_designer/src/services/picture_encoder.dart';
import 'package:mirror_designer/src/ui/picture_screen.dart';

final List<Directory> _temps = <Directory>[];

MirrorStatus mirrorStatus({
  String id = 'aaaa00000001',
  String name = 'Mirror',
  int width = 64,
  int height = 32,
  DisplayMode? mode = DisplayMode.clock,
  DisplayMode? baseMode = DisplayMode.clock,
  bool pictureReady = false,
  int displayApi = 1,
}) =>
    MirrorStatus(
      version: '0.2.34',
      core: 'core-1',
      ip: '',
      online: true,
      rssi: -50,
      uptime_s: 12,
      layout: 'home',
      width: width,
      height: height,
      brightness: 128,
      id: id,
      name: name,
      mode: mode,
      baseMode: baseMode,
      pictureReady: pictureReady,
      flip180: false,
      displayApi: displayApi,
    );

MirrorFrame mirrorFrame({int width = 64, int height = 32}) => MirrorFrame(
      width: width,
      height: height,
      sequence: 1,
      brightness: 128,
      mode: DisplayMode.clock,
      flip180: false,
      rgb: Uint8List(width * height * 3),
    );

/// A picture file whose first byte tags it, so a composed or uploaded frame
/// can be traced back to the file it came from.
XFile pictureFile(int tag) =>
    XFile.fromData(Uint8List.fromList(<int>[tag, 3, 1, 4]));

/// The LAN client, with scripted answers and a record of what it was sent.
class _Lan extends MirrorLan {
  _Lan(super.ip);

  MirrorStatus statusBody = mirrorStatus();
  MirrorFrame frameBody = mirrorFrame();
  Object? frameError;
  Object? uploadError;
  DisplayResult uploadResult = const DisplayResult(
    mode: DisplayMode.picture,
    baseMode: DisplayMode.picture,
    pictureReady: true,
  );

  int statusCalls = 0;
  int uploadCalls = 0;
  final List<Uint8List> uploads = <Uint8List>[];
  int? uploadedWidth;
  int? uploadedHeight;

  Uint8List? get uploaded => uploads.isEmpty ? null : uploads.last;

  @override
  Future<MirrorStatus> status() async {
    statusCalls++;
    return statusBody;
  }

  @override
  Future<MirrorFrame> frame() async {
    final failure = frameError;
    if (failure != null) throw failure;
    return frameBody;
  }

  @override
  Future<DisplayResult> uploadPicture(
    Uint8List rgb, {
    required int width,
    required int height,
  }) async {
    uploadCalls++;
    uploads.add(rgb);
    uploadedWidth = width;
    uploadedHeight = height;
    final failure = uploadError;
    if (failure != null) throw failure;
    return uploadResult;
  }

  @override
  Future<bool> reachable({
    Duration timeout = const Duration(seconds: 4),
  }) async =>
      true;
}

/// The BLE link. A LAN record never uses it; the picture screen must work
/// without a radio, so a connect here only records that it happened.
class _Link extends MirrorConnection {
  _Link()
      : super(
          deviceId: null,
          deviceName: null,
          panelWidth: 0,
          panelHeight: 0,
        );

  @override
  BleSession? get session => null;

  @override
  MirrorConnectionStatus get status => MirrorConnectionStatus.disconnected;

  @override
  Future<void> connectDevice({
    required String id,
    required String name,
    Duration timeout = const Duration(seconds: 35),
  }) async {}

  @override
  Future<void> disconnect() async {}
}

/// The composer seam: pixel fills tag the byte the source file started with.
class _Renderer {
  final List<({int width, int height, PictureFit fit})> calls =
      <({int width, int height, PictureFit fit})>[];

  /// When set, the next call waits on it before answering.
  Completer<void>? hold;

  /// When set, the next call throws it.
  Object? error;

  Future<Uint8List> call(
    Uint8List encoded, {
    required int width,
    required int height,
    required PictureFit fit,
  }) async {
    calls.add((width: width, height: height, fit: fit));
    final gate = hold;
    hold = null;
    if (gate != null) await gate.future;
    final failure = error;
    if (failure != null) {
      error = null;
      throw failure;
    }
    final tag = encoded.isEmpty ? 0 : encoded.first;
    return Uint8List(width * height * 3)..fillRange(0, width * height * 3, tag);
  }
}

/// The picker seam: a queue of answers, so cancel is one more answer.
class _Chooser {
  final List<XFile?> _queue = <XFile?>[];
  int calls = 0;

  void willPick(XFile? file) => _queue.add(file);

  Future<XFile?> call() async {
    calls++;
    if (_queue.isEmpty) return null;
    return _queue.removeAt(0);
  }
}

class _Fixture {
  _Fixture() {
    dir = Directory.systemTemp.createTempSync('picture-screen');
    _temps.add(dir);
    registry = MirrorDevices(
      connectionFactory: _link,
      lanFactory: lanAt,
      ensureBleReady: () async {},
      previewDirectory: () async => dir,
      now: () => clock,
    );
  }

  late final Directory dir;
  late final MirrorDevices registry;
  final Map<String, _Lan> _lans = <String, _Lan>{};
  DateTime clock = DateTime.utc(2026, 9, 21, 9);

  static MirrorConnection _link({
    String? deviceId,
    String? deviceName,
    int panelWidth = 0,
    int panelHeight = 0,
  }) =>
      _Link();

  _Lan lanAt(String endpoint) =>
      _lans.putIfAbsent(endpoint, () => _Lan(endpoint));

  /// Adds a device the registry can already reach, with its status and first
  /// frame in place.
  Future<MirrorDevice> addLan(
    String host, {
    int port = 8080,
    MirrorStatus? status,
    bool withFrame = false,
  }) async {
    final lan = lanAt('$host:$port');
    if (status != null) lan.statusBody = status;
    final device = await registry.addLan(host, port);
    if (withFrame) await registry.refresh(device, includeFrame: true);
    return device.mergedInto ?? device;
  }
}

Future<void> _open(
  WidgetTester tester, {
  required _Fixture fixture,
  required MirrorDevice device,
  required _Chooser chooser,
  _Renderer? renderer,
  PictureReachability? reachability,
}) async {
  // Tall enough that every control is on screen for a tap.
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: PictureScreen(
        devices: fixture.registry,
        device: device,
        chooser: chooser.call,
        // Null leaves the screen on the shipped encoder.
        renderer: renderer?.call,
        reachability: reachability ?? (context, endpoint) async => true,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

FilledButton _displayButton(WidgetTester tester) => tester.widget<FilledButton>(
      find.byKey(const ValueKey<String>('picture-display')),
    );

OutlinedButton _chooseButton(WidgetTester tester) =>
    tester.widget<OutlinedButton>(
      find.byKey(const ValueKey<String>('picture-choose')),
    );

Future<void> _choose(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey<String>('picture-choose')));
  await tester.pumpAndSettle();
}

Future<void> _display(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey<String>('picture-display')));
  await tester.pumpAndSettle();
}

/// Chooses a picture with the shipped encoder, which really decodes.
///
/// The codec works off the Dart event loop, and a test's fake clock never
/// advances it, so the tap and the wait have to happen inside `runAsync`:
/// otherwise the composition stays pending forever and the screen never
/// offers Display.
Future<void> _chooseForReal(WidgetTester tester, Key key) async {
  await tester.runAsync(() async {
    await tester.tap(find.byKey(key));
    await Future<void>.delayed(const Duration(milliseconds: 500));
  });
  await tester.pumpAndSettle();
}

String _textOf(WidgetTester tester, String key) => tester
    .widget<Text>(
      find.descendant(
        of: find.byKey(ValueKey<String>(key)),
        matching: find.byType(Text),
        matchRoot: true,
      ),
    )
    .data!;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));
  tearDown(() {
    for (final dir in _temps) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
    _temps.clear();
  });

  testWidgets('choosing composes locally and cancel writes nothing',
      (tester) async {
    final fixture = _Fixture();
    final device = await fixture.addLan('127.0.0.1', withFrame: true);
    final seeded = device.frame!;
    final lan = fixture.lanAt('127.0.0.1:8080');
    final chooser = _Chooser();
    final renderer = _Renderer();

    chooser.willPick(null); // the user cancels
    chooser.willPick(pictureFile(7));
    await _open(
      tester,
      fixture: fixture,
      device: device,
      chooser: chooser,
      renderer: renderer,
    );

    expect(_displayButton(tester).onPressed, isNull,
        reason: 'nothing is prepared yet');
    expect(find.text('Framing preview'), findsOneWidget);

    await _choose(tester); // cancel
    expect(_displayButton(tester).onPressed, isNull);
    expect(renderer.calls, isEmpty);

    await _choose(tester); // a real picture
    expect(renderer.calls, hasLength(1));
    expect(renderer.calls.single, (width: 64, height: 32, fit: PictureFit.fit));
    expect(
        find.byKey(const ValueKey<String>('picture-framing')), findsOneWidget);
    final segmented = tester.widget<SegmentedButton<PictureFit>>(
      find.byType(SegmentedButton<PictureFit>),
    );
    expect(segmented.selected, <PictureFit>{PictureFit.fit});

    // Switching to Fill re-composes from the original file, not from the
    // scaled copy it produced.
    await tester.tap(find.text('Fill'));
    await tester.pumpAndSettle();
    expect(renderer.calls, hasLength(2));
    expect(renderer.calls.last.fit, PictureFit.fill);

    // Everything above was local: the device kept its own frame and was sent
    // nothing.
    expect(lan.uploadCalls, 0);
    expect(identical(device.frame, seeded), isTrue);
    expect(_displayButton(tester).onPressed, isNotNull);
  });

  testWidgets('an oversized file is refused before its bytes are read',
      (tester) async {
    final fixture = _Fixture();
    final device = await fixture.addLan('127.0.0.1', withFrame: true);
    final lan = fixture.lanAt('127.0.0.1:8080');
    final chooser = _Chooser();
    final renderer = _Renderer();

    chooser.willPick(pictureFile(7));
    chooser.willPick(XFile.fromData(
      Uint8List.fromList(<int>[9]),
      length: pictureMaxFileBytes + 1,
    ));
    await _open(
      tester,
      fixture: fixture,
      device: device,
      chooser: chooser,
      renderer: renderer,
    );

    await _choose(tester);
    await _choose(tester);

    expect(_textOf(tester, 'picture-error'), contains('MB'));
    // The picture that already worked is still the one prepared.
    expect(renderer.calls, hasLength(1));
    expect(_displayButton(tester).onPressed, isNotNull);

    await _display(tester);
    expect(lan.uploadCalls, 1);
    expect(lan.uploaded!.every((byte) => byte == 7), isTrue);
  });

  testWidgets('a failed decode keeps the previous picture ready to send',
      (tester) async {
    final fixture = _Fixture();
    final device = await fixture.addLan('127.0.0.1', withFrame: true);
    final lan = fixture.lanAt('127.0.0.1:8080');
    final chooser = _Chooser();
    final renderer = _Renderer();

    chooser.willPick(pictureFile(7));
    chooser.willPick(pictureFile(9));
    await _open(
      tester,
      fixture: fixture,
      device: device,
      chooser: chooser,
      renderer: renderer,
    );

    await _choose(tester);
    renderer.error = PictureEncodeException(
      'That file is not a PNG or JPEG picture.',
    );
    await _choose(tester);

    expect(_textOf(tester, 'picture-error'), contains('PNG or JPEG'));
    expect(_displayButton(tester).onPressed, isNotNull);

    await _display(tester);
    expect(lan.uploadCalls, 1);
    // The bytes are the first picture's, not the unreadable file's.
    expect(lan.uploaded!.every((byte) => byte == 7), isTrue);
  });

  testWidgets('a late decode cannot replace a newer selection', (tester) async {
    final fixture = _Fixture();
    final device = await fixture.addLan('127.0.0.1');
    final lan = fixture.lanAt('127.0.0.1:8080');
    final chooser = _Chooser();
    final renderer = _Renderer();

    chooser.willPick(pictureFile(7));
    chooser.willPick(pictureFile(9));
    await _open(
      tester,
      fixture: fixture,
      device: device,
      chooser: chooser,
      renderer: renderer,
    );

    // The first picture's composition is still running when the second one is
    // chosen.
    final gate = Completer<void>();
    renderer.hold = gate;
    await _choose(tester);
    await _choose(tester);
    expect(renderer.calls, hasLength(2));

    // It finishes last, and must not draw over the newer selection.
    gate.complete();
    await tester.pumpAndSettle();

    await _display(tester);
    expect(lan.uploadCalls, 1);
    expect(lan.uploaded!.every((byte) => byte == 9), isTrue);
  });

  testWidgets('a panel that changed shape needs a second press',
      (tester) async {
    final fixture = _Fixture();
    final device = await fixture.addLan('127.0.0.1', withFrame: true);
    final lan = fixture.lanAt('127.0.0.1:8080');
    final chooser = _Chooser();
    final renderer = _Renderer();

    chooser.willPick(pictureFile(5));
    await _open(
      tester,
      fixture: fixture,
      device: device,
      chooser: chooser,
      renderer: renderer,
    );
    await _choose(tester);
    expect(renderer.calls.single, (width: 64, height: 32, fit: PictureFit.fit));

    // The mirror turned out to have a different panel.
    lan.statusBody = mirrorStatus(width: 80, height: 40);
    await _display(tester);

    expect(lan.uploadCalls, 0,
        reason: 'bytes framed for 64x32 must not be cropped to 80x40 blindly');
    expect(_textOf(tester, 'picture-notice'), contains('80×40'));
    expect(renderer.calls.last, (width: 80, height: 40, fit: PictureFit.fit));
    expect(_displayButton(tester).onPressed, isNotNull);

    await _display(tester);
    expect(lan.uploadCalls, 1);
    expect(lan.uploadedWidth, 80);
    expect(lan.uploadedHeight, 40);
    expect(lan.uploaded, hasLength(80 * 40 * 3));
  });

  testWidgets('a real PNG is framed by the shipped encoder', (tester) async {
    final fixture = _Fixture();
    final device = await fixture.addLan('127.0.0.1');
    final lan = fixture.lanAt('127.0.0.1:8080');
    final chooser = _Chooser();

    // A square 16x16 source: on a 64x32 panel, Fit can only fill 32x32 of it,
    // so the two sides must come out black.
    final png = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 8, 16),
        Paint()..color = const Color(0xFFFF0000),
      );
      canvas.drawRect(
        const Rect.fromLTWH(8, 0, 8, 16),
        Paint()..color = const Color(0xFF0000FF),
      );
      final image = await recorder.endRecording().toImage(16, 16);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data!.buffer.asUint8List();
    });
    chooser.willPick(XFile.fromData(png!, mimeType: 'image/png'));

    // No renderer seam: the screen uses `encodePicture` itself.
    await _open(tester, fixture: fixture, device: device, chooser: chooser);
    await _chooseForReal(tester, const ValueKey<String>('picture-choose'));
    expect(_displayButton(tester).onPressed, isNotNull,
        reason: 'the shipped encoder must prepare a real PNG');

    await _display(tester);

    final rgb = lan.uploads.single;
    expect(lan.uploadedWidth, 64);
    expect(lan.uploadedHeight, 32);
    expect(rgb, hasLength(64 * 32 * 3));
    int pixel(int x, int y) {
      final at = (y * 64 + x) * 3;
      return (rgb[at] << 16) | (rgb[at + 1] << 8) | rgb[at + 2];
    }

    // Letterbox: 16 columns of black on each side of a centred 32x32 picture.
    expect(pixel(4, 16), 0x000000);
    expect(pixel(59, 16), 0x000000);
    // Sampled away from the red/blue boundary and from the picture's own
    // edges, where the encoder's medium-quality resampling blends neighbours.
    expect(pixel(20, 16), 0xFF0000, reason: 'the red half is on the left');
    expect(pixel(44, 16), 0x0000FF);
  });

  testWidgets('an upload only reaches the record it was framed for',
      (tester) async {
    final fixture = _Fixture();
    final first = await fixture.addLan(
      '127.0.0.1',
      port: 8080,
      status: mirrorStatus(id: 'aaaa00000001', name: 'Hallway'),
      withFrame: true,
    );
    final second = await fixture.addLan(
      '127.0.0.1',
      port: 8081,
      status: mirrorStatus(id: 'aaaa00000002', name: 'Study'),
      withFrame: true,
    );
    final firstLan = fixture.lanAt('127.0.0.1:8080');
    final secondLan = fixture.lanAt('127.0.0.1:8081');
    final firstFrame = first.frame!;
    final secondFrame = second.frame!;
    final firstStatusCalls = firstLan.statusCalls;
    final chooser = _Chooser();
    final renderer = _Renderer();

    chooser.willPick(pictureFile(3));
    await _open(
      tester,
      fixture: fixture,
      device: second,
      chooser: chooser,
      renderer: renderer,
    );
    await _choose(tester);

    // Composing for one record touches neither record's own preview: the
    // framing preview is the app's, not the mirror's.
    expect(identical(first.frame, firstFrame), isTrue);
    expect(identical(second.frame, secondFrame), isTrue);

    await _display(tester);

    expect(secondLan.uploadCalls, 1);
    expect(firstLan.uploadCalls, 0);
    expect(firstLan.statusCalls, firstStatusCalls,
        reason: 'the other record was neither polled nor written');
    expect(identical(first.frame, firstFrame), isTrue);
    expect(_textOf(tester, 'picture-notice'), contains('now showing on Study'));
  });

  testWidgets('an unanswered upload is not reported as a definite outcome',
      (tester) async {
    final fixture = _Fixture();
    final device = await fixture.addLan('127.0.0.1', withFrame: true);
    final lan = fixture.lanAt('127.0.0.1:8080');
    lan.frameError = MirrorApiException('frame: HTTP 503');
    final chooser = _Chooser();
    final renderer = _Renderer();

    chooser.willPick(pictureFile(7));
    await _open(
      tester,
      fixture: fixture,
      device: device,
      chooser: chooser,
      renderer: renderer,
    );
    await _choose(tester);

    // The normalization the transport performs for a timeout: no HTTP status,
    // so nothing is known about whether the picture was stored.
    lan.uploadError =
        MirrorApiException('picture: the mirror did not answer within 30s');
    await _display(tester);

    final message = _textOf(tester, 'picture-error');
    expect(message, contains('Could not confirm the upload'));
    expect(message, contains('refresh the device before retrying'));
    expect(message, contains('did not answer within 30s'));
    // The work is kept for a retry, and the device is read back rather than
    // assumed to have kept or dropped it.
    expect(_displayButton(tester).onPressed, isNotNull);
    expect(lan.statusCalls, greaterThan(1));
  });

  testWidgets('a refusal is shown as the device worded it', (tester) async {
    final fixture = _Fixture();
    final device = await fixture.addLan('127.0.0.1');
    final lan = fixture.lanAt('127.0.0.1:8080');
    final chooser = _Chooser();
    final renderer = _Renderer();

    chooser.willPick(pictureFile(7));
    await _open(
      tester,
      fixture: fixture,
      device: device,
      chooser: chooser,
      renderer: renderer,
    );
    await _choose(tester);

    lan.uploadError = MirrorApiException(
      'picture: HTTP 413 {"ok":false,"error":"too large"}',
      statusCode: 413,
    );
    await _display(tester);

    final message = _textOf(tester, 'picture-error');
    expect(message, contains('HTTP 413'));
    expect(message, isNot(contains('Could not confirm')));
  });

  testWidgets('a refusal that never reached the wire is not hedged',
      (tester) async {
    final fixture = _Fixture();
    final device = await fixture.addLan('127.0.0.1');
    final lan = fixture.lanAt('127.0.0.1:8080');
    final chooser = _Chooser();
    final renderer = _Renderer();

    chooser.willPick(pictureFile(7));
    await _open(
      tester,
      fixture: fixture,
      device: device,
      chooser: chooser,
      renderer: renderer,
    );
    await _choose(tester);

    // What the registry reports when the address is gone by the time the send
    // starts: nothing can have been received, so there is nothing to hedge.
    lan.uploadError =
        MirrorRegistryException(MirrorDevices.uploadNeedsWifiMessage);
    await _display(tester);

    expect(
      _textOf(tester, 'picture-error'),
      MirrorDevices.uploadNeedsWifiMessage,
    );
    // The prepared picture is still there for when Wi-Fi comes back.
    expect(_displayButton(tester).onPressed, isNotNull);
  });

  testWidgets('a picture committed under a running game says when it shows',
      (tester) async {
    final fixture = _Fixture();
    final device = await fixture.addLan(
      '127.0.0.1',
      status: mirrorStatus(
        mode: DisplayMode.games,
        baseMode: DisplayMode.clock,
      ),
    );
    final lan = fixture.lanAt('127.0.0.1:8080');
    lan.uploadResult = const DisplayResult(
      mode: DisplayMode.games,
      baseMode: DisplayMode.picture,
      pictureReady: true,
    );
    final chooser = _Chooser();
    final renderer = _Renderer();

    chooser.willPick(pictureFile(7));
    await _open(
      tester,
      fixture: fixture,
      device: device,
      chooser: chooser,
      renderer: renderer,
    );
    expect(find.byKey(const ValueKey<String>('picture-game-running')),
        findsOneWidget);

    await _choose(tester);
    await _display(tester);

    expect(
      _textOf(tester, 'picture-notice'),
      'Picture saved; it will appear when the game ends.',
    );
  });

  testWidgets('a mirror with no Wi-Fi address explains what uploads need',
      (tester) async {
    final fixture = _Fixture();
    final device = await fixture.registry.addBle(
      BleScanEntry(BluetoothDevice.fromId('AA:BB:CC:DD:EE:FF'), 'Study', -40),
    );
    final chooser = _Chooser();
    final renderer = _Renderer();

    await _open(
      tester,
      fixture: fixture,
      device: device,
      chooser: chooser,
      renderer: renderer,
    );

    expect(device.endpoint, isNull);
    expect(
      _textOf(tester, 'picture-needs-wifi'),
      MirrorDevices.uploadNeedsWifiMessage,
    );
    expect(_chooseButton(tester).onPressed, isNull);
    expect(_displayButton(tester).onPressed, isNull);
  });

  testWidgets('firmware without the picture API cannot be prepared for',
      (tester) async {
    final fixture = _Fixture();
    final device = await fixture.addLan(
      '127.0.0.1',
      status: mirrorStatus(displayApi: 0),
    );
    final chooser = _Chooser();
    final renderer = _Renderer();

    await _open(
      tester,
      fixture: fixture,
      device: device,
      chooser: chooser,
      renderer: renderer,
    );

    expect(find.byKey(const ValueKey<String>('picture-unsupported')),
        findsOneWidget);
    expect(_chooseButton(tester).onPressed, isNull);
    expect(_displayButton(tester).onPressed, isNull);
  });
}
