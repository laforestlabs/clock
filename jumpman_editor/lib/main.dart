import 'package:flutter/material.dart';

import 'src/playtest_window.dart';
import 'src/ui/editor_app.dart';

/// The editor - or, when the editor has opened one, a playtest window.
///
/// The same binary runs both: the editor launches itself with `--playtest` and
/// the level to play (see PlaytestOptions), which is what makes the playtest a
/// real window of its own rather than a panel inside the editor's.
void main(List<String> args) {
  final playtest = PlaytestOptions.fromArgs(args);
  runApp(playtest == null
      ? const JumpmanEditorApp()
      : PlaytestWindowApp(options: playtest));
}
