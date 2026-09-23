// The BLE push protocol, in pure Dart.
//
//   begin <kind> <len> [<offset>]  kind includes firmware for OTA resume
//   <data chunks>                  each chunk is one ATT write
//   commit
//
// The device answers begin and commit on the shared status stream; unsolicited
// game notifications are filtered by BleSession.
// Both replies share the status stream with unsolicited game notifications.
// BleSession waits for each matching reply before advancing the transaction.
//
// This file only splits a payload into wire frames. It imports no Flutter
// or plugin code, so the chunking protocol can be checked without a device.

import 'dart:convert';

/// Which characteristic a frame is destined for.
enum BleFrameKind { cmd, data }

/// One write to one characteristic.
class BleFrame {
  const BleFrame(this.kind, this.bytes);

  final BleFrameKind kind;
  final List<int> bytes;
}

/// The `begin` command line for a payload of [length] bytes.
String beginCommand(String kind, int length, {int offset = 0}) =>
    offset == 0 ? 'begin $kind $length' : 'begin $kind $length $offset';

/// Splits a payload into wire frames.
class BlePayloadWriter {
  BlePayloadWriter({this.chunkSize = 500});

  final int chunkSize;

  List<BleFrame> frames(String kind, List<int> payload) {
    final out = <BleFrame>[
      BleFrame(
          BleFrameKind.cmd, ascii.encode(beginCommand(kind, payload.length)))
    ];
    for (var offset = 0; offset < payload.length; offset += chunkSize) {
      final end = (offset + chunkSize < payload.length)
          ? offset + chunkSize
          : payload.length;
      out.add(BleFrame(BleFrameKind.data, payload.sublist(offset, end)));
    }
    out.add(BleFrame(BleFrameKind.cmd, ascii.encode('commit')));
    return out;
  }
}
