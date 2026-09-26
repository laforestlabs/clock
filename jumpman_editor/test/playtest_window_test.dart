// The playtest window, opened the way the editor opens it.
//
// Everything else about the playtest is covered elsewhere - the bot by
// autoplay_test.dart, the wire by fidelity_test.dart, the command line by
// playtest_protocol_test.dart - but the seam between them is this: the editor
// writes a level out, launches itself as a window, and reads back what that
// window reports. It is the part most likely to break quietly, so it is run for
// real: the built app is started with a level, and the report it writes is read.
//
// Needs the app built and a display, like the other native tests, and skips
// without one (a GTK window cannot open on a machine with no display at all):
//
//   cd jumpman_editor && flutter build linux --debug
//   LD_LIBRARY_PATH=build/linux/x64/debug/bundle/lib flutter test

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jumpman_editor/src/editor_state.dart';
import 'package:jumpman_editor/src/game_source.dart';
import 'package:jumpman_editor/src/playtest.dart';

import 'support.dart';

/// The built app, which is what a playtest window is a process of.
File _bundle() =>
    File('build/linux/x64/debug/bundle/jumpman_editor');

/// An editor whose playtest windows are the built app rather than the test
/// runner.
class _BundleEditorState extends EditorState {
  _BundleEditorState({required super.spec, required super.gameSource, required super.level});

  @override
  String get playtestExecutable => _bundle().absolute.path;
}

void main() {
  final hasDisplay = Platform.environment['DISPLAY'] != null ||
      Platform.environment['WAYLAND_DISPLAY'] != null;
  final reason = !hasDisplay
      ? 'no display: a playtest window cannot open without one'
      : !_bundle().existsSync()
          ? 'the app is not built: flutter build linux --debug'
          : null;

  test('the editor opens a window on the level and reads its report', () async {
    final spec = readSpec();
    final state = _BundleEditorState(
      spec: spec,
      gameSource: GameSource.fromFile(gameSourceFile.path),
      level: readAuthoredLevel(spec),
    );
    addTearDown(state.dispose);
    addTearDown(state.closePlaytestWindow);

    await state.openPlaytestWindow();
    expect(state.playtestError, isNull);
    expect(state.playtestRunning, isTrue);

    // The window has to load the level, open a session and get going: a few
    // seconds of a starting process. The first report is written with the
    // session open and before its first tick, so waiting for a tick is waiting
    // for the run.
    PlaytestReport? report;
    for (var i = 0; i < 100 && (report == null || report.tick == 0); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      report = state.playtestReport;
    }
    expect(report, isNotNull, reason: 'the window never reported');
    expect(report!.lives, 3);
    expect(report.auto, isFalse);
    expect(report.tick, greaterThan(0));
    expect(state.cameraWindow, report.camera);

    // The computer driving is the same window with a bot at the controls.
    await state.openPlaytestWindow(auto: true);
    expect(state.playtestRunning, isTrue);
    PlaytestReport? auto;
    for (var i = 0; i < 100 && (auto == null || auto.tick == 0); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      auto = state.playtestReport;
    }
    expect(auto, isNotNull, reason: 'the auto playtest window never reported');
    expect(auto!.auto, isTrue);
    expect(auto.lives, 3);

    await state.closePlaytestWindow();
    expect(state.playtestRunning, isFalse);
    expect(state.playtestReport, isNull);
  }, timeout: const Timeout(Duration(minutes: 2)), skip: reason);
}
