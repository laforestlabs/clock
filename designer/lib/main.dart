// Smart mirror layout designer.
//
// Opens on the devices it has met, not on a render engine. Every tile shows
// what its mirror is actually displaying, decoded by this app alone, so the
// app starts on a checkout whose C core was never compiled. The engine is
// loaded by the routes that need it (the layout workspace, the game
// catalogue), which is where a missing library shows its fix.

import 'dart:async';

import 'package:flutter/material.dart';

import 'src/services/mirror_devices.dart';
import 'src/ui/device_routes.dart';
import 'src/ui/devices_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MirrorDesignerApp());
}

class MirrorDesignerApp extends StatefulWidget {
  const MirrorDesignerApp({super.key, this.devices});

  /// The registry the dashboard shows. The app owns and disposes its own; a
  /// test injects one to drive the screens without touching prefs.
  final MirrorDevices? devices;

  @override
  State<MirrorDesignerApp> createState() => _MirrorDesignerAppState();
}

class _MirrorDesignerAppState extends State<MirrorDesignerApp> {
  late final MirrorDevices _devices = widget.devices ?? MirrorDevices();
  late final bool _ownsDevices = widget.devices == null;

  @override
  void initState() {
    super.initState();
    // Remembered devices first, from prefs alone: no radio is opened, and no
    // Bluetooth or permission prompt stands between the owner and the home
    // screen. Discovery and the first status polls follow from the dashboard.
    unawaited(_devices.load());
  }

  @override
  void dispose() {
    if (_ownsDevices) _devices.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mirror Designer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00E5FF),
          brightness: Brightness.dark,
        ),
      ),
      // The routes under the home screen need to know when they are covered
      // (the device page stops polling while a nested route is on top).
      navigatorObservers: <NavigatorObserver>[appRouteObserver],
      home: DevicesScreen(devices: _devices),
    );
  }
}
