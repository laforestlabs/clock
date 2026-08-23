// Loading and saving layouts.
//
// Stock layouts ship as assets and are the same files the firmware and the CLI
// use, linked rather than copied by setup.sh so there is one copy of the truth.

import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;

class StockLayout {
  const StockLayout(this.name, this.assetPath, this.width, this.height);
  final String name;
  final String assetPath;

  /// The layout's canvas size, read from its JSON. Zero when unreadable, in
  /// which case the preset never matches a connected panel and is hidden
  /// while one is connected.
  final int width;
  final int height;
}

/// Presets that fit a panel of the given size. A zero or negative panel size
/// means "no panel known", which keeps every preset visible.
List<StockLayout> stockLayoutsForPanel(
  List<StockLayout> layouts,
  int width,
  int height,
) {
  if (width <= 0 || height <= 0) return layouts;
  return layouts
      .where((l) => l.width == width && l.height == height)
      .toList(growable: false);
}

class LayoutRepository {
  /// Discovers bundled layouts from the asset manifest, so dropping a new
  /// JSON into layouts/ makes it appear here without a code change.
  Future<List<StockLayout>> stockLayouts() async {
    try {
      // Read through AssetManifest rather than parsing AssetManifest.json by
      // hand. Flutter stopped shipping that file in favour of a binary
      // manifest, and because the failure lands in the catch below it did not
      // look like a bug: the layout list just went quietly empty.
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);

      final paths = manifest
          .listAssets()
          .where((k) => k.startsWith('assets/layouts/') && k.endsWith('.json'))
          .toList()
        ..sort();

      final layouts = <StockLayout>[];
      for (final path in paths) {
        final name = path.split('/').last.replaceAll('.json', '');
        var width = 0;
        var height = 0;
        try {
          final json = jsonDecode(await rootBundle.loadString(path))
              as Map<String, dynamic>;
          final canvas = json['canvas'];
          if (canvas is Map<String, dynamic>) {
            width = (canvas['width'] as num?)?.toInt() ?? 0;
            height = (canvas['height'] as num?)?.toInt() ?? 0;
          }
        } catch (_) {
          // Keep the preset discoverable; it just never matches a panel.
        }
        layouts.add(StockLayout(name, path, width, height));
      }
      return layouts;
    } catch (_) {
      // A missing manifest is not fatal; the user can still open a file.
      return const <StockLayout>[];
    }
  }

  Future<String> loadAsset(String assetPath) => rootBundle.loadString(assetPath);

  /// Opens a layout from disk. Returns null if the user cancelled.
  Future<({String json, String path})?> openFile() async {
    const typeGroup = XTypeGroup(label: 'layout', extensions: <String>['json']);
    final file = await openFiles(acceptedTypeGroups: <XTypeGroup>[typeGroup]);
    if (file.isEmpty) return null;
    final picked = file.first;
    return (json: await picked.readAsString(), path: picked.path);
  }

  /// Saves to a path already known. Returns false if there is no path yet.
  Future<bool> saveTo(String path, String contents) async {
    try {
      await File(path).writeAsString(contents);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// Prompts for a location. Returns the chosen path, or null if cancelled.
  Future<String?> saveAs(String suggestedName, String contents) async {
    final location = await getSaveLocation(
      suggestedName: suggestedName.endsWith('.json')
          ? suggestedName
          : '$suggestedName.json',
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(label: 'layout', extensions: <String>['json']),
      ],
    );
    if (location == null) return null;

    await File(location.path).writeAsString(contents);
    return location.path;
  }
}
