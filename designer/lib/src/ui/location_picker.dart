// Choosing where a mirror hangs: the one location UI the setup wizard and the
// Mirror screen's Configure dialog both render.
//
// Three explicit sources, one at a time, because they fail differently and an
// owner should be able to see which one they are using:
//
//   ZIP code — the original free-text lookup. A postal code, a city name, or
//              raw "lat, lon" against Open-Meteo's geocoder, which also
//              carries the country (unit prefill) and the IANA zone.
//   GPS      — this device's own position ([currentDeviceLocation]); the
//              least typing, and the source that works on a phone with no
//              idea what its own ZIP is.
//   Map      — a pin on [PlacePinPage], for owners who would rather point.
//
// GPS and a pin know no country and no zone, so the picker asks the forecast
// endpoint for the zone afterwards ([timezoneIanaForCoordinates]). That lookup
// can land after the owner has already moved to the next step, which is why
// [onChanged] fires again when it arrives rather than only on the first
// selection: a host that has moved on still sees the zone.
//
// Presentation and lookup only: the picker never touches the device, so the
// hosts own the push and the picker stays widget-testable with injected seams.

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../services/device_location.dart';
import '../services/mirror_location.dart';
import 'place_pin_page.dart';

/// How the owner is choosing a location, one source at a time.
enum LocationSource {
  /// Postal code, city name, or raw "lat, lon".
  zip,

  /// This device's own position.
  gps,

  /// A pin dropped on the map.
  map,
}

/// A chosen location: decimal degrees, an optional label, and whatever the
/// source could say about the country (F/C prefill) and the zone.
class LocationChoice {
  const LocationChoice({
    required this.latitude,
    required this.longitude,
    this.place = '',
    this.countryCode,
    this.timezoneIana,
  });

  final double latitude;
  final double longitude;

  /// The label the weather widget shows. Empty means "let the device keep
  /// whatever it has".
  final String place;

  /// ISO 3166-1 alpha-2, when the source knew one (a ZIP lookup does; a GPS
  /// fix and a pin do not).
  final String? countryCode;

  /// IANA zone name, when the source knew one. Run it through
  /// [posixTzForIana] before pushing.
  final String? timezoneIana;

  /// The coordinate label both hosts show and the config push uses.
  String get coordinates =>
      '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}';

  LocationChoice copyWith({String? place, String? timezoneIana}) =>
      LocationChoice(
        latitude: latitude,
        longitude: longitude,
        place: place ?? this.place,
        countryCode: countryCode,
        timezoneIana: timezoneIana ?? this.timezoneIana,
      );
}

class LocationPicker extends StatefulWidget {
  const LocationPicker({
    super.key,
    this.initial,
    required this.onChanged,
    this.enabled = true,
    this.geocode = geocodeSearch,
    this.timezoneLookup = timezoneIanaForCoordinates,
    this.deviceLocation = currentDeviceLocation,
    this.pickOnMap = _showPinPicker,
  });

  /// Prefill (the Configure dialog); null leaves the picker empty. Read once,
  /// when the picker is created: after that the picker owns its choice.
  final LocationChoice? initial;

  /// Called with the current choice on every change: a new source result, an
  /// edited label, or a timezone that arrived after the choice.
  final ValueChanged<LocationChoice> onChanged;

  final bool enabled;

  /// Geocoder seam: [geocodeSearch] on device runs, a fake in tests.
  final Future<List<GeocodeResult>> Function(String query) geocode;

  /// Reverse coordinate→zone seam, for the sources that have no zone of
  /// their own (GPS, map pin).
  final Future<String?> Function(double latitude, double longitude)
      timezoneLookup;

  /// This device's position seam.
  final Future<LatLng> Function() deviceLocation;

  /// Map picker seam: pushes [PlacePinPage] for real, a stub in tests.
  final Future<LatLng?> Function(BuildContext context, {LatLng? initial})
      pickOnMap;

  static Future<LatLng?> _showPinPicker(BuildContext context,
          {LatLng? initial}) =>
      showPlacePinPicker(context, initial: initial);

  @override
  State<LocationPicker> createState() => _LocationPickerState();
}

class _LocationPickerState extends State<LocationPicker> {
  LocationSource _source = LocationSource.zip;

  LocationChoice? _choice;

  final TextEditingController _query = TextEditingController();
  final TextEditingController _place = TextEditingController();

  /// While true, the place label tracks the selection; editing it detaches.
  bool _placeAuto = true;

  int _searchToken = 0;
  bool _searching = false;
  bool _fixing = false;
  bool _tzLooking = false;
  int _tzToken = 0;
  String? _error;

  /// Set when the zone lookup came back empty-handed: the host's display step
  /// shows its own line for this, so the picker only reports it here.
  String? _tzNote;

  List<GeocodeResult> _results = const <GeocodeResult>[];

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _choice = initial;
    _place.text = initial?.place ?? '';
  }

  @override
  void dispose() {
    _query.dispose();
    _place.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- choosing

  /// Record a location the owner picked, then go find its timezone.
  void _choose(
    double latitude,
    double longitude, {
    required String place,
    String? countryCode,
    String? timezoneIana,
  }) {
    final label = _placeAuto ? place : _place.text;
    ++_searchToken; // a pending ZIP lookup must not land on the new choice
    ++_tzToken;
    setState(() {
      _choice = LocationChoice(
        latitude: latitude,
        longitude: longitude,
        place: label,
        countryCode: countryCode,
        timezoneIana: timezoneIana,
      );
      _results = const <GeocodeResult>[];
      _error = null;
      _fixing = false;
      _searching = false;
      _tzLooking = false;
      _tzNote = null;
      if (_placeAuto) _place.text = place;
    });
    widget.onChanged(_choice!);
    if (timezoneIana == null) _resolveTimezone();
  }

  /// Ask the forecast endpoint for the chosen point's zone. Nothing is
  /// guessed when it comes back empty: the host tells the owner to pick one.
  Future<void> _resolveTimezone() async {
    final choice = _choice;
    if (choice == null || choice.timezoneIana != null) return;
    final token = ++_tzToken;
    setState(() {
      _tzLooking = true;
      _tzNote = null;
    });
    final tz = await widget.timezoneLookup(choice.latitude, choice.longitude);
    if (!mounted || token != _tzToken) return;
    if (tz == null || tz.isEmpty) {
      setState(() {
        _tzLooking = false;
        _tzNote = "Could not determine this spot's timezone; "
            'choose one on the next step.';
      });
      return;
    }
    final folded = _choice!.copyWith(timezoneIana: tz);
    setState(() {
      _tzLooking = false;
      _choice = folded;
    });
    // A zone that arrives late must still notify, or a host already on its
    // next step never sees it.
    widget.onChanged(folded);
  }

  // ----------------------------------------------------------- zip source

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    // A coordinate pair needs no lookup; short-circuit it here rather than
    // through the injected seam so a stubbed geocoder cannot change it.
    final direct = parseCoordinateQuery(q);
    if (direct != null) {
      ++_searchToken;
      setState(() {
        _searching = false;
        _error = null;
        _results = const <GeocodeResult>[];
      });
      _applySelection(direct);
      return;
    }
    final token = ++_searchToken;
    setState(() {
      _searching = true;
      _error = null;
      _results = const <GeocodeResult>[];
    });
    try {
      final res = await widget.geocode(q);
      if (!mounted || token != _searchToken) return;
      setState(() {
        _searching = false;
        if (res.isEmpty) {
          _error =
              'Nothing found for "$q". A city on its own is usually enough.';
        } else if (res.length == 1) {
          _applySelection(res.single);
        } else {
          _results = res;
        }
      });
    } catch (e) {
      if (!mounted || token != _searchToken) return;
      setState(() {
        _searching = false;
        _error = '$e'.replaceFirst('Exception: ', '');
      });
    }
  }

  void _applySelection(GeocodeResult r) {
    _choose(
      r.latitude,
      r.longitude,
      place: r.placeDraft,
      countryCode: r.countryCode,
      timezoneIana: r.timezone,
    );
  }

  // ----------------------------------------------------------- gps source

  Future<void> _useDeviceLocation() async {
    setState(() {
      _fixing = true;
      _error = null;
    });
    try {
      final position = await widget.deviceLocation();
      if (!mounted) return;
      _choose(position.latitude, position.longitude, place: 'Home');
    } on DeviceLocationException catch (e) {
      if (!mounted) return;
      setState(() {
        _fixing = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _fixing = false;
        _error = '$e';
      });
    }
  }

  // ----------------------------------------------------------- map source

  Future<void> _pinOnMap() async {
    final choice = _choice;
    final initial =
        choice == null ? null : LatLng(choice.latitude, choice.longitude);
    final pin = await widget.pickOnMap(context, initial: initial);
    if (pin == null || !mounted) return;
    _choose(pin.latitude, pin.longitude, place: 'Home');
  }

  // ---------------------------------------------------------------- label

  void _onPlaceChanged(String value) {
    _placeAuto = false;
    final choice = _choice;
    if (choice == null) return;
    final next = choice.copyWith(place: value);
    setState(() => _choice = next);
    widget.onChanged(next);
  }

  // ----------------------------------------------------------------- view

  @override
  Widget build(BuildContext context) {
    final choice = _choice;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SegmentedButton<LocationSource>(
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: const <ButtonSegment<LocationSource>>[
            ButtonSegment<LocationSource>(
                value: LocationSource.zip, label: Text('ZIP code')),
            ButtonSegment<LocationSource>(
                value: LocationSource.gps, label: Text('GPS')),
            ButtonSegment<LocationSource>(
                value: LocationSource.map, label: Text('Map')),
          ],
          selected: <LocationSource>{_source},
          onSelectionChanged: widget.enabled
              ? (s) => setState(() => _source = s.first)
              : null,
        ),
        const SizedBox(height: 12),
        switch (_source) {
          LocationSource.zip => _zipEntry(),
          LocationSource.gps => _gpsEntry(),
          LocationSource.map => _mapEntry(),
        },
        if (_results.isNotEmpty) ...<Widget>[
          const Padding(
            padding: EdgeInsets.only(top: 12, bottom: 4),
            child: Text('Did you mean:',
                style: TextStyle(color: Colors.grey, fontSize: 13)),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: ListView(
              shrinkWrap: true,
              children: <Widget>[
                for (final r in _results)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.place_outlined, size: 18),
                    title: Text(r.fullLabel),
                    subtitle: Text(
                      '${r.latitude.toStringAsFixed(4)}, '
                      '${r.longitude.toStringAsFixed(4)}'
                      '${r.timezone == null ? '' : '  •  ${r.timezone}'}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    onTap: () => _applySelection(r),
                  ),
              ],
            ),
          ),
        ],
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _error!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 13,
              ),
            ),
          ),
        if (choice != null) ...<Widget>[
          const SizedBox(height: 12),
          _choiceCard(choice),
        ],
      ],
    );
  }

  Widget _zipEntry() {
    return Row(
      children: <Widget>[
        Expanded(
          child: TextField(
            controller: _query,
            onChanged: (_) => setState(() {}),
            enabled: widget.enabled,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              hintText: 'ZIP or city name',
              helperText: 'Postal code, city, or "lat, lon"',
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: _searching
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : null,
            ),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed:
              !widget.enabled || _query.text.trim().isEmpty ? null : _search,
          child: const Text('Find'),
        ),
      ],
    );
  }

  Widget _gpsEntry() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        FilledButton.tonalIcon(
          onPressed: widget.enabled && !_fixing ? _useDeviceLocation : null,
          icon: const Icon(Icons.my_location, size: 18),
          label: Text(_fixing ? 'Finding you...' : 'Use my location'),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            'Asks this device for its position, once.',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ),
      ],
    );
  }

  Widget _mapEntry() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        FilledButton.tonalIcon(
          onPressed: widget.enabled ? _pinOnMap : null,
          icon: const Icon(Icons.map_outlined, size: 18),
          label: const Text('Pin it on a map'),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            'Tap the map where the mirror hangs.',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ),
      ],
    );
  }

  Widget _choiceCard(LocationChoice choice) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.check_circle,
                    size: 18, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(child: Text(choice.coordinates)),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _place,
              maxLength: 23,
              onChanged: _onPlaceChanged,
              decoration: const InputDecoration(
                labelText: 'Place name',
                helperText: 'Shown by weather widgets',
                helperMaxLines: 1,
                isDense: true,
                counterText: '',
              ),
            ),
            if (_tzLooking || _tzNote != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _tzLooking ? 'Looking up the timezone...' : _tzNote!,
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
