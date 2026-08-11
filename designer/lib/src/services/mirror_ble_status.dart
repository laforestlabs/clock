// Parsing of the BLE brightness status lines, kept free of Flutter and
// plugin imports so it is unit testable like the rest of the protocol layer.
// The wire format is defined in firmware/main/net/ble.c:
//
//   get brightness       -> "brightness <n> <auto|manual>"
//   set brightness <n>   -> "brightness ok <n>" | "brightness error <why>"
//   set brightness auto  -> "brightness ok auto"
//
// <n> is always the live panel value (0..255).

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
