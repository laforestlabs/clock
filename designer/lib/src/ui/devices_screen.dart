// The dashboard: every mirror this app has met, one tile each.
//
// A tile says at a glance whether the mirror behind it is answering, and the
// grid's order is decided once — at first render, by how recently each mirror
// answered — so nothing ever moves a tile under the owner's finger.
//
// This is the app's home and it deliberately does not load the native render
// engine: it shows what the devices are actually displaying, which means tiles
// keep working on a checkout whose C core was never built. Selecting a tile
// opens that device's own page; nothing here connects to a mirror that was not
// chosen.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/mirror_devices.dart';
import 'add_device_screen.dart';
import 'device_preview.dart';
import 'device_routes.dart';
import 'device_screen.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key, required this.devices});

  final MirrorDevices devices;

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen>
    with WidgetsBindingObserver, RouteAware {
  /// How often tiles on screen are re-read: their status *and* their frame.
  static const Duration visibleInterval = Duration(seconds: 5);

  /// How often the ones scrolled out of view, or remembered but offline, are
  /// retried. A hidden tile costs a status request, not a screenshot.
  static const Duration hiddenInterval = Duration(seconds: 15);

  /// The tile width the grid aims for, in logical pixels.
  static const double targetTileWidth = 200;

  /// Outer padding and the gap between tiles.
  static const double gridPadding = 16;
  static const double gridGap = 12;

  Timer? _visibleTimer;
  Timer? _hiddenTimer;
  bool _foreground = true;
  bool _onTop = true;
  bool _subscribed = false;

  /// One key per record, so a poll can tell which tiles are actually on
  /// screen. The grid builds every tile (it is a `Wrap`, not a lazy list), so
  /// this is a viewport question — which is exactly what "visible" means here.
  final Map<String, GlobalKey> _tileKeys = <String, GlobalKey>{};

  Size _screen = Size.zero;

  /// The order tiles are laid out in, fixed the first time the grid is built.
  /// Keys rather than records: a merged device gives its slot up to the record
  /// that absorbed it.
  final List<String> _tileOrder = <String>[];
  final Set<String> _tileOrderKeys = <String>{};
  bool _orderFixed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startTimers();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(widget.devices.refreshDiscovery());
      _pollVisible();
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
    _visibleTimer?.cancel();
    _visibleTimer = null;
    _hiddenTimer?.cancel();
    _hiddenTimer = null;
    if (_subscribed) appRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // -------------------------------------------------------------- polling

  void _startTimers() {
    if (!_foreground || !_onTop) return;
    _visibleTimer ??= Timer.periodic(visibleInterval, (_) => _pollVisible());
    _hiddenTimer ??= Timer.periodic(hiddenInterval, (_) => _pollHidden());
  }

  void _stopTimers() {
    _visibleTimer?.cancel();
    _visibleTimer = null;
    _hiddenTimer?.cancel();
    _hiddenTimer = null;
  }

  /// Refreshes the tiles the owner can actually see, frames included.
  void _pollVisible() {
    if (!mounted) return;
    for (final device in widget.devices.devices) {
      if (device.removed || !_tileIsVisible(device.key)) continue;
      unawaited(widget.devices.refresh(device, includeFrame: true));
    }
  }

  /// Retries the records the visible timer skipped: scrolled away, or
  /// remembered and offline. Status only; a screenshot nobody is looking at
  /// is wasted work on the mirror.
  void _pollHidden() {
    if (!mounted) return;
    for (final device in widget.devices.devices) {
      if (device.removed || _tileIsVisible(device.key)) continue;
      unawaited(widget.devices.refresh(device));
    }
  }

  bool _tileIsVisible(String key) {
    final tile = _tileKeys[key]?.currentContext;
    if (tile == null) return false;
    final box = tile.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    return rect.overlaps(Offset.zero & _screen);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    _foreground = foreground;
    if (foreground) {
      _startTimers();
      unawaited(widget.devices.refreshDiscovery());
      _pollVisible();
      return;
    }
    _stopTimers();
    // Leaving the foreground is the last chance to write the previews: the
    // next launch should show the panels as they were, not as they were two
    // minutes before.
    for (final device in widget.devices.devices) {
      unawaited(widget.devices.saveMetadata(device));
    }
  }

  @override
  void didPush() {
    _onTop = true;
    _startTimers();
  }

  @override
  void didPushNext() {
    _onTop = false;
    _stopTimers();
  }

  @override
  void didPopNext() {
    _onTop = true;
    _startTimers();
    // A device page can change the display; the tiles are stale the moment it
    // closes.
    _pollVisible();
  }

  // ------------------------------------------------------------ navigation

  Future<void> _refreshAll() async {
    await widget.devices.refreshDiscovery();
    if (!mounted) return;
    for (final device in widget.devices.devices) {
      unawaited(widget.devices.refresh(device, includeFrame: true));
    }
  }

  Future<void> _openDevice(MirrorDevice device) async {
    final target = device.mergedInto ?? device;
    // Started, not awaited: a Bluetooth connect can take seconds, and the
    // device page says so while it happens.
    unawaited(widget.devices.activate(target));
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DeviceScreen(devices: widget.devices, device: target),
      ),
    );
    if (!mounted) return;
    for (final device in widget.devices.devices) {
      unawaited(widget.devices.refresh(device));
    }
  }

  Future<void> _openAddDevice() async {
    final device = await Navigator.of(context).push<MirrorDevice>(
      MaterialPageRoute<MirrorDevice>(
        builder: (_) => AddDeviceScreen(devices: widget.devices),
      ),
    );
    if (!mounted || device == null) return;
    await _openDevice(device);
  }

  // --------------------------------------------------------------- ordering

  /// The devices in their fixed tile order.
  ///
  /// The first grid this screen builds is sorted by how recently each mirror
  /// answered — most recent first, so a launch puts the mirrors the owner has
  /// just been using at the top. That is the only sort that ever happens:
  /// every later poll moves only `lastSeen`, and a grid whose tiles reshuffle
  /// under a finger mid-tap or mid-scroll is worse than one left in a slightly
  /// stale order. A record that appears afterwards takes the next free slot;
  /// one that leaves gives its slot up.
  List<MirrorDevice> _inTileOrder(List<MirrorDevice> devices) {
    final live = <String, MirrorDevice>{
      for (final device in devices) device.key: device,
    };
    _tileOrder.removeWhere((key) => !live.containsKey(key));
    _tileOrderKeys.removeWhere((key) => !live.containsKey(key));
    if (!_orderFixed && devices.isNotEmpty) {
      _orderFixed = true;
      final sorted = devices.asMap().entries.toList()
        ..sort((a, b) {
          final recency = _byRecency(a.value, b.value);
          // Ties keep the restored order, which is the order the records were
          // loaded in: the one sort may as well be predictable.
          return recency != 0 ? recency : a.key.compareTo(b.key);
        });
      _tileOrder
        ..clear()
        ..addAll(sorted.map((entry) => entry.value.key));
      _tileOrderKeys
        ..clear()
        ..addAll(_tileOrder);
    }
    for (final device in devices) {
      if (_tileOrderKeys.add(device.key)) _tileOrder.add(device.key);
    }
    return <MirrorDevice>[for (final key in _tileOrder) live[key]!];
  }

  /// Most recently reached first. A device that has never answered goes last:
  /// it has no recency to sort by, and the tail is where an unknown device the
  /// owner has not met yet belongs.
  static int _byRecency(MirrorDevice a, MirrorDevice b) {
    final at = a.lastSeen;
    final bt = b.lastSeen;
    if (at == null) return bt == null ? 0 : 1;
    if (bt == null) return -1;
    return bt.compareTo(at);
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    _screen = MediaQuery.sizeOf(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Devices'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () => unawaited(_refreshAll()),
          ),
          IconButton(
            tooltip: 'Add device',
            icon: const Icon(Icons.add),
            onPressed: () => unawaited(_openAddDevice()),
          ),
          PopupMenuButton<VoidCallback>(
            tooltip: 'More',
            onSelected: (action) => action(),
            itemBuilder: (_) => <PopupMenuEntry<VoidCallback>>[
              PopupMenuItem<VoidCallback>(
                // The screen's own context, not the menu's: the menu route is
                // gone by the time this runs.
                value: () => unawaited(openWorkspace(context)),
                child: const Text('Layout designer / simulator'),
              ),
            ],
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.devices,
        builder: (context, _) => _body(context),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final devices = widget.devices;
    return Column(
      children: <Widget>[
        if (devices.warning != null)
          _Notice(
            message: devices.warning!,
            icon: Icons.warning_amber_outlined,
            actionLabel: 'Dismiss',
            onAction: devices.clearWarning,
          ),
        if (devices.discoveryError != null)
          _Notice(
            message: devices.discoveryError!,
            icon: Icons.wifi_tethering_off,
            actionLabel: 'Retry',
            onAction: () => unawaited(devices.refreshDiscovery()),
          ),
        Expanded(
          child: !devices.loaded
              ? const Center(child: CircularProgressIndicator())
              : devices.devices.isEmpty
                  ? _empty(context)
                  : _grid(context, _inTileOrder(devices.devices)),
        ),
      ],
    );
  }

  Widget _empty(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.devices_other,
                size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('No devices yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Add a mirror by its address, or pair one nearby over '
              'Bluetooth.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => unawaited(_openAddDevice()),
              icon: const Icon(Icons.add),
              label: const Text('Add device'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _grid(BuildContext context, List<MirrorDevice> devices) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Android can lay out the restored home before its first viewport
        // metrics arrive. Wait for space rather than creating negative tiles.
        if (constraints.maxWidth <= gridPadding * 2) {
          return const SizedBox.shrink();
        }
        final available = constraints.maxWidth - gridPadding * 2;
        final columns = math.max(
          1,
          ((available + gridGap) / (targetTileWidth + gridGap)).floor(),
        );
        final width = (available - gridGap * (columns - 1)) / columns;
        return SingleChildScrollView(
          padding: const EdgeInsets.all(gridPadding),
          child: Wrap(
            spacing: gridGap,
            runSpacing: gridGap,
            children: <Widget>[
              for (final device in devices)
                SizedBox(
                  width: width,
                  child: _DeviceTile(
                    key: _tileKeys.putIfAbsent(
                      device.key,
                      () => GlobalKey(),
                    ),
                    device: device,
                    onOpen: () => unawaited(_openDevice(device)),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// One device, as a tile: its actual panel, its name, its mode and whether it
/// is answering right now.
///
/// A mirror that answers on either transport is highlighted — a slight tint
/// over the card, a hairline, and a filled presence dot — so connected and
/// absent are one glance apart. The tile packs itself to the width the grid
/// gave it rather than assuming one shape: a wide tile puts the text beside
/// the panel, which is height saved on every tile of a phone's single column,
/// while the narrow tiles of a dense desktop grid keep the panel on top.
class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    super.key,
    required this.device,
    required this.onOpen,
  });

  /// Below this inner width the panel and the text stack.
  static const double besideBreakpoint = 260;

  /// The panel's box in each arrangement.
  static const double panelHeight = 84;
  static const double besidePanelHeight = 72;
  static const double besidePanelWidth = 132;

  final MirrorDevice device;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final online = deviceIsOnline(device);
    final frameAt = device.frameAt;
    final stale = devicePreviewIsStale(device);
    return Semantics(
      container: true,
      button: true,
      // One sentence for a screen reader rather than four fragments, and the
      // action it announces has to be the action the tile performs.
      label: deviceTileLabel(device),
      onTap: onOpen,
      child: ExcludeSemantics(
        child: Card(
          clipBehavior: Clip.antiAlias,
          // A mirror that answers is highlighted, one that does not keeps the
          // plain card. The tint is deliberately slight — the panel the tile
          // is showing stays the brightest thing on it — and the hairline
          // holds the highlight together on a theme where the tint alone is
          // nearly invisible.
          color: online
              ? Color.alphaBlend(
                  scheme.primary.withValues(alpha: 0.10),
                  theme.cardTheme.color ?? scheme.surfaceContainerLow,
                )
              : null,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: online
                ? BorderSide(color: scheme.primary.withValues(alpha: 0.5))
                : BorderSide.none,
          ),
          child: InkWell(
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final beside = constraints.maxWidth >= besideBreakpoint;
                  final details = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        device.displayName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        deviceModeLabel(device),
                        style: theme.textTheme.labelMedium,
                      ),
                      const SizedBox(height: 4),
                      // Presence as shape as well as colour: filled for a
                      // mirror that answers, hollow for one that does not, so
                      // the tile does not rest on hue alone.
                      Row(
                        children: <Widget>[
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: online ? scheme.primary : null,
                              border: Border.all(
                                color:
                                    online ? scheme.primary : scheme.outline,
                                width: 1.5,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              deviceStatusText(device),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: online
                                    ? scheme.onSurface
                                    : scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (device.uploading)
                        Text(
                          'Sending picture…',
                          style: theme.textTheme.bodySmall,
                        )
                      else if (stale && frameAt != null)
                        Text(
                          'Last seen ${relativeTime(frameAt)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  );
                  final preview = DevicePreview(
                    device: device,
                    height: beside ? besidePanelHeight : panelHeight,
                  );
                  if (!beside) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        preview,
                        const SizedBox(height: 10),
                        details,
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: besidePanelWidth,
                        ),
                        child: preview,
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: details),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An inline message above the grid: a restore problem, or a discovery run
/// that failed. Retryable rather than a dead end, because a network that
/// refuses multicast is the normal case, not the broken one.
class _Notice extends StatelessWidget {
  const _Notice({
    required this.message,
    required this.icon,
    required this.actionLabel,
    required this.onAction,
  });

  final String message;
  final IconData icon;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message, style: theme.textTheme.bodySmall),
            ),
            TextButton(
              onPressed: onAction,
              child: Text(actionLabel),
            ),
          ],
        ),
      ),
    );
  }
}
