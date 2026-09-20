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

import '../services/firmware_update.dart';
import '../services/mirror_lan.dart';

/// Ask whether to update a mirror running [deviceVersion] to [bundledVersion],
/// the firmware this app ships. Returns true when the owner asked for it.
///
/// The panel goes dark while the mirror reboots, so that is said here rather
/// than met as a surprise.
Future<bool> confirmFirmwareUpdate(
  BuildContext context, {
  required String deviceVersion,
  required String bundledVersion,
}) async {
  final answer = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Firmware update available'),
      content: Text(
        'This mirror is running v$deviceVersion. This app includes '
        'v$bundledVersion.\n\n'
        'The image is sent over WiFi and the mirror restarts when it is '
        'installed, so the panel goes dark for a few seconds.',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
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
Future<bool> ensureMirrorReachable(BuildContext context, String ip) async {
  final lan = MirrorLan(ip);
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

/// Upload [bytes] to the mirror at [ip] behind a progress dialog and wait for
/// it to answer again after its reboot.
///
/// Returns the mirror's status once it is back, or null when it did not return
/// before [rebootTimeout]. Throws on an upload failure. The dialog is closed
/// either way.
Future<MirrorStatus?> pushFirmwareWithProgress(
  BuildContext context, {
  required String ip,
  required Uint8List bytes,
  required String label,
  Duration rebootTimeout = const Duration(seconds: 60),
}) async {
  final progress = ValueNotifier<double>(0);
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => FirmwareUploadDialog(progress: progress, fileName: label),
  ));
  try {
    return await uploadFirmwareAndWait(
      ip,
      bytes,
      onProgress: (sent, total) =>
          progress.value = total > 0 ? sent / total : 0,
      rebootTimeout: rebootTimeout,
    );
  } finally {
    if (context.mounted) Navigator.of(context).pop(); // close the dialog
    progress.dispose();
  }
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
