// The stock layout list comes from the asset manifest, which is a moving
// target: Flutter replaced AssetManifest.json with a binary manifest, and
// because LayoutRepository swallows a manifest failure so the app still opens,
// that break was silent. The list went empty, the picker showed nothing, and
// the app started on a blank canvas instead of the default layout.
//
// So assert the list is actually populated, not merely that the call returns.

import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/services/layout_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('stock layouts', () {
    test('are discovered from the asset manifest', () async {
      final stock = await LayoutRepository().stockLayouts();

      expect(
        stock,
        isNotEmpty,
        reason: 'an empty list means the asset manifest was not readable, '
            'which leaves the designer with no stock layouts at all',
      );

      final names = stock.map((s) => s.name).toList();
      expect(names, containsAll(<String>['mini', 'single', 'dual', 'quad']));
    });

    test('include mini, which the app opens by default', () async {
      final stock = await LayoutRepository().stockLayouts();
      final mini = stock.where((s) => s.name == 'mini');

      expect(mini, hasLength(1));
      expect(mini.first.assetPath, 'assets/layouts/mini.json');
    });

    test('mini is loadable and is a 64x32 canvas', () async {
      final repo = LayoutRepository();
      final stock = await repo.stockLayouts();
      final mini = stock.firstWhere((s) => s.name == 'mini');

      final contents = await repo.loadAsset(mini.assetPath);

      expect(contents, contains('"width": 64'));
      expect(contents, contains('"height": 32'));
      expect(contents, contains('"type": "clock"'));
      expect(contents, contains('weather.temp'));
    });
  });
}
