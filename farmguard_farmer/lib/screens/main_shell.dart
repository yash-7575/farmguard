import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../data/mock_data.dart';
import '../models/models.dart';
import '../services/api/exceptions.dart';
import '../services/app_services.dart';
import '../services/messaging/messaging_gateway.dart';
import 'cameras_screen.dart';
import 'history_screen.dart';
import 'home_screen.dart';
import 'settings_screen.dart';
import 'detection_detail_screen.dart';
import '../widgets/async_states.dart';
import '../widgets/empty_state.dart';
import '../widgets/pairing_code_dialog.dart';

enum _LoadStatus { loading, ready, error }

/// Bottom-navigation shell hosting the four top-level destinations.
///
/// Single state owner for the live backend data: events and cameras are
/// fetched through the injected repositories (constructor injection — fakes
/// in tests). The retained demo records from `MockData` stay visible and
/// labelled DEMO; live events are shown above them, newest first.
///
/// Async states per tab: loading spinner on first fetch; on failure an
/// error card when there is nothing to show, else the cached data with a
/// subtle "offline — cached" banner and Retry. Unauthorized errors clear
/// the session and return to login via [onSessionExpired].
///
/// Follows the skill's NavigationBar pattern (save/restore state between
/// tabs) via an [IndexedStack], so each tab keeps its scroll position.
class MainShell extends StatefulWidget {
  final AppServices services;
  final String farmerName;
  final String farmerEmail;
  final VoidCallback onSessionExpired;

  /// Clears the push registration and the session, then returns to login
  /// (Settings → Log out). Owned by the auth gate so it runs before the
  /// token is cleared.
  final Future<void> Function() onLogout;

  const MainShell({
    super.key,
    required this.services,
    required this.farmerName,
    required this.farmerEmail,
    required this.onSessionExpired,
    required this.onLogout,
  });

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;
  StreamSubscription<FcmTap>? _tapSub;

  // ── Live data (repositories) ──────────────────────────────────────────
  List<DetectionEvent> _liveEvents = <DetectionEvent>[];
  List<FarmCamera> _cameras = <FarmCamera>[];
  String? _nextBefore;
  _LoadStatus _eventsStatus = _LoadStatus.loading;
  _LoadStatus _camerasStatus = _LoadStatus.loading;
  ApiException? _camerasError;
  bool _loadingMore = false;

  /// Cameras with a delete request in flight — prevents duplicate removals
  /// and disables the card's remove action meanwhile.
  final Set<String> _removingCameraIds = <String>{};

  // Shared, mutable event objects so New → Viewed transitions are visible
  // across Home and History. Demo records come first in object identity:
  // MockData.events entries are mutated in place.
  List<DetectionEvent> get _displayEvents =>
      <DetectionEvent>[..._liveEvents, ...MockData.events];

  /// Cameras for tile lookups: live cameras win, demo cameras fill in.
  List<FarmCamera> get _lookupCameras =>
      <FarmCamera>[..._cameras, ...MockData.cameras];

  FarmCamera? _cameraById(String id) {
    for (final FarmCamera camera in _lookupCameras) {
      if (camera.id == id) return camera;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _refreshAll();
    // Push-notification taps (background resumption and cold start) route
    // to the matching detail screen. No gateway (test wiring) → no-op.
    _tapSub = widget.services.messaging?.taps.listen(_handleNotificationTap);
  }

  @override
  void dispose() {
    _tapSub?.cancel();
    super.dispose();
  }

  /// Connected / total camera counts from live data only. `null` while
  /// unknown (no cached cameras and fetch not ready) so the UI never
  /// fabricates a status.
  (int, int)? get _cameraCounts {
    if (_camerasStatus == _LoadStatus.ready || _cameras.isNotEmpty) {
      return (_cameras.where((c) => c.isOnline).length, _cameras.length);
    }
    return null;
  }

  void _handleError(ApiException error) {
    if (error.isUnauthorized) {
      widget.onSessionExpired();
    }
  }

  Future<void> _refreshAll() async {
    await Future.wait(<Future<void>>[_loadEvents(), _loadCameras()]);
  }

  Future<void> _loadEvents() async {
    try {
      final page = await widget.services.eventRepository
          .fetchFirstPageWithCursor();
      if (!mounted) return;
      setState(() {
        _liveEvents = page.events;
        _nextBefore = page.nextBefore;
        _eventsStatus = _LoadStatus.ready;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.isUnauthorized) {
        widget.onSessionExpired();
        return;
      }
      setState(() => _eventsStatus = _LoadStatus.error);
    } catch (_) {
      if (!mounted) return;
      setState(() => _eventsStatus = _LoadStatus.error);
    }
  }

  Future<void> _loadCameras() async {
    try {
      final cameras = await widget.services.cameraRepository.fetchCameras();
      if (!mounted) return;
      setState(() {
        _cameras = cameras;
        _camerasStatus = _LoadStatus.ready;
        _camerasError = null;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.isUnauthorized) {
        widget.onSessionExpired();
        return;
      }
      setState(() {
        _camerasStatus = _LoadStatus.error;
        _camerasError = error;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _camerasStatus = _LoadStatus.error);
    }
  }

  Future<void> _loadMoreEvents() async {
    final String? before = _nextBefore;
    if (before == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.services.eventRepository
          .fetchPageWithCursor(before);
      if (!mounted) return;
      setState(() {
        _liveEvents = <String, DetectionEvent>{
          for (final DetectionEvent e in _liveEvents) e.id: e,
          for (final DetectionEvent e in page.events) e.id: e,
        }.values.toList();
        _nextBefore = page.nextBefore;
        _eventsStatus = _LoadStatus.ready;
        _loadingMore = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      if (error.isUnauthorized) {
        widget.onSessionExpired();
        return;
      }
      if (error.isTransient) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text("Couldn't load older events. Try again."),
            ),
          );
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  // ── Push-notification tap routing ─────────────────────────────────────

  /// Taps without an event id are a no-op; taps with one open the event's
  /// detail screen (404/deleted → graceful snackbar, never a crash).
  void _handleNotificationTap(FcmTap tap) {
    final String? eventId = tap.eventId;
    if (eventId == null) return;
    _openEventFromTap(eventId);
  }

  Future<void> _openEventFromTap(String eventId) async {
    try {
      final DetectionEvent event =
          await widget.services.eventRepository.getEvent(eventId);
      if (!mounted) return;
      _openDetection(event);
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.isUnauthorized) {
        widget.onSessionExpired();
        return;
      }
      if (error.statusCode == 404) {
        // Deleted (or foreign) event → tell the farmer, stay put.
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('Event no longer available'),
            ),
          );
      }
      // Other errors (offline etc.) → silent no-op; the push can be
      // re-opened from History later.
    } catch (_) {
      // Never crash on a tap.
    }
  }

  void _openDetection(DetectionEvent event) {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(
          builder: (BuildContext context) => DetectionDetailScreen(
            event: event,
            camera: _cameraById(event.cameraId),
            eventRepository: widget.services.eventRepository,
            onViewedError: _handleError,
          ),
        ))
        .then((_) {
      if (mounted) {
        // Local mutation kept so the New → Viewed transition is visible
        // across tabs even when the server call failed (fire-and-forget in
        // the detail screen).
        setState(() => event.isViewed = true);
      }
    });
  }

  // ── Per-tab builders ──────────────────────────────────────────────────

  Widget? get _eventsBanner {
    if (_eventsStatus != _LoadStatus.error) return null;
    return OfflineBanner(onRetry: _refreshAll);
  }

  Widget _homeTab() {
    if (_eventsStatus == _LoadStatus.loading && _liveEvents.isEmpty) {
      return const LoadingView();
    }
    final (int, int)? counts = _cameraCounts;
    return HomeScreen(
      events: _displayEvents,
      connectedCameras: counts?.$1,
      totalCameras: counts?.$2,
      cameras: _lookupCameras,
      topBanner: _eventsBanner,
      imageLoader: widget.services.eventRepository.getImage,
      onSeeAllHistory: () => setState(() => _index = 1),
      onOpenEvent: _openDetection,
    );
  }

  Widget _historyTab() {
    if (_eventsStatus == _LoadStatus.loading && _liveEvents.isEmpty) {
      return const LoadingView();
    }
    return HistoryScreen(
      events: _displayEvents,
      cameras: _lookupCameras,
      topBanner: _eventsBanner,
      canLoadMore: _nextBefore != null,
      isLoadingMore: _loadingMore,
      onLoadMore: _loadMoreEvents,
      imageLoader: widget.services.eventRepository.getImage,
      onOpenEvent: _openDetection,
    );
  }

  Widget _camerasTab() {
    if (_camerasStatus == _LoadStatus.loading && _cameras.isEmpty) {
      return const LoadingView();
    }
    if (_camerasStatus == _LoadStatus.error && _cameras.isEmpty) {
      return ErrorCard(
        title: "Couldn't load cameras",
        message: _camerasError?.message ??
            'Check your connection and try again.',
        onRetry: _loadCameras,
      );
    }
    if (_camerasStatus == _LoadStatus.ready && _cameras.isEmpty) {
      return EmptyState(
        icon: Icons.videocam,
        title: 'No cameras yet',
        message:
            'When a camera is added to your farm, it will appear here with '
            'its live status.',
        action: FilledButton.tonal(
          onPressed: _openPairingDialog,
          child: const Text('Pair a camera'),
        ),
      );
    }
    return CamerasScreen(
      cameras: _cameras,
      topBanner: _camerasStatus == _LoadStatus.error
          ? OfflineBanner(onRetry: _refreshAll)
          : null,
      onPairCamera: _openPairingDialog,
      onRemoveCamera: _confirmAndRemoveCamera,
      removingCameraIds: _removingCameraIds,
    );
  }

  /// Asks the farmer to confirm, then deletes the camera on the backend and
  /// refreshes the list. Historical events (`_liveEvents`, `MockData.events`)
  /// are deliberately untouched — only the camera record goes away.
  Future<void> _confirmAndRemoveCamera(FarmCamera camera) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Remove Camera'),
        content: Text(
          'Remove ${camera.name}? This will disconnect the camera from your '
          'account. You will need to pair it again to reconnect.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove Camera'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (_removingCameraIds.contains(camera.id)) return;

    setState(() => _removingCameraIds.add(camera.id));
    try {
      await widget.services.cameraRepository.deleteCamera(camera.id);
      if (!mounted) return;
      await _loadCameras();
      if (!mounted) return;
      setState(() => _removingCameraIds.remove(camera.id));
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('${camera.name} removed.')));
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _removingCameraIds.remove(camera.id));
      if (error.isUnauthorized) {
        widget.onSessionExpired();
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              error.message.isNotEmpty
                  ? error.message
                  : "Couldn't remove ${camera.name}. Try again.",
            ),
          ),
        );
    } catch (_) {
      if (!mounted) return;
      setState(() => _removingCameraIds.remove(camera.id));
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text("Couldn't remove ${camera.name}. Try again."),
          ),
        );
    }
  }

  /// Opens the pairing-code dialog (direct api call via AppServices —
  /// CameraRepository is not involved). 401 inside the dialog pops it and
  /// routes through the shell's session-expiry path.
  Future<void> _openPairingDialog() async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => PairingCodeDialog(
        onCreateCode: widget.services.api.createPairingCode,
        onSessionExpired: widget.onSessionExpired,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: <Widget>[
          _homeTab(),
          _historyTab(),
          _camerasTab(),
          SettingsScreen(
            farmerName: widget.farmerName,
            farmerEmail: widget.farmerEmail,
            onLogout: () => widget.onLogout(),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (int value) => setState(() => _index = value),
        destinations: const <Widget>[
          NavigationDestination(
            selectedIcon: Icon(Icons.home),
            icon: Icon(Icons.home_outlined),
            label: 'Home',
          ),
          NavigationDestination(
            selectedIcon: Icon(Icons.history),
            icon: Icon(Icons.history_outlined),
            label: 'History',
          ),
          NavigationDestination(
            selectedIcon: Icon(Icons.videocam),
            icon: Icon(Icons.videocam_outlined),
            label: 'Cameras',
          ),
          NavigationDestination(
            selectedIcon: Icon(Icons.settings),
            icon: Icon(Icons.settings_outlined),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
