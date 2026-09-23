// How one device is shown: the small preview of its panel, the connectivity
// line under its name, and how long ago that preview was captured.
//
// Deliberately free of the native render engine. The dashboard shows the bytes
// the mirror actually sent, decoded through `dart:ui` alone, which is what
// lets the home screen work on a checkout whose C core was never compiled.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/mirror_devices.dart';
import '../services/mirror_display.dart';

/// Turns a frame's RGB888 bytes into an image the preview can draw.
///
/// A seam for tests only: the app always uses [decodeFrameToImage].
typedef FrameDecoder = Future<ui.Image> Function(MirrorFrame frame);

/// The default decoder: pack the RGB triplets into RGBA8888 and hand them to
/// `dart:ui`.
///
/// Nothing else is applied. The firmware gamma-corrected, brightness-scaled
/// and (when configured) rotated the pixels before sending them, so applying
/// any of that here would show a picture the panel never had.
Future<ui.Image> decodeFrameToImage(MirrorFrame frame) {
  final rgb = frame.rgb;
  final rgba = Uint8List(frame.width * frame.height * 4);
  for (var i = 0, j = 0; i + 2 < rgb.length; i += 3, j += 4) {
    rgba[j] = rgb[i];
    rgba[j + 1] = rgb[i + 1];
    rgba[j + 2] = rgb[i + 2];
    rgba[j + 3] = 0xFF;
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    frame.width,
    frame.height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

/// A device's panel as it actually looks right now.
///
/// When the record has never received a frame this is an empty display
/// outline sized to the panel the device reported, never a drawn clock or
/// game: a fabricated preview on a tile is worse than no preview at all.
class DevicePreview extends StatelessWidget {
  const DevicePreview({
    super.key,
    required this.device,
    this.height,
    this.decoder,
    this.semanticLabel,
  });

  final MirrorDevice device;

  /// The box the preview is centred in. Null lets the parent's constraints
  /// decide (a column of intrinsic-height content).
  final double? height;

  /// Test seam; see [FrameDecoder].
  final FrameDecoder? decoder;

  /// What a screen reader announces for this preview, if anything.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final frame = device.frame;
    if (frame == null) {
      return _PanelOutline(
        width: device.width,
        height: device.height,
        boxHeight: height,
        semanticLabel: semanticLabel,
      );
    }
    return FramePreview(
      frame: frame,
      height: height,
      decoder: decoder,
      semanticLabel: semanticLabel,
    );
  }
}

/// One actual frame, drawn pixel-exact.
///
/// Nearest-neighbour scaling is mandatory, for the same reason the workspace
/// preview uses it: any interpolation turns a 5x7 glyph into grey mush and the
/// tile stops describing the panel.
class FramePreview extends StatefulWidget {
  const FramePreview({
    super.key,
    required this.frame,
    this.height,
    this.decoder,
    this.semanticLabel,
  });

  final MirrorFrame frame;
  final double? height;

  /// Test seam; see [FrameDecoder].
  final FrameDecoder? decoder;

  final String? semanticLabel;

  @override
  State<FramePreview> createState() => _FramePreviewState();
}

class _FramePreviewState extends State<FramePreview> {
  ui.Image? _image;
  bool _busy = false;

  /// Bumped per decode: a frame that resolves after a newer one arrived is
  /// thrown away rather than drawn over it.
  int _generation = 0;

  FrameDecoder get _decoder => widget.decoder ?? decodeFrameToImage;

  @override
  void initState() {
    super.initState();
    unawaited(_decode());
  }

  @override
  void didUpdateWidget(FramePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.frame, widget.frame)) unawaited(_decode());
  }

  @override
  void dispose() {
    _generation++;
    _image?.dispose();
    _image = null;
    super.dispose();
  }

  Future<void> _decode() async {
    // A decode already running picks the newer frame up in its own `finally`;
    // bumping the generation here would throw its work away first.
    if (_busy) return;
    final frame = widget.frame;
    final generation = ++_generation;
    _busy = true;
    try {
      final image = await _decoder(frame);
      if (!mounted || generation != _generation) {
        image.dispose();
        return;
      }
      final previous = _image;
      setState(() => _image = image);
      // Disposed after the frame that stopped painting it, not before: an
      // image still in the layer tree cannot be freed underneath the raster.
      if (previous != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
      }
    } catch (_) {
      // A frame this build cannot draw leaves the outline in place. There is
      // nothing useful to say: the bytes came off the device and were
      // validated when they were decoded.
    } finally {
      _busy = false;
      // A newer frame may have arrived while this one was decoding.
      if (mounted && !identical(frame, widget.frame)) unawaited(_decode());
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final aspect = widget.frame.width <= 0 || widget.frame.height <= 0
        ? 2.0
        : widget.frame.width / widget.frame.height;
    final content = image == null
        ? const _PanelBody(child: SizedBox.shrink())
        : _PanelBody(
            child: RawImage(
              image: image,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.none,
              isAntiAlias: false,
            ),
          );
    final sized = SizedBox(
      height: widget.height,
      child: Center(
        child: AspectRatio(
          aspectRatio: aspect,
          child: content,
        ),
      ),
    );
    final label = widget.semanticLabel;
    if (label == null) return sized;
    return Semantics(image: true, label: label, child: sized);
  }
}

/// The empty display outline: the panel's shape, with nothing in it.
class _PanelOutline extends StatelessWidget {
  const _PanelOutline({
    required this.width,
    required this.height,
    required this.boxHeight,
    this.semanticLabel,
  });

  final int width;
  final int height;
  final double? boxHeight;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final aspect = width > 0 && height > 0 ? width / height : 2.0;
    final icon = Icon(
      Icons.tv_outlined,
      size: 20,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final sized = SizedBox(
      height: boxHeight,
      child: Center(
        child: AspectRatio(
          aspectRatio: aspect,
          child: _PanelBody(child: Center(child: icon)),
        ),
      ),
    );
    final label = semanticLabel;
    if (label == null) return sized;
    return Semantics(label: label, child: sized);
  }
}

/// The bezel every preview state shares, so the tile does not jump when a
/// frame replaces the outline.
class _PanelBody extends StatelessWidget {
  const _PanelBody({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF000000),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: child,
      ),
    );
  }
}

/// The effective display of a record, as the device page names it.
///
/// A restored record has no persisted mode, but the cached frame carries the
/// mode it was captured in, and that is the last thing the mirror actually
/// showed — a better answer than "unknown" while the device is away. It is
/// still a *remembered* mode: nothing here claims the panel is showing it now.
String deviceModeLabel(MirrorDevice device) => switch (_shownMode(device)) {
      DisplayMode.clock => 'Smart clock',
      DisplayMode.games => 'Games',
      DisplayMode.picture => 'Picture display',
      // An absent or unrecognised mode is not the clock: claiming a state the
      // device never reported is exactly what the parser refuses to do.
      null => 'Mode unknown',
    };

DisplayMode? _shownMode(MirrorDevice device) =>
    device.mode ?? device.frame?.mode;

/// Whether this record has ever heard what the device can do.
///
/// Capability is not persisted: a remembered device that has not answered
/// since launch reports no display API, and that is not evidence of old
/// firmware. Only a device that has actually reported — a status body, or a
/// live Bluetooth session — can be said to lack the feature.
bool deviceCapabilityKnown(MirrorDevice device) =>
    device.status != null || device.connection.session != null;

/// Whether a live path to the mirror exists right now.
///
/// Wi-Fi and Bluetooth are independent, so either one is enough. A connect in
/// flight is not a connection yet. This is the single answer the tile's
/// highlight and its status line both rest on, so the two can never disagree.
bool deviceIsOnline(MirrorDevice device) =>
    device.lanReachable || device.bleConnected;

/// The concise connectivity line for a tile.
///
/// Wi-Fi and Bluetooth are independent paths: a phone can hold a Bluetooth
/// link to a mirror it cannot reach over Wi-Fi, and the LAN is what serves
/// previews and picture uploads. So a Bluetooth-only device says what is
/// missing rather than looking broken.
String deviceStatusText(MirrorDevice device) {
  if (device.bleConnecting) return 'Connecting…';
  final parts = <String>[
    if (device.lanReachable) 'Wi-Fi',
    if (device.bleConnected) 'Bluetooth',
  ];
  if (!deviceIsOnline(device)) return 'Offline';
  if (deviceCapabilityKnown(device) && !device.supportsDisplay) {
    parts.add('Preview needs firmware update');
  } else if (!device.lanReachable) {
    parts.add('Preview needs Wi-Fi');
  }
  return parts.join(' · ');
}

/// Whether the tile's image is a remembered one rather than a live view.
///
/// Cached bytes remain useful when a snapshot fails, even if status still
/// succeeds. Reachability alone cannot make an old preview current.
bool devicePreviewIsStale(MirrorDevice device) =>
    device.frame != null && !device.frameFresh;

/// "2m ago", "just now": how long ago [at] was, coarse enough to be stable.
String relativeTime(DateTime at, {DateTime? now}) {
  final elapsed = (now ?? DateTime.now()).difference(at);
  if (elapsed.inSeconds < 45) return 'just now';
  if (elapsed.inMinutes < 60) return '${elapsed.inMinutes}m ago';
  if (elapsed.inHours < 24) return '${elapsed.inHours}h ago';
  return '${elapsed.inDays}d ago';
}

/// The whole tile as one sentence, for a screen reader: name, mode,
/// connectivity and whether the preview is remembered.
String deviceTileLabel(MirrorDevice device, {DateTime? now}) {
  final parts = <String>[device.displayName, deviceModeLabel(device)];
  parts.add(deviceStatusText(device));
  final frameAt = device.frameAt;
  if (devicePreviewIsStale(device) && frameAt != null) {
    parts.add('Last seen ${relativeTime(frameAt, now: now)}');
  }
  return parts.join(', ');
}
