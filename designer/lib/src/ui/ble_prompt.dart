// Bluetooth adapter prompt shared by the workspace (auto-connect at launch)
// and the Mirror screen (scan). The BLE stack itself can turn the adapter on
// silently, but the user asked to be asked first: scanning or reconnecting
// with the radio off is a surprise, and on Android 13+ the OS then shows its
// own "allow turning on Bluetooth" dialog anyway.

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Returns true when the Bluetooth adapter is on, prompting the user to turn
/// it on first when it is off. Returns false without prompting when the
/// platform has no Bluetooth at all, when the user declines, or when the
/// adapter could not be switched on. Callers should check
/// [FlutterBluePlus.isSupported] themselves when they need to distinguish
/// "unavailable" from "declined".
Future<bool> ensureBluetoothOn(BuildContext context) async {
  if (!await FlutterBluePlus.isSupported) return false;
  if (await _adapterIsOn()) return true;

  if (!context.mounted) return false;
  final turnOn = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Bluetooth is off'),
      content: const Text('Turn on Bluetooth to connect to your mirror.'),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Turn on'),
        ),
      ],
    ),
  );
  if (turnOn != true) return false;

  try {
    // Throws (user rejected the system prompt, or the platform cannot turn
    // the adapter on programmatically) and waits for the adapter to reach
    // "on" before returning on success.
    await FlutterBluePlus.turnOn();
    return true;
  } catch (_) {
    return false;
  }
}

Future<bool> _adapterIsOn() async {
  final state = await FlutterBluePlus.adapterState.first
      .timeout(const Duration(seconds: 5), onTimeout: () => FlutterBluePlus.adapterStateNow);
  return state == BluetoothAdapterState.on;
}
