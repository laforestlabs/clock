// Loading and saving layouts.
//
// Stock layouts ship as assets and are the same files the firmware and the CLI
// use, linked rather than copied by setup.sh so there is one copy of the truth.

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;

class StockLayout {
  const StockLayout(this.name, this.assetPath);
  final String name;
  final String assetPath;
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

      return paths
          .map(
            (p) => StockLayout(
              p.split('/').last.replaceAll('.json', ''),
              p,
            ),
          )
          .toList(growable: false);
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
