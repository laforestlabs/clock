import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/ui/picture_crop_screen.dart';

void main() {
  testWidgets('pinch and drag preserve panel ratio and clamp to source edges',
      (tester) async {
    final image = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.red, BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(400, 400);
      picture.dispose();
      return image;
    });
    Rect? result;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      return TextButton(
        onPressed: () async {
          result = await Navigator.of(context).push<Rect>(MaterialPageRoute(
            builder: (_) => PictureCropScreen(
                image: image!, panelWidth: 64, panelHeight: 32),
          ));
        },
        child: const Text('Open'),
      );
    })));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final viewport =
        find.byKey(const ValueKey<String>('picture-crop-viewport'));
    final center = tester.getCenter(viewport);
    final first =
        await tester.startGesture(center - const Offset(40, 0), pointer: 1);
    final second =
        await tester.startGesture(center + const Offset(40, 0), pointer: 2);
    await tester.pump();
    await first.moveTo(center - const Offset(80, 0));
    await second.moveTo(center + const Offset(80, 0));
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pump();
    await tester.drag(viewport, const Offset(2000, 2000));
    await tester.pump();
    await tester.tap(find.text('Use crop'));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result!.width, lessThan(0.9));
    expect(result!.width / result!.height, closeTo(2, 0.000001));
    expect(result!.left, 0);
    expect(result!.top, 0);
    expect(result!.right, lessThanOrEqualTo(1));
    expect(result!.bottom, lessThanOrEqualTo(1));
    await tester.pumpWidget(const SizedBox.shrink());
    image!.dispose();
  });
}
