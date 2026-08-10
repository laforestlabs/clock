// The BLE push protocol, in pure Dart.
//
// The firmware (firmware/main/net/ble.c) speaks a small ASCII protocol on a
// command characteristic, with payload bytes on a data characteristic:
//
//   begin <kind> <len>   kind in {layout, config}, 1 <= len <= 32768
//   <data chunks>        each chunk a single ATT write within the MTU
//   commit
//
// This file only knows how to turn a payload into that sequence of frames.
// It imports no Flutter or plugin code, so it unit-tests without a device.
// The session in mirror_ble.dart writes the frames over the air.

import 'dart:convert';

/// Which characteristic a frame is destined for.
enum BleFrameKind { cmd, data }

/// One write to one characteristic.
class BleFrame {
  const BleFrame(this.kind, this.bytes);

  final BleFrameKind kind;
  final List<int> bytes;
}

/// Splits a payload into the wire frames: one `begin` command, data chunks
/// of at most [chunkSize] bytes, one `commit` command.
class BlePayloadWriter {
  BlePayloadWriter({this.chunkSize = 500});

  final int chunkSize;

  List<BleFrame> frames(String kind, List<int> payload) {
    final out = <BleFrame>[
      BleFrame(BleFrameKind.cmd, ascii.encode('begin $kind ${payload.length}')),
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
