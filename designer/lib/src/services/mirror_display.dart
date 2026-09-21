// The display vocabulary shared by the LAN and BLE transports.
//
// A mirror has a saved *base* display (the smart clock or a still picture) and
// an *effective* display that games temporarily override. The firmware words
// are defined in firmware/main/net/api_server.c and firmware/main/net/ble.c;
// this file only translates them, and deliberately keeps the two apart: a
// caller that read `mode` as the saved state would show "clock" for a running
// game, and one that accepted "games" as a base would persist an override.

import 'dart:convert';
import 'dart:typed_data';

// The decoder raises the same exception the LAN transport raises, so callers
// have one failure vocabulary. `mirror_lan.dart` imports this file back for
// the frame types; the cycle is deliberate and both sides only need the names
// at the top level.
import 'mirror_lan.dart' show MirrorApiException;

/// Which display a mirror is showing.
enum DisplayMode { clock, games, picture }

/// The wire word for [mode].
String displayModeName(DisplayMode mode) => switch (mode) {
      DisplayMode.clock => 'clock',
      DisplayMode.games => 'games',
      DisplayMode.picture => 'picture',
    };

/// Parses a firmware display word. Anything this build does not know — a
/// missing field, or a mode a newer firmware grew — is null rather than a
/// default: guessing "clock" would claim a state the device never reported.
DisplayMode? parseDisplayMode(String? wire) => switch (wire) {
      'clock' => DisplayMode.clock,
      'games' => DisplayMode.games,
      'picture' => DisplayMode.picture,
      _ => null,
    };

/// Parses a *base* display word. A game is a temporary override the renderer
/// restores from, never a persisted base, so "games" is rejected here even
/// though [parseDisplayMode] understands it.
DisplayMode? parseBaseDisplayMode(String? wire) {
  final mode = parseDisplayMode(wire);
  return mode == DisplayMode.games ? null : mode;
}

/// The payload of the BLE `device {...}` reply: the firmware identity plus
/// the display capabilities the app needs before it offers picture or preview
/// controls.
class MirrorDeviceInfo {
  const MirrorDeviceInfo({
    required this.id,
    required this.displayApi,
    required this.mode,
    required this.baseMode,
    required this.pictureReady,
  });

  /// The firmware identity: 12 lowercase hexadecimal digits derived from the
  /// Wi-Fi station MAC, reported identically over LAN and BLE. It is what
  /// makes two records the same physical device; the BLE remote id and the
  /// friendly name are not.
  final String id;

  /// The display API version, 0 when the field is absent. Absent means the
  /// firmware predates picture/preview support.
  final int displayApi;

  /// The effective display, or null when the firmware reported one this
  /// build does not know.
  final DisplayMode? mode;

  /// The saved base display, or null when unknown. Never `games`.
  final DisplayMode? baseMode;

  /// Whether a stored picture matches the current panel dimensions.
  final bool pictureReady;

  /// Parses the object of a `device {...}` line. Returns null when it carries
  /// no usable identity, so a malformed reply is treated as an old mirror
  /// rather than as a device with a guessed name.
  static MirrorDeviceInfo? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    final api = json['display_api'];
    final mode = json['mode'];
    final baseMode = json['base_mode'];
    final pictureReady = json['picture_ready'];
    return MirrorDeviceInfo(
      id: id,
      displayApi: api is num ? api.toInt() : 0,
      mode: parseDisplayMode(mode is String ? mode : null),
      baseMode: parseBaseDisplayMode(baseMode is String ? baseMode : null),
      pictureReady: pictureReady is bool && pictureReady,
    );
  }
}

/// Parses a `device {...}` status line into [MirrorDeviceInfo]. Returns null
/// for anything else, including the "unknown command" an older mirror answers
/// to `get device` and a body that is not JSON, so a newer app keeps working
/// against firmware that predates the command.
MirrorDeviceInfo? parseDeviceInfoLine(String line) {
  if (!line.startsWith('device ')) return null;
  final body = line.substring('device '.length).trim();
  try {
    final json = jsonDecode(body);
    if (json is! Map<String, dynamic>) return null;
    return MirrorDeviceInfo.fromJson(json);
  } on FormatException {
    return null;
  }
}

/// The fixed header of an `MRF1` body: magic, little-endian panel size, frame
/// sequence, brightness, mode, orientation and a reserved byte. The firmware
/// side lives in firmware/main/frame_snapshot.c.
const int mirrorFrameHeaderSize = 16;

/// The largest RGB888 payload a frame or an upload may carry: a 256×256 panel,
/// the biggest geometry the picture-display API supports. Firmware refuses to
/// advertise `display_api:1` beyond it, so a larger body is a protocol error
/// rather than a big picture.
const int mirrorFrameMaxPayloadBytes = 196608;

/// `MRF1`, the snapshot body's magic.
const List<int> _frameMagic = <int>[0x4d, 0x52, 0x46, 0x31];

/// The firmware's `mirror_display_mode_t` value for [mode].
int _frameModeValue(DisplayMode mode) => switch (mode) {
      DisplayMode.clock => 0,
      DisplayMode.games => 1,
      DisplayMode.picture => 2,
    };

/// The mode a wire byte names, or null for a value this build does not know.
DisplayMode? _frameModeFromValue(int value) => switch (value) {
      0 => DisplayMode.clock,
      1 => DisplayMode.games,
      2 => DisplayMode.picture,
      _ => null,
    };

/// One frame the mirror actually rendered: `GET /api/frame`'s body and the
/// bytes cached under the application-support directory.
///
/// The pixels are exactly what the panel showed — gamma-corrected, scaled by
/// brightness and, when configured, rotated 180° — but *not* channel-swapped
/// for the panel's wiring. A consumer draws [rgb] as-is; nothing here may
/// re-apply brightness, gamma or flip.
class MirrorFrame {
  const MirrorFrame({
    required this.width,
    required this.height,
    required this.sequence,
    required this.brightness,
    required this.mode,
    required this.flip180,
    required this.rgb,
  });

  /// Panel width in pixels.
  final int width;

  /// Panel height in pixels.
  final int height;

  /// How many frames the device has shown since boot. Sampling identity, so
  /// it proves a *newer* sample, never which device it came from.
  final int sequence;

  /// 0–255, already applied to [rgb].
  final int brightness;

  /// The effective display the frame was sampled from.
  final DisplayMode mode;

  /// Whether [rgb] is rotated 180°, already applied.
  final bool flip180;

  /// Exactly `width * height * 3` RGB888 bytes.
  final Uint8List rgb;
}

/// The payload size [width]×[height] RGB888 occupies, or null when the
/// geometry is impossible: empty, or past [mirrorFrameMaxPayloadBytes].
int? _framePayloadSize(int width, int height) {
  if (width <= 0 || height <= 0) return null;
  final size = width * height * 3;
  if (size > mirrorFrameMaxPayloadBytes) return null;
  return size;
}

/// Decodes an `MRF1` snapshot body into a [MirrorFrame].
///
/// Strict by construction: the geometry comes from the frame's own header, not
/// from a status body that may describe a different moment, and every header
/// field is checked before any byte is handed on. A truncated, oversized,
/// foreign or internally inconsistent body raises [MirrorApiException] rather
/// than yielding pixels the mirror never sent — a caller that cached them
/// would show a fabricated preview.
MirrorFrame decodeMirrorFrame(Uint8List bytes) {
  if (bytes.length < mirrorFrameHeaderSize) {
    throw MirrorApiException('frame: ${bytes.length} bytes is shorter than the '
        '$mirrorFrameHeaderSize-byte header');
  }
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < _frameMagic.length; i++) {
    if (data.getUint8(i) != _frameMagic[i]) {
      throw MirrorApiException('frame: the body does not start with MRF1');
    }
  }
  final width = data.getUint16(4, Endian.little);
  final height = data.getUint16(6, Endian.little);
  final payload = _framePayloadSize(width, height);
  if (payload == null) {
    throw MirrorApiException(
        'frame: ${width}x$height is not a supported panel (at most 256x256)');
  }
  if (bytes.length != mirrorFrameHeaderSize + payload) {
    throw MirrorApiException('frame: ${bytes.length} bytes does not match the '
        '${mirrorFrameHeaderSize + payload} bytes ${width}x$height declares');
  }
  final mode = _frameModeFromValue(data.getUint8(13));
  if (mode == null) {
    throw MirrorApiException(
        'frame: unknown display mode ${data.getUint8(13)}');
  }
  final flip = data.getUint8(14);
  if (flip > 1) {
    throw MirrorApiException('frame: flip180 is not a boolean ($flip)');
  }
  final reserved = data.getUint8(15);
  if (reserved != 0) {
    throw MirrorApiException('frame: reserved byte is $reserved, not zero');
  }
  return MirrorFrame(
    width: width,
    height: height,
    sequence: data.getUint32(8, Endian.little),
    brightness: data.getUint8(12),
    mode: mode,
    flip180: flip == 1,
    // A view, not a copy: the bytes arrive from a fresh buffer per response,
    // and a 256×256 preview is not worth duplicating.
    rgb: Uint8List.sublistView(bytes, mirrorFrameHeaderSize),
  );
}

/// Packs [frame] into the `MRF1` body the device sends and the preview cache
/// stores.
///
/// It validates the same invariants [decodeMirrorFrame] does, so a frame that
/// could not have come off a device can never be written to the cache and
/// later read back as a real preview.
Uint8List encodeMirrorFrame(MirrorFrame frame) {
  final payload = _framePayloadSize(frame.width, frame.height);
  if (payload == null) {
    throw MirrorApiException(
        'frame: ${frame.width}x${frame.height} is not a supported panel '
        '(at most 256x256)');
  }
  if (frame.rgb.length != payload) {
    throw MirrorApiException(
        'frame: ${frame.rgb.length} bytes is not the $payload bytes '
        '${frame.width}x${frame.height} needs');
  }
  if (frame.brightness < 0 || frame.brightness > 255) {
    throw MirrorApiException(
        'frame: brightness ${frame.brightness} is out of range');
  }
  if (frame.sequence < 0 || frame.sequence > 0xffffffff) {
    throw MirrorApiException(
        'frame: sequence ${frame.sequence} does not fit the header');
  }
  final out = Uint8List(mirrorFrameHeaderSize + payload);
  final data = ByteData.sublistView(out);
  for (var i = 0; i < _frameMagic.length; i++) {
    data.setUint8(i, _frameMagic[i]);
  }
  data.setUint16(4, frame.width, Endian.little);
  data.setUint16(6, frame.height, Endian.little);
  data.setUint32(8, frame.sequence, Endian.little);
  data.setUint8(12, frame.brightness);
  data.setUint8(13, _frameModeValue(frame.mode));
  data.setUint8(14, frame.flip180 ? 1 : 0);
  data.setUint8(15, 0);
  out.setRange(mirrorFrameHeaderSize, out.length, frame.rgb);
  return out;
}

/// The display state a mode change or an upload reports:
/// `{"ok":true,"mode":…,"base_mode":…,"picture_ready":…}`.
///
/// [mode] is the *effective* display, so it may be `games` while a game runs;
/// [baseMode] is the saved display games override and is never `games`.
class DisplayResult {
  const DisplayResult({
    required this.mode,
    required this.baseMode,
    required this.pictureReady,
  });

  /// The display the panel is showing: the base, or games while one runs.
  final DisplayMode mode;

  /// The saved display games temporarily override: clock or picture.
  final DisplayMode baseMode;

  /// Whether the device holds a picture matching its current panel.
  final bool pictureReady;

  /// Parses a successful mode/upload response.
  ///
  /// Strict: the effective and base displays must both be named, the base must
  /// be a display games can restore to, and `picture_ready` must be reported.
  /// A body that cannot say what the panel is doing raises
  /// [MirrorApiException] rather than reporting a guessed clock.
  static DisplayResult fromJson(Map<String, dynamic> json) {
    final mode = json['mode'];
    final parsedMode = mode is String ? parseDisplayMode(mode) : null;
    if (parsedMode == null) {
      throw MirrorApiException(mode == null
          ? 'mode: the mirror did not report the display it is showing'
          : 'mode: the mirror reported an unsupported display "$mode"');
    }
    final base = json['base_mode'];
    final parsedBase = base is String ? parseBaseDisplayMode(base) : null;
    if (parsedBase == null) {
      throw MirrorApiException(base == null
          ? 'mode: the mirror did not report its saved display'
          : 'mode: "$base" is not a saved display');
    }
    final pictureReady = json['picture_ready'];
    if (pictureReady is! bool) {
      throw MirrorApiException(
          'mode: the mirror did not report whether a picture is stored');
    }
    return DisplayResult(
      mode: parsedMode,
      baseMode: parsedBase,
      pictureReady: pictureReady,
    );
  }
}
