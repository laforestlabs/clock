import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Edits original-image coordinates; the caller owns [image].
class PictureCropScreen extends StatefulWidget {
  const PictureCropScreen({
    super.key,
    required this.image,
    required this.panelWidth,
    required this.panelHeight,
    this.initialCrop,
  });

  final ui.Image image;
  final int panelWidth;
  final int panelHeight;
  final Rect? initialCrop;

  @override
  State<PictureCropScreen> createState() => _PictureCropScreenState();
}

class _PictureCropScreenState extends State<PictureCropScreen> {
  late Rect _crop;
  late Rect _gestureCrop;
  Offset _anchor = Offset.zero;
  double get _aspect => widget.panelWidth / widget.panelHeight;
  double get _baseWidth =>
      math.min(widget.image.width.toDouble(), widget.image.height * _aspect);
  double get _zoom => _baseWidth / _crop.width;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialCrop;
    _crop = initial == null
        ? _bounded(Offset(widget.image.width / 2, widget.image.height / 2), 1)
        : _bounded(
            Offset(initial.center.dx * widget.image.width,
                initial.center.dy * widget.image.height),
            _baseWidth / (initial.width * widget.image.width));
  }

  Rect _bounded(Offset center, double zoom) {
    final width = _baseWidth / zoom.clamp(1.0, 8.0);
    final height = width / _aspect;
    return Rect.fromLTWH(
      (center.dx - width / 2).clamp(0.0, widget.image.width - width),
      (center.dy - height / 2).clamp(0.0, widget.image.height - height),
      width,
      height,
    );
  }

  void _setZoom(double zoom) =>
      setState(() => _crop = _bounded(_crop.center, zoom));

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Crop picture'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(Rect.fromLTRB(
                _crop.left / widget.image.width,
                _crop.top / widget.image.height,
                _crop.right / widget.image.width,
                _crop.bottom / widget.image.height,
              )),
              child: const Text('Use crop'),
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: <Widget>[
                Text('${widget.panelWidth} × ${widget.panelHeight} panel — '
                    'aspect ratio locked'),
                const SizedBox(height: 8),
                const Text('Pinch to zoom. Drag to position. '
                    'Only the area inside the frame will be displayed.'),
                const SizedBox(height: 16),
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: _aspect,
                      child: LayoutBuilder(builder: (context, constraints) {
                        return Semantics(
                          label: 'Photo crop, panel aspect ratio locked',
                          child: GestureDetector(
                            key:
                                const ValueKey<String>('picture-crop-viewport'),
                            behavior: HitTestBehavior.opaque,
                            onScaleStart: (details) {
                              _gestureCrop = _crop;
                              _anchor = _crop.topLeft +
                                  Offset(
                                    details.localFocalPoint.dx /
                                        constraints.maxWidth *
                                        _crop.width,
                                    details.localFocalPoint.dy /
                                        constraints.maxHeight *
                                        _crop.height,
                                  );
                            },
                            onScaleUpdate: (details) {
                              final zoom = (_baseWidth /
                                      _gestureCrop.width *
                                      details.scale)
                                  .clamp(1.0, 8.0);
                              final width = _baseWidth / zoom;
                              final height = width / _aspect;
                              final center = _anchor +
                                  Offset(
                                    (0.5 -
                                            details.localFocalPoint.dx /
                                                constraints.maxWidth) *
                                        width,
                                    (0.5 -
                                            details.localFocalPoint.dy /
                                                constraints.maxHeight) *
                                        height,
                                  );
                              setState(() => _crop = _bounded(center, zoom));
                            },
                            child: CustomPaint(
                              painter: _CropPainter(widget.image, _crop),
                              child: const SizedBox.expand(),
                            ),
                          ),
                        );
                      }),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(children: <Widget>[
                  const Icon(Icons.zoom_out),
                  Expanded(
                    child: Slider(
                      value: _zoom.clamp(1.0, 8.0),
                      min: 1,
                      max: 8,
                      label: '${_zoom.toStringAsFixed(1)}×',
                      semanticFormatterCallback: (value) =>
                          '${value.toStringAsFixed(1)} times zoom',
                      onChanged: _setZoom,
                    ),
                  ),
                  const Icon(Icons.zoom_in),
                  TextButton(
                    onPressed: () => setState(() => _crop = _bounded(
                        Offset(widget.image.width / 2, widget.image.height / 2),
                        1)),
                    child: const Text('Reset'),
                  ),
                ]),
              ],
            ),
          ),
        ),
      );
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.image, this.crop);

  final ui.Image image;
  final Rect crop;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRect(bounds, Paint()..color = Colors.black);
    canvas.drawImageRect(
        image, crop, bounds, Paint()..filterQuality = FilterQuality.medium);
    final grid = Paint()
      ..color = Colors.white54
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      canvas.drawLine(Offset(size.width * i / 3, 0),
          Offset(size.width * i / 3, size.height), grid);
      canvas.drawLine(Offset(0, size.height * i / 3),
          Offset(size.width, size.height * i / 3), grid);
    }
    canvas.drawRect(
        bounds.deflate(1),
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_CropPainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.crop != crop;
}
