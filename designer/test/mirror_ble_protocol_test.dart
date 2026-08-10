// The BLE payload writer, checked against a Dart re-implementation of the
// firmware's transfer rules (firmware/main/net/ble.c): begin/append/commit,
// busy rejection, length mismatch, size cap. No device needed.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/services/mirror_ble_protocol.dart';

/// Mirrors the firmware's staging-buffer logic closely enough to be a test
/// oracle for the writer: begin allocates, data appends, commit checks the
/// length and reports the kind, a second begin while busy is rejected.
class FirmwareAssembler {
  static const int maxPayload = 32768;

  String? kind;
  int? declared;
  final List<int> _payload = <int>[];
  bool busy = false;

  int get received => _payload.length;

  /// The bytes received so far, in order. The firmware hands exactly this
  /// buffer to the store on commit.
  List<int> get payload => List<int>.unmodifiable(_payload);

  void data(List<int> chunk) {
    if (!busy) return; // firmware drops data with no transfer open
    _payload.addAll(chunk);
  }

  String cmd(String line) {
    if (line.startsWith('begin ')) {
      final parts = line.split(' ');
      if (parts.length != 3) return 'begin error bad kind';
      final k = parts[1];
      if (k != 'layout' && k != 'config') return 'begin error bad kind';
      final len = int.tryParse(parts[2]);
      if (len == null || len < 1 || len > maxPayload) {
        return 'begin error too large';
      }
      if (busy) return 'begin error busy';
      kind = k;
      declared = len;
      _payload.clear();
      busy = true;
      return 'begin ok';
    }
    if (line == 'commit') {
      if (!busy) return 'commit error no transfer';
      if (received != declared) {
        busy = false;
        return 'commit error length mismatch';
      }
      final result = 'commit ok $kind';
      busy = false;
      return result;
    }
    if (line == 'abort') {
      busy = false;
      return 'abort ok';
    }
    return 'unknown command';
  }
}

void main() {
  group('BlePayloadWriter', () {
    test('200-byte payload uses one chunk', () {
      final writer = BlePayloadWriter(chunkSize: 500);
      final frames = writer.frames('layout', List<int>.filled(200, 0x41));
      expect(frames, hasLength(3)); // begin, one data, commit
      expect(frames[0].kind, BleFrameKind.cmd);
      expect(ascii.decode(frames[0].bytes), 'begin layout 200');
      expect(frames[1].kind, BleFrameKind.data);
      expect(frames[1].bytes, hasLength(200));
      expect(ascii.decode(frames[2].bytes), 'commit');
    });

    test('chunks never exceed the chunk size', () {
      final writer = BlePayloadWriter(chunkSize: 500);
      final frames = writer.frames('config', List<int>.filled(2048, 0x42));
      final chunks = frames.where((f) => f.kind == BleFrameKind.data).toList();
      for (final c in chunks) {
        expect(c.bytes.length, lessThanOrEqualTo(500));
      }
      expect(chunks, hasLength(5)); // ceil(2048 / 500)
      expect(chunks.last.bytes, hasLength(48));
    });

    test('round-trips a 2KB payload through the firmware rules', () {
      final payload = List<int>.generate(2048, (i) => i % 251);
      final writer = BlePayloadWriter(chunkSize: 500);
      final frames = writer.frames('layout', payload);

      final device = FirmwareAssembler();
      String? commitReply;
      for (final f in frames) {
        if (f.kind == BleFrameKind.cmd) {
          commitReply = device.cmd(ascii.decode(f.bytes));
        } else {
          device.data(f.bytes);
        }
      }

      expect(device.received, 2048);
      expect(commitReply, 'commit ok layout');
      // The assembler consumed the payload; compare against the original.
      expect(device.payload, payload);
    });

    test('length mismatch is caught at commit', () {
      final writer = BlePayloadWriter(chunkSize: 500);
      final frames = writer.frames('layout', List<int>.filled(100, 1));

      final device = FirmwareAssembler();
      for (final f in frames.take(frames.length - 1)) {
        if (f.kind == BleFrameKind.cmd) {
          device.cmd(ascii.decode(f.bytes));
        } else {
          device.data(f.bytes);
        }
      }
      // Send one more byte than declared.
      device.data(<int>[9]);
      expect(device.cmd('commit'), 'commit error length mismatch');
    });

    test('a second begin while busy is rejected', () {
      final writer = BlePayloadWriter(chunkSize: 500);
      final frames = writer.frames('layout', List<int>.filled(10, 1));

      final device = FirmwareAssembler();
      for (final f in frames.take(frames.length - 1)) {
        if (f.kind == BleFrameKind.cmd) {
          expect(device.cmd(ascii.decode(f.bytes)), isNot(startsWith('begin error')));
        } else {
          device.data(f.bytes);
        }
      }
      expect(device.cmd('begin layout 5'), 'begin error busy');
      expect(device.cmd('abort'), 'abort ok');
      expect(device.cmd('begin layout 5'), 'begin ok');
    });

    test('an oversized begin is rejected', () {
      final device = FirmwareAssembler();
      expect(device.cmd('begin layout 40000'), 'begin error too large');
      expect(device.cmd('begin layout 0'), 'begin error too large');
    });

    test('commit without a transfer is rejected', () {
      final device = FirmwareAssembler();
      expect(device.cmd('commit'), 'commit error no transfer');
    });
  });
}
