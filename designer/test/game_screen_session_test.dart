// Session races use a broadcast protocol transport and the real native controller.
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mirror_designer/src/controller.dart';
import 'package:mirror_designer/src/engine/engine.dart';
import 'package:mirror_designer/src/engine/game_engine.dart';
import 'package:mirror_designer/src/services/mirror_ble.dart';
import 'package:mirror_designer/src/services/mirror_ble_game.dart';
import 'package:mirror_designer/src/services/mirror_ble_status.dart';
import 'package:mirror_designer/src/services/mirror_connection.dart';
import 'package:mirror_designer/src/ui/game_screen.dart';

class _Characteristic extends Fake implements BluetoothCharacteristic {}

/// The controls a game declares when it is steered by the pads only.
const List<MirrorControl> _buttonsOnly = <MirrorControl>[
  MirrorControl('Up', MirrorControlType.button),
  MirrorControl('Down', MirrorControlType.button),
  MirrorControl('Left', MirrorControlType.button),
  MirrorControl('Right', MirrorControlType.button),
];

/// The controls a game declares when the phone's tilt steers it: the pads'
/// buttons, plus the accelerometer axis the tilt drives. The mirror states the
/// type on the wire, which is how the screen knows tilt can drive the round.
const List<MirrorControl> _withTilt = <MirrorControl>[
  MirrorControl('Up', MirrorControlType.button),
  MirrorControl('Down', MirrorControlType.button),
  MirrorControl('Left', MirrorControlType.button),
  MirrorControl('Right', MirrorControlType.button),
  MirrorControl('TiltX', MirrorControlType.axis),
  MirrorControl('TiltY', MirrorControlType.axis),
];

class _Session extends Fake implements BleSession {
  final statuses = StreamController<String>.broadcast(sync: true);
  final start = Completer<MirrorGame>();
  List<String>? catalogue = ['snake'];
  Object? listFailure;
  Object? pauseFailure;
  Object? stopFailure;
  int pauses = 0;
  int stops = 0;
  int resumes = 0;
  int latencyCalls = 0;
  Completer<BleLatency?>? pendingLatency;
  Completer<void>? pendingPause;
  final started = <String>[];
  final inputs = <List<int>>[];
  @override
  BluetoothCharacteristic get gameIn => _Characteristic();
  @override
  Stream<String> get statusLines => statuses.stream;
  @override
  Future<List<String>?> listGames() async {
    if (listFailure != null) throw listFailure!;
    return catalogue;
  }

  @override
  Future<MirrorGame> startGame(String id) {
    started.add(id);
    return start.future;
  }

  @override
  Future<void> stopGame() async {
    stops++;
    if (stopFailure != null) throw stopFailure!;
  }

  @override
  Future<void> pauseGame() async {
    pauses++;
    if (pauseFailure != null) throw pauseFailure!;
    final pending = pendingPause;
    if (pending != null) await pending.future;
  }

  @override
  Future<void> resumeGame() async {
    resumes++;
  }

  @override
  Future<void> sendGameInput(List<int> values) async {
    inputs.add(List<int>.of(values));
  }

  @override
  Future<Duration> measureRoundTrip() async => Duration.zero;
  @override
  Future<BleLatency?> getLatency() {
    latencyCalls++;
    return pendingLatency?.future ?? Future.value(null);
  }

  void acknowledge({List<MirrorControl>? controls}) => start.complete(
        MirrorGame(started.single, controls ?? _buttonsOnly),
      );
}

class _Connection extends MirrorConnection {
  _Connection(this.live);
  _Session? live;
  @override
  BleSession? get session => live;
  @override
  MirrorConnectionStatus get status => live == null
      ? MirrorConnectionStatus.disconnected
      : MirrorConnectionStatus.connected;
  @override
  String get deviceName => 'Protocol fixture';
  @override
  Future<void> disconnect() async {
    live = null;
    notifyListeners();
  }

  void replace(_Session next) {
    live = next;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const sensorChannel = 'dev.fluttercommunity.plus/sensors/accelerometer';
  const sensorMethods =
      MethodChannel('dev.fluttercommunity.plus/sensors/method');
  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(sensorMethods, (_) async => null);
    messenger.setMockMethodCallHandler(
        const MethodChannel(sensorChannel), (_) async => null);
  });
  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(sensorMethods, null);
    messenger.setMockMethodCallHandler(
        const MethodChannel(sensorChannel), null);
  });

  Future<void> sample(WidgetTester tester, double x, double y, double z) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        sensorChannel,
        const StandardMethodCodec().encodeSuccessEnvelope(<double>[x, y, z, 0]),
        (_) {});
    await tester.pump(const Duration(milliseconds: 20));
  }

  Future<void> beginCalibration(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey<String>('mode-motion')));
    await tester.pump();
    if (find.text('Hold the phone still').evaluate().isEmpty) {
      await tester.tap(find.text('Start Game'));
      await tester.pump();
    }
    expect(find.text('Hold the phone still'), findsOneWidget);
  }

  Future<(_Session, _Connection)> boot(
    WidgetTester tester, {
    void Function(_Session)? configure,
    Future<ui.Image?> Function(GameEngine, Uint8List)? decodeFrame,
    Size surface = const Size(1000, 600),
  }) async {
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = DesignerController(MirrorEngine.open());
    await tester.runAsync(() => c.loadJson(
        '{"canvas":{"width":64,"height":32},"background":"#000000","widgets":[]}'));
    final session = _Session();
    configure?.call(session);
    final connection = _Connection(session);
    await tester.pumpWidget(MaterialApp(
        home: GameScreen(
            controller: c, connection: connection, decodeFrame: decodeFrame)));
    await tester.pump();
    await tester.pump();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
      connection.dispose();
      await session.statuses.close();
    });
    return (session, connection);
  }

  testWidgets('empty catalogue differs from unsupported firmware',
      (tester) async {
    final (_, connection) =
        await boot(tester, configure: (s) => s.catalogue = []);
    expect(find.text('No games on this mirror'), findsOneWidget);
    expect(connection.session, isNotNull);
    expect(find.text('Start Game'), findsNothing);
  });

  testWidgets('unsupported firmware is not presented as an empty catalogue',
      (tester) async {
    final (_, connection) =
        await boot(tester, configure: (s) => s.catalogue = null);
    expect(connection.session, isNotNull);
    expect(find.text('No games on this mirror'), findsNothing);
    expect(find.text('Start Game'), findsNothing);
    expect(find.textContaining('firmware'), findsWidgets);
  });

  testWidgets('catalogue timeout offers Retry without dropping the link',
      (tester) async {
    final (session, connection) = await boot(tester,
        configure: (s) =>
            s.listFailure = TimeoutException('catalogue timed out'));
    expect(connection.session, isNotNull);
    expect(find.text('Retry'), findsOneWidget);
    session.listFailure = null;
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(connection.session, isNotNull);
    expect(find.text('Start Game'), findsOneWidget);
  });
  testWidgets('motion starts only after neutral calibration completes',
      (tester) async {
    final (session, _) = await boot(tester);
    await beginCalibration(tester);
    for (var i = 0; i < 19; i++) {
      await sample(tester, 0, 0, 9.8);
    }
    expect(session.started, isEmpty);
    await sample(tester, 0, 0, 9.8);
    if (session.started.isEmpty) {
      await tester.tap(find.text('Start Game'));
      await tester.pump();
    }
    expect(session.started, ['snake']);
    session.acknowledge(controls: _withTilt);
    await tester.pump();
    await tester.pump();
    expect(find.text('Hold the phone still'), findsNothing);
    expect(find.byTooltip('Pause'), findsOneWidget);
  });

  testWidgets('missing motion samples fail without starting a remote game',
      (tester) async {
    final (session, connection) = await boot(tester);
    await beginCalibration(tester);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(session.started, isEmpty);
    expect(connection.session, isNotNull);
    expect(find.text('Motion unavailable; use manual controls'), findsWidgets);
  });

  testWidgets('cancelled calibration cannot start from late sensor samples',
      (tester) async {
    final (session, _) = await boot(tester);
    await beginCalibration(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await sample(tester, 0, 0, 9.8);
    }
    expect(session.started, isEmpty);
    expect(find.text('Start Game'), findsOneWidget);
  });

  testWidgets('sensor errors leave setup usable without starting',
      (tester) async {
    final (session, _) = await boot(tester);
    await beginCalibration(tester);
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        sensorChannel,
        const StandardMethodCodec().encodeErrorEnvelope(
            code: 'unavailable', message: 'No accelerometer'),
        (_) {});
    await tester.pump();
    await tester.pump();
    expect(session.started, isEmpty);
    expect(find.text('Motion unavailable; use manual controls'), findsWidgets);
    expect(find.text('Start Game'), findsOneWidget);
  });

  testWidgets('tilt drives the axes and never the buttons', (tester) async {
    final (session, _) =
        await boot(tester, configure: (s) => s.catalogue = ['tetris']);
    await beginCalibration(tester);
    for (var i = 0; i < 20; i++) {
      await sample(tester, 0, 0, 9.8);
    }
    if (session.started.isEmpty) {
      await tester.tap(find.text('Start Game'));
      await tester.pump();
    }
    session.acknowledge(controls: _withTilt);
    await tester.pump();
    await tester.pump();

    // Rolling the phone right sends a position on TiltX. The buttons that
    // would have been pressed by the old threshold mapper stay released: tilt
    // is a position now, not a direction.
    for (var i = 0; i < 12; i++) {
      await sample(tester, 0, 5, 9.8);
    }
    expect(session.inputs, isNotEmpty);
    expect(session.inputs.any((p) => p[4] > 0), isTrue,
        reason: 'a rightward roll drives TiltX positive');
    expect(session.inputs.every((p) => p[0] == 0 && p[1] == 0), isTrue,
        reason: 'no button is held by tilt');

    // Tipping the phone's top edge away moves the player up: the canvas axis
    // is positive downwards, so the value goes negative.
    for (var i = 0; i < 12; i++) {
      await sample(tester, 5, 0, 9.8);
    }
    expect(session.inputs.any((p) => p[5] < 0), isTrue,
        reason: 'a forward pitch drives TiltY negative (up)');
    expect(session.inputs.last.sublist(0, 4), [0, 0, 0, 0]);

    // A level phone is a level position: once the filter has settled, the app
    // either sends nothing at all (the value has not changed, so there is
    // nothing to send) or sends the middle. It never keeps driving the player
    // the way the old threshold mapper did. Which frame lands last depends on
    // the wall-clock send throttle, so this reads the set of frames after the
    // tilt is gone rather than picking one.
    for (var i = 0; i < 40; i++) {
      await sample(tester, 0, 0, 9.8);
    }
    final settledFrom = session.inputs.length;
    for (var i = 0; i < 20; i++) {
      await sample(tester, 0, 0, 9.8);
    }
    await tester.pump(const Duration(milliseconds: 200));
    expect(session.inputs.sublist(settledFrom).every((p) => p[4] == 0 && p[5] == 0),
        isTrue,
        reason: 'a still phone must only ever send a level position');

    // Manual play is untouched: the pad still presses its button.
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('mode-manual')));
    await tester.pump();
    await tester.tap(find.text('Resume').first);
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('control-Up')));
    await tester.pump();
    expect(session.inputs.any((p) => p[0] == 1), isTrue);
    // A released axis, not a recentred one: zero would be the middle of the
    // travel and would move the piece under a still phone.
    expect(session.inputs.last.sublist(4), [-32768, -32768]);
  });

  testWidgets('terminal notification before Start acknowledgment survives',
      (tester) async {
    final (session, _) = await boot(tester);
    await tester.tap(find.text('Start Game'));
    await tester.pump();
    session.statuses.add('game over snake');
    session.acknowledge();
    await tester.pump();
    await tester.pump();
    expect(
        find.textContaining(RegExp('Game Over|Round finished')), findsWidgets);
    expect(tester.takeException(), isNull);
  });
  testWidgets('watchdog pause before Start acknowledgment survives',
      (tester) async {
    final (session, _) = await boot(tester);
    await tester.tap(find.text('Start Game'));
    await tester.pump();
    session.statuses.add('game paused');
    session.acknowledge();
    await tester.pump();
    await tester.pump();
    expect(find.text('Resume'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
  testWidgets('unrelated game terminal event does not end active game',
      (tester) async {
    final (session, _) = await boot(tester);
    await tester.tap(find.text('Start Game'));
    await tester.pump();
    session.statuses.add('game over tetris');
    session.acknowledge();
    await tester.pump();
    await tester.pump();
    expect(
        find.textContaining(RegExp('Game Over|Round finished')), findsNothing);
    expect(find.byTooltip('Pause'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('a replaced session cannot finish an old pending Start',
      (tester) async {
    final (session, connection) = await boot(tester);
    await tester.tap(find.text('Start Game'));
    await tester.pump();
    final replacement = _Session()..catalogue = ['tetris'];
    connection.replace(replacement);
    await tester.pump();
    await tester.pump();
    session.acknowledge();
    await tester.pump();
    await tester.pump();
    expect(find.text('Start Game'), findsOneWidget);
    expect(find.byKey(const ValueKey('control-Up')), findsNothing);
    expect(replacement.started, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await replacement.statuses.close();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'mirror takeover disposes the local round and disconnect stays idle',
      (tester) async {
    final gate = Completer<void>();
    GameEngine? preview;
    var decoded = false;
    Future<void> drainDecode() async {
      for (var i = 0; i < 20 && preview != null && !decoded; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      if (preview != null) expect(decoded, isTrue);
      await tester.pump();
    }

    final (session, connection) =
        await boot(tester, decodeFrame: (engine, bytes) {
      preview = engine;
      final rendered = engine.decodeImage(bytes);
      unawaited(rendered.then<void>((_) {
        decoded = true;
      }));
      return gate.future.then((_) => rendered);
    });
    try {
      await connection.disconnect();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('start-game')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 25));
      final local = preview!;
      expect(find.byKey(const ValueKey<String>('control-Up')), findsOneWidget);
      connection.replace(session);
      await tester.pump();
      await tester.pump();
      expect(() => local.tick, throwsStateError);
      expect(find.byKey(const ValueKey<String>('start-game')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('control-Up')), findsNothing);
      gate.complete();
      await drainDecode();
      await connection.disconnect();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey<String>('start-game')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('control-Up')), findsNothing);
      expect(find.byKey(const ValueKey<String>('round-resume')), findsNothing);
    } finally {
      if (!gate.isCompleted) gate.complete();
      await drainDecode();
    }
  });

  testWidgets(
      'ordinary motion pause retains neutral but suspension recalibrates',
      (tester) async {
    final (session, _) = await boot(tester);
    addTearDown(() => tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    await beginCalibration(tester);
    for (var i = 0; i < 20; i++) {
      await sample(tester, 0, 0, 9.8);
    }
    session.acknowledge(controls: _withTilt);
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('game-pause')));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('round-resume')));
    await tester.pump();
    await tester.pump();
    expect(session.resumes, 1);
    expect(find.text('Hold the phone still'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(session.resumes, 1);
    await tester.tap(find.byKey(const ValueKey<String>('round-resume')));
    await tester.pump();
    expect(find.text('Hold the phone still'), findsOneWidget);
    for (var i = 0; i < 19; i++) {
      await sample(tester, 0, 0, 9.8);
    }
    expect(session.resumes, 1);
    await sample(tester, 0, 0, 9.8);
    await tester.pump();
    expect(session.resumes, 2);
    // Buttons released and axes idle: the paddle keeps the position it was
    // paused at instead of being recentred by the resume.
    expect(session.inputs.last, [0, 0, 0, 0, -32768, -32768]);
  });

  testWidgets('Help waits for the actual Pause acknowledgment', (tester) async {
    final (session, _) = await boot(tester);
    await tester.tap(find.text('Start Game'));
    await tester.pump();
    session.acknowledge();
    await tester.pump();
    await tester.pump();
    session.pendingPause = Completer<void>();
    await tester.tap(find.byKey(const ValueKey<String>('game-help')));
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('game-help-sheet')), findsNothing);
    expect(find.byKey(const ValueKey<String>('round-resume')), findsNothing);
    session.pendingPause!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
        find.byKey(const ValueKey<String>('game-help-sheet')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey<String>('round-resume')), findsOneWidget);
    expect(session.resumes, 0);
  });

  testWidgets('unsupported Help pause stops instead of covering a live game',
      (tester) async {
    final (session, connection) = await boot(tester, configure: (s) {
      s.pauseFailure =
          BlePushException('Update the mirror firmware to use Pause.');
    });
    await tester.tap(find.text('Start Game'));
    await tester.pump();
    session.acknowledge();
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('game-help')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(session.stops, 1);
    expect(connection.session, isNotNull);
    expect(find.byKey(const ValueKey<String>('game-help-sheet')), findsNothing);
    expect(find.byKey(const ValueKey<String>('start-game')), findsOneWidget);
    expect(find.text('This firmware cannot pause; the game was stopped.'),
        findsOneWidget);
  });

  testWidgets('confirmed mirror Restart starts after the acknowledged Stop',
      (tester) async {
    final (session, _) = await boot(tester);
    await tester.tap(find.text('Start Game'));
    await tester.pump();
    session.acknowledge();
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('game-pause')));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('round-restart')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey<String>('discard-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(session.stops, 1);
    expect(session.started, ['snake', 'snake']);
    expect(find.byKey(const ValueKey<String>('control-Up')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('start-game')), findsNothing);
  });

  testWidgets('diagnostics poll only while open with one request in flight',
      (tester) async {
    final (session, _) = await boot(tester);
    await tester.tap(find.text('Start Game'));
    await tester.pump();
    session.acknowledge();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(session.latencyCalls, 0);
    session.pendingLatency = Completer<BleLatency?>();
    await tester.tap(find.byKey(const ValueKey<String>('game-menu')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey<String>('menu-diagnostics')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(seconds: 3));
    expect(session.latencyCalls, 1);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Resume').first);
    await tester.pump();
    expect(session.resumes, 0);
    session.pendingLatency!.complete(null);
    await tester.pump();
    await tester.pump();
    expect(session.resumes, 1);
    await tester.pump(const Duration(seconds: 2));
    expect(session.latencyCalls, 1);
  });

  testWidgets('interruption while Start is pending pauses after acknowledgment',
      (tester) async {
    final (session, _) = await boot(tester);
    addTearDown(() => tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    await tester.tap(find.text('Start Game'));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    session.acknowledge();
    await tester.pump();
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('Resume'), findsWidgets);
    expect(session.resumes, 0);
  });

  testWidgets('manual Pause rejection does not pretend the mirror is paused',
      (tester) async {
    final (session, connection) = await boot(tester, configure: (s) {
      s.pauseFailure =
          BlePushException('Update the mirror firmware to use Pause.');
    });
    await tester.tap(find.text('Start Game'));
    await tester.pump();
    session.acknowledge();
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    await tester.pump();
    expect(connection.session, isNotNull);
    expect(find.text('Resume'), findsNothing);
    expect(find.byTooltip('Pause'), findsOneWidget);
    expect(find.textContaining('Update the mirror firmware to use Pause.'),
        findsWidgets);
    expect(session.inputs.last, [0, 0, 0, 0]);
  });

  testWidgets(
      'unsupported automatic Pause stops instead of faking preservation',
      (tester) async {
    final (session, connection) = await boot(tester, configure: (s) {
      s.pauseFailure =
          BlePushException('Update the mirror firmware to use Pause.');
    });
    addTearDown(() => tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    await tester.tap(find.text('Start Game'));
    await tester.pump();
    session.acknowledge();
    await tester.pump();
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(connection.session, isNotNull);
    expect(find.text('Start Game'), findsOneWidget);
    expect(find.text('This firmware cannot pause; the game was stopped.'),
        findsOneWidget);
  });

  testWidgets(
      'unacknowledged compatibility Stop disconnects the remote session',
      (tester) async {
    final (session, connection) = await boot(tester, configure: (s) {
      s.pauseFailure =
          BlePushException('Update the mirror firmware to use Pause.');
      s.stopFailure = BlePushException('busy');
    });
    addTearDown(() => tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    await tester.tap(find.text('Start Game'));
    await tester.pump();
    session.acknowledge();
    await tester.pump();
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(connection.session, isNull);
    expect(find.text('Game connection lost. Reconnect to play again.'),
        findsOneWidget);
  });

  testWidgets(
      'Stop timeout disconnects instead of leaving a stale paused round',
      (tester) async {
    final (session, connection) = await boot(tester, configure: (s) {
      s.stopFailure = TimeoutException('Stop acknowledgment lost');
    });
    await tester.tap(find.text('Start Game'));
    await tester.pump();
    session.acknowledge();
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('game-pause')));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('round-choose')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey<String>('discard-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(connection.session, isNull);
    expect(find.byKey(const ValueKey<String>('round-resume')), findsNothing);
    expect(find.byKey(const ValueKey<String>('start-game')), findsOneWidget);
    expect(find.text('Game connection lost. Reconnect to play again.'),
        findsOneWidget);
  });

  testWidgets('small large-text mirror controls retain actions and calibration',
      (tester) async {
    tester.view.padding = const FakeViewPadding(left: 48, right: 48);
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final (session, _) = await boot(tester,
        configure: (s) => s.catalogue = ['tetris'],
        surface: const Size(640, 360));
    final start = find.byKey(const ValueKey<String>('start-game'));
    await tester.ensureVisible(start);
    await tester.tap(start);
    await tester.pump();
    session.acknowledge();
    await tester.pump();
    await tester.pump();
    final right = find.byKey(const ValueKey<String>('control-Right'));
    final rotate = find.byKey(const ValueKey<String>('control-Up'));
    final drop = find.byKey(const ValueKey<String>('control-Down'));
    for (final action in [rotate, drop]) {
      final rect = tester.getRect(action);
      expect(rect.shortestSide, greaterThanOrEqualTo(48));
      expect(rect.left, greaterThan(tester.getRect(right).right));
      expect(rect.right, lessThanOrEqualTo(592));
      expect(rect.bottom, lessThanOrEqualTo(360));
    }
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey<String>('game-pause')));
    await tester.pump();
    await tester.pump();
    final motion = find.byKey(const ValueKey<String>('mode-motion'));
    await tester.ensureVisible(motion);
    await tester.tap(motion);
    await tester.pump();
    expect(find.text('Hold the phone still'), findsOneWidget);
    for (var i = 0; i < 20; i++) {
      await sample(tester, 0, 0, 9.8);
    }
    expect(session.resumes, 0);
    expect(session.started, ['tetris']);
    final manual = find.byKey(const ValueKey<String>('mode-manual'));
    await tester.ensureVisible(manual);
    await tester.tap(manual);
    await tester.pump();
    final resume = find.byKey(const ValueKey<String>('round-resume'));
    await tester.ensureVisible(resume);
    await tester.tap(resume);
    await tester.pump();
    await tester.pump();
    expect(rotate, findsOneWidget);
    expect(session.inputs.last, [0, 0, 0, 0]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Start timeout disconnects unknown remote session',
      (tester) async {
    final (session, connection) = await boot(tester);
    await tester.tap(find.text('Start Game'));
    await tester.pump();
    session.start.completeError(TimeoutException('test transport timeout'));
    await tester.pump();
    await tester.pump();
    expect(connection.session, isNull);
    expect(find.text('Game connection lost. Reconnect to play again.'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
