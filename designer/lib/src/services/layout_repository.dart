// Loading and saving layouts.
//
// Stock layouts ship as assets and are the same files the firmware and the CLI
// use, linked rather than copied by setup.sh so there is one copy of the truth.

import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart'
    show AssetManifest, MethodChannel, MissingPluginException, PlatformException, rootBundle;

/// Android's `file_selector` has no save dialog, so "Save As" routes through
/// ACTION_CREATE_DOCUMENT in MainActivity.kt instead. The same channel also
/// routes "Open" through ACTION_OPEN_DOCUMENT so the document URI survives for
/// a later in-place Save.
const MethodChannel _saveChannel = MethodChannel(
  'com.example.mirror_designer/file_io',
);

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
  Future<({String json, String path, String? label})?> openFile() async {
    if (Platform.isAndroid) {
      // `file_selector` copies the chosen document into the app cache and
      // returns that path, so saving to it would update the copy and leave
      // the original untouched. Ask MainActivity for the document URI instead,
      // so a later Save writes back through the Storage Access Framework.
      try {
        final chosen = await _saveChannel.invokeMapMethod<String, String>('openFile');
        if (chosen == null) return null; // user cancelled
        final uri = chosen['uri'];
        final contents = chosen['contents'];
        if (uri != null && contents != null) {
          return (json: contents, path: uri, label: chosen['name']);
        }
      } on MissingPluginException {
        // Fall through to `file_selector`, for example in a test harness
        // without MainActivity.
      } on PlatformException {
        // Fall through to `file_selector`.
      }
    }

    const typeGroup = XTypeGroup(label: 'layout', extensions: <String>['json']);
    final file = await openFiles(acceptedTypeGroups: <XTypeGroup>[typeGroup]);
    if (file.isEmpty) return null;
    final picked = file.first;
    return (json: await picked.readAsString(), path: picked.path, label: null);
  }

  /// Saves to a location already known. Returns false if the write fails.
  Future<bool> saveTo(String location, String contents) async {
    // Android "Save As" hands back a content:// URI rather than a file path;
    // dart:io cannot write to those, so it goes back through the platform.
    if (Platform.isAndroid && location.startsWith('content://')) {
      return await _saveChannel.invokeMethod<bool>(
            'saveTo',
            <String, String>{'uri': location, 'contents': contents},
          ) ??
          false;
    }

    try {
      await File(location).writeAsString(contents);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// Prompts for a location and writes [contents] there. Returns null if the
  /// user cancels. `location` is the opaque token to pass back to [saveTo];
  /// `label` is the user-facing name shown in the save confirmation.
  Future<({String location, String label})?> saveAs(
    String suggestedName,
    String contents,
  ) async {
    final name = suggestedName.endsWith('.json')
        ? suggestedName
        : '$suggestedName.json';

    if (Platform.isAndroid) {
      final chosen = await _saveChannel.invokeMapMethod<String, String>(
        'saveAs',
        <String, String>{
          'suggestedName': name,
          'contents': contents,
          'mimeType': 'application/json',
        },
      );
      if (chosen == null) return null;
      final uri = chosen['uri'];
      if (uri == null) return null;
      return (location: uri, label: chosen['name'] ?? name);
    }

    final loc = await getSaveLocation(
      suggestedName: name,
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(label: 'layout', extensions: <String>['json']),
      ],
    );
    if (loc == null) return null;

    await File(loc.path).writeAsString(contents);
    return (location: loc.path, label: loc.path);
  }
}
