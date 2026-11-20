import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ultralytics_yolo/core/yolo_model_manager.dart' show YOLOModelManager;
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import '../services/api_client.dart';
import '../services/cloud_services.dart';
import '../services/detection_event_engine.dart';
import '../services/detection_stats.dart';
import '../services/device_registration.dart';
import '../services/diagnostic_logger.dart';
import '../services/model_gateway.dart';
import '../services/pending_event_store.dart';
import '../widgets/camera_status_views.dart';
import '../widgets/cloud_status_card.dart';
import '../widgets/detection_stats_bar.dart';
import '../widgets/pairing_dialog.dart';

/// Phases of the monitoring flow.
enum MonitoringPhase {
  /// Placeholder card; no camera resources held.
  idle,

  /// Permission request, model download and model load in progress.
  initializing,

  /// Live detection running. Entered only after the model loaded and the
  /// native view reports inference readiness.
  monitoring,

  /// User denied the camera permission; retrying re-prompts.
  permissionDenied,

  /// Permission appears permanently denied; user must enable it in settings.
  permissionPermanentlyDenied,

  /// Any other failure (download, model load, native view error).
  error,
}

/// What happens inside the [MonitoringPhase.initializing] phase.
///
/// The stages are explicit so the UI always says what is actually going on
/// instead of a generic "Starting…" for up to a minute.
enum MonitoringStartupStage {
  /// Native camera permission check/request.
  checkingPermissions,

  /// Official YOLO26s model is being downloaded and cached (first use only).
  downloadingModel,

  /// Model is cached; the native view is loading it into LiteRT.
  loadingModel,

  /// Model path resolved and the native view mounted; waiting for the
  /// first native inference callback (camera + detection pipeline up).
  initializingCamera,
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.modelGateway, this.cloudServices});

  /// Injectable model-asset gateway; defaults to the real Ultralytics
  /// resolver. Tests inject a fake so no platform channel is touched.
  final ModelGateway? modelGateway;

  /// Injectable cloud bundle (API, registration store, event engine,
  /// upload queue); defaults to [CloudServices.production]. Tests inject
  /// a bundle built from fakes.
  final CloudServices? cloudServices;

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

/// State for [HomeScreen].
///
/// Public (with the `debug…` hooks below) so widget tests can drive the
/// startup readiness gate without a native platform view.
class HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const _settingsChannel = MethodChannel('farmguard_camera/settings');

  /// Official Ultralytics model ID. Resolves to the pinned official
  /// `yolo26s_w8a32.tflite` asset (int8 weights, FP32 activations) from the
  /// plugin's v0.7.0 LiteRT release. Never silently substituted.
  static const _modelId = 'yolo26s';

  /// Label shown in the stats bar.
  static const _modelLabel = 'YOLO26s · W8A32';

  /// Streaming cap: results are sent to Flutter at most 15 times per second
  /// so the UI thread is never flooded; native inference cadence is managed
  /// by the plugin's analyzer backpressure.
  static final _streamingConfig = YOLOStreamingConfig.throttled(
    maxFPS: 15,
    includeMasks: false,
    includeOriginalImage: false,
  );

  MonitoringPhase _phase = MonitoringPhase.idle;
  String? _errorDetail;
  MonitoringStartupStage _startupStage =
      MonitoringStartupStage.checkingPermissions;
  double _downloadFraction = 0;

  final DetectionStatsTracker _stats = DetectionStatsTracker();
  YOLOViewController? _yoloController;

  late final ModelGateway _modelGateway =
      widget.modelGateway ?? const UltralyticsModelGateway();

  /// Resolved local path of the cached model; non-null once the model is
  /// ready and the native detection view may be mounted.
  String? _resolvedModelPath;

  /// Monotonically increasing token guarding start/stop/lifecycle races.
  int _session = 0;

  /// Whether monitoring was active before an app lifecycle interruption.
  bool _resumeOnAppResume = false;

  StreamSubscription<DownloadProgress>? _downloadProgressSub;

  /// Startup readiness watchdog: armed when the model path resolves, fired
  /// if the native pipeline never reports a detection/metrics callback.
  Timer? _startupWatchdog;

  static const _startupTimeout = Duration(seconds: 20);

  bool get _busy => _phase == MonitoringPhase.initializing;

  /// Whether the detection preview may be mounted (model path resolved).
  bool get _showPreview =>
      _resolvedModelPath != null &&
      (_phase == MonitoringPhase.initializing ||
          _phase == MonitoringPhase.monitoring);

  // ---- Cloud wiring (pairing, event engine, upload queue) ----

  /// Injected or production cloud bundle; first access builds the
  /// default (which is inert under `flutter test`).
  late final CloudServices _cloud =
      widget.cloudServices ?? CloudServices.production();

  /// Whether this screen created the bundle itself (and therefore owns
  /// its disposal).
  late final bool _ownsCloud = widget.cloudServices == null;

  StreamSubscription<ConfirmedEvent>? _eventSubscription;
  Timer? _heartbeatTimer;
  CameraRegistration? _registration;

  /// True while the startup restore is running (drives the 'Syncing'
  /// cloud state).
  bool _restoringCloud = false;

  /// True while the pairing dialog's redeem call is in flight.
  bool _pairingInFlight = false;

  /// Last confirmed heartbeat / session refresh (UTC).
  DateTime? _lastHeartbeatAt;

  /// Whether the last heartbeat/session call reached the backend.
  bool _backendOnline = false;

  /// One-line notice shown in the status card (e.g. "camera was removed").
  String? _cloudNotice;

  static const _heartbeatInterval = Duration(seconds: 60);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Confirmed presence events → capture → enqueue for upload.
    _eventSubscription =
        _cloud.engine.eventStream.listen(_onConfirmedEventGuarded);
    // One-time startup restore: persisted registration + upload queue.
    // Inert in the test-environment default bundle.
    if (_cloud.backgroundEnabled) {
      unawaited(_restoreCloud());
    }
  }

  @override
  void dispose() {
    unawaited(_eventSubscription?.cancel());
    _eventSubscription = null;
    _stopCloudSync();
    if (_ownsCloud) {
      _cloud.dispose();
    }
    WidgetsBinding.instance.removeObserver(this);
    _teardownResources();
    _stats.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
      case AppLifecycleState.paused:
        _pauseForLifecycle();
      case AppLifecycleState.resumed:
        _resumeAfterLifecycle();
    }
  }

  /// Releases the detection view (and its camera) when the app leaves the
  /// foreground, remembering whether monitoring should resume on return.
  void _pauseForLifecycle() {
    final wasActive = _phase == MonitoringPhase.monitoring ||
        _phase == MonitoringPhase.initializing;
    if (!wasActive && _yoloController == null) {
      return;
    }
    _resumeOnAppResume = wasActive;
    _session++;
    _stopCloudSync();
    _teardownResources();
    if (mounted) {
      setState(() => _phase = MonitoringPhase.idle);
    }
  }

  /// Re-starts monitoring only if it was active before the interruption.
  void _resumeAfterLifecycle() {
    if (!_resumeOnAppResume) {
      return;
    }
    _resumeOnAppResume = false;
    if (mounted && _phase == MonitoringPhase.idle) {
      unawaited(startMonitoring());
    }
  }

  /// Starts monitoring: permission → model download/cache → native view
  /// load → live detection. Never re-enters while initializing/monitoring.
  Future<void> startMonitoring() async {
    if (!mounted ||
        _phase == MonitoringPhase.initializing ||
        _phase == MonitoringPhase.monitoring) {
      return;
    }

    final session = ++_session;
    _cancelStartupWatchdog();
    setState(() {
      _phase = MonitoringPhase.initializing;
      _startupStage = MonitoringStartupStage.checkingPermissions;
      _downloadFraction = 0;
      _errorDetail = null;
      _resolvedModelPath = null;
    });
    _stats.reset();
    logCameraDiagnostic('start_monitoring');

    // 1) Camera permission (native channel keeps deniability states working;
    //    YOLOView only mounts with the permission already granted).
    final permission = await _requestCameraPermission();
    if (session != _session || !mounted) {
      return;
    }
    switch (permission) {
      case 'granted':
        break;
      case 'denied':
        setState(() => _phase = MonitoringPhase.permissionDenied);
        return;
      case 'permanentlyDenied':
        setState(() => _phase = MonitoringPhase.permissionPermanentlyDenied);
        return;
      default:
        setState(() {
          _phase = MonitoringPhase.error;
          _errorDetail = 'Permission check failed: $permission';
        });
        return;
    }

    // 2) Show download progress for the official model (streamed by the
    //    plugin whenever it downloads; cached models skip this entirely).
    _downloadProgressSub = YOLOModelManager.downloadProgress
        .where((progress) => progress.modelId == _modelId)
        .listen((progress) {
      if (!mounted || _phase != MonitoringPhase.initializing) {
        return;
      }
      setState(() {
        _downloadFraction = progress.fraction;
        if (progress.fraction < 1) {
          _startupStage = MonitoringStartupStage.downloadingModel;
        }
      });
    });

    // 3) Resolve the model: cache hit → instant; first use → one download
    //    to app storage. Interrupted downloads are retried by calling this
    //    again; the resolver validates the artifact before installing it.
    try {
      final availableLocally =
          await _modelGateway.isModelAvailableLocally(_modelId);
      if (session != _session || !mounted) {
        return;
      }
      setState(() {
        _startupStage = availableLocally
            ? MonitoringStartupStage.loadingModel
            : MonitoringStartupStage.downloadingModel;
      });
      logCameraDiagnostic(
        'model_resolve_start',
        {'cached': availableLocally},
      );

      final resolvedPath = await _modelGateway.resolveModel(_modelId);
      if (session != _session || !mounted) {
        return;
      }
      setState(() {
        _resolvedModelPath = resolvedPath;
        _startupStage = MonitoringStartupStage.initializingCamera;
      });
      logCameraDiagnostic('model_resolved');
      // The native view is mounted now. `MonitoringPhase.monitoring` is only
      // entered once the native pipeline reports its first inference
      // callback (see [_promoteToMonitoringIfReady]); `onModelLoad` alone
      // fires before the camera/LiteRT pipeline actually runs.
    } catch (error) {
      _handleStartFailure(session, error);
    }
  }

  /// Stops monitoring and releases the camera immediately from the user's
  /// point of view; native teardown then completes asynchronously.
  Future<void> stopMonitoring() async {
    if (_phase == MonitoringPhase.idle) {
      return;
    }
    _session++; // Invalidate any in-flight permission/download/load work.
    logCameraDiagnostic('stop_monitoring', {'phase': _phase.name});
    _stopCloudSync();
    _teardownResources();
    if (mounted) {
      setState(() {
        _phase = MonitoringPhase.idle;
        _errorDetail = null;
      });
    }
    _stats.reset();
  }

  /// Cancels subscriptions, the startup watchdog and unmounts the native
  /// view's controller.
  void _teardownResources() {
    unawaited(_downloadProgressSub?.cancel());
    _downloadProgressSub = null;
    _cancelStartupWatchdog();
    _resolvedModelPath = null;
    final controller = _yoloController;
    _yoloController = null;
    if (controller != null) {
      unawaited(_safeStop(controller));
    }
  }

  Future<void> _safeStop(YOLOViewController controller) async {
    try {
      await controller.stop();
    } catch (_) {
      // Stopping a view that is already gone is harmless.
    }
    try {
      controller.dispose();
    } catch (_) {
      // Disposal errors are non-fatal.
    }
  }

  void _handleStartFailure(int session, Object error) {
    if (session != _session || !mounted) {
      return;
    }
    logCameraDiagnostic('start_failed', {'error': '$error'});
    _cancelStartupWatchdog();
    setState(() {
      _phase = MonitoringPhase.error;
      _errorDetail = '$error';
    });
  }

  /// Arms the startup watchdog: after the plugin's model-load callback the
  /// native pipeline must report a detection or performance-metrics callback
  /// within [_startupTimeout], otherwise the mount is treated as failed.
  void _startStartupWatchdog() {
    _cancelStartupWatchdog();
    _startupWatchdog = Timer(_startupTimeout, _onStartupTimeout);
  }

  void _cancelStartupWatchdog() {
    _startupWatchdog?.cancel();
    _startupWatchdog = null;
  }

  /// The native view never delivered an inference callback in time. Tear
  /// the half-initialized view down and surface a retryable error instead of
  /// leaving the user on an endless "Initializing…" screen.
  void _onStartupTimeout() {
    _startupWatchdog = null;
    if (!mounted || _phase != MonitoringPhase.initializing) {
      return;
    }
    logCameraDiagnostic('startup_watchdog_timeout');
    _session++;
    _stopCloudSync();
    _teardownResources();
    setState(() {
      _phase = MonitoringPhase.error;
      _errorDetail =
          'Camera and YOLO26s detection pipeline timed out during '
          'initialization. Please try again.';
    });
  }

  /// Called by the native view when the model file is loaded.
  ///
  /// In ultralytics_yolo 0.7.2 this fires in Dart as soon as the file path
  /// resolves — *before* the native AndroidView, LiteRT interpreter and
  /// CameraX pipeline start. Monitoring therefore stays in
  /// [MonitoringPhase.initializing] and only the first native inference
  /// callback ([_promoteToMonitoringIfReady]) reports live monitoring.
  void _onModelReady() {
    if (!mounted || _phase != MonitoringPhase.initializing) {
      return;
    }
    logCameraDiagnostic('model_load_callback');
    setState(() {
      _startupStage = MonitoringStartupStage.initializingCamera;
    });
    _startStartupWatchdog();
  }

  /// Promotes to [MonitoringPhase.monitoring] on the first native inference
  /// callback (detections or performance metrics), which proves the camera
  /// and detection pipeline are actually running.
  void _promoteToMonitoringIfReady() {
    if (!mounted ||
        _phase != MonitoringPhase.initializing ||
        _resolvedModelPath == null) {
      return;
    }
    _cancelStartupWatchdog();
    logCameraDiagnostic('native_ready');
    setState(() {
      _phase = MonitoringPhase.monitoring;
      _startupStage = MonitoringStartupStage.initializingCamera;
    });
    // Live monitoring is up: start upload-queue processing and heartbeats.
    _startCloudSync();
  }

  void _onModelError(Object error) {
    if (!mounted) {
      return;
    }
    logCameraDiagnostic('model_error', {'error': '$error'});
    _cancelStartupWatchdog();
    _stopCloudSync();
    setState(() {
      _phase = MonitoringPhase.error;
      _errorDetail = '$error';
    });
  }

  void _onDetections(List<YOLOResult> results) {
    _promoteToMonitoringIfReady();
    _stats.recordDetections(
      results.map(
        (result) => (
          className: result.className,
          confidence: result.confidence,
        ),
      ),
    );
    // Also feed the presence-confirmation engine: YOLOResult's
    // `normalizedBox` (Rect) maps to the engine's normalized box record.
    _engine.processFrame(results.map(_toEngineDetection));
  }

  EngineDetection _toEngineDetection(YOLOResult result) {
    final box = result.normalizedBox;
    final usable = box.width > 0 && box.height > 0;
    return (
      className: result.className,
      confidence: result.confidence,
      box: usable
          ? (
              left: box.left,
              top: box.top,
              width: box.width,
              height: box.height,
            )
          : null,
    );
  }

  void _onMetrics(YOLOPerformanceMetrics metrics) {
    _promoteToMonitoringIfReady();
    _stats.recordMetrics(
      fps: metrics.fps,
      inferenceMs: metrics.processingTimeMs,
    );
  }

  /// Test hook: drives the "first native callback" promotion without a
  /// native platform view (see [_promoteToMonitoringIfReady]).
  @visibleForTesting
  void debugNotifyNativeReady() => _promoteToMonitoringIfReady();

  /// Test hook: simulates the plugin's `onModelLoad` callback.
  @visibleForTesting
  void debugNotifyModelReady() => _onModelReady();

  /// Test hook: sends one heartbeat through the normal path.
  @visibleForTesting
  Future<void> debugSendHeartbeat() => _sendHeartbeat();

  /// Test hook: current startup sub-stage.
  @visibleForTesting
  MonitoringStartupStage get debugStartupStage => _startupStage;

  /// Test hook: whether the backend is currently considered reachable.
  @visibleForTesting
  bool get debugBackendOnline => _backendOnline;

  // -----------------------------------------------------------------------
  // Cloud: restore, pairing, engine events, queue + heartbeat lifecycle
  // -----------------------------------------------------------------------

  DetectionEventEngine get _engine => _cloud.engine;

  /// One-time startup restore (production path only): loads the persisted
  /// registration and the upload queue, then refreshes the camera session so
  /// a camera removed from the farmer account is detected immediately.
  /// Best effort — failures never block the camera UI.
  Future<void> _restoreCloud() async {
    _restoringCloud = true;
    try {
      final registration = await _cloud.registrationStore.load();
      if (!mounted) {
        return;
      }
      _cloud.updateRegistration(registration);
      setState(() => _registration = registration);
      await _cloud.queue.restore();
      if (registration != null) {
        await _refreshCameraSession();
      }
    } catch (_) {
      // Cloud restore is best-effort at startup.
    } finally {
      if (mounted) {
        setState(() => _restoringCloud = false);
      } else {
        _restoringCloud = false;
      }
    }
  }

  /// Refreshes the server's view of this camera (`GET /api/v1/cameras/me`):
  /// picks up a renamed camera and the farmer account details, and drops the
  /// registration when the camera was removed from the farmer account.
  Future<void> _refreshCameraSession() async {
    final registration = _registration;
    if (registration == null) {
      return;
    }
    final CameraSessionInfo? info;
    try {
      info = await _cloud.api.fetchCameraSession();
    } on PermanentUploadException {
      logCameraDiagnostic('session_unauthorized');
      await _handleUnpaired(
        'This camera was removed from the farmer account. '
        'Pair again to reconnect.',
      );
      return;
    } catch (error) {
      logCameraDiagnostic('session_refresh_failed', {'error': '$error'});
      if (mounted) {
        setState(() => _backendOnline = false);
      }
      return;
    }
    if (!mounted) {
      return;
    }
    if (info == null) {
      setState(() => _backendOnline = false);
      return;
    }
    final updated = CameraRegistration(
      token: registration.token,
      cameraId: info.cameraId.isEmpty ? registration.cameraId : info.cameraId,
      cameraName:
          info.cameraName.isEmpty ? registration.cameraName : info.cameraName,
      location: info.location ?? registration.location,
      farmerId: info.farmerId ?? registration.farmerId,
      farmerName: info.farmerName ?? registration.farmerName,
      farmerEmailMasked:
          info.farmerEmailMasked ?? registration.farmerEmailMasked,
    );
    try {
      await _cloud.registrationStore.save(
        token: updated.token,
        cameraId: updated.cameraId,
        cameraName: updated.cameraName,
        location: updated.location,
        farmerId: updated.farmerId,
        farmerName: updated.farmerName,
        farmerEmailMasked: updated.farmerEmailMasked,
      );
    } catch (error) {
      logCameraDiagnostic('session_persist_failed', {'error': '$error'});
    }
    _cloud.updateRegistration(updated);
    if (!mounted) {
      return;
    }
    logCameraDiagnostic('session_refreshed', {
      'cameraId': updated.cameraId,
      'hasFarmer': updated.farmerId != null,
    });
    setState(() {
      _registration = updated;
      _backendOnline = true;
      _lastHeartbeatAt = DateTime.now().toUtc();
    });
  }

  /// Drops the local pairing: used when the server says the camera is no
  /// longer paired (401 on session/heartbeat) and when the user disconnects
  /// from the Connection Details card.
  Future<void> _handleUnpaired(String notice) async {
    logCameraDiagnostic('unpaired');
    _stopCloudSync();
    try {
      await _cloud.registrationStore.clear();
    } catch (_) {
      // Clearing is best effort; the in-memory state is authoritative.
    }
    _cloud.updateRegistration(null);
    if (!mounted) {
      return;
    }
    setState(() {
      _registration = null;
      _backendOnline = false;
      _lastHeartbeatAt = null;
      _cloudNotice = notice;
    });
  }

  /// Starts upload-queue processing (production timer), sends an immediate
  /// heartbeat and keeps a 60 s heartbeat while monitoring is active. Never
  /// runs in the test-environment bundle (tests pump the queue manually).
  void _startCloudSync() {
    if (!_cloud.backgroundEnabled) {
      return;
    }
    _cloud.queue.start();
    // Immediate heartbeat: the farmer sees the camera come online without
    // waiting a full interval.
    unawaited(_sendHeartbeat());
    _heartbeatTimer ??= Timer.periodic(_heartbeatInterval, (_) {
      unawaited(_sendHeartbeat());
    });
  }

  /// Stops queue processing and the heartbeat timer.
  void _stopCloudSync() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _cloud.queue.stop();
  }

  /// Sends one heartbeat and reconciles the UI state with the outcome.
  /// A 401/403 means the farmer removed the camera: the registration is
  /// dropped so the user is prompted to pair again.
  Future<void> _sendHeartbeat() async {
    final registration = _registration;
    if (registration == null) {
      return;
    }
    final HeartbeatOutcome outcome;
    try {
      outcome = await _cloud.api.sendHeartbeatDetailed(
        registration.cameraId,
        status: 'monitoring',
      );
    } catch (error) {
      logCameraDiagnostic('heartbeat_failed', {'error': '$error'});
      if (mounted) {
        setState(() => _backendOnline = false);
      }
      return;
    }
    if (!mounted) {
      return;
    }
    switch (outcome) {
      case HeartbeatOutcome.ok:
        logCameraDiagnostic('heartbeat_ok', {
          'cameraId': registration.cameraId,
        });
        setState(() {
          _backendOnline = true;
          _lastHeartbeatAt = DateTime.now().toUtc();
          _cloudNotice = null;
        });
      case HeartbeatOutcome.unauthorized:
        logCameraDiagnostic('heartbeat_unauthorized', {
          'cameraId': registration.cameraId,
        });
        await _handleUnpaired(
          'Camera was disconnected by the farmer account.',
        );
      case HeartbeatOutcome.transientError:
        logCameraDiagnostic('heartbeat_transient_error', {
          'cameraId': registration.cameraId,
        });
        setState(() => _backendOnline = false);
    }
  }

  /// Confirms and performs a camera-side disconnect: unpair on the server
  /// and forget the local registration. A failed server call still clears
  /// the local pairing (the camera can no longer upload either way).
  Future<void> _confirmUnpair() async {
    final registration = _registration;
    if (registration == null) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Disconnect camera?'),
        content: Text(
          'Disconnect ${registration.cameraName}? This will unpair this '
          'camera from the farmer account on the server. You will need a '
          'new pairing code to reconnect.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    var serverUnpaired = false;
    try {
      serverUnpaired = await _cloud.api.unpairSelf();
    } catch (error) {
      logCameraDiagnostic('unpair_failed', {'error': '$error'});
    }
    logCameraDiagnostic('unpair', {
      'cameraId': registration.cameraId,
      'serverUnpaired': serverUnpaired,
    });
    await _handleUnpaired(
      serverUnpaired
          ? 'Camera disconnected. Pair again with a new pairing code.'
          : 'Camera disconnected locally. The server could not be reached.',
    );
  }

  void _onConfirmedEventGuarded(ConfirmedEvent event) {
    unawaited(_onConfirmedEvent(event));
  }

  /// Handles a confirmed presence event: captures a full-scene still via
  /// the plugin's own ImageCapture use-case (no second camera pipeline)
  /// and enqueues the event for upload. Dropped silently when unpaired —
  /// without a camera identity there is nowhere to upload.
  Future<void> _onConfirmedEvent(ConfirmedEvent event) async {
    final registration = _registration;
    if (registration == null) {
      return;
    }
    final imageBytes = await _captureSnapshot();
    final pendingEvent = PendingEvent(
      eventId: event.eventId,
      cameraId: registration.cameraId,
      detectionType: 'person',
      confidence: event.confidence,
      personCount: event.personCount,
      capturedAt: event.confirmedAt.toUtc().toIso8601String(),
      createdAt: DateTime.now().toUtc(),
      boundingBox: event.boundingBox,
      imageBytes: imageBytes,
      imageContentType: imageBytes == null ? null : 'image/jpeg',
      sourceType: 'LIVE',
    );
    await _cloud.queue.enqueue(pendingEvent);
  }

  /// Full-scene still via the detection controller's capturePhoto
  /// (withOverlays: false → raw camera frame; the plugin manages the
  /// ImageCapture use-case itself). A null result or a thrown error means
  /// no snapshot — the event still uploads without its image, never
  /// crashes.
  Future<Uint8List?> _captureSnapshot() async {
    final controller = _yoloController;
    if (controller == null) {
      return null;
    }
    try {
      return await controller.capturePhoto(withOverlays: false);
    } catch (_) {
      return null;
    }
  }

  /// Opens the pairing dialog and stores the registration on success.
  Future<void> _openPairingDialog() async {
    String deviceIdentifier;
    try {
      deviceIdentifier = await _cloud.deviceIdSource.id;
    } catch (_) {
      return;
    }
    if (!mounted) {
      return;
    }
    _pairingInFlight = true;
    CameraRegistration? registration;
    try {
      registration = await showDialog<CameraRegistration>(
        context: context,
        builder: (dialogContext) => PairingDialog(
          onRedeem: (code, cameraName, location) async {
            final result = await _cloud.api.redeemPairingCode(
              code: code,
              deviceIdentifier: deviceIdentifier,
              cameraName: cameraName,
              location: location,
            );
            await _cloud.registrationStore.save(
              token: result.token,
              cameraId: result.cameraId,
              cameraName: result.cameraName,
              location: location,
              farmerId: result.farmerId,
              farmerName: result.farmerName,
              farmerEmailMasked: result.farmerEmailMasked,
            );
            return CameraRegistration(
              token: result.token,
              cameraId: result.cameraId,
              cameraName: result.cameraName,
              location: location,
              farmerId: result.farmerId,
              farmerName: result.farmerName,
              farmerEmailMasked: result.farmerEmailMasked,
            );
          },
        ),
      );
    } finally {
      _pairingInFlight = false;
    }
    if (registration == null || !mounted) {
      return;
    }
    logCameraDiagnostic('paired', {'cameraId': registration.cameraId});
    _cloud.updateRegistration(registration);
    setState(() {
      _registration = registration;
      _cloudNotice = null;
    });
    // Pull the server's view (renamed camera, farmer details) right away.
    await _refreshCameraSession();
  }

  /// Retries every permanently failed upload immediately.
  Future<void> _retryFailedUploads() async {
    await _cloud.queue.retryFailed();
    await _cloud.queue.processDue();
  }

  /// Derives the cloud sync state shown in the status card:
  /// - unpaired → offline (nothing talks to the cloud);
  /// - a queue restore/pairing action in flight → syncing;
  /// - events waiting for upload → uploading;
  /// - otherwise idle.
  CloudSyncState _cloudState() {
    if (_registration == null) {
      return CloudSyncState.offline;
    }
    if (_pairingInFlight || _restoringCloud) {
      return CloudSyncState.syncing;
    }
    if (_cloud.queue.pendingCount > 0) {
      return CloudSyncState.uploading;
    }
    return CloudSyncState.idle;
  }

  Future<String> _requestCameraPermission() async {
    try {
      final status =
          await _settingsChannel.invokeMethod<String>('requestCameraPermission');
      return status ?? 'denied';
    } on PlatformException catch (error) {
      return 'error:${error.code}';
    } on MissingPluginException {
      return 'error:channel-unavailable';
    }
  }

  Future<void> _openAppSettings() async {
    try {
      await _settingsChannel.invokeMethod<void>('openAppSettings');
    } on PlatformException {
      // Best effort only; the user can still open settings manually.
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('FarmGuard Camera'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(theme),
              const SizedBox(height: 16),
              // The live preview must live DIRECTLY inside Expanded: that
              // gives the ClipRRect → Stack(fit: StackFit.expand) → YOLOView
              // tight, bounded constraints. Inside a scroll view the height
              // would be unbounded and the preview would crash on layout
              // (Defect 2A). Only the non-preview status views scroll.
              Expanded(
                child: _showPreview
                    ? _buildDetectionView()
                    : Center(
                        child: SingleChildScrollView(
                          child: _buildStatusView(),
                        ),
                      ),
              ),
              const SizedBox(height: 16),
              ListenableBuilder(
                listenable: _stats,
                builder: (context, _) => Visibility(
                  visible: _phase == MonitoringPhase.monitoring,
                  child: DetectionStatsBar(
                    snapshot: _stats.snapshot,
                    modelLabel: _modelLabel,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              ListenableBuilder(
                listenable: _cloud.queue,
                builder: (context, _) => CloudStatusCard(
                  paired: _registration != null,
                  cameraName: _registration?.cameraName,
                  cameraId: _registration?.cameraId,
                  farmerName: _registration?.farmerName,
                  farmerEmailMasked: _registration?.farmerEmailMasked,
                  backendOnline: _backendOnline,
                  lastHeartbeatAt: _lastHeartbeatAt,
                  noticeText: _cloudNotice,
                  state: _cloudState(),
                  pendingCount: _cloud.queue.pendingCount,
                  failedCount: _cloud.queue.failedCount,
                  lastSyncAt: _cloud.queue.lastSyncAt,
                  onPair: _openPairingDialog,
                  onRetry: _retryFailedUploads,
                  onUnpair: _registration == null ? null : _confirmUnpair,
                ),
              ),
              const SizedBox(height: 16),
              _buildControls(theme),
            ],
          ),
        ),
      ),
    );
  }

  /// Non-preview phase content (idle, loading, permission and error views).
  Widget _buildStatusView() {
    return switch (_phase) {
      MonitoringPhase.idle => const IdlePlaceholderView(),
      MonitoringPhase.initializing =>
        CameraLoadingView(progressLabel: _progressLabel()),
      MonitoringPhase.monitoring => const CameraLoadingView(),
      MonitoringPhase.permissionDenied => PermissionDeniedView(
          onRetry: startMonitoring,
        ),
      MonitoringPhase.permissionPermanentlyDenied =>
        PermissionPermanentlyDeniedView(
          onOpenSettings: _openAppSettings,
          onRetry: startMonitoring,
        ),
      MonitoringPhase.error => CameraErrorView(
          detail: _errorDetail,
          onRetry: startMonitoring,
        ),
    };
  }

  /// Label for the explicit startup sub-stage currently in progress.
  String _progressLabel() {
    switch (_startupStage) {
      case MonitoringStartupStage.checkingPermissions:
        return 'Checking camera permission…';
      case MonitoringStartupStage.downloadingModel:
        if (_downloadFraction > 0 && _downloadFraction < 1) {
          return 'Downloading YOLO26s model… '
              '${(_downloadFraction * 100).round()}%';
        }
        return 'Preparing YOLO26s model…';
      case MonitoringStartupStage.loadingModel:
        return 'Loading YOLO26s model…';
      case MonitoringStartupStage.initializingCamera:
        return 'Initializing camera & detection…';
    }
  }

  Widget _buildHeader(ThemeData theme) {
    return Column(
      children: [
        Icon(
          Icons.spa,
          size: 40,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 8),
        Text(
          'FarmGuard Camera',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Smart Farm Surveillance',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// The native detection view. Bounding boxes, `Person` labels and
  /// confidence scores are rendered natively by YOLOView; this app only
  /// consumes the result stream for the statistics bar.
  Widget _buildDetectionView() {
    final resolvedModelPath = _resolvedModelPath;
    if (resolvedModelPath == null) {
      return const CameraLoadingView();
    }
    final controller = _yoloController ??= YOLOViewController();
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        fit: StackFit.expand,
        children: [
          YOLOView(
            modelPath: resolvedModelPath,
            task: YOLOTask.detect,
            controller: controller,
            streamingConfig: _streamingConfig,
            confidenceThreshold: 0.5,
            onResult: _onDetections,
            onPerformanceMetrics: _onMetrics,
            onModelLoad: (_, _) => _onModelReady(),
            onModelError: (error, _, _) => _onModelError(error),
          ),
          if (_phase == MonitoringPhase.initializing)
            Positioned(
              top: 12,
              left: 12,
              child: Chip(
                backgroundColor: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest,
                label: const Text('Initializing camera & detection…'),
              ),
            ),
          if (_phase == MonitoringPhase.monitoring)
            Positioned(
              top: 12,
              left: 12,
              child: Chip(
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                avatar: Icon(
                  Icons.circle,
                  size: 10,
                  color: Theme.of(context).colorScheme.error,
                ),
                label: const Text('Monitoring'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildControls(ThemeData theme) {
    final monitoring = _phase == MonitoringPhase.monitoring;
    // While initializing, the user may cancel as soon as the native preview
    // is mounted (a permission check or model download is still cancellable
    // by leaving the screen, but there is nothing on screen to cancel yet).
    final canCancelStartup =
        _phase == MonitoringPhase.initializing && _resolvedModelPath != null;
    final showStop = monitoring || canCancelStartup;
    return FilledButton.icon(
      onPressed: switch (_phase) {
        MonitoringPhase.initializing =>
          canCancelStartup ? stopMonitoring : null, // No double-start races.
        MonitoringPhase.monitoring => stopMonitoring,
        _ => startMonitoring,
      },
      icon: Icon(
        showStop
            ? Icons.stop
            : _busy
                ? Icons.hourglass_top
                : Icons.videocam,
      ),
      label: Text(
        switch (_phase) {
          MonitoringPhase.initializing =>
            canCancelStartup ? 'Cancel' : 'Starting…',
          MonitoringPhase.monitoring => 'Stop Monitoring',
          _ => 'Start Monitoring',
        },
      ),
      style: showStop
          ? FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.errorContainer,
              foregroundColor: theme.colorScheme.onErrorContainer,
            )
          : null,
    );
  }
}
