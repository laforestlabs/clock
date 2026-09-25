// One mirror's own page: what it is showing, and the three things it can be
// asked to show.
//
// Opening this page is read-only. Nothing here changes the panel until the
// owner taps a control that says what it does, because a device page that
// quietly rewrote the saved display on entry would be the most annoying bug
// this app could ship.
//
// Everything on it is pinned to this record: the preview and status come from
// the device's own transports, the clock editor is opened for this device, the
// games route uses this device's Bluetooth link, and the firmware prompt
// belongs to this page rather than to background polling.

import 'dart:async';

import 'package:flutter/material.dart';

import '../controller.dart';
import '../engine/bindings.dart';
import '../engine/engine.dart';
import '../services/bundled_firmware.dart';
import '../services/firmware_update.dart';
import '../services/mirror_devices.dart';
import '../services/mirror_display.dart';
import '../services/user_view.dart';
import 'add_device_screen.dart';
import 'device_preview.dart';
import 'device_routes.dart';
import 'firmware_prompt.dart';
import 'game_screen.dart';
import 'mirror_screen.dart';
import 'picture_screen.dart';
import 'settings_screen.dart';

/// Firmware versions this run has already offered an update for, keyed by the
/// record and the version. A page that is reopened, or a link that drops and
/// comes back, must not ask about the same build twice.
final Set<String> _offeredFirmware = <String>{};

class DeviceScreen extends StatefulWidget {
  const DeviceScreen({super.key, required this.devices, required this.device});

  final MirrorDevices devices;
  final MirrorDevice device;

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen>
    with WidgetsBindingObserver, RouteAware {
  /// The detail poll. Slower than the eye can see and fast enough that a mode
  /// change or a game frame shows up while the owner is looking at it.
  static const Duration pollInterval = Duration(seconds: 2);

  /// The width at which the page stops stacking and starts spending it: the
  /// preview sits beside the status it belongs to, and the three display cards
  /// share one row instead of adding three heights.
  static const double wideBreakpoint = 600;

  /// Nothing here is worth reading across a desk-wide window, so the page
  /// keeps a content width and centres itself rather than stretching.
  static const double contentWidth = 1040;

  /// The preview box in the header: the panel keeps its shape and fits inside
  /// one band of the page instead of dominating it.
  static const double previewHeight = 96;

  Timer? _timer;
  bool _foreground = true;
  bool _onTop = true;
  bool _subscribed = false;

  /// True while a mode change is in flight: a second tap would race the first.
  bool _busy = false;

  UserView _view = UserView.defaultView;

  BundledFirmware? _bundled;
  bool _offeringFirmware = false;

  MirrorDevice get _device => widget.device;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _device.addListener(_onDeviceChanged);
    // The device route holds the Bluetooth link for as long as it is open —
    // including while a nested route (games, the clock workspace) is on top.
    unawaited(widget.devices.activate(_device));
    unawaited(widget.devices.refresh(_device, includeFrame: true));
    unawaited(_loadView());
    _startTimer();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_maybeOfferFirmware());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_subscribed) return;
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic>) {
      appRouteObserver.subscribe(this, route);
      _subscribed = true;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    if (_subscribed) appRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _device.removeListener(_onDeviceChanged);
    // Releases the link this route held; a route that already exited never
    // drops the link a newer one opened.
    unawaited(widget.devices.deactivate(_device));
    super.dispose();
  }

  Future<void> _loadView() async {
    final view = await loadUserView();
    if (!mounted) return;
    setState(() => _view = view);
  }

  Future<void> _setView(UserView view) async {
    await saveUserView(view);
    if (mounted) setState(() => _view = view);
  }

  /// Follows a record that turned out to name the same hardware as another
  /// one: this page must not keep driving a record that was folded away.
  /// Returns false when the caller should stop.
  Future<bool> _followMerge() async {
    final survivor = _device.mergedInto;
    if (survivor == null) return true;
    if (!mounted) return false;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => DeviceScreen(devices: widget.devices, device: survivor),
      ),
    );
    return false;
  }

  // ------------------------------------------------------------- polling

  void _startTimer() {
    if (!_foreground || !_onTop) return;
    _timer ??= Timer.periodic(pollInterval, (_) => _poll());
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _poll() {
    if (!mounted || _device.removed) {
      _stopTimer();
      return;
    }
    // One transfer at a time on the device: an upload owns it while it runs.
    if (_device.uploading) return;
    unawaited(widget.devices.refresh(_device, includeFrame: true));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    _foreground = foreground;
    if (foreground) {
      _startTimer();
      unawaited(widget.devices.refresh(_device, includeFrame: true));
    } else {
      _stopTimer();
      // The cached preview is written on the way out: the next launch shows
      // the last thing the mirror actually displayed.
      unawaited(widget.devices.saveMetadata(_device));
    }
  }

  @override
  void didPush() {
    _onTop = true;
    _startTimer();
  }

  @override
  void didPushNext() {
    // A nested route covers this one: polling it would be work nobody sees.
    _onTop = false;
    _stopTimer();
  }

  @override
  void didPopNext() {
    _onTop = true;
    _startTimer();
    unawaited(widget.devices.refresh(_device, includeFrame: true));
  }

  // ------------------------------------------------------------- warnings

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _onDeviceChanged() {
    if (!mounted) return;
    final version = _deviceVersion;
    final key = '${_device.key}|$version';
    if (version == null || version.isEmpty) return;
    if (_offeredFirmware.contains(key)) return;
    unawaited(_maybeOfferFirmware());
  }

  /// The firmware version this device is running, from whichever transport
  /// answered: the LAN status body, or the Bluetooth pong.
  String? get _deviceVersion {
    final status = _device.status?.version;
    if (status != null && status.isNotEmpty) return status;
    final pong = _device.connection.pong?.version;
    if (pong != null && pong.isNotEmpty) return pong;
    return null;
  }

  /// Offers this app's firmware to a device running something older, once per
  /// (record, version). Nothing happens for a device on the same version, a
  /// newer one, or a build whose version this app cannot read.
  Future<void> _maybeOfferFirmware() async {
    if (_offeringFirmware || !mounted) return;
    final version = _deviceVersion;
    if (version == null || version.isEmpty) return;
    final key = '${_device.key}|$version';
    if (_offeredFirmware.contains(key)) return;

    _offeringFirmware = true;
    try {
      final bundled = _bundled ?? await loadBundledFirmware();
      if (!mounted || bundled == null) return;
      _bundled = bundled;
      if (!firmwareUpdateAvailable(
          deviceVersion: version, bundledVersion: bundled.version)) {
        return;
      }
      // Recorded before the ask: "not now" is an answer, and the next status
      // poll must not raise the same build again.
      _offeredFirmware.add(key);
      final accepted = await confirmFirmwareUpdate(
        context,
        deviceVersion: version,
        bundledVersion: bundled.version,
        device: _device,
      );
      if (!accepted || !mounted) return;
      await _installBundledFirmware(bundled);
    } finally {
      _offeringFirmware = false;
    }
  }

  /// Push the bundled image to this device and reconnect only this device.
  ///
  /// The upload writes straight to an address rather than through the
  /// registry's mutations, so everything it needs is captured before the first
  /// await: the record, the address to send to (see
  /// [MirrorDevice.updateAddress]) and, when that address came from the
  /// record, the firmware identity it has to answer as.
  ///
  /// An address the mirror reported itself — the pong on a live Bluetooth link
  /// — needs no LAN identity check: it came from this device, over the link
  /// being held. One taken from the record is re-confirmed against a fresh
  /// status read, because an address can be handed to another mirror between a
  /// poll and a write. Either way an image is never written to hardware the
  /// owner did not choose.
  Future<void> _installBundledFirmware(BundledFirmware bundled) async {
    final device = _device;
    if (device.removed) return;
    if (device.connection.session == null) {
      _toast(MirrorDevice.needsBluetooth);
      return;
    }
    try {
      final version = await pushFirmwareOverBleWithProgress(context,
          devices: widget.devices,
          device: device,
          bytes: bundled.bytes,
          label: 'bundled v${bundled.version}');
      if (!mounted) return;
      _toast(version == null
          ? 'Update uploaded; the mirror is rebooting'
          : 'Updated to $version');
      if (version != null) {
        unawaited(widget.devices.refresh(device, includeFrame: true));
      }
    } catch (e) {
      if (mounted) _toast('Update: ${describeRegistryError(e)}');
    }
  }

  // ------------------------------------------------------------ mutations

  /// Whether a display change has somewhere to go right now: a live Bluetooth
  /// session, or a Wi-Fi endpoint that has answered.
  bool get _canMutate =>
      _device.connection.session != null || _device.lanReachable;

  /// Whether a picture upload has somewhere to go: image bytes travel over
  /// Wi-Fi only.
  bool get _canUpload => _device.supportsDisplay && _device.lanReachable;

  Future<void> _setMode(DisplayMode mode) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.devices.setMode(_device, mode);
      if (!mounted) return;
      if (_device.gamesRunning) {
        _toast(mode == DisplayMode.picture
            ? 'Picture saved; it will appear when the game ends.'
            : 'Smart clock saved; it will appear when the game ends.');
      } else {
        _toast(mode == DisplayMode.picture
            ? 'Showing the saved picture'
            : 'Showing the smart clock');
      }
    } catch (e) {
      if (mounted) _toast(describeRegistryError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reconnect() async {
    try {
      if (_device.bleId != null) {
        await widget.devices.connect(_device);
      }
      await widget.devices.refresh(_device, includeFrame: true);
      if (!mounted) return;
      if (_device.connection.session == null && !_device.lanReachable) {
        _toast('Still no answer from ${_device.displayName}.');
      }
    } catch (e) {
      if (mounted) _toast(describeRegistryError(e));
    }
  }

  Future<void> _pair() async {
    final paired = await Navigator.of(context).push<MirrorDevice>(
      MaterialPageRoute<MirrorDevice>(
        builder: (_) =>
            AddDeviceScreen(devices: widget.devices, pairWith: _device),
      ),
    );
    if (!mounted || paired == null) return;
    if (!await _followMerge()) return;
    _toast('${_device.displayName} paired over Bluetooth');
  }

  void _openClockEditor() {
    unawaited(openWorkspace(context, device: _device));
  }

  Future<void> _openGames() async {
    if (_device.bleId == null) {
      final paired = await Navigator.of(context).push<MirrorDevice>(
        MaterialPageRoute<MirrorDevice>(
          builder: (_) =>
              AddDeviceScreen(devices: widget.devices, pairWith: _device),
        ),
      );
      if (!mounted || paired == null) return;
      if (!await _followMerge()) return;
    } else if (_device.connection.session == null) {
      try {
        await widget.devices.connect(_device);
      } catch (e) {
        if (mounted) _toast(describeRegistryError(e));
        return;
      }
    }
    if (!mounted) return;
    if (_device.connection.session == null) {
      _toast('Games need a live Bluetooth link to the mirror.');
      return;
    }

    final controller = _createController();
    if (controller == null) return;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => GameScreen(
            controller: controller,
            connection: _device.connection,
            simplified: _view == UserView.defaultView,
            // A device-bound round never falls back to the local simulator:
            // the panel is what the player is steering.
            requireDevice: true,
          ),
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  Future<void> _openPicture() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PictureScreen(devices: widget.devices, device: _device),
      ),
    );
  }

  /// A controller for a route that needs the native engine, or null when the
  /// engine is missing. The caller disposes it, which closes the engine with
  /// it.
  ///
  /// [repair] says whether a missing engine is worth a page of instructions:
  /// a Games round cannot run without it, while device settings still can.
  DesignerController? _createController({bool repair = true}) {
    try {
      return DesignerController(
        MirrorEngine.open(),
        persistFlip180: (flipped) =>
            widget.devices.setFlip180(_device, flipped),
      );
    } on MirrorLibraryException catch (e) {
      if (repair) {
        unawaited(Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => EngineMissing(message: e.message),
          ),
        ));
      }
      return null;
    }
  }

  Future<void> _openSettings() async {
    final controller = _createController(repair: false);
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => DeviceSettingsScreen(
            device: _device,
            controller: controller,
            view: _view,
            onViewChanged: (view) => unawaited(_setView(view)),
            onUpdateFirmware: _updateFirmwareFromSettings,
          ),
        ),
      );
    } finally {
      controller?.dispose();
    }
  }

  Future<void> _updateFirmwareFromSettings() async {
    final bundled = _bundled ?? await loadBundledFirmware();
    if (!mounted) return;
    if (bundled == null) {
      _toast('This build has no bundled firmware to install.');
      return;
    }
    _bundled = bundled;
    final version = _deviceVersion ?? '';
    if (!firmwareUpdateAvailable(
        deviceVersion: version, bundledVersion: bundled.version)) {
      _toast(version.isEmpty
          ? 'This mirror has not reported a version yet.'
          : 'This mirror is already on v$version.');
      return;
    }
    final accepted = await confirmFirmwareUpdate(
      context,
      deviceVersion: version,
      bundledVersion: bundled.version,
      device: _device,
    );
    if (!accepted || !mounted) return;
    _offeredFirmware.add('${_device.key}|$version');
    await _installBundledFirmware(bundled);
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back to Devices',
          icon: const Icon(Icons.arrow_back),
          onPressed: () => unawaited(Navigator.maybePop(context)),
        ),
        title: Text(_device.displayName, overflow: TextOverflow.ellipsis),
        actions: <Widget>[
          IconButton(
            tooltip: 'Device settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => unawaited(_openSettings()),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _device,
        builder: (context, _) => _body(context),
      ),
    );
  }

  Widget _body(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: contentWidth),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= wideBreakpoint;
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: <Widget>[
                _header(context, wide: wide),
                const SizedBox(height: 12),
                if (wide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(child: _clockCard()),
                      const SizedBox(width: 12),
                      Expanded(child: _gamesCard()),
                      const SizedBox(width: 12),
                      Expanded(child: _pictureCard()),
                    ],
                  )
                else ...<Widget>[
                  _clockCard(),
                  const SizedBox(height: 12),
                  _gamesCard(),
                  const SizedBox(height: 12),
                  _pictureCard(),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _clockCard() => _SmartClockCard(
        device: _device,
        busy: _busy,
        canMutate: _canMutate,
        onUseClock: () => unawaited(_setMode(DisplayMode.clock)),
        onEditClock: _openClockEditor,
      );

  Widget _gamesCard() => _GamesCard(
        device: _device,
        onOpen: () => unawaited(_openGames()),
      );

  Widget _pictureCard() => _PictureCard(
        device: _device,
        busy: _busy,
        canUpload: _canUpload,
        canMutate: _canMutate,
        onChoose: () => unawaited(_openPicture()),
        onShow: () => unawaited(_setMode(DisplayMode.picture)),
      );

  /// The preview and the state it is showing. A phone stacks them; a window
  /// with room puts the status and its buttons beside the panel, so the width
  /// is spent on content instead of on margins around a tall picture.
  ///
  /// Device settings is deliberately not repeated here: it is in the app bar,
  /// where it does not cost the page a card.
  Widget _header(BuildContext context, {required bool wide}) {
    final theme = Theme.of(context);
    final device = _device;
    final preview = DevicePreview(
      device: device,
      height: previewHeight,
      semanticLabel: '${device.displayName} display',
    );
    final detailAlign =
        wide ? CrossAxisAlignment.start : CrossAxisAlignment.center;
    final actionAlign = wide ? WrapAlignment.start : WrapAlignment.center;
    final details = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: detailAlign,
      children: <Widget>[
        Text(
          deviceStatusText(device),
          textAlign: wide ? TextAlign.start : TextAlign.center,
          style: theme.textTheme.titleSmall,
        ),
        if (devicePreviewIsStale(device) && device.frameAt != null)
          Text(
            'Last seen ${relativeTime(device.frameAt!)}',
            textAlign: wide ? TextAlign.start : TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        if (device.error != null)
          Text(
            device.error!,
            textAlign: wide ? TextAlign.start : TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.error),
          ),
        const SizedBox(height: 8),
        Wrap(
          alignment: actionAlign,
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            OutlinedButton.icon(
              onPressed: () => unawaited(_reconnect()),
              icon: const Icon(Icons.refresh),
              label: const Text('Reconnect'),
            ),
            // A tooltip rather than a second wide button: two labelled buttons
            // of this length do not fit a phone, and the row they wrap into
            // costs the page more height than the Bluetooth action is worth.
            if (device.bleId == null)
              IconButton.outlined(
                tooltip: 'Connect Bluetooth',
                icon: const Icon(Icons.bluetooth_searching),
                onPressed: () => unawaited(_pair()),
              ),
          ],
        ),
      ],
    );
    if (!wide) {
      return Column(
        children: <Widget>[
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: preview,
            ),
          ),
          const SizedBox(height: 12),
          details,
        ],
      );
    }
    return Row(
      children: <Widget>[
        Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: preview,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(child: details),
      ],
    );
  }
}

/// The saved smart-clock display: choose it, or edit it.
class _SmartClockCard extends StatelessWidget {
  const _SmartClockCard({
    required this.device,
    required this.busy,
    required this.canMutate,
    required this.onUseClock,
    required this.onEditClock,
  });

  final MirrorDevice device;
  final bool busy;
  final bool canMutate;
  final VoidCallback onUseClock;
  final VoidCallback onEditClock;

  @override
  Widget build(BuildContext context) {
    final known = deviceCapabilityKnown(device);
    final offered = known && device.supportsDisplay;
    final showing = device.baseMode == DisplayMode.clock;
    final String state;
    final String explanation;
    if (!known) {
      state = 'Not known right now';
      explanation = 'This mirror has not answered yet. The clock editor still '
          'works; the saved display it changes is read from the device.';
    } else if (!offered) {
      state = 'Not offered by this firmware';
      explanation = 'This firmware has no saved display. The clock editor '
          'still pushes a layout, which is how it always worked.';
    } else {
      state = showing ? 'Saved display · showing now' : 'Saved display';
      explanation =
          'The clock the mirror falls back to when no game is running.';
    }
    return _ModeCard(
      icon: Icons.schedule,
      title: 'Smart clock',
      state: state,
      explanation: explanation,
      actions: <Widget>[
        if (offered)
          FilledButton(
            onPressed: busy || showing || !canMutate ? null : onUseClock,
            child: const Text('Use smart clock'),
          ),
        OutlinedButton(
          onPressed: onEditClock,
          child: const Text('Edit clock'),
        ),
      ],
      hint: _mutationHint(device, canMutate),
    );
  }
}

/// Games: a temporary override of whatever the saved display is.
class _GamesCard extends StatelessWidget {
  const _GamesCard({required this.device, required this.onOpen});

  final MirrorDevice device;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final state = device.gamesRunning
        ? 'Running now'
        : (device.bleId == null ? 'Not paired over Bluetooth' : 'Ready');
    return _ModeCard(
      icon: Icons.sports_esports,
      title: 'Games',
      state: state,
      explanation: 'A game takes over the panel until it is stopped, then the '
          'saved display comes back. Games run over Bluetooth.',
      actions: <Widget>[
        FilledButton(
          onPressed: onOpen,
          child: Text(device.gamesRunning ? 'Open games' : 'Start a game'),
        ),
      ],
      hint: device.bleId == null
          ? 'Pair this mirror over Bluetooth to play.'
          : null,
    );
  }
}

/// Picture display: one saved still image as the base display.
class _PictureCard extends StatelessWidget {
  const _PictureCard({
    required this.device,
    required this.busy,
    required this.canUpload,
    required this.canMutate,
    required this.onChoose,
    required this.onShow,
  });

  final MirrorDevice device;
  final bool busy;
  final bool canUpload;
  final bool canMutate;
  final VoidCallback onChoose;
  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) {
    final known = deviceCapabilityKnown(device);
    final offered = known && device.supportsDisplay;
    final String state;
    final String explanation;
    if (!known) {
      state = 'Not known right now';
      explanation = 'This mirror has not answered yet, so nothing is claimed '
          'about the picture it holds.';
    } else if (!offered) {
      state = 'Not offered by this firmware';
      explanation = 'Update this mirror\'s firmware to show pictures on it.';
    } else {
      state = !device.pictureReady
          ? 'No picture saved'
          : device.baseMode == DisplayMode.picture
              ? 'Saved picture · showing now'
              : 'Saved picture';
      explanation = 'One still image, stored on the mirror. Pictures are sent '
          'over Wi-Fi.';
    }

    return _ModeCard(
      icon: Icons.image_outlined,
      title: 'Picture display',
      state: state,
      explanation: explanation,
      actions: <Widget>[
        FilledButton(
          onPressed: !canUpload || busy ? null : onChoose,
          child: const Text('Choose picture'),
        ),
        if (offered && device.pictureReady)
          OutlinedButton(
            onPressed:
                busy || !canMutate || device.baseMode == DisplayMode.picture
                    ? null
                    : onShow,
            child: const Text('Show saved picture'),
          ),
      ],
      hint: _mutationHint(device, canMutate),
    );
  }
}

/// Why a display change cannot be sent right now, or null when it can.
String? _mutationHint(MirrorDevice device, bool canMutate) {
  if (canMutate) return null;
  if (device.endpoint == null && device.bleId == null) {
    return 'This device has no address yet. Add it over Wi-Fi or Bluetooth.';
  }
  return 'Offline. Reconnect to change the display.';
}

/// One of the three display cards: what the card is, what state it is in, and
/// the actions that change it.
///
/// The state and the actions are what the page exists for, so they are always
/// on screen; the explanation is prose read once, so it opens from the info
/// control and costs no height until asked for. Anything the owner has to know
/// *before* tapping — an offline device, an unpaired one — stays visible
/// rather than hidden: a disabled button with no reason is worse than a card
/// with a line of text.
class _ModeCard extends StatefulWidget {
  const _ModeCard({
    required this.icon,
    required this.title,
    required this.state,
    required this.explanation,
    required this.actions,
    this.hint,
  });

  final IconData icon;
  final String title;
  final String state;
  final String explanation;
  final List<Widget> actions;
  final String? hint;

  @override
  State<_ModeCard> createState() => _ModeCardState();
}

class _ModeCardState extends State<_ModeCard> {
  bool _explained = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = widget.hint;
    return Card(
      // The page already spaces its cards; a second margin inside each one
      // would only add height to a column that has to fit a phone.
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(widget.icon, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(widget.title, style: theme.textTheme.titleSmall),
                      Text(
                        widget.state,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip:
                      _explained ? 'Hide what this does' : 'What this does',
                  icon: Icon(
                    _explained ? Icons.expand_less : Icons.info_outline,
                  ),
                  onPressed: () => setState(() => _explained = !_explained),
                ),
              ],
            ),
            if (_explained) ...<Widget>[
              const SizedBox(height: 4),
              Text(widget.explanation, style: theme.textTheme.bodySmall),
            ],
            if (hint != null) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                hint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: widget.actions),
          ],
        ),
      ),
    );
  }
}

/// Device settings: everything that configures the mirror itself.
///
/// It links to the screens that already do this work rather than growing a
/// second provisioning implementation, and every control in them is bound to
/// the one device this route was opened for.
class DeviceSettingsScreen extends StatelessWidget {
  const DeviceSettingsScreen({
    super.key,
    required this.device,
    required this.controller,
    required this.view,
    required this.onViewChanged,
    required this.onUpdateFirmware,
  });

  final MirrorDevice device;

  /// Null when the native engine is missing: the setup screens need it, the
  /// firmware update does not.
  final DesignerController? controller;

  final UserView view;
  final ValueChanged<UserView> onViewChanged;
  final Future<void> Function() onUpdateFirmware;

  @override
  Widget build(BuildContext context) {
    final engineMissing = controller == null;
    return Scaffold(
      appBar: AppBar(title: const Text('Device settings')),
      body: ListView(
        children: <Widget>[
          ListTile(
            leading: const Icon(Icons.settings_remote),
            title: const Text('Setup, brightness, Wi-Fi and name'),
            subtitle: Text(engineMissing
                ? 'Needs the render engine (see the workspace fix)'
                : 'Rename this mirror, set its network and its display'),
            trailing: const Icon(Icons.chevron_right),
            enabled: !engineMissing,
            onTap: engineMissing
                ? null
                : () => unawaited(Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => MirrorScreen(
                          controller: controller!,
                          device: device,
                        ),
                      ),
                    )),
          ),
          ListTile(
            leading: const Icon(Icons.screen_rotation),
            title: const Text('Workspace and panel orientation'),
            subtitle: Text(engineMissing
                ? 'Needs the render engine (see the workspace fix)'
                : 'Rotate the panel, and choose the artist tools'),
            trailing: const Icon(Icons.chevron_right),
            enabled: !engineMissing,
            onTap: engineMissing
                ? null
                : () => unawaited(Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => SettingsScreen(
                          controller: controller!,
                          view: view,
                          onViewChanged: onViewChanged,
                          device: device,
                          connection: device.connection,
                        ),
                      ),
                    )),
          ),
          ListTile(
            leading: const Icon(Icons.system_update_alt),
            title: const Text('Update firmware'),
            subtitle: Text(
              device.status == null
                  ? 'The mirror\'s version is not known yet'
                  : 'Running v${device.status!.version}',
            ),
            onTap: () => unawaited(onUpdateFirmware()),
          ),
        ],
      ),
    );
  }
}
