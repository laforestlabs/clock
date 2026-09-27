import 'package:flutter/material.dart';

/// The same simple reflection mark used by the platform launcher icons.
class MirrorMark extends StatelessWidget {
  const MirrorMark({super.key, this.size = 64});

  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: CustomPaint(
        size: Size.square(size),
        painter: _MirrorMarkPainter(scheme.primary, scheme.onSurface),
      ),
    );
  }
}

class _MirrorMarkPainter extends CustomPainter {
  const _MirrorMarkPainter(this.accent, this.reflection);

  final Color accent;
  final Color reflection;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 100, size.height / 100);
    final pen = Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(24, 14, 52, 72), const Radius.circular(12)),
      pen,
    );
    pen.color = reflection;
    canvas.drawLine(const Offset(38, 56), const Offset(60, 34), pen);
    pen
      ..color = accent
      ..style = PaintingStyle.fill;
    for (final x in const <double>[39, 50, 61]) {
      canvas.drawCircle(Offset(x, 72), 2, pen);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MirrorMarkPainter oldDelegate) =>
      oldDelegate.accent != accent || oldDelegate.reflection != reflection;
}

/// Real indeterminate work, never a timed splash or invented percentage.
class MirrorLoading extends StatelessWidget {
  const MirrorLoading({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const MirrorMark(size: 96),
              const SizedBox(height: 20),
              Text('Mirror Designer',
                  style: theme.textTheme.titleLarge,
                  textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(label,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  textAlign: TextAlign.center),
              const SizedBox(height: 28),
              if (MediaQuery.disableAnimationsOf(context))
                Icon(Icons.hourglass_empty, color: theme.colorScheme.primary)
              else
                SizedBox(
                  width: 120,
                  child: LinearProgressIndicator(
                    semanticsLabel: label,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
