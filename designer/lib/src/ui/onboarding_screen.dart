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
//   3. Location — three explicit sources, one per way an owner can answer:
//                 a ZIP/postal code (or city, or raw "lat, lon"), this
//                 device's own GPS, or a pin on the map. The weather
//                 provider needs coordinates, nothing more.
//   4. Time & units — timezone (prefilled from whatever the location source
//                 could say about the zone), 12/24-hour clock,
//                 Fahrenheit/Celsius (prefilled from the country, when the
//                 source knew one).
//
// The later steps prefill from what came before them but never lock the
// owner in: every prefill is an ordinary editable control, and a zone that
// arrives after the owner moved on still lands. The WiFi step advances by
// itself the moment the mirror confirms it joined, and a failure keeps the
// owner on the step with the network list still in front of them. WiFi is
// skipped when [includeWifi] is false (the device already has credentials and
// the owner reran setup to fix its name, location or display).
//
// The page talks to the device only through injected callbacks, so the whole
// walkthrough is widget-testable without a mirror on the other end of the
// radio. The return value is the device's config commit status, or null when
// cancelled; a cancelled walkthrough still leaves the WiFi push (step 2)
// applied, which is what the device needs most.

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../services/device_location.dart';
import '../services/mirror_ble.dart';
import '../services/mirror_config.dart';
import '../services/mirror_location.dart';
import '../services/mirror_wifi.dart';
import '../services/mirror_wifi_status.dart';
import 'location_picker.dart';
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
    this.wifiStatus,
    this.geocode = geocodeSearch,
    this.timezoneLookup = timezoneIanaForCoordinates,
    this.deviceLocation = currentDeviceLocation,
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

  /// Ask the device what it currently thinks of its network (normally
  /// [BleSession.getWifi]). Consulted only when [wifiAwait] ran out of
  /// window with no outcome, which would otherwise be reported as a failure
  /// the owner has no way to check.
  final Future<BleWifiStatus?> Function()? wifiStatus;

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

  /// Reverse coordinate→zone seam, for the sources with no zone of their own.
  final Future<String?> Function(double latitude, double longitude)
      timezoneLookup;

  /// This device's position seam (the wizard's GPS source).
  final Future<LatLng> Function() deviceLocation;

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

  // --------------------------------------------------------- location step

  /// The picker's current choice; null until one of the three sources lands.
  LocationChoice? _choice;

  /// True when the chosen point's zone could not be turned into a POSIX
  /// string (unknown to the preset table, or the lookup failed). The display
  /// step says so rather than leaving the owner with a silent UTC clock.
  bool _tzUnmapped = false;

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

  /// Prefill the display step from wherever the location choice landed,
  /// unless the owner already changed those controls by hand. Callers wrap
  /// this in setState; it mutates state only.
  void _deriveFromLocation() {
    final choice = _choice;
    if (choice == null) return;
    final f = tempFForCountry(choice.countryCode);
    if (f != null) _tempF = f;
    final tz = posixTzForIana(choice.timezoneIana);
    _tzUnmapped = tz == null;
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

  /// What the device says about its own network, for the case where the
  /// async outcome window closed with no answer from the mirror.
  Future<bool> _deviceJoined(String ssid) async {
    final ask = widget.wifiStatus;
    if (ask == null) return false;
    try {
      final status = await ask();
      return status != null && status.connected && status.ssid == ssid;
    } catch (_) {
      // An unanswerable device is an unconfirmed join: stay on the step.
      return false;
    }
  }

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
    var joined = false;
    try {
      // Subscribe before pushing so the async outcome can never be missed,
      // exactly like the Mirror screen's own flow.
      final resultFuture = widget.wifiAwait!();
      await widget.wifiPush!(draft);
      final result = await resultFuture;
      if (result != null && result.connected) {
        joined = true;
      } else if (result != null) {
        note = 'Could not join ${draft.ssid}: ${result.detail}. '
            'Pick a different network below, or try again.';
      } else {
        // No outcome within the window. A push that gets no answer is not a
        // success (the wizard used to walk on and leave the owner with a
        // mirror that never joined), and it is not a failure either until
        // the device itself says so.
        joined = await _deviceJoined(draft.ssid);
        if (!joined) {
          note = 'No answer from ${draft.ssid} within 40 seconds. '
              'Check the password, or pick a different network below.';
        }
      }
    } catch (e) {
      note = e is BlePushException ? e.message : '$e';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _note = joined ? null : note;
    });
    // A confirmed join continues by itself: the owner already said which
    // network to join, and there is nothing left to decide here.
    if (joined) _next();
  }

  /// Give up on the current draft and go back to the scanned list: clears the
  /// note and the draft, so the primary is disabled until the owner picks a
  /// network again.
  void _chooseAnotherNetwork() {
    setState(() {
      _note = null;
      _wifiDraft = null;
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
    final choice = _choice;
    final place = choice?.place.trim() ?? '';
    return MirrorConfig(
      name: _pushedName,
      timezone: _timezone,
      latitude: choice?.latitude.toStringAsFixed(5),
      longitude: choice?.longitude.toStringAsFixed(5),
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
    // Every note is now a failure to show next to the button that produced
    // it: a confirmed WiFi join advances instead of leaving a message.
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(
        note,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
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
          // A stale verdict about the previous network (backlog M11) cannot
          // exist without a flag to go stale: a new draft clears the note.
          onDraft: (c) => setState(() {
            _wifiDraft = c;
            _note = null;
          }),
        ),
        _noteLine(),
      ],
    );
  }

  // ----------------------------------------------------- location step

  Widget _locationStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text(
          'Weather is fetched for a point on the map, so the mirror needs to '
          "know roughly where it hangs. Use a ZIP/postal code, this device's "
          'GPS, or a tap on the map.',
        ),
        const SizedBox(height: 12),
        // initial is the wizard's own record, so stepping Back and forward
        // keeps the choice; the picker owns it from then on.
        LocationPicker(
          enabled: !_busy,
          initial: _choice,
          geocode: widget.geocode,
          timezoneLookup: widget.timezoneLookup,
          deviceLocation: widget.deviceLocation,
          pickOnMap: widget.pickOnMap,
          onChanged: (c) => setState(() {
            _choice = c;
            // Runs again when a zone arrives late, which is what carries a
            // GPS or pin timezone onto the display step.
            _deriveFromLocation();
          }),
        ),
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
          // FormField keeps the value it was created with, so a zone derived
          // after this step was built only appears if the field is rebuilt
          // with it (a GPS fix whose lookup landed last).
          key: ValueKey<String?>(_presetTz),
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
        if (_tzUnmapped && _timezone == null)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Could not set the timezone from this location; '
              'choose one here.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
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
      SetupStep.wifi => 'Connect',
      SetupStep.location => 'Continue',
      SetupStep.display => 'Finish setup',
    };
    final bool primaryEnabled = switch (step) {
      SetupStep.name => !_busy,
      SetupStep.wifi => !_busy && _wifiDraft != null,
      SetupStep.location => _busy ? false : _choice != null,
      SetupStep.display => !_busy,
    };
    final VoidCallback? onPrimary = primaryEnabled
        ? () {
            if (step == SetupStep.wifi) {
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
                  // The list below stays on screen and is the choice UI; this
                  // is the way back to it after a failure, and the reason the
                  // primary can be disabled again.
                  if (step == SetupStep.wifi && _note != null)
                    TextButton(
                      onPressed: _busy ? null : _chooseAnotherNetwork,
                      child: const Text('Choose another network'),
                    ),
                  FilledButton(
                    onPressed: onPrimary,
                    child: Text(_busy && isLast
                        ? 'Saving...'
                        : _busy && step == SetupStep.wifi
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
      // With nothing chosen, the device keeps its factory coordinates. A
      // location chosen before tapping Skip is still pushed: skipping leaves
      // the step, it does not undo the choice.
    });
  }
}
