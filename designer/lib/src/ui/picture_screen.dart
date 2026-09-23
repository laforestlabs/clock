// Framing one picture for a panel and sending it to the mirror.
//
// A mirror stores one still picture as raw pre-gamma RGB888 and renders it
// itself, so this screen is a composer rather than a file dropper: the chosen
// image is fitted to the panel's exact pixel grid here, shown at a whole-pixel
// zoom so the user can see what the panel will show, and only then sent over
// Wi-Fi. Nothing is written to the device until the user presses Display —
// choosing, re-framing and switching Fit/Fill are all local work.
//
// Two previews are on screen and they must not be confused. The upper one is
// the mirror's *actual* display, the bytes the device really sent; the lower
// one is this app's own composition, which is uncalibrated until the device
// answers with a fresh frame. Nothing local is ever stored on the record, so a
// tile can never show a picture the mirror has not received.

import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../services/mirror_devices.dart';
import '../services/mirror_display.dart';
import '../services/mirror_lan.dart';
import '../services/picture_encoder.dart';
import 'device_preview.dart';
import 'firmware_prompt.dart';
import 'picture_crop_screen.dart';

/// Picks one picture file, or null when the user cancelled.
///
/// A seam for tests: the app always opens the platform picker.
typedef PictureChooser = Future<XFile?> Function();

/// Composes [encoded] into panel-sized pre-gamma RGB888. The default is
/// [encodePicture]; tests replace it to control timing and pixels.
typedef PictureRenderer = Future<Uint8List> Function(
  Uint8List encoded, {
  required int width,
  required int height,
  required PictureFit fit,
  Rect? crop,
});

/// Asks whether this phone can open a connection to [endpoint], offering to
/// retry. The default is [ensureMirrorReachable].
typedef PictureReachability = Future<bool> Function(
  BuildContext context,
  String endpoint,
);

/// PNG and JPEG only: the mirror has no decoder, so the app must decode the
/// file itself, and these are the two formats the codec handles.
const XTypeGroup _pictureTypes = XTypeGroup(
  label: 'Pictures',
  extensions: <String>['png', 'jpg', 'jpeg'],
  mimeTypes: <String>['image/png', 'image/jpeg'],
  uniformTypeIdentifiers: <String>['public.png', 'public.jpeg'],
);

/// Opens the platform picker for one picture. Cancel returns null.
Future<XFile?> openPictureFile() =>
    openFile(acceptedTypeGroups: <XTypeGroup>[_pictureTypes]);

Future<bool> _defaultReachability(BuildContext context, String endpoint) =>
    ensureMirrorReachable(context, endpoint);

/// The composed bytes as the shared pixel-exact preview's input.
///
/// The pixels are the app's own pre-gamma RGB for the target panel, so the
/// remaining fields only fill the shape: [FramePreview] draws the RGB exactly
/// as given and reads none of them.
MirrorFrame framingPreviewFrame(Uint8List rgb, int width, int height) =>
    MirrorFrame(
      width: width,
      height: height,
      sequence: 0,
      brightness: 255,
      mode: DisplayMode.picture,
      flip180: false,
      rgb: rgb,
    );

/// The largest whole-pixel zoom the framing preview uses, in logical pixels.
const double framingPreviewMaxExtent = 192;

/// The zoom factor for a [width]×[height] panel.
///
/// Whole multiples only: a 64-wide panel is drawn 64, 128 or 192 logical
/// pixels wide, never smeared into 137, so every panel pixel stays a crisp
/// square the user can count.
int framingPreviewScale(
  int width,
  int height, {
  double maxExtent = framingPreviewMaxExtent,
}) {
  final longest = width > height ? width : height;
  if (longest <= 0) return 1;
  final scale = maxExtent ~/ longest;
  return scale < 1 ? 1 : scale;
}

/// What the mirror's answer to an upload means, in one sentence.
///
/// A game overrides the saved display while it runs, so a committed picture
/// behind a running game is *saved*, not showing: saying "now showing" there
/// would claim the panel switched when it did not.
String pictureOutcomeMessage(String name, DisplayResult result) {
  if (result.mode == DisplayMode.games) {
    return 'Picture saved; it will appear when the game ends.';
  }
  if (result.baseMode == DisplayMode.picture) {
    return 'Picture saved and now showing on $name.';
  }
  return 'Picture saved. Choose Picture display to show it on the panel.';
}

/// Compose one picture for a mirror's panel and send it.
///
/// The record is captured once, and every send goes to it: opening the picture
/// screen for one mirror and then selecting another in the dashboard must
/// never redirect an in-flight upload to the replacement.
class PictureScreen extends StatefulWidget {
  const PictureScreen({
    super.key,
    required this.devices,
    required this.device,
    this.chooser,
    this.renderer,
    this.reachability,
  });

  /// The registry that owns [device]; every write goes through it.
  final MirrorDevices devices;

  /// The mirror this screen frames for.
  final MirrorDevice device;

  /// Test seams; null uses the platform picker, the real encoder and the
  /// real reachability prompt.
  final PictureChooser? chooser;
  final PictureRenderer? renderer;
  final PictureReachability? reachability;

  @override
  State<PictureScreen> createState() => _PictureScreenState();
}

class _PictureScreenState extends State<PictureScreen> {
  /// The chosen file's original bytes. Every re-frame starts here rather than
  /// from a previous scaling, which would compound resampling artefacts.
  Uint8List? _source;
  String? _sourceName;

  PictureFit _fit = PictureFit.fit;
  Rect? _crop;
  bool _cropping = false;

  /// The composed RGB888 and the geometry it was composed for. Kept together
  /// so a send can prove the bytes match the panel they were framed for.
  Uint8List? _prepared;
  int _preparedWidth = 0;
  int _preparedHeight = 0;

  /// Cached so [FramePreview] sees the same frame object across rebuilds and
  /// does not re-decode it on every poll tick.
  MirrorFrame? _framingFrame;

  /// Bumped for every composition round: a decode that finishes after a newer
  /// selection must not draw over the framing the user is looking at.
  int _generation = 0;

  bool _preparing = false;
  bool _sending = false;
  String? _error;
  String? _notice;

  @override
  void dispose() {
    // A late decode has nothing to update once this screen is gone.
    _generation++;
    super.dispose();
  }

  // ------------------------------------------------------------- choosing

  /// Opens the picker and composes the chosen file.
  ///
  /// Cancel is a no-op, and a file this build cannot read leaves the previous
  /// selection and framing exactly as they were.
  Future<void> _choose() async {
    if (_sending) return;
    final XFile? file;
    try {
      file = await (widget.chooser ?? openPictureFile)();
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _error = 'The picture picker could not be opened: $e');
      return;
    }
    if (file == null) return; // the user cancelled: nothing changed

    // The length is read before the bytes so an oversized file is refused
    // without pulling it into memory.
    final Uint8List bytes;
    try {
      validatePictureFileSize(await file.length());
      bytes = await file.readAsBytes();
    } on PictureEncodeException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
      return;
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _error = 'That picture could not be read: $e');
      return;
    }
    if (!mounted) return;
    if (bytes.isEmpty) {
      setState(() => _error = 'That file is empty.');
      return;
    }
    if (!pictureGeometrySupported(widget.device.width, widget.device.height)) {
      setState(
        () => _error = 'The mirror has not reported a panel size this build '
            'can frame a picture for.',
      );
      return;
    }
    await _compose(
      bytes,
      name: _label(file),
      width: widget.device.width,
      height: widget.device.height,
    );
  }

  /// The name to show for a chosen file. A document URI or an in-memory file
  /// need not carry one, so the path is the fallback and nothing is invented.
  String _label(XFile file) {
    final name = file.name;
    if (name.isNotEmpty) return name;
    final path = file.path;
    if (path.isEmpty) return 'Selected picture';
    final cut = path.lastIndexOf(RegExp(r'[/\\]'));
    return cut == -1 ? path : path.substring(cut + 1);
  }

  // ------------------------------------------------------------ composing

  /// Re-composes the current source for the panel's current geometry.
  ///
  /// Called when Fit/Fill changes and when the panel turned out to have
  /// changed shape: both regenerate from the original file, never from a
  /// previously scaled copy.
  Future<void> _reframe() async {
    final source = _source;
    if (source == null) return;
    final width = widget.device.width;
    final height = widget.device.height;
    if (!pictureGeometrySupported(width, height)) {
      setState(
        () => _error = 'The mirror has not reported a panel size this build '
            'can frame a picture for.',
      );
      return;
    }
    await _compose(
      source,
      name: _sourceName,
      width: width,
      height: height,
      crop: _crop,
    );
  }

  Future<void> _compose(
    Uint8List source, {
    String? name,
    required int width,
    required int height,
    Rect? crop,
  }) async {
    final generation = ++_generation;
    setState(() {
      _preparing = true;
      _error = null;
      _notice = null;
    });
    final expected = width * height * 3;
    try {
      final rgb = await (widget.renderer ?? encodePicture)(
        source,
        width: width,
        height: height,
        fit: _fit,
        crop: crop,
      );
      if (!mounted || generation != _generation) return;
      if (rgb.length != expected) {
        setState(() {
          _preparing = false;
          _error = 'The picture came back ${rgb.length} bytes for a '
              '$expected-byte panel; nothing was prepared.';
        });
        return;
      }
      setState(() {
        _source = source;
        if (name != null) _sourceName = name;
        _crop = crop;
        _prepared = rgb;
        _preparedWidth = width;
        _preparedHeight = height;
        _framingFrame = framingPreviewFrame(rgb, width, height);
        _preparing = false;
      });
    } on Object catch (e) {
      if (!mounted || generation != _generation) return;
      // The previous framing stays: a file this build cannot read is not a
      // reason to lose a picture that already works.
      setState(() {
        _preparing = false;
        _error = _composeError(e);
      });
    }
  }

  String _composeError(Object error) {
    if (error is PictureEncodeException) return error.message;
    if (error is MirrorApiException) return error.message;
    return 'That picture could not be prepared: $error';
  }

  void _setFit(PictureFit fit) {
    if (_fit == fit || _sending) return;
    setState(() => _fit = fit);
    if (_source != null) unawaited(_reframe());
  }

  Future<void> _editCrop() async {
    final source = _source;
    if (source == null || _sending || _preparing || _cropping) return;
    setState(() => _cropping = true);
    try {
      final image = await decodePicture(source);
      try {
        if (!mounted) return;
        final route = MaterialPageRoute<Rect>(
          builder: (_) => PictureCropScreen(
            image: image,
            panelWidth: widget.device.width,
            panelHeight: widget.device.height,
            initialCrop: _crop,
          ),
        );
        final crop = await Navigator.of(context).push<Rect>(route);
        await route.completed;
        if (!mounted || crop == null) return;
        await _compose(
          source,
          width: widget.device.width,
          height: widget.device.height,
          crop: crop,
        );
      } finally {
        image.dispose();
      }
    } on Object catch (e) {
      if (mounted) setState(() => _error = _composeError(e));
    } finally {
      if (mounted) setState(() => _cropping = false);
    }
  }

  // -------------------------------------------------------------- sending

  /// Re-reads the device, then sends the prepared bytes.
  ///
  /// The bytes were framed for a panel size, so both the reachability of the
  /// endpoint and the panel's current geometry are established first. A mirror
  /// that changed shape is re-framed for the new geometry and needs a second
  /// press: uploading bytes cropped to a size it no longer has would be a
  /// silent edit of the user's picture.
  Future<void> _display() async {
    final device = widget.device;
    final prepared = _prepared;
    if (prepared == null || _sending || _preparing) return;
    final preparedWidth = _preparedWidth;
    final preparedHeight = _preparedHeight;
    final endpoint = device.endpoint;
    if (endpoint == null) {
      setState(() => _error = MirrorDevices.uploadNeedsWifiMessage);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
      _notice = null;
    });
    try {
      // Megabytes travel over Wi-Fi, and Bluetooth and Wi-Fi are separate
      // paths, so this is checked before anything is sent.
      final reachable = await (widget.reachability ?? _defaultReachability)(
          context, endpoint);
      if (!mounted) return;
      if (!reachable) {
        setState(() => _sending = false);
        return;
      }
      await widget.devices.refresh(device, includeFrame: false);
      if (!mounted) return;
      if (device.removed) {
        // The record was folded into another one while this screen was open:
        // it is no longer a target, so nothing is sent from here.
        setState(() {
          _sending = false;
          _error = 'This device was merged into another record; nothing was '
              'sent. Open it from the dashboard.';
        });
        return;
      }
      if (!device.lanReachable) {
        setState(() {
          _sending = false;
          _error = 'The mirror did not answer, so nothing was sent.';
        });
        return;
      }
      final width = device.width;
      final height = device.height;
      if (width != preparedWidth || height != preparedHeight) {
        // The bytes are framed for a panel the mirror no longer has: re-frame
        // rather than let it crop them blindly, and ask for another press.
        await _reframeAfterPanelChange(width, height);
        return;
      }
      final result = await widget.devices.uploadPicture(
        device,
        prepared,
        width: preparedWidth,
        height: preparedHeight,
      );
      if (!mounted) return;
      setState(() {
        _sending = false;
        _notice = pictureOutcomeMessage(device.displayName, result);
      });
    } on Object catch (e) {
      if (!mounted) return;
      final width = device.width;
      final height = device.height;
      final panelChanged = width != preparedWidth || height != preparedHeight;
      if (panelChanged ||
          (e is MirrorRegistryException && e.statusCode == 409)) {
        // Read the panel back first: a refusal is the device saying its size
        // is not the one these bytes were framed for, so the size to re-frame
        // for is whatever it reports now, not what this screen last saw.
        await widget.devices.refresh(device, includeFrame: false);
        if (!mounted) return;
        await _reframeAfterPanelChange(device.width, device.height);
        return;
      }
      // An HTTP status means the mirror answered and refused; the registry's
      // own "no address" refusal means nothing was ever sent. Both are
      // certain. Anything else — no answer, a timeout, a socket that died
      // mid-body — leaves the upload's fate unknown: the device may have
      // committed and lost the reply, so this screen says what is true of both
      // outcomes and reads the device back instead of guessing.
      final certain = e is MirrorRegistryException &&
          (e.statusCode != null ||
              e.message == MirrorDevices.uploadNeedsWifiMessage);
      final message = _failureMessage(e);
      setState(() {
        _sending = false;
        _error = certain
            ? message
            : 'Could not confirm the upload; refresh the device before '
                'retrying. $message';
      });
      if (!certain) {
        unawaited(widget.devices.refresh(device, includeFrame: true));
      }
    }
  }

  String _failureMessage(Object error) {
    if (error is MirrorRegistryException) return error.message;
    if (error is MirrorApiException) return error.message;
    return '$error';
  }

  /// Handles a panel that turned out not to be the size the prepared bytes
  /// were framed for: regenerates the framing from the original file and asks
  /// for another press. Nothing is sent until the user has looked at it.
  ///
  /// A geometry this build cannot frame for leaves the error from [_reframe]
  /// in place instead of the "press again" notice, because there is nothing
  /// to press Display for.
  Future<void> _reframeAfterPanelChange(int width, int height) async {
    setState(() => _sending = false);
    await _reframe();
    if (!mounted || _error != null) return;
    setState(
      () => _notice = 'The mirror\'s panel is now $width×$height; the framing '
          'has been redone for it. Check it, then press Display again.',
    );
  }

  // --------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final device = widget.device;
    return PopScope<Object?>(
      // A bounded upload is already committed to the device; leaving mid
      // request would leave the user with no answer at all.
      canPop: !_sending,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || !_sending) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('The picture is still being sent.'),
            duration: Duration(seconds: 2),
          ),
        );
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Picture display')),
        body: ListenableBuilder(
          listenable: device,
          builder: (context, _) => SafeArea(
            child: LayoutBuilder(builder: (context, constraints) {
              final wide = constraints.maxWidth >= 600;
              final controls = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _chooserRow(context, device),
                  if (_source != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        _sourceName ?? 'Selected picture',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  const SizedBox(height: 8),
                  _framingControls(context),
                ],
              );
              return Column(
                children: <Widget>[
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 1040),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              if (wide)
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: <Widget>[
                                          _header(context, device),
                                          const SizedBox(height: 12),
                                          controls,
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 24),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: <Widget>[
                                          _actualPreview(context, device),
                                          const SizedBox(height: 12),
                                          _framingPreview(context),
                                        ],
                                      ),
                                    ),
                                  ],
                                )
                              else ...<Widget>[
                                Row(
                                  children: <Widget>[
                                    Expanded(child: _header(context, device)),
                                    const SizedBox(width: 16),
                                    SizedBox(
                                      width: 128,
                                      child: _actualPreview(context, device),
                                    ),
                                  ],
                                ),
                                const Divider(height: 24),
                                controls,
                                const SizedBox(height: 12),
                                _framingPreview(context),
                              ],
                              if (_notice != null) ...<Widget>[
                                const SizedBox(height: 12),
                                _Note(
                                  key: const ValueKey<String>('picture-notice'),
                                  icon: Icons.check_circle_outline,
                                  text: _notice!,
                                ),
                              ],
                              if (_error != null) ...<Widget>[
                                const SizedBox(height: 12),
                                _Note(
                                  key: const ValueKey<String>('picture-error'),
                                  icon: Icons.error_outline,
                                  text: _error!,
                                  isError: true,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: constraints.maxHeight * .4,
                      maxWidth: 1072,
                    ),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: SizedBox(
                        width: double.infinity,
                        child: _sendRow(context, device),
                      ),
                    ),
                  ),
                ],
              );
            }),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, MirrorDevice device) {
    final theme = Theme.of(context);
    final size = pictureGeometrySupported(device.width, device.height)
        ? '${device.width} × ${device.height} pixels'
        : 'Panel size not reported yet';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(device.displayName, style: theme.textTheme.titleMedium),
        const SizedBox(height: 2),
        Text(size, style: theme.textTheme.bodyMedium),
      ],
    );
  }

  Widget _actualPreview(BuildContext context, MirrorDevice device) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Tooltip(
          message: _actualCaption(device),
          child: Text(
            _actualCaption(device),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
        const SizedBox(height: 4),
        // The record's own frame: this screen never writes a locally composed
        // picture into it, so what is drawn here came off the mirror.
        DevicePreview(
          device: device,
          height: 64,
          semanticLabel: 'The display of ${device.displayName}',
        ),
      ],
    );
  }

  /// Describes what the upper preview is, without implying it is live.
  String _actualCaption(MirrorDevice device) {
    final at = device.frameAt;
    if (device.frame == null) {
      return 'The mirror has not sent its display yet';
    }
    if (at == null) return 'The mirror\'s display';
    if (devicePreviewIsStale(device)) {
      return 'Last display sent ${relativeTime(at)}';
    }
    return 'The mirror\'s display now';
  }

  Widget _chooserRow(BuildContext context, MirrorDevice device) {
    final enabled = !_sending &&
        !_cropping &&
        device.supportsDisplay &&
        pictureGeometrySupported(device.width, device.height);
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        OutlinedButton.icon(
          key: const ValueKey<String>('picture-choose'),
          onPressed: enabled ? _choose : null,
          icon: const Icon(Icons.image_outlined),
          label: Text(_source == null ? 'Choose picture' : 'Choose another'),
        ),
        if (_preparing)
          const Text(
            'Preparing the picture…',
            key: ValueKey<String>('picture-preparing'),
          ),
      ],
    );
  }

  Widget _framingControls(BuildContext context) {
    final enabled = !_sending && !_preparing && !_cropping && _source != null;
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        SegmentedButton<PictureFit>(
          segments: const <ButtonSegment<PictureFit>>[
            ButtonSegment<PictureFit>(
              value: PictureFit.fit,
              label: Text('Fit'),
              icon: Icon(Icons.fit_screen),
            ),
            ButtonSegment<PictureFit>(
              value: PictureFit.fill,
              label: Text('Fill'),
              icon: Icon(Icons.crop),
            ),
          ],
          selected: <PictureFit>{_fit},
          onSelectionChanged:
              enabled ? (selection) => _setFit(selection.first) : null,
        ),
        OutlinedButton.icon(
          key: const ValueKey<String>('picture-crop'),
          onPressed: enabled ? _editCrop : null,
          icon: const Icon(Icons.crop),
          label: Text(_cropping ? 'Opening crop…' : 'Crop / zoom'),
        ),
        const Tooltip(
          triggerMode: TooltipTriggerMode.tap,
          message: 'Crop / zoom selects an area with the panel’s aspect ratio '
              'locked. Fit keeps the selected area with black bars; Fill '
              'covers the panel. The framing preview is local; the mirror’s '
              'own preview shows its calibrated colors.',
          child: Padding(
            padding: EdgeInsets.all(12),
            child: Icon(Icons.info_outline, size: 20),
          ),
        ),
      ],
    );
  }

  Widget _framingPreview(BuildContext context) {
    final frame = _framingFrame;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Framing preview', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        if (frame == null)
          const _EmptyFraming()
        else
          KeyedSubtree(
            key: const ValueKey<String>('picture-framing'),
            child: FramePreview(
              frame: frame,
              height: (frame.height *
                      framingPreviewScale(frame.width, frame.height))
                  .clamp(64, 160)
                  .toDouble(),
              semanticLabel: 'Framing preview: ${frame.width} by '
                  '${frame.height} panel pixels',
            ),
          ),
      ],
    );
  }

  Widget _sendRow(BuildContext context, MirrorDevice device) {
    final canSend = _canSend(device);
    final hasPrepared = _prepared != null;
    final label = _error != null && hasPrepared
        ? 'Retry display on ${device.displayName}'
        : 'Display on ${device.displayName}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (_sending) ...<Widget>[
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          Text(
            'Sending picture…',
            key: const ValueKey<String>('picture-sending'),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
        ],
        FilledButton.icon(
          key: const ValueKey<String>('picture-display'),
          onPressed: canSend ? _display : null,
          icon: const Icon(Icons.upload),
          label: Text(label),
        ),
        if (_geometryChanged(device)) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            'The mirror\'s panel is ${device.width}×${device.height} now; '
            'pressing Display re-frames the picture for it.',
            key: const ValueKey<String>('picture-geometry-change'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (device.gamesRunning) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            'A game is running on this mirror; a saved picture will appear '
            'when the game ends.',
            key: const ValueKey<String>('picture-game-running'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 8),
        ..._guidance(context, device),
      ],
    );
  }

  /// The obstacles, if any, between a prepared picture and the device. A
  /// Bluetooth-only mirror that also runs old firmware gets both: the update
  /// and the Wi-Fi address are each missing for a reason.
  List<Widget> _guidance(BuildContext context, MirrorDevice device) {
    final style = Theme.of(context).textTheme.bodySmall;
    final notes = <Widget>[];
    if (device.endpoint == null) {
      notes.add(
        Text(
          MirrorDevices.uploadNeedsWifiMessage,
          key: const ValueKey<String>('picture-needs-wifi'),
          style: style,
        ),
      );
    } else if (!device.lanReachable) {
      notes.add(
        Text(
          'The mirror is not answering at ${device.endpoint} right now.',
          key: const ValueKey<String>('picture-unreachable'),
          style: style,
        ),
      );
    }
    if (!device.supportsDisplay) {
      notes.add(
        Text(
          'This mirror\'s firmware has no picture support. Update it from the '
          'device page, then come back.',
          key: const ValueKey<String>('picture-unsupported'),
          style: style,
        ),
      );
    }
    return notes;
  }

  bool _canSend(MirrorDevice device) =>
      _prepared != null &&
      !_preparing &&
      !_cropping &&
      !_sending &&
      !device.uploading &&
      device.supportsDisplay &&
      device.endpoint != null &&
      device.lanReachable;

  bool _geometryChanged(MirrorDevice device) =>
      _prepared != null &&
      pictureGeometrySupported(device.width, device.height) &&
      (device.width != _preparedWidth || device.height != _preparedHeight);
}

/// The placeholder before anything is chosen: the panel's shape, empty.
class _EmptyFraming extends StatelessWidget {
  const _EmptyFraming();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 96,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: const Text(
        'No picture chosen yet',
        style: TextStyle(color: Colors.white70),
      ),
    );
  }
}

/// A one-line outcome or problem, inline rather than in a transient snack bar:
/// an upload that could or could not be confirmed is worth reading twice.
class _Note extends StatelessWidget {
  const _Note({
    super.key,
    required this.icon,
    required this.text,
    this.isError = false,
  });

  final IconData icon;
  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isError ? scheme.errorContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 18, color: isError ? scheme.onErrorContainer : null),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: isError ? scheme.onErrorContainer : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
