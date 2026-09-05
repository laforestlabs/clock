// A full-screen "tap where you are" map for the setup wizard's location
// step, and the manual-coordinate fallback for owners who know their numbers.
//
// Tiles come from OpenStreetMap through flutter_map (pure Dart, so the same
// code runs on phone and desktop). No API key and no account, in keeping with
// the project's zero-credential stance; the User-Agent is what OSM's tile
// usage policy asks for, and personal home use is well inside its limits.

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Opens the pin picker. Returns the chosen point, or null when cancelled.
/// [initial] centres the map there (a search the owner did not like, or the
/// mirror's current coordinates) so adjusting is a drag and a tap, not a
/// fresh search.
Future<LatLng?> showPlacePinPicker(
  BuildContext context, {
  LatLng? initial,
}) {
  return Navigator.of(context).push<LatLng>(
    MaterialPageRoute(builder: (_) => PlacePinPage(initial: initial)),
  );
}

class PlacePinPage extends StatefulWidget {
  const PlacePinPage({super.key, this.initial});

  final LatLng? initial;

  @override
  State<PlacePinPage> createState() => _PlacePinPageState();
}

class _PlacePinPageState extends State<PlacePinPage> {
  final MapController _controller = MapController();
  late LatLng _center;
  late double _zoom;
  LatLng? _pin;

  @override
  void initState() {
    super.initState();
    _center = widget.initial ?? const LatLng(20, 0);
    _zoom = widget.initial == null ? 2 : 12;
  }

  void _zoomBy(double delta) {
    final zoom = (_zoom + delta).clamp(2.0, 19.0);
    try {
      if (_controller.move(_center, zoom)) _zoom = zoom;
    } catch (_) {
      // The map is not attached yet; a no-op.
    }
  }

  @override
  Widget build(BuildContext context) {
    final pin = _pin;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pick your spot'),
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: Stack(
              children: <Widget>[
                FlutterMap(
                  mapController: _controller,
                  options: MapOptions(
                    initialCenter: _center,
                    initialZoom: _zoom,
                    minZoom: 2,
                    maxZoom: 19,
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                    ),
                    onPositionChanged: (camera, _) {
                      _center = camera.center;
                      _zoom = camera.zoom;
                    },
                    onTap: (_, point) => setState(() => _pin = point),
                  ),
                  children: <Widget>[
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      maxNativeZoom: 19,
                      // OSM's tile usage policy asks for a recognisable
                      // User-Agent; flutter_map sets it from this.
                      userAgentPackageName: 'com.example.mirror_designer',
                      tileProvider: NetworkTileProvider(
                        // Tiles that fail to load draw nothing rather than
                        // throwing over and over; the map still pans.
                        silenceExceptions: true,
                      ),
                    ),
                    if (pin != null)
                      CircleLayer(
                        circles: <CircleMarker<Object>>[
                          CircleMarker<Object>(
                            point: pin,
                            radius: 9,
                            color: const Color(0xCC00E5FF),
                            borderStrokeWidth: 2.5,
                            borderColor: const Color(0xFF00E5FF),
                          ),
                        ],
                      ),
                    const SimpleAttributionWidget(
                      source: Text('© OpenStreetMap contributors'),
                    ),
                  ],
                ),
                if (pin == null)
                  // IgnorePointer so the bubble never eats the tap it asks
                  // for; the map beneath receives it.
                  IgnorePointer(
                    child: SafeArea(
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: const Text(
                            'Tap the map where the mirror hangs',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  ),
                SafeArea(
                  child: Column(
                    children: <Widget>[
                      const Spacer(),
                      Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: Column(
                            children: <Widget>[
                              _zoomButton(Icons.add, () => _zoomBy(1)),
                              const SizedBox(height: 8),
                              _zoomButton(Icons.remove, () => _zoomBy(-1)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      pin == null
                          ? 'No spot picked yet'
                          : '${pin.latitude.toStringAsFixed(5)}, '
                              '${pin.longitude.toStringAsFixed(5)}',
                      style: const TextStyle(
                          fontFeatures: [FontFeature.tabularFigures()]),
                    ),
                  ),
                  FilledButton(
                    onPressed: pin == null
                        ? null
                        : () => Navigator.of(context).pop(pin),
                    child: const Text('Use this spot'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _zoomButton(IconData icon, VoidCallback onPressed) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 2,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: IconButton(
        icon: Icon(icon),
        tooltip: icon == Icons.add ? 'Zoom in' : 'Zoom out',
        onPressed: onPressed,
      ),
    );
  }
}
