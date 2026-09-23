// What the device dashboard guarantees.
//
// The failures worth pinning are the ones the whole feature rests on: the home
// screen appears without the native render engine, a tile keeps showing an
// offline mirror's last actual frame with its age, selecting one device never
// writes to another, a failed discovery is retryable rather than a dead end,
// and the grid survives a phone at large text scale.
//
// The registry is real here; only its transports are fakes, so the tests
// exercise the same records, the same refresh gate and the same persistence
// the app uses.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mirror_designer/src/services/mirror_ble.dart';
import 'package:mirror_designer/src/services/mirror_connection.dart';
import 'package:mirror_designer/src/services/mirror_devices.dart';
import 'package:mirror_designer/src/services/mirror_display.dart';
import 'package:mirror_designer/src/services/mirror_discovery.dart';
import 'package:mirror_designer/src/services/mirror_lan.dart';
import 'package:mirror_designer/src/ui/add_device_screen.dart';
import 'package:mirror_designer/src/ui/device_preview.dart';
import 'package:mirror_designer/src/ui/device_routes.dart';
import 'package:mirror_designer/src/ui/device_screen.dart';
import 'package:mirror_designer/src/ui/devices_screen.dart';

/// Temp preview directories to remove after each test.
final List<Directory> _temps = <Directory>[];

Uint8List _pattern(int salt) => Uint8List.fromList(
    List<int>.generate(64 * 32 * 3, (i) => (i + salt) % 251));

MirrorStatus _status({
  String id = 'aaaa00000001',
  String name = 'Hall mirror',
  int width = 64,
  int height = 32,
  DisplayMode? mode = DisplayMode.clock,
  DisplayMode? baseMode = DisplayMode.clock,
  bool pictureReady = false,
  int displayApi = 1,
}) =>
    MirrorStatus(
      version: '99.9.9',
      core: 'core-1',
      ip: '0.0.0.0',
      online: true,
      rssi: -50,
      uptime_s: 3,
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

/// One record as the registry persists it, for a launch whose screen has a
/// history to order before it ever builds.
Map<String, Object?> _saved({
  required String key,
  required String id,
  required String name,
  required int port,
  DateTime? lastSeen,
}) =>
    <String, Object?>{
      'key': key,
      'id': id,
      'name': name,
      'host': '127.0.0.1',
      'port': port,
      'width': 64,
      'height': 32,
      'flip180': false,
      'last_seen': lastSeen?.toUtc().toIso8601String(),
    };

MirrorFrame _frame({int sequence = 7}) => MirrorFrame(
      width: 64,
      height: 32,
      sequence: sequence,
      brightness: 128,
      mode: DisplayMode.clock,
      flip180: false,
      rgb: _pattern(1),
    );

/// The colour a frame pasted onto the mirror's panel is unmistakable in: the
/// page's own preview has to show exactly these pixels.
const List<int> _mirrorGreen = <int>[0, 200, 0];

/// A frame that is one flat colour, the way a test can tell a preview that
/// painted the device's display from one that is still showing an empty panel.
MirrorFrame _flatFrame(List<int> rgb, {int sequence = 8}) => MirrorFrame(
      width: 64,
      height: 32,
      sequence: sequence,
      brightness: 255,
      mode: DisplayMode.clock,
      flip180: false,
      rgb: Uint8List.fromList(
        List<int>.generate(64 * 32 * 3, (i) => rgb[i % 3]),
      ),
    );

bool _isMirrorGreen(List<int> pixel) =>
    pixel[1] > 150 && pixel[0] < 60 && pixel[2] < 60;

/// The LAN client, with per-endpoint scripted answers.
class _Lan extends MirrorLan {
  _Lan(this.endpoint) : super(endpoint);

  final String endpoint;

  MirrorStatus Function()? statusBody;
  Object? statusError;
  MirrorFrame Function()? frameBody;
  Object? frameError;
  DisplayResult Function(DisplayMode)? modeBody;
  Object? modeError;

  int statusCalls = 0;
  int frameCalls = 0;
  int modeCalls = 0;
  DisplayMode? lastMode;

  @override
  Future<MirrorStatus> status() async {
    statusCalls++;
    final failure = statusError;
    if (failure != null) throw failure;
    return statusBody?.call() ?? _status();
  }

  @override
  Future<MirrorFrame> frame() async {
    frameCalls++;
    final failure = frameError;
    if (failure != null) throw failure;
    return frameBody?.call() ?? _frame();
  }

  @override
  Future<DisplayResult> setDisplayMode(DisplayMode mode) async {
    modeCalls++;
    lastMode = mode;
    final failure = modeError;
    if (failure != null) throw failure;
    return modeBody?.call(mode) ??
        DisplayResult(mode: mode, baseMode: mode, pictureReady: false);
  }

  @override
  Future<PutLayoutResult> putLayout(String json) async =>
      (ok: true, diag: const <String>[], error: null);

  @override
  Future<bool> reachable(
          {Duration timeout = const Duration(seconds: 4)}) async =>
      true;
}

/// A live BLE session whose identity the test states.
class _Session extends Fake implements BleSession {
  _Session(this.info);

  final MirrorDeviceInfo info;

  @override
  Future<MirrorDeviceInfo?> getDeviceInfo() async => info;

  @override
  Future<void> close() async {}
}

/// The Bluetooth link for these records.
///
/// A LAN dashboard never opens a radio: a record with no scripted identity
/// fails its connect honestly, and one with an identity adopts a session —
/// which is what the Bluetooth-only tile states are built from.
class _Connection extends MirrorConnection {
  _Connection({
    super.deviceId,
    super.deviceName,
    super.panelWidth,
    super.panelHeight,
  });

  /// What a connect to this link reports, or null for "there is no radio".
  MirrorDeviceInfo? info;

  _Session? _live;
  int connects = 0;

  @override
  BleSession? get session => _live;

  @override
  MirrorConnectionStatus get status => _live == null
      ? MirrorConnectionStatus.disconnected
      : MirrorConnectionStatus.connected;

  @override
  Future<void> connectDevice({
    required String id,
    required String name,
    Duration timeout = const Duration(seconds: 35),
  }) async {
    connects++;
    final info = this.info;
    if (info == null) {
      throw BleUnavailableException('there is no radio in this test');
    }
    _live = _Session(info);
    notifyListeners();
  }

  @override
  Future<void> disconnect() async {
    _live = null;
    notifyListeners();
  }
}

/// A registry wired to fakes, plus the endpoints it built.
class _Dashboard {
  _Dashboard({Directory? directory}) {
    final dir = directory ?? Directory.systemTemp.createTempSync('dash');
    if (directory == null) _temps.add(dir);
    registry = MirrorDevices(
      connectionFactory: createConnection,
      lanFactory: lan,
      browse: browse,
      scan: ({Duration timeout = const Duration(seconds: 6)}) async =>
          <BleScanEntry>[],
      ensureBleReady: () async {},
      previewDirectory: () async => dir,
      now: () => DateTime.utc(2026, 9, 21, 12),
    );
  }

  late final MirrorDevices registry;
  final Map<String, _Lan> lans = <String, _Lan>{};
  final List<LanDevice> advertised = <LanDevice>[];

  /// What a Bluetooth connect to a remote id reports, when a test wants one.
  final Map<String, MirrorDeviceInfo> identities = <String, MirrorDeviceInfo>{};
  Object? browseError;
  int browseRuns = 0;

  MirrorConnection createConnection({
    String? deviceId,
    String? deviceName,
    int panelWidth = 0,
    int panelHeight = 0,
  }) {
    final connection = _Connection(
      deviceId: deviceId,
      deviceName: deviceName,
      panelWidth: panelWidth,
      panelHeight: panelHeight,
    );
    // A record's own link only knows an identity once it has been paired.
    connection.info = deviceId == null ? null : identities[deviceId];
    return connection;
  }

  MirrorLan lan(String endpoint) =>
      lans.putIfAbsent(endpoint, () => _Lan(endpoint));

  _Lan lanAt(String endpoint) =>
      lans.putIfAbsent(endpoint, () => _Lan(endpoint));

  Stream<LanDevice> browse(
      {Duration timeout = const Duration(seconds: 5)}) async* {
    browseRuns++;
    final failure = browseError;
    if (failure != null) throw failure;
    // No timer between records: a screen starts discovery from its own frame,
    // and a test that had to advance a fake clock to finish that same run
    // would be waiting on itself.
    for (final device in advertised) {
      yield device;
    }
  }
}

/// Adds a reachable device over the fake LAN and returns it.
Future<MirrorDevice> _addDevice(
  _Dashboard dashboard, {
  required String host,
  required int port,
  String id = 'aaaa00000001',
  String name = 'Hall mirror',
  DisplayMode? mode = DisplayMode.clock,
  DisplayMode? baseMode = DisplayMode.clock,
  bool pictureReady = false,
  int displayApi = 1,
}) async {
  dashboard.lanAt('$host:$port').statusBody = () => _status(
        id: id,
        name: name,
        mode: mode,
        baseMode: baseMode,
        pictureReady: pictureReady,
        displayApi: displayApi,
      );
  return dashboard.registry.addLan(host, port);
}

/// Reads the persisted list, the way the app root does at launch. The
/// dashboard shows a spinner until it has: an unloaded registry is not an
/// empty one.
Future<void> loadRegistry(WidgetTester tester, MirrorDevices registry) async {
  await tester.runAsync(registry.load);
}

/// Advances past a route transition.
///
/// Never `pumpAndSettle`: every screen here polls on a timer, so a settle loop
/// would keep finding new frames until it timed out on a *working* screen.
/// The steps matter: a tap that pops a route registers the pop a microtask
/// later, so the exit animation starts on the second frame and the route only
/// leaves the tree on the frame after the animation has run.
Future<void> settleRoute(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

/// Lets a frame's real `dart:ui` decode land and reach the screen.
///
/// Previews decode through `dart:ui`, which is engine work outside fake async:
/// pumps alone would leave the panel as black as it was before the frame
/// arrived. The drain ends when the preview has an image to draw, so it waits
/// for the decode rather than guessing how long a decode takes.
Future<void> settleDecode(WidgetTester tester) async {
  final painted = find.descendant(
    of: find.byType(DeviceScreen),
    matching: find.byType(RawImage),
  );
  for (var turn = 0; turn < 100; turn++) {
    await tester.pump();
    if (painted.evaluate().isNotEmpty) return;
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
}

/// The widget tree a test can read back the pixels of.
final GlobalKey _painted = GlobalKey();

/// The colour the device page's own preview is painting, sampled at its middle.
///
/// Read from the frame tree actually produced, not from the record: a preview
/// that was never repainted still shows the empty black panel, whatever the
/// record holds.
Future<List<int>> _paintedPreviewCentre(WidgetTester tester) async {
  final boundary =
      _painted.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final centre = tester
      .getRect(find.descendant(
        of: find.byType(DeviceScreen),
        matching: find.byType(DevicePreview),
      ))
      .center;
  final pixel = await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final bytes = data!.buffer.asUint8List();
      final at = (centre.dy.floor() * image.width + centre.dx.floor()) * 4;
      return <int>[bytes[at], bytes[at + 1], bytes[at + 2]];
    } finally {
      image.dispose();
    }
  });
  return pixel!;
}

/// Pumps the dashboard, sized and scaled, and disposes it at the end of the
/// test so its polling timers cannot outlive the widget tree.
Future<void> pumpHome(
  WidgetTester tester,
  MirrorDevices registry, {
  Size size = const Size(800, 800),
  double textScale = 1.0,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    RepaintBoundary(
      key: _painted,
      child: MaterialApp(
        navigatorObservers: <NavigatorObserver>[appRouteObserver],
        // Above the navigator, so the scale applies to pushed routes too: the
        // pages a phone opens are where a layout actually breaks.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: DevicesScreen(devices: registry),
      ),
    ),
  );
  // Screens do real work that outlives the last frame of a test: a device page
  // releases its record and writes the preview it was holding, a workspace
  // loads the engine and a layout. Let that land while the tree is still
  // alive, and again while it is being torn down — a screen disposed
  // mid-flight reports into an owner nobody has any more, which is a test
  // artifact rather than device behavior. Then unmount before the registry the
  // test disposes at the end.
  addTearDown(() async {
    for (var turn = 0; turn < 6; turn++) {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  });
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));
  tearDown(() {
    for (final dir in _temps) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
    _temps.clear();
  });

  testWidgets('the home screen appears without the render engine',
      (tester) async {
    final dashboard = _Dashboard();
    addTearDown(dashboard.registry.dispose);
    await loadRegistry(tester, dashboard.registry);
    await tester.runAsync(() async {
      await _addDevice(dashboard, host: '127.0.0.1', port: 8080);
    });

    await pumpHome(tester, dashboard.registry);

    expect(find.text('Devices'), findsOneWidget);
    expect(find.text('Hall mirror'), findsOneWidget);
    expect(find.text('Smart clock'), findsOneWidget);
    expect(find.text('Wi-Fi'), findsOneWidget);
    // Nothing on the way in loads the native library: no workspace and no
    // repair page exists until the owner asks for one.
    expect(find.byType(WorkspaceRoute), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // A restored home is laid out before Android hands the app its first
  // viewport metrics, so the first build can be zero wide. A grid that divides
  // the width it has would size its tiles negatively there and take the tree
  // down with it; the tiles belong on screen the moment there is room.
  testWidgets('a home that starts zero wide grows into the grid',
      (tester) async {
    final dashboard = _Dashboard();
    addTearDown(dashboard.registry.dispose);
    await loadRegistry(tester, dashboard.registry);
    await tester.runAsync(() async {
      await _addDevice(dashboard, host: '127.0.0.1', port: 8080);
    });

    await pumpHome(tester, dashboard.registry, size: const Size(0, 0));
    expect(tester.takeException(), isNull,
        reason:
            'a viewport with no width lays nothing out rather than breaking');

    await tester.binding.setSurfaceSize(const Size(360, 800));
    await tester.pump();
    await tester.pump();

    expect(find.text('Hall mirror'), findsOneWidget);
    expect(find.text('Wi-Fi'), findsOneWidget);
    expect(tester.takeException(), isNull,
        reason: 'the grid appears once the viewport has a width');
  });

  testWidgets('an offline tile keeps its last actual frame and its age',
      (tester) async {
    final dashboard = _Dashboard();
    addTearDown(dashboard.registry.dispose);
    await loadRegistry(tester, dashboard.registry);
    late final MirrorDevice device;
    await tester.runAsync(() async {
      device = await _addDevice(dashboard, host: '127.0.0.1', port: 8080);
      await dashboard.registry.refresh(device, includeFrame: true);
      // The mirror stops answering: the frame it already sent stays, and the
      // tile must say how old it is rather than implying a live view.
      dashboard.lanAt('127.0.0.1:8080').statusError =
          MirrorApiException('could not reach 127.0.0.1');
      await dashboard.registry.refresh(device, includeFrame: true);
    });

    expect(device.frame, isNotNull);
    expect(device.lanReachable, isFalse);

    await pumpHome(tester, dashboard.registry);

    expect(find.text('Hall mirror'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
    expect(find.textContaining('Last seen'), findsOneWidget);

    // An offline tile is still selectable: its page is inspectable, with the
    // controls that would change the display still on it.
    await tester.tap(find.text('Hall mirror'));
    await settleRoute(tester);
    expect(
        find.widgetWithText(FilledButton, 'Use smart clock'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the device page disables display changes while offline',
      (tester) async {
    final dashboard = _Dashboard();
    addTearDown(dashboard.registry.dispose);
    await loadRegistry(tester, dashboard.registry);
    late final MirrorDevice device;
    await tester.runAsync(() async {
      device = await _addDevice(
        dashboard,
        host: '127.0.0.1',
        port: 8080,
        mode: DisplayMode.picture,
        baseMode: DisplayMode.picture,
        pictureReady: true,
      );
      dashboard.lanAt('127.0.0.1:8080').statusError =
          MirrorApiException('could not reach 127.0.0.1');
      await dashboard.registry.refresh(device);
    });

    await pumpHome(tester, dashboard.registry);
    await tester.tap(find.text('Hall mirror'));
    await settleRoute(tester);

    final useClock = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Use smart clock'),
    );
    expect(useClock.onPressed, isNull,
        reason: 'an offline device must not be sent a display change');
    // The cards below the fold are off too: the page is read-only, not one
    // disabled control with live ones under it.
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();
    expect(find.text('Saved picture · showing now'), findsOneWidget,
        reason: 'the page still knows what the device last saved');
    final showSaved = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Show saved picture'),
    );
    expect(showSaved.onPressed, isNull,
        reason: 'the saved picture cannot be recalled onto an absent mirror');
    final choose = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Choose picture'),
    );
    expect(choose.onPressed, isNull,
        reason: 'a picture has nowhere to go without a reachable address');
    // …and each card the owner cannot act on says why. Several carry the same
    // explanation, so this is a presence check, not a count.
    expect(find.textContaining('Reconnect to change the display'), findsWidgets,
        reason: 'the page explains why the controls do nothing');
    expect(dashboard.lanAt('127.0.0.1:8080').modeCalls, 0,
        reason: 'opening the page is read-only');
  });

  // The page exists for three actions — put the clock on the panel, start a
  // game, choose a picture. On the phone the app is used on, all three have to
  // be on screen without scrolling: a page that pushes them under the fold may
  // as well not have them.
  testWidgets('the device page keeps its three actions on a phone screen',
      (tester) async {
    final dashboard = _Dashboard();
    addTearDown(dashboard.registry.dispose);
    await loadRegistry(tester, dashboard.registry);
    await tester.runAsync(() async {
      await _addDevice(dashboard, host: '127.0.0.1', port: 8080);
    });

    await pumpHome(tester, dashboard.registry, size: const Size(360, 800));
    await tester.tap(find.text('Hall mirror'));
    await settleRoute(tester);

    final screen = tester.getRect(find.byType(DeviceScreen));
    for (final label in <String>[
      'Use smart clock',
      'Start a game',
      'Choose picture',
    ]) {
      final action = find.widgetWithText(FilledButton, label);
      expect(action, findsOneWidget, reason: '$label is on the page');
      expect(tester.getRect(action).bottom, lessThanOrEqualTo(screen.bottom),
          reason: '$label is not below the fold of a phone screen');
    }
    expect(find.widgetWithText(OutlinedButton, 'Reconnect'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // A window with room spends it on width rather than height: the three cards
  // share one row instead of stacking, so a desktop page stops growing down
  // the screen. The one thing that must not be repeated for that is the
  // settings route: it lives in the app bar.
  testWidgets('a wide window lays the display cards out side by side',
      (tester) async {
    final dashboard = _Dashboard();
    addTearDown(dashboard.registry.dispose);
    await loadRegistry(tester, dashboard.registry);
    await tester.runAsync(() async {
      await _addDevice(dashboard, host: '127.0.0.1', port: 8080);
    });

    await pumpHome(tester, dashboard.registry, size: const Size(1280, 800));
    await tester.tap(find.text('Hall mirror'));
    await settleRoute(tester);

    // One info control per card, and the three cards start at the same height:
    // they share a row instead of stacking.
    final controls = find.byTooltip('What this does');
    expect(controls, findsNWidgets(3), reason: 'one control per display card');
    Rect card(String title) => tester.getRect(find
        .ancestor(
          of: find.descendant(
            of: find.byType(DeviceScreen),
            matching: find.text(title),
          ),
          matching: find.byType(Card),
        )
        .first);
    final clock = card('Smart clock');
    final games = card('Games');
    final picture = card('Picture display');
    expect(games.top, closeTo(clock.top, 0.5),
        reason: 'the games card shares the clock card\'s row');
    expect(picture.top, closeTo(clock.top, 0.5),
        reason: 'the picture card shares the clock card\'s row');
    expect(games.left, greaterThan(clock.right),
        reason: 'the games card sits beside the clock card, not over it');
    expect(picture.left, greaterThan(games.right),
        reason: 'the picture card sits beside the games card, not over it');

    expect(find.byTooltip('Device settings'), findsOneWidget,
        reason: 'settings stays one tap away in the app bar');
    expect(tester.takeException(), isNull);
  });

  // What each card does is a one-time read, so it opens from the card's info
  // control instead of costing three paragraphs of height on every page. The
  // state and the actions never move behind it.
  testWidgets('a display card explains itself when asked', (tester) async {
    final dashboard = _Dashboard();
    addTearDown(dashboard.registry.dispose);
    await loadRegistry(tester, dashboard.registry);
    await tester.runAsync(() async {
      await _addDevice(dashboard, host: '127.0.0.1', port: 8080);
    });

    await pumpHome(tester, dashboard.registry, size: const Size(360, 800));
    await tester.tap(find.text('Hall mirror'));
    await settleRoute(tester);

    const explanation =
        'The clock the mirror falls back to when no game is running.';
    expect(find.text('Saved display · showing now'), findsOneWidget,
        reason: 'the state is on screen without asking');
    expect(find.text(explanation), findsNothing,
        reason: 'the explanation is not permanent page height');

    await tester.tap(find.byTooltip('What this does').first);
    await tester.pump();
    expect(find.text(explanation), findsOneWidget,
        reason: 'the info control opens the explanation');

    await tester.tap(find.byTooltip('Hide what this does'));
    await tester.pump();
    expect(find.text(explanation), findsNothing, reason: 'and closes it again');
  });

  // A tile gets whatever width the grid gives it. In a phone's single column
  // that is room for the text beside the panel, which keeps the card short and
  // spends less vertical space per device; the dense tiles of a desktop grid
  // are too narrow for that and keep the panel above the text.
  testWidgets('a tile packs its text beside the panel when it has the width',
      (tester) async {
    final dashboard = _Dashboard();
    addTearDown(dashboard.registry.dispose);
    await loadRegistry(tester, dashboard.registry);
    await tester.runAsync(() async {
      await _addDevice(dashboard, host: '127.0.0.1', port: 8080);
    });

    await pumpHome(tester, dashboard.registry, size: const Size(360, 800));
    final phonePanel = tester.getRect(find.byType(DevicePreview));
    final phoneName = tester.getRect(find.text('Hall mirror'));
    expect(phoneName.left, greaterThanOrEqualTo(phonePanel.right),
        reason: 'a one-column phone tile puts the text beside the panel');
    expect(phoneName.top, lessThan(phonePanel.bottom),
        reason: 'the text shares the panel row rather than starting under it');
    expect(tester.takeException(), isNull);

    await pumpHome(tester, dashboard.registry, size: const Size(1280, 800));
    final gridPanel = tester.getRect(find.byType(DevicePreview));
    final gridName = tester.getRect(find.text('Hall mirror'));
    expect(gridName.top, greaterThanOrEqualTo(gridPanel.bottom),
        reason: 'a narrow grid tile keeps the panel above the text');
  });

  // The device page reads its preview off the record, so a frame that lands
  // after the page opened only reaches the panel if the record announces it.
  // The page decodes through `dart:ui` itself (the decoder seam lives on
  // `DevicePreview`, which the page builds for itself), so this reads the
  // pixels the page actually painted rather than a stubbed decode: a page that
  // never repaints keeps showing the empty black panel.
  testWidgets('a frame that arrives while the page is open repaints it',
      (tester) async {
    final dashboard = _Dashboard();
    addTearDown(dashboard.registry.dispose);
    await loadRegistry(tester, dashboard.registry);
    late final MirrorDevice device;
    await tester.runAsync(() async {
      device = await _addDevice(dashboard, host: '127.0.0.1', port: 8080);
    });
    // The mirror has nothing to hand over yet: its framebuffer request fails
    // for as long as the owner is opening the page.
    final lan = dashboard.lanAt('127.0.0.1:8080');
    lan.frameError = MirrorApiException('no frame yet');

    await pumpHome(tester, dashboard.registry);
    await tester.tap(find.text('Hall mirror'));
    await settleRoute(tester);
    expect(find.widgetWithText(FilledButton, 'Use smart clock'), findsOneWidget,
        reason: 'the device page is open');
    expect(_isMirrorGreen(await _paintedPreviewCentre(tester)), isFalse,
        reason: 'nothing from the mirror has been painted on the page yet');

    // The panel is now showing something the page has never seen. Its own
    // poll is what finds out, and the page has to repaint the frame that
    // arrives rather than keep the panel it was opened with.
    lan
      ..frameError = null
      ..frameBody = () => _flatFrame(_mirrorGreen);
    await tester.pump(const Duration(seconds: 2));
    await settleDecode(tester);

    expect(device.frame, isNotNull, reason: 'the page polled a real frame');
    expect(_isMirrorGreen(await _paintedPreviewCentre(tester)), isTrue,
        reason: 'the page repainted the frame the mirror sent');
  });

  testWidgets('changing one device leaves the other alone', (tester) async {
    final dashboard = _Dashboard();
    addTearDown(dashboard.registry.dispose);
    await loadRegistry(tester, dashboard.registry);
    late final MirrorDevice a;
    late final MirrorDevice b;
    var bMode = DisplayMode.picture;
    await tester.runAsync(() async {
      a = await _addDevice(
        dashboard,
        host: '127.0.0.1',
        port: 8080,
        name: 'Hall mirror',
      );
      b = await _addDevice(
        dashboard,
        host: '127.0.0.1',
        port: 8081,
        id: 'bbbb00000002',
        name: 'Kitchen mirror',
        mode: DisplayMode.picture,
        baseMode: DisplayMode.picture,
        pictureReady: true,
      );
      // The mirror really changes display: what it reports next must agree,
      // or the page would be reading a state the device no longer has.
      final kitchen = dashboard.lanAt('127.0.0.1:8081');
      kitchen.modeBody = (mode) {
        bMode = mode;
        kitchen.statusBody = () => _status(
              id: 'bbbb00000002',
              name: 'Kitchen mirror',
              mode: bMode,
              baseMode: bMode,
              pictureReady: true,
            );
        return DisplayResult(mode: mode, baseMode: mode, pictureReady: true);
      };
    });

    await pumpHome(tester, dashboard.registry);
    expect(find.text('Hall mirror'), findsOneWidget);
    expect(find.text('Kitchen mirror'), findsOneWidget);

    await tester.tap(find.text('Kitchen mirror'));
    await settleRoute(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Use smart clock'));
    await settleRoute(tester);

    expect(dashboard.lanAt('127.0.0.1:8081').modeCalls, 1);
    expect(dashboard.lanAt('127.0.0.1:8081').lastMode, DisplayMode.clock);
    expect(dashboard.lanAt('127.0.0.1:8080').modeCalls, 0,
        reason: 'the other device must never see the change');
    expect(b.baseMode, DisplayMode.clock);
    expect(a.baseMode, DisplayMode.clock);
    expect(find.text('Smart clock'), findsWidgets,
        reason: 'the page reads the change back from the device');
  });

  testWidgets('a restored record is not called old firmware', (tester) async {
    final dir = Directory.systemTemp.createTempSync('dash-restore');
    _temps.add(dir);
    const key = 'lan:127.0.0.1:8080';
    final name = base64Url.encode(utf8.encode(key)).replaceAll('=', '');
    File('${dir.path}/$name.frame')
        .writeAsBytesSync(encodeMirrorFrame(_frame()));
    final frameAt = DateTime.utc(2026, 9, 21, 11, 30);
    SharedPreferences.setMockInitialValues(<String, Object>{
      MirrorDevices.storeKey: jsonEncode(<String, Object>{
        'version': 1,
        'devices': <Object?>[
          <String, Object?>{
            'key': key,
            'id': 'aaaa00000001',
            'name': 'Hall mirror',
            'host': '127.0.0.1',
            'port': 8080,
            'width': 64,
            'height': 32,
            'flip180': false,
            'frame_at': frameAt.toIso8601String(),
          },
        ],
      }),
    });

    final dashboard = _Dashboard(directory: dir);
    addTearDown(dashboard.registry.dispose);
    await tester.runAsync(() => dashboard.registry.load());
    final device = dashboard.registry.devices.single;
    expect(device.frame, isNotNull, reason: 'the cached preview is restored');
    expect(device.status, isNull, reason: 'capability is not persisted');
    // The mirror is away, so the record keeps whatever it last knew.
    dashboard.lanAt('127.0.0.1:8080').statusError =
        MirrorApiException('could not reach 127.0.0.1');

    await pumpHome(tester, dashboard.registry);

    expect(find.text('Offline'), findsOneWidget);
    expect(find.textContaining('Preview needs firmware update'), findsNothing,
        reason: 'an unanswered device is not an old-firmware device');
    expect(find.textContaining('Last seen'), findsOneWidget);
    expect(find.text('Smart clock'), findsOneWidget,
        reason: 'the cached frame carries the mode it was captured in');
  });

  testWidgets('a preview that stopped arriving is stamped, a live one is not',
      (tester) async {
    final dashboard = _Dashboard();
    addTearDown(dashboard.registry.dispose);
    await loadRegistry(tester, dashboard.registry);
    late final MirrorDevice device;
    await tester.runAsync(() async {
      device = await _addDevice(dashboard, host: '127.0.0.1', port: 8080);
      await dashboard.registry.refresh(device, includeFrame: true);
    });
    expect(device.frameFresh, isTrue,
        reason: 'the frame came back with the poll, so the panel is live');

    await pumpHome(tester, dashboard.registry);
    expect(find.text('Wi-Fi'), findsOneWidget);
    expect(find.textContaining('Last seen'), findsNothing,
        reason: 'a preview that arrived with the poll is not an old one');

    // The address still answers — this is not an offline device — but the
    // panel stops sending frames. What the tile holds is now a remembered
    // picture, and it has to say so rather than implying a live view.
    dashboard.lanAt('127.0.0.1:8080').frameError =
        MirrorApiException('no frame this time');
    await tester
        .runAsync(() => dashboard.registry.refresh(device, includeFrame: true));
    await tester.pump();
    await tester.pump();

    expect(device.frame, isNotNull, reason: 'the last actual frame stays');
    expect(device.frameFresh, isFalse);
    expect(find.text('Wi-Fi'), findsOneWidget,
        reason: 'a stale preview is not an offline device');
    expect(find.textContaining('Last seen'), findsOneWidget,
        reason: 'the tile dates the picture it is still showing');
  });

  testWidgets('a mirror that answers is highlighted, an absent one is not',
      (tester) async {
    final dashboard = _Dashboard();
    addTearDown(dashboard.registry.dispose);
    await loadRegistry(tester, dashboard.registry);
    late final MirrorDevice attic;
    await tester.runAsync(() async {
      await _addDevice(
        dashboard,
        host: '127.0.0.1',
        port: 8080,
        name: 'Hall mirror',
      );
      attic = await _addDevice(
        dashboard,
        host: '127.0.0.1',
        port: 8081,
        id: 'bbbb00000002',
        name: 'Attic mirror',
      );
      dashboard.lanAt('127.0.0.1:8081').statusError =
          MirrorApiException('could not reach 127.0.0.1');
      await dashboard.registry.refresh(attic);
    });
    expect(attic.lanReachable, isFalse);

    await pumpHome(tester, dashboard.registry, size: const Size(360, 800));

    Card tileOf(String name) => tester.widget<Card>(
          find.ancestor(of: find.text(name), matching: find.byType(Card)).first,
        );
    final connected = tileOf('Hall mirror');
    final offline = tileOf('Attic mirror');
    expect(connected.color, isNotNull,
        reason: 'the answering mirror tints its tile');
    expect(offline.color, isNull,
        reason: 'the absent one keeps the plain card');
    expect(find.text('Wi-Fi'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // The owner opens the app to the mirrors they were just using, so the first
  // render orders the tiles by how recently each answered. That is the only
  // sort: a poll that later makes another device the most recent must not move
  // the tile the owner is about to tap.
  testWidgets('tiles are ordered by recency once, and never reshuffled',
      (tester) async {
    final at = DateTime.utc(2026, 9, 21, 11, 59);
    SharedPreferences.setMockInitialValues(<String, Object>{
      MirrorDevices.storeKey: jsonEncode(<String, Object>{
        'version': 1,
        'devices': <Object?>[
          _saved(
            key: 'lan:127.0.0.1:8080',
            id: 'aaaa00000001',
            name: 'Stale mirror',
            port: 8080,
            lastSeen: at.subtract(const Duration(hours: 3)),
          ),
          _saved(
            key: 'lan:127.0.0.1:8081',
            id: 'bbbb00000002',
            name: 'Fresh mirror',
            port: 8081,
            lastSeen: at.subtract(const Duration(minutes: 1)),
          ),
          _saved(
            key: 'lan:127.0.0.1:8082',
            id: 'cccc00000003',
            name: 'Never met',
            port: 8082,
          ),
        ],
      }),
    });

    final dashboard = _Dashboard();
    addTearDown(dashboard.registry.dispose);
    await tester.runAsync(() => dashboard.registry.load());
    dashboard.lanAt('127.0.0.1:8080').statusError =
        MirrorApiException('could not reach 127.0.0.1');
    dashboard.lanAt('127.0.0.1:8081').statusBody =
        () => _status(id: 'bbbb00000002', name: 'Fresh mirror');
    dashboard.lanAt('127.0.0.1:8082').statusError =
        MirrorApiException('could not reach 127.0.0.1');

    await pumpHome(tester, dashboard.registry, size: const Size(360, 800));

    double rowOf(String name) => tester.getTopLeft(find.text(name)).dy;
    expect(rowOf('Fresh mirror'), lessThan(rowOf('Stale mirror')),
        reason: 'the most recently reached device is first');
    expect(rowOf('Stale mirror'), lessThan(rowOf('Never met')),
        reason: 'a device that has never answered goes last');

    // The never-met device now answers, so it is the most recently reached
    // one. The grid must not act on that: the order was decided once.
    dashboard.lanAt('127.0.0.1:8082').statusError = null;
    dashboard.lanAt('127.0.0.1:8082').statusBody =
        () => _status(id: 'cccc00000003', name: 'Never met');
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));

    expect(dashboard.registry.devices.last.lastSeen, isNotNull,
        reason: 'the record really became the most recently reached one');
    expect(rowOf('Fresh mirror'), lessThan(rowOf('Stale mirror')),
        reason: 'the tiles did not move when the recency changed');
    expect(rowOf('Stale mirror'), lessThan(rowOf('Never met')),
        reason: 'the new contact did not jump to the top');
    expect(tester.takeException(), isNull);
  });

  testWidgets('no devices yet offers Add device and a manual address',
      (tester) async {
    final dashboard = _Dashboard();
    addTearDown(dashboard.registry.dispose);
    await tester.runAsync(() => dashboard.registry.load());
    dashboard.lanAt('127.0.0.1:8080').statusBody = () => _status();

    await pumpHome(tester, dashboard.registry);
    expect(find.text('No devices yet'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Add device'));
    await settleRoute(tester);
    expect(find.byType(AddDeviceScreen), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '127.0.0.1');
    await tester.enterText(find.byType(TextField).last, '8080');
    await tester.tap(find.widgetWithText(FilledButton, 'Add address'));
    await settleRoute(tester);
    await settleRoute(tester);

    expect(dashboard.registry.devices, hasLength(1));
    expect(find.text('Use smart clock'), findsOneWidget,
        reason: 'the added device opens its own page');
  });

  testWidgets('a failed discovery is retryable, not a dead end',
      (tester) async {
    final dashboard = _Dashboard()
      ..browseError = const SocketException('no lan');
    addTearDown(dashboard.registry.dispose);
    await tester.runAsync(() => dashboard.registry.load());

    await pumpHome(tester, dashboard.registry);
    await tester.pump();
    expect(find.textContaining('Could not search the network'), findsOneWidget);
    expect(find.text('No devices yet'), findsOneWidget,
        reason: 'the empty state is not the only message on screen');

    dashboard.browseError = null;
    final runsBefore = dashboard.browseRuns;
    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(dashboard.browseRuns, greaterThan(runsBefore),
        reason: 'Retry really searches again');
    expect(find.textContaining('Could not search the network'), findsNothing);
  });

  testWidgets('LAN discovery adds only mirrors that answer', (tester) async {
    final dashboard = _Dashboard()
      ..advertised.addAll(<LanDevice>[
        LanDevice(
            'smart-mirror-aabb._smartmirror._tcp.local', '127.0.0.1', 8080),
        // Advertises the same service but is not a mirror: multicast announces
        // a service, not a device.
        LanDevice(
            'smart-mirror-cccc._smartmirror._tcp.local', '127.0.0.1', 8081),
      ]);
    addTearDown(dashboard.registry.dispose);
    await loadRegistry(tester, dashboard.registry);
    dashboard.lanAt('127.0.0.1:8080').statusBody =
        () => _status(id: 'aaaa00000001', name: 'Hall mirror');
    dashboard.lanAt('127.0.0.1:8081').statusError =
        MirrorApiException('not a mirror');

    // The screen searches the network from its own first frame, so the search
    // is finished by pumping the screen, not by waiting on it from outside.
    await pumpHome(tester, dashboard.registry);
    await tester.pump();
    await tester.pump();

    expect(dashboard.registry.devices, hasLength(1));
    expect(find.text('Hall mirror'), findsOneWidget);
  });

  testWidgets('the grid fits a phone and a desktop at large text scale',
      (tester) async {
    final dashboard = _Dashboard();
    addTearDown(dashboard.registry.dispose);
    await loadRegistry(tester, dashboard.registry);
    await tester.runAsync(() async {
      for (var i = 0; i < 7; i++) {
        await _addDevice(
          dashboard,
          host: '127.0.0.1',
          port: 8080 + i,
          id: 'aaaa0000000$i',
          name: 'Mirror $i',
        );
      }
    });

    await pumpHome(tester, dashboard.registry,
        size: const Size(360, 800), textScale: 1.5);
    expect(find.text('Mirror 0'), findsOneWidget);
    expect(tester.takeException(), isNull,
        reason: 'no overflow on a phone at 1.5x text');

    await pumpHome(tester, dashboard.registry,
        size: const Size(1280, 800), textScale: 1.5);
    expect(find.text('Mirror 6'), findsOneWidget);
    expect(tester.takeException(), isNull,
        reason: 'no overflow on a desktop at 1.5x text');

    // Five tiles fit across a 1280-wide window, so the sixth wraps.
    final first = tester.getTopLeft(find.text('Mirror 0')).dy;
    final fifth = tester.getTopLeft(find.text('Mirror 4')).dy;
    final sixth = tester.getTopLeft(find.text('Mirror 5')).dy;
    expect(fifth, first, reason: 'the first five share a row');
    expect(sixth, greaterThan(first), reason: 'the sixth wraps to a new row');
  });

  testWidgets('on-screen tiles poll every 5s, the rest every 15s',
      (tester) async {
    final dashboard = _Dashboard();
    addTearDown(dashboard.registry.dispose);
    await loadRegistry(tester, dashboard.registry);
    await tester.runAsync(() async {
      for (var i = 0; i < 12; i++) {
        await _addDevice(
          dashboard,
          host: '127.0.0.1',
          port: 8080 + i,
          id: 'aaaa000000${i.toString().padLeft(2, '0')}',
          name: 'Mirror $i',
        );
      }
    });

    await pumpHome(tester, dashboard.registry, size: const Size(360, 800));
    final visible = dashboard.lanAt('127.0.0.1:8080');
    final hidden = dashboard.lanAt('127.0.0.1:8091');

    // Adding a device reads its status once; what the dashboard does with the
    // tiles is everything after that.
    final hiddenAtStart = hidden.statusCalls;

    // The first poll of the visible tiles happens as the screen settles.
    await tester.pump(const Duration(milliseconds: 100));
    expect(visible.statusCalls, greaterThan(hiddenAtStart));
    expect(visible.frameCalls, greaterThan(0));
    expect(hidden.statusCalls, hiddenAtStart,
        reason: 'a tile scrolled out of view is not polled every 5s');

    final visibleAtStart = visible.statusCalls;
    await tester.pump(const Duration(seconds: 5));
    expect(visible.statusCalls, greaterThan(visibleAtStart));

    // Past 15 seconds the hidden tiles are probed too.
    await tester.pump(const Duration(seconds: 10));
    expect(hidden.statusCalls, greaterThan(hiddenAtStart));
    expect(hidden.frameCalls, 0,
        reason: 'a hidden tile costs a status request, not a screenshot');
  });

  testWidgets('the pages a phone opens survive 1.5x text', (tester) async {
    final dashboard = _Dashboard();
    addTearDown(dashboard.registry.dispose);
    await loadRegistry(tester, dashboard.registry);
    await tester.runAsync(() async {
      await _addDevice(dashboard, host: '127.0.0.1', port: 8080);
    });

    await pumpHome(tester, dashboard.registry,
        size: const Size(360, 800), textScale: 1.5);

    await tester.tap(find.byTooltip('Add device'));
    await settleRoute(tester);
    expect(find.byType(AddDeviceScreen), findsOneWidget);
    expect(tester.takeException(), isNull,
        reason: 'the add-device page fits a phone at 1.5x text');

    await tester.pageBack();
    await settleRoute(tester);
    expect(find.byType(AddDeviceScreen), findsNothing);

    await tester.tap(find.text('Hall mirror'));
    await settleRoute(tester);
    expect(find.text('Use smart clock'), findsOneWidget);
    expect(tester.takeException(), isNull,
        reason: 'the device page fits a phone at 1.5x text');
  });

  testWidgets('a Bluetooth-only device says what the preview needs',
      (tester) async {
    final dashboard = _Dashboard();
    addTearDown(dashboard.registry.dispose);
    await loadRegistry(tester, dashboard.registry);
    dashboard.identities['REMOTE-1'] = const MirrorDeviceInfo(
      id: 'aaaa00000001',
      displayApi: 1,
      mode: DisplayMode.clock,
      baseMode: DisplayMode.clock,
      pictureReady: false,
    );
    late final MirrorDevice device;
    await tester.runAsync(() async {
      device = await dashboard.registry.addBle(BleScanEntry(
        BluetoothDevice.fromId('REMOTE-1'),
        'Twirling Elephant',
        -40,
      ));
    });
    expect(device.endpoint, isNull, reason: 'no Wi-Fi address on this record');
    expect(device.bleConnected, isTrue);

    await pumpHome(tester, dashboard.registry);

    expect(find.text('Bluetooth · Preview needs Wi-Fi'), findsOneWidget,
        reason: 'a Bluetooth link cannot serve previews');
  });

  testWidgets('a mirror whose firmware is too old says so', (tester) async {
    final dashboard = _Dashboard();
    addTearDown(dashboard.registry.dispose);
    await loadRegistry(tester, dashboard.registry);
    await tester.runAsync(() async {
      await _addDevice(
        dashboard,
        host: '127.0.0.1',
        port: 8080,
        displayApi: 0,
        mode: null,
        baseMode: null,
      );
    });

    await pumpHome(tester, dashboard.registry);

    expect(find.text('Wi-Fi · Preview needs firmware update'), findsOneWidget);
    expect(find.text('Mode unknown'), findsOneWidget,
        reason: 'a firmware that reports no mode is not the clock');
  });

  testWidgets('the local simulator stays a secondary destination',
      (tester) async {
    final dashboard = _Dashboard();
    addTearDown(dashboard.registry.dispose);
    await tester.runAsync(() => dashboard.registry.load());

    await pumpHome(tester, dashboard.registry);
    await tester.tap(find.byTooltip('More'));
    await settleRoute(tester);
    await tester.tap(find.text('Layout designer / simulator'));
    await settleRoute(tester);

    expect(find.byType(WorkspaceRoute), findsOneWidget,
        reason: 'the developer workspace is reachable without a device');
    expect(dashboard.registry.devices, isEmpty,
        reason: 'opening the simulator invents no device tile');
  });
}
