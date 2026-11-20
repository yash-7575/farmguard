import 'dart:io';

import 'api_client.dart';
import 'device_registration.dart';
import 'detection_event_engine.dart';
import 'file_pending_store.dart';
import 'pending_event_store.dart';
import 'upload_queue.dart';

/// Bundle of cloud-facing dependencies injected into [HomeScreen] as one
/// unit (same idea as the `ModelGateway` injection).
///
/// Every dependency is injectable with a pure-Dart default, so tests can
/// build a bundle from fakes only. The [CloudServices.production] factory
/// wires the real platform-backed implementations.
class CloudServices {
  CloudServices({
    FarmGuardApi? api,
    UploadClient? uploadClient,
    CameraRegistrationStore? registrationStore,
    DeviceIdSource? deviceIdSource,
    PendingEventStore? eventStore,
    DetectionEventEngine? engine,
    UploadQueue? uploadQueue,
    this.backgroundEnabled = true,
  }) {
    final effectiveApi =
        api ?? HttpFarmGuardApi(tokenProvider: () => _registration?.token);
    final UploadClient effectiveUploadClient;
    if (uploadClient != null) {
      effectiveUploadClient = uploadClient;
    } else if (effectiveApi is UploadClient) {
      effectiveUploadClient = effectiveApi as UploadClient;
    } else {
      throw ArgumentError(
        'provide an uploadClient or an api implementing UploadClient',
      );
    }
    final effectiveStore = eventStore ?? InMemoryPendingEventStore();

    this.api = effectiveApi;
    this.uploadClient = effectiveUploadClient;
    this.registrationStore =
        registrationStore ?? InMemoryCameraRegistrationStore();
    this.deviceIdSource = deviceIdSource ?? LocalDeviceIdSource();
    this.eventStore = effectiveStore;
    this.engine = engine ?? DetectionEventEngine();
    queue = uploadQueue ??
        UploadQueue(store: effectiveStore, client: effectiveUploadClient);
  }

  /// Production bundle: real HTTP client, secure-storage registration
  /// store (with one-time migration from legacy shared preferences),
  /// file-backed event store.
  ///
  /// The `api` is deliberately NOT passed in: the constructor then creates
  /// `HttpFarmGuardApi(tokenProvider: () => _registration?.token)`, so every
  /// authenticated call carries the current camera token. Passing
  /// `api: HttpFarmGuardApi()` here silently dropped the token provider.
  ///
  /// When running under `flutter test` (the test runner sets FLUTTER_TEST
  /// in the environment) this bundle is fully inert: [backgroundEnabled]
  /// is false so no startup restore, registration load, queue timer or
  /// heartbeat ever runs — unmocked platform channels hang widget tests
  /// forever. Tests that exercise cloud behavior inject their own fakes.
  factory CloudServices.production() {
    final backgroundEnabled =
        !Platform.environment.containsKey('FLUTTER_TEST');
    return CloudServices(
      backgroundEnabled: backgroundEnabled,
      registrationStore: SecureCameraRegistrationStore(),
      deviceIdSource:
          LocalDeviceIdSource(preferences: SecurePreferencesStore()),
      eventStore: FilePendingEventStore(),
    );
  }

  late final FarmGuardApi api;

  /// Used by the [UploadQueue]; normally the same instance as [api].
  late final UploadClient uploadClient;

  late final CameraRegistrationStore registrationStore;
  late final DeviceIdSource deviceIdSource;
  late final PendingEventStore eventStore;
  late final DetectionEventEngine engine;
  late final UploadQueue queue;

  /// Whether background work may run: startup restore, registration
  /// load, queue timer and heartbeat. Tests inject bundles with fakes and
  /// either drive the queue manually or set this to false.
  final bool backgroundEnabled;

  CameraRegistration? _registration;

  /// The token the production [HttpFarmGuardApi] will send on the next
  /// authenticated call (null when unpaired). Exposed so tests can prove
  /// [updateRegistration] wires the token into the API's token provider.
  String? get currentToken => _registration?.token;

  /// Makes the current registration available to the API's token
  /// provider; called whenever the screen loads or stores one.
  void updateRegistration(CameraRegistration? registration) {
    _registration = registration;
  }

  /// Releases the owned ChangeNotifiers. Call only when nothing else
  /// uses this bundle anymore (the screen disposes it when it created
  /// the bundle itself).
  void dispose() {
    engine.dispose();
    queue.dispose();
  }
}
