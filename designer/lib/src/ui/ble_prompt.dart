// Bluetooth adapter prompt shared by the dashboard and explicit BLE actions.

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
      content: const Text(
        'Nearby mirrors cannot be found or connected over Bluetooth while it '
        'is off. Turn on Bluetooth to continue. Wi-Fi devices still work.',
      ),
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

  if (!context.mounted) return false;
  return turnOnBluetooth(context);
}

/// Enables Bluetooth after an explicit user action, without another app prompt.
/// The platform may still require its own confirmation.
Future<bool> turnOnBluetooth(BuildContext context) async {
  try {
    // Throws (user rejected the system prompt, or the platform cannot turn
    // the adapter on programmatically) and waits for the adapter to reach
    // "on" before returning on success.
    await FlutterBluePlus.turnOn();
    return true;
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Bluetooth is still off. Turn it on in system settings.'),
        ),
      );
    }
    return false;
  }
}

Future<bool> _adapterIsOn() async {
  final state = await FlutterBluePlus.adapterState.first.timeout(
      const Duration(seconds: 5),
      onTimeout: () => FlutterBluePlus.adapterStateNow);
  return state == BluetoothAdapterState.on;
}
