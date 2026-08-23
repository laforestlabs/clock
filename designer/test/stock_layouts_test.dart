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
      expect(
        names,
        containsAll(<String>[
          'mini',
          'single',
          'dual',
          'quad',
          'weather',
          'countdown',
          'status',
          'bigclock',
          'planner',
        ]),
      );
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

    test('every canonical preset targets the 64x32 panel', () async {
      final stock = await LayoutRepository().stockLayouts();
      const canonical = <String>{
        'mini',
        'single',
        'dual',
        'quad',
        'weather',
        'planner',
        'bigclock',
        'status',
        'countdown',
      };

      for (final name in canonical) {
        final preset = stock.firstWhere(
          (s) => s.name == name,
          orElse: () => throw StateError('missing stock preset $name'),
        );
        expect(preset.width, 64, reason: '$name should be 64 wide');
        expect(preset.height, 32, reason: '$name should be 32 tall');
      }
    });

    test('larger presets are kept under size-suffixed names', () async {
      final stock = await LayoutRepository().stockLayouts();
      final byName = {for (final s in stock) s.name: s};

      expect(byName['single-64x64']?.width, 64);
      expect(byName['single-64x64']?.height, 64);
      expect(byName['dual-128x64']?.width, 128);
      expect(byName['dual-128x64']?.height, 64);
      expect(byName['quad-128x128']?.height, 128);
      expect(byName['planner-128x128']?.height, 128);
    });
  });

  group('stock layout filtering', () {
    const layouts = <StockLayout>[
      StockLayout('mini', 'a', 64, 32),
      StockLayout('single', 'b', 64, 32),
      StockLayout('dual-128x64', 'c', 128, 64),
    ];

    test('shows everything when no panel size is known', () {
      expect(stockLayoutsForPanel(layouts, 0, 0), hasLength(3));
    });

    test('shows only presets matching the panel size', () {
      final mini = stockLayoutsForPanel(layouts, 64, 32);
      expect(mini.map((l) => l.name), containsAll(<String>['mini', 'single']));
      expect(mini, hasLength(2));

      final dual = stockLayoutsForPanel(layouts, 128, 64);
      expect(dual.single.name, 'dual-128x64');

      expect(stockLayoutsForPanel(layouts, 64, 64), isEmpty);
    });
  });
}
