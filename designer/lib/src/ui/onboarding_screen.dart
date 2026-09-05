// The guided setup walkthrough for a freshly connected mirror.
//
// A brand-new device reaches the phone over Bluetooth with no network and no
// location, so its panel can only ever show placeholders. This page walks the
// owner through fixing exactly that, one screen per decision:
//
//   1. Name     — the verb-and-animal identity the device generated for
//                 itself; the owner keeps it or types a name of their own,
//                 which is then pushed so the device advertises it.
//   2. WiFi     — the existing guided scan/pick flow (reused as a form).
//   3. Location — imprecise on purpose: a ZIP code, a city, or a tap on a
//                 map. The weather provider needs coordinates, nothing more.
//   4. Time & units — timezone (prefilled from wherever the location search
//                 found), 12/24-hour clock, Fahrenheit/Celsius (prefilled
//                 from the country).
//
// The later steps prefill from what came before them but never lock the
// owner in: every prefill is an ordinary editable control. WiFi is skipped
// when [includeWifi] is false (the device already has credentials and the
// owner reran setup to fix its name, location or display).
//
// The page talks to the device only through injected callbacks, so the whole
// walkthrough is widget-testable without a mirror on the other end of the
// radio. The return value is the device's config commit status, or null when
// cancelled; a cancelled walkthrough still leaves the WiFi push (step 2)
// applied, which is what the device needs most.

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../services/mirror_ble.dart';
import '../services/mirror_config.dart';
import '../services/mirror_location.dart';
import '../services/mirror_wifi.dart';
import '../services/mirror_wifi_status.dart';
import 'place_pin_page.dart';
import 'wifi_setup_form.dart';

/// The wizard's steps, in order. [wifi] is only included for a device with
/// no saved network; every run includes the rest.
enum SetupStep { name, wifi, location, display }

class MirrorOnboardingPage extends StatefulWidget {
  const MirrorOnboardingPage({
    super.key,
    required this.configPush,
    this.currentName,
    this.nameApplied,
    this.includeWifi = true,
    this.wifiScan,
    this.wifiPush,
    this.wifiAwait,
    this.geocode = geocodeSearch,
    this.pickOnMap = _showPinPicker,
  });

  /// Whether the WiFi step is part of this run. When true, the three
  /// callbacks below are required.
  final bool includeWifi;

  /// Device seams, normally bound straight from a [BleSession]:
  final Future<List<BleWifiNetwork>> Function()? wifiScan;
  final Future<String> Function(WifiConfig wifi)? wifiPush;

  /// Await the async connect outcome after [wifiPush]; the caller must
  /// start this before pushing (see [BleSession.awaitWifiResult]).
  final Future<BleWifiResult?> Function()? wifiAwait;

  /// Push the collected config (a partial MirrorConfig JSON) and return the
  /// device's commit status.
  final Future<String> Function(Map<String, dynamic> json) configPush;

  /// The name the device goes by right now (what it advertised at connect),
  /// prefilled into the Name step so the owner edits a real starting point
  /// rather than a blank. Null leaves the field empty.
  final String? currentName;

  /// Called after a finished run that pushed a rename, with the new name,
  /// so the caller can update what it shows and remembers.
  final void Function(String name)? nameApplied;

  /// Location lookup seam: [geocodeSearch] on device runs, a fake in tests.
  final Future<List<GeocodeResult>> Function(String query) geocode;

  /// Map picker seam: pushes [PlacePinPage] for real, a stub in tests.
  final Future<LatLng?> Function(BuildContext context, {LatLng? initial})
      pickOnMap;

  static Future<LatLng?> _showPinPicker(BuildContext context,
          {LatLng? initial}) =>
      showPlacePinPicker(context, initial: initial);

  @override
  State<MirrorOnboardingPage> createState() => _MirrorOnboardingPageState();
}

class _MirrorOnboardingPageState extends State<MirrorOnboardingPage> {
  // ------------------------------------------------------------ scaffold

  int _stepIndex = 0;
  bool _busy = false;

  /// Inline status/error line above the bottom bar. The wizard never toasts;
  /// the owner is reading this screen, so the message goes next to the
  /// button they just pressed.
  String? _note;

  List<SetupStep> get _steps => widget.includeWifi
      ? const <SetupStep>[
          SetupStep.name,
          SetupStep.wifi,
          SetupStep.location,
          SetupStep.display,
        ]
      : const <SetupStep>[
          SetupStep.name,
          SetupStep.location,
          SetupStep.display,
        ];

  SetupStep get _step => _steps[_stepIndex];

  // -------------------------------------------------------------- name step

  late final TextEditingController _mirrorName;

  // ------------------------------------------------------------- wifi step

  WifiConfig? _wifiDraft;

  /// True once the device reported it joined the network (or the outcome
  /// simply timed out, which the existing flow treats as "saved"); flips the
  /// primary button from Connect to Continue.
  bool _wifiOk = false;

  // --------------------------------------------------------- location step

  final TextEditingController _query = TextEditingController();
  final TextEditingController _place = TextEditingController();
  int _searchToken = 0;
  bool _searching = false;
  String? _searchError;
  List<GeocodeResult> _results = const <GeocodeResult>[];
  GeocodeResult? _selected;

  /// While true, the place label tracks the selection; editing it detaches.
  bool _placeAuto = true;

  // ------------------------------------------------------------ display step

  String? _presetTz;
  late final TextEditingController _tzCustom;
  bool _tzTouched = false;
  bool _clock12h = true;
  bool _tempF = true;

  @override
  void initState() {
    super.initState();
    _mirrorName = TextEditingController(text: widget.currentName ?? '');
    _tzCustom = TextEditingController();
  }

  @override
  void dispose() {
    _query.dispose();
    _place.dispose();
    _tzCustom.dispose();
    _mirrorName.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ navigation

  void _next() {
    final was = _step;
    if (was == SetupStep.name) {
      final typed = _mirrorName.text.trim();
      if (typed.isNotEmpty) {
        final problem = MirrorConfig(name: typed).validate();
        if (problem != null) {
          setState(() => _note = problem);
          return;
        }
      }
    }
    if (_stepIndex >= _steps.length - 1) {
      _finish();
      return;
    }
    setState(() {
      _stepIndex++;
      _note = null;
      if (was == SetupStep.location) _deriveFromLocation();
    });
  }

  void _back() {
    if (_stepIndex == 0) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _stepIndex--;
      _note = null;
    });
  }

  /// Prefill the display step from wherever the location search landed,
  /// unless the owner already changed those controls by hand.
  void _deriveFromLocation() {
    final sel = _selected;
    if (sel == null) return;
    final f = tempFForCountry(sel.countryCode);
    if (f != null) _tempF = f;
    final tz = posixTzForIana(sel.timezone);
    if (tz == null || _tzTouched) return;
    final presetValues = kTimezonePresets.map((p) => p.tz).toSet();
    if (presetValues.contains(tz)) {
      _presetTz = tz;
    } else {
      // A derived zone outside the presets: show it in the custom field so
      // the owner can see what will be pushed rather than a silent guess.
      _presetTz = '';
      _tzCustom.text = tz;
    }
  }

  // ---------------------------------------------------------- wifi actions

  Future<void> _submitWifi() async {
    final draft = _wifiDraft;
    if (draft == null || widget.wifiPush == null || widget.wifiAwait == null) {
      return;
    }
    final problem = draft.validate();
    if (problem != null) {
      setState(() => _note = problem);
      return;
    }
    setState(() {
      _busy = true;
      _note = null;
    });
    String? note;
    var ok = false;
    try {
      // Subscribe before pushing so the async outcome can never be missed,
      // exactly like the Mirror screen's own flow.
      final resultFuture = widget.wifiAwait!();
      await widget.wifiPush!(draft);
      final result = await resultFuture;
      if (result != null && result.connected) {
        note = 'Connected to ${draft.ssid}';
        ok = true;
      } else if (result != null) {
        note = 'Could not join ${draft.ssid}: ${result.detail}';
      } else {
        // No outcome within the window: the mirror kept the credentials and
        // is still trying. Let the walkthrough proceed; the device will
        // connect when the router answers.
        note = 'Saved; the mirror is still trying to join ${draft.ssid}';
        ok = true;
      }
    } catch (e) {
      note = e is BlePushException ? e.message : '$e';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _note = note;
      _wifiOk = ok;
    });
  }

  // ----------------------------------------------------- location actions

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
        _searchError = null;
        _results = const <GeocodeResult>[];
      });
      _applySelection(direct);
      return;
    }
    final token = ++_searchToken;
    setState(() {
      _searching = true;
      _searchError = null;
      _results = const <GeocodeResult>[];
    });
    try {
      final res = await widget.geocode(q);
      if (!mounted || token != _searchToken) return;
      setState(() {
        _searching = false;
        if (res.isEmpty) {
          _searchError =
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
        _searchError = '$e'.replaceFirst('Exception: ', '');
      });
    }
  }

  void _applySelection(GeocodeResult r) {
    setState(() {
      _selected = r;
      _results = const <GeocodeResult>[];
      if (_placeAuto) _place.text = r.placeDraft;
    });
  }

  Future<void> _pickOnMap() async {
    final sel = _selected;
    final initial = sel == null ? null : LatLng(sel.latitude, sel.longitude);
    final pin = await widget.pickOnMap(context, initial: initial);
    if (pin == null || !mounted) return;
    setState(() {
      _selected = GeocodeResult(
        name: 'Pinned location',
        latitude: pin.latitude,
        longitude: pin.longitude,
      );
      _results = const <GeocodeResult>[];
      _searchError = null;
      if (_placeAuto) _place.text = 'Home';
    });
  }

  // -------------------------------------------------------- display fields

  String? get _timezone {
    if (_presetTz == null || _presetTz!.isEmpty) {
      final custom = _tzCustom.text.trim();
      return custom.isEmpty ? null : custom;
    }
    return _presetTz;
  }

  /// The rename to push, or null when the owner left the field at the
  /// device's current name (or cleared it): a null name means "unchanged"
  /// in the config JSON, so an untouched step pushes nothing.
  String? get _pushedName {
    final typed = _mirrorName.text.trim();
    if (typed.isEmpty) return null;
    if (typed == (widget.currentName?.trim() ?? '')) return null;
    return typed;
  }

  MirrorConfig _collect() {
    final sel = _selected;
    final place = _place.text.trim();
    return MirrorConfig(
      name: _pushedName,
      timezone: _timezone,
      latitude: sel?.latitude.toStringAsFixed(5),
      longitude: sel?.longitude.toStringAsFixed(5),
      place: place.isEmpty
          ? null
          : (place.length <= 23 ? place : place.substring(0, 23)),
      clock12h: _clock12h,
      tempF: _tempF,
    );
  }

  Future<void> _finish() async {
    final cfg = _collect();
    final problem = cfg.validate();
    if (problem != null) {
      setState(() => _note = problem);
      return;
    }
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      final status = await widget.configPush(cfg.toJson());
      if (!mounted) return;
      Navigator.of(context).pop(status);
      final pushed = cfg.name;
      if (pushed != null) widget.nameApplied?.call(pushed);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _note = e is BlePushException ? e.message : '$e';
      });
    }
  }

  // ------------------------------------------------------------------ view

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Set up your mirror'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel setup',
          onPressed: _busy ? null : _back,
        ),
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            _stepHeader(),
            const Divider(height: 1),
            Expanded(child: _stepBody()),
            _bottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _stepHeader() {
    final labels = <SetupStep, String>{
      SetupStep.name: 'Name',
      SetupStep.wifi: 'WiFi',
      SetupStep.location: 'Location',
      SetupStep.display: 'Time & units',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: <Widget>[
          for (var i = 0; i < _steps.length; i++)
            Expanded(
              child: Column(
                children: <Widget>[
                  Container(
                    width: 26,
                    height: 26,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i == _stepIndex
                          ? Theme.of(context).colorScheme.primary
                          : i < _stepIndex
                              ? Theme.of(context).colorScheme.primaryContainer
                              : Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                    ),
                    child: Text(
                      '${i + 1}',
                      style: TextStyle(
                        fontSize: 13,
                        color: i <= _stepIndex
                            ? Theme.of(context).colorScheme.onPrimary
                            : null,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    labels[_steps[i]]!,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight:
                          i == _stepIndex ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _stepBody() {
    final content = switch (_step) {
      SetupStep.name => _nameStep(),
      SetupStep.wifi => _wifiStep(),
      SetupStep.location => _locationStep(),
      SetupStep.display => _displayStep(),
    };
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: content,
    );
  }

  Widget _noteLine() {
    final note = _note;
    if (note == null) return const SizedBox.shrink();
    // A "Connected to ..." line on the WiFi step is a status, not an error;
    // everywhere else the note holds a failure to show next to the button.
    final isStatus = _step == SetupStep.wifi && _wifiOk;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(
        note,
        style: TextStyle(
          color: isStatus ? Colors.grey : Theme.of(context).colorScheme.error,
        ),
      ),
    );
  }

  // ----------------------------------------------------------- name step

  Widget _nameStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text(
          'A mirror names itself when it wakes up: a verb and an animal, '
          'the same pair every time. Keep that name or type your own; the '
          'phone looks the mirror up by it from now on.',
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _mirrorName,
          maxLength: 24,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Mirror name',
            helperText: 'Broadcast over Bluetooth. Up to 24 characters.',
            isDense: true,
            counterText: '',
          ),
        ),
        _noteLine(),
      ],
    );
  }

  // ----------------------------------------------------------- wifi step

  Widget _wifiStep() {
    if (widget.wifiScan == null) {
      // includeWifi was set but the device seam is missing (no BLE session);
      // nothing this step can do. The wizard simply continues.
      return const Text('This mirror is already on a network.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text(
          'Give the mirror your WiFi. It needs the network for weather and '
          'time updates; the layout stays on the device itself.',
        ),
        const SizedBox(height: 12),
        WifiSetupForm(
          scan: widget.wifiScan!,
          onDraft: (c) => setState(() => _wifiDraft = c),
        ),
        _noteLine(),
      ],
    );
  }

  // ----------------------------------------------------- location step

  Widget _locationStep() {
    final sel = _selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text(
          'Weather is fetched for a point on the map, so the mirror needs to '
          'know roughly where it hangs. A ZIP/postal code or a city name is '
          'precise enough; you can also tap the map, or type "lat, lon".',
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _query,
                onChanged: (_) => setState(() {}),
                enabled: !_busy,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                decoration: InputDecoration(
                  hintText: 'ZIP or city name',
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
              onPressed: _busy || _query.text.trim().isEmpty ? null : _search,
              child: const Text('Find'),
            ),
          ],
        ),
        if (_searchError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _searchError!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 13,
              ),
            ),
          ),
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
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _busy ? null : _pickOnMap,
          icon: const Icon(Icons.map_outlined, size: 18),
          label: const Text('Pick on a map instead'),
        ),
        if (sel != null) ...<Widget>[
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(Icons.check_circle,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(sel.fullLabel),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _place,
                    maxLength: 23,
                    onChanged: (_) => _placeAuto = false,
                    decoration: const InputDecoration(
                      labelText: 'Place name',
                      helperText: 'Shown by weather widgets',
                      helperMaxLines: 1,
                      isDense: true,
                      counterText: '',
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _busy ? null : _pickOnMap,
                    icon: const Icon(Icons.my_location, size: 16),
                    label: const Text('Adjust on the map'),
                  ),
                ],
              ),
            ),
          ),
        ],
        _noteLine(),
      ],
    );
  }

  // --------------------------------------------------------- display step

  Widget _displayStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text(
          'How the mirror shows the time and the weather. All of it stays '
          'changeable later.',
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String?>(
          initialValue: _presetTz,
          decoration: const InputDecoration(labelText: 'Timezone'),
          items: <DropdownMenuItem<String?>>[
            // Just the friendly name at phone width; the full POSIX string
            // (what actually gets pushed) shows in the custom field.
            for (final p in kTimezonePresets)
              DropdownMenuItem<String?>(
                value: p.tz,
                child: Text(p.label),
              ),
            const DropdownMenuItem<String?>(
              value: '',
              child: Text('Custom...'),
            ),
          ],
          onChanged: (value) => setState(() {
            _tzTouched = true;
            _presetTz = value;
          }),
        ),
        if (_presetTz == null || _presetTz!.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextField(
              controller: _tzCustom,
              onChanged: (_) => _tzTouched = true,
              decoration: const InputDecoration(
                labelText: 'POSIX timezone string',
                hintText: 'e.g. UTC0',
              ),
            ),
          ),
        const SizedBox(height: 16),
        SegmentedButton<bool>(
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: const <ButtonSegment<bool>>[
            ButtonSegment<bool>(value: true, label: Text('12-hour clock')),
            ButtonSegment<bool>(value: false, label: Text('24-hour clock')),
          ],
          selected: <bool>{_clock12h},
          onSelectionChanged: (s) => setState(() => _clock12h = s.first),
        ),
        const SizedBox(height: 8),
        SegmentedButton<bool>(
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: const <ButtonSegment<bool>>[
            ButtonSegment<bool>(value: true, label: Text('Fahrenheit')),
            ButtonSegment<bool>(value: false, label: Text('Celsius')),
          ],
          selected: <bool>{_tempF},
          onSelectionChanged: (s) => setState(() => _tempF = s.first),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Text(
            'Pushed to the mirror over Bluetooth.',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ),
        _noteLine(),
      ],
    );
  }

  // ---------------------------------------------------------- bottom bar

  Widget _bottomBar() {
    final step = _step;
    final isLast = _stepIndex == _steps.length - 1;

    final String primaryLabel = switch (step) {
      SetupStep.name => 'Continue',
      SetupStep.wifi => _wifiOk ? 'Continue' : 'Connect',
      SetupStep.location => 'Continue',
      SetupStep.display => 'Finish setup',
    };
    final bool primaryEnabled = switch (step) {
      SetupStep.name => !_busy,
      SetupStep.wifi => !_busy && (_wifiOk || _wifiDraft != null),
      SetupStep.location => _busy ? false : _selected != null,
      SetupStep.display => !_busy,
    };
    final VoidCallback? onPrimary = primaryEnabled
        ? () {
            if (step == SetupStep.wifi && !_wifiOk) {
              _submitWifi();
            } else {
              _next();
            }
          }
        : null;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: <Widget>[
            if (_stepIndex > 0)
              TextButton.icon(
                onPressed: _busy ? null : _back,
                icon: const Icon(Icons.arrow_back, size: 18),
                label: const Text('Back'),
              )
            else
              TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            // OverflowBar stacks the actions on extra lines when the text is
            // scaled up or the phone is narrow, instead of overflowing.
            Expanded(
              child: OverflowBar(
                alignment: MainAxisAlignment.end,
                overflowAlignment: OverflowBarAlignment.end,
                children: <Widget>[
                  if (step == SetupStep.location)
                    TextButton(
                      onPressed: _busy ? null : _skipLocation,
                      child: const Text('Skip'),
                    ),
                  FilledButton(
                    onPressed: onPrimary,
                    child: Text(_busy && isLast
                        ? 'Saving...'
                        : _busy && step == SetupStep.wifi && !_wifiOk
                            ? 'Connecting...'
                            : primaryLabel),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _skipLocation() {
    setState(() {
      _note = null;
      _stepIndex = _steps.indexOf(SetupStep.display);
      // No selection: keep the device's factory defaults rather than
      // pushing anything derived.
    });
  }
}
