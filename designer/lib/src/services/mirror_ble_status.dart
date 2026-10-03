// Parsing of the BLE status lines, kept free of Flutter and plugin imports so
// it is unit testable like the rest of the protocol layer. The wire format is
// defined in firmware/main/net/ble.c:
//
//   get brightness       -> "brightness <n> <auto|manual>"
//   set brightness <n>   -> "brightness ok <n>" | "brightness error <why>"
//   set brightness auto  -> "brightness ok auto"
//   get memory           -> "memory <internal_free> <internal_largest> <dma_largest> <psram_free>"
//
// <n> is always the live panel value (0..255). The memory figures are bytes.

/// A parsed `brightness <n> <auto|manual>` status line.
class BleBrightness {
  const BleBrightness({required this.value, required this.auto});

  /// The live panel brightness, 0..255.
  final int value;

  /// True when the device follows the layout's brightness, false when a
  /// manual override is set.
  final bool auto;
}

/// Parses a "brightness ..." status line into [BleBrightness]. Returns null
/// for anything else, including the answer an older mirror gives to the new
/// commands ("unknown command"), so a newer app keeps working against it.
BleBrightness? parseBrightnessStatus(String line) {
  final parts = line.split(' ');
  if (parts.length != 3 || parts[0] != 'brightness') return null;
  final value = int.tryParse(parts[1]);
  if (value == null || value < 0 || value > 255) return null;
  final mode = parts[2];
  if (mode != 'auto' && mode != 'manual') return null;
  return BleBrightness(value: value, auto: mode == 'auto');
}

/// What the mirror reports for `get ota`.
class BleOtaStatus {
  const BleOtaStatus(
      {required this.written, required this.total, required this.active});
  final int written;
  final int total;
  final bool active;

  static BleOtaStatus? parse(String line) {
    final parts = line.split(' ');
    if (parts.length != 4 || parts[0] != 'ota') return null;
    final written = int.tryParse(parts[1]);
    final total = int.tryParse(parts[2]);
    if (written == null || total == null) return null;
    if (parts[3] == 'active') {
      return BleOtaStatus(written: written, total: total, active: true);
    }
    if (parts[3] == 'idle') {
      return BleOtaStatus(written: written, total: total, active: false);
    }
    return null;
  }
}

/// The mirror's scarce-pool figures, from `get memory`.
///
/// This is the same reading the firmware's boot and 30-second console lines
/// carry: internal SRAM is the pool this board runs out of contiguous room in
/// (docs/ota_sram_fragmentation.md), and until this command existed only a
/// serial cable could see it.
///
/// [parse] returns null for anything that is not a memory line, including the
/// "unknown command" an older mirror answers to the new command, so a newer
/// app keeps working against it.
class BleMemory {
  const BleMemory({
    required this.internalFree,
    required this.internalLargest,
    required this.dmaLargest,
    required this.psramFree,
  });

  /// Free internal SRAM, in bytes.
  final int internalFree;

  /// The largest contiguous free block of internal SRAM, in bytes. The one
  /// that matters: a request bigger than this cannot be satisfied however much
  /// total memory is free.
  final int internalLargest;

  /// The largest contiguous DMA-capable block, in bytes.
  final int dmaLargest;

  /// Free PSRAM, in bytes.
  final int psramFree;

  static BleMemory? parse(String line) {
    final parts = line.split(' ');
    if (parts.length != 5 || parts[0] != 'memory') return null;
    final values = <int>[];
    for (var i = 1; i < parts.length; i++) {
      final v = int.tryParse(parts[i]);
      if (v == null || v < 0) return null;
      values.add(v);
    }
    return BleMemory(
      internalFree: values[0],
      internalLargest: values[1],
      dmaLargest: values[2],
      psramFree: values[3],
    );
  }
}

/// A parsed `latency <input_to_render_us> <conn_itvl_ms>` status line.
class BleLatency {
  const BleLatency({required this.inputToRenderUs, required this.connItvlMs});

  /// Time from the most recent input packet's arrival to the frame that
  /// rendered it, in microseconds, measured on the mirror's own clock.
  final int inputToRenderUs;

  /// The negotiated BLE connection interval in milliseconds, or 0 when the
  /// mirror could not read it (e.g. no connection).
  final int connItvlMs;
}

/// Parses a "latency ..." status line. Returns null for anything else,
/// including the "unknown command" an older mirror answers to the new
/// command, so a newer app keeps working against it.
BleLatency? parseLatencyStatus(String line) {
  final parts = line.split(' ');
  if (parts.length != 3 || parts[0] != 'latency') return null;
  final us = int.tryParse(parts[1]);
  final itvl = int.tryParse(parts[2]);
  if (us == null || itvl == null || us < 0 || itvl < 0) return null;
  return BleLatency(inputToRenderUs: us, connItvlMs: itvl);
}
