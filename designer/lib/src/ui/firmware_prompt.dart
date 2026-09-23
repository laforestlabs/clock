// The firmware-update dialogs: the prompt the workspace raises when it
// connects to a mirror running older firmware, the reachability check that
// every upload starts with, and the progress dialog the upload runs behind.
//
// The upload itself is services/firmware_update.dart, so the prompt and the
// Mirror screen's own update button cannot drift apart.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../services/bundled_firmware.dart';
import '../services/firmware_update.dart';
import '../services/mirror_ble.dart';
import '../services/mirror_devices.dart';
import '../services/mirror_lan.dart';

/// Ask whether to update a mirror running [deviceVersion] to [bundledVersion],
/// the firmware this app ships. Returns true when the owner asked for it.
///
/// The panel goes dark while the mirror reboots, so that is said here rather
/// than met as a surprise.
///
/// [blockedReason] is the app's own reason it cannot send the image — no
/// address for this mirror. The offer still reports the gap, because the owner
/// should know an update exists, but the update action is disabled instead of
/// being offered and then refused after the tap.
Future<bool> confirmFirmwareUpdate(
  BuildContext context, {
  required String deviceVersion,
  required String bundledVersion,
  String? blockedReason,
}) async {
  final answer = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Firmware update available'),
      content: Text(
        'This mirror is running v$deviceVersion. This app includes '
        'v$bundledVersion.\n\n'
        'The image is sent over Bluetooth and the mirror restarts when it is '
        'installed, so the panel goes dark for a few seconds.'
        '${blockedReason == null ? '' : '\n\n$blockedReason'}',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: blockedReason == null
              ? () => Navigator.of(context).pop(true)
              : null,
          child: Text('Update to v$bundledVersion'),
        ),
      ],
    ),
  );
  return answer == true;
}

/// Whether this phone can open a connection to the mirror at [ip], offering to
/// retry when it cannot. Returns false when the owner gave up.
///
/// Everything that follows sends megabytes over WiFi, and Bluetooth and WiFi
/// are separate paths, so a mirror that looks connected over Bluetooth can
/// still be unreachable at its WiFi address.
///
/// [lanFactory] is the transport this app sends through, so the probe and the
/// upload that follows it cannot end up talking to the address by different
/// means (and a test answers the probe instead of the network).
Future<bool> ensureMirrorReachable(
  BuildContext context,
  String ip, {
  MirrorLan Function(String ip)? lanFactory,
}) async {
  final lan = (lanFactory ?? MirrorLan.new)(ip);
  while (context.mounted) {
    if (await lan.reachable()) return true;
    if (!context.mounted) return false;
    final retry = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Can't reach the mirror over WiFi"),
        content: Text(
          'This phone could not open a connection to $ip.\n\n'
          'Bluetooth and WiFi are separate paths, so a mirror that looks '
          'connected can still be unreachable at its WiFi address. The two '
          'usual causes:\n\n'
          '• A VPN on this phone is routing local traffic into its tunnel. '
          'Turn it off, or allow local-network traffic (Proton VPN: Allow '
          'LAN connections).\n'
          '• This phone is not on the same WiFi network as the mirror.\n\n'
          'The data itself travels over WiFi — Bluetooth only carries the '
          'command — so this has to work before anything is sent.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
    if (retry != true) return false;
  }
  return false;
}

/// Install [bytes] over Bluetooth, retrying a dropped link by resuming the
/// mirror's retained OTA session.
Future<String?> pushFirmwareOverBleWithProgress(
  BuildContext context, {
  required MirrorDevices devices,
  required MirrorDevice device,
  required Uint8List bytes,
  required String label,
  Duration rebootTimeout = const Duration(seconds: 90),
  int attempts = 3,
}) async {
  final progress = ValueNotifier<double>(0);
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => FirmwareUploadDialog(progress: progress, fileName: label),
  ));
  final expected = firmwareVersionFromImage(bytes);
  try {
    for (var attempt = 1;; attempt++) {
      final session = device.connection.session;
      if (session == null) {
        throw BlePushException('the Bluetooth link to ${device.name} is down');
      }
      try {
        await session.pushFirmware(bytes,
            offset: firmwareResumeOffset(
                await session.getOtaStatus(), bytes.length),
            onProgress: (sent, total) =>
                progress.value = total > 0 ? sent / total : 0);
        break;
      } catch (e) {
        if (attempt >= attempts) rethrow;
        final back = await _awaitVersionAfterReboot(
            devices, device, rebootTimeout,
            expected: expected);
        if (back != null && back == expected) return back;
        await devices.connect(device);
      }
    }
    return _awaitVersionAfterReboot(devices, device, rebootTimeout,
        expected: expected);
  } finally {
    if (context.mounted) Navigator.of(context).pop();
    progress.dispose();
  }
}

Future<String?> _awaitVersionAfterReboot(
    MirrorDevices devices, MirrorDevice device, Duration timeout,
    {required String? expected}) async {
  final before = device.connection.session;
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final session = device.connection.session;
    if (session == null || identical(session, before)) {
      try {
        if (session == null) await devices.connect(device);
      } catch (_) {}
    } else {
      final version = device.connection.pong?.version;
      if (version != null) return version;
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  return null;
}

/// Upload progress dialog; dismissed by whoever opened it.
class FirmwareUploadDialog extends StatelessWidget {
  const FirmwareUploadDialog({
    super.key,
    required this.progress,
    required this.fileName,
  });

  final ValueListenable<double> progress;
  final String fileName;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Updating firmware'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(fileName, style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 12),
          ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (context, value, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                LinearProgressIndicator(value: value),
                const SizedBox(height: 8),
                Text('${(value * 100).toStringAsFixed(0)}%'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
