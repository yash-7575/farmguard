import '../data/repositories/auth_repository.dart';
import '../data/repositories/event_repository.dart';
import '../data/repositories/notification_repository.dart';
import 'api/farmer_api.dart';
import 'api/http_farmer_api.dart';
import 'api/token_store.dart';
import 'messaging/messaging_gateway.dart';

/// Bundle of FarmGuard backend dependencies injected into the app as one
/// unit (the `CloudServices` idiom from the camera app).
///
/// Every dependency is injectable; tests build the bundle from a fake
/// [FarmerApi] plus an in-memory [TokenStore] only — never the platform-
/// backed implementations, whose construction would touch platform channels
/// and hang widget tests. [AppServices.production] wires the real ones.
class AppServices {
  /// Builds the bundle.
  ///
  /// Provide BOTH [tokenStore] and [api] (the pure, test-safe pair), or
  /// NEITHER to get the production wiring. Mixed construction is rejected so
  /// a test can never accidentally instantiate [SecureTokenStore] or
  /// [HttpFarmerApi]. [messaging] is optional: production wires the real
  /// [FirebaseMessagingGateway]; tests inject a fake, or none (the app then
  /// runs fully functional without push).
  AppServices({
    TokenStore? tokenStore,
    FarmerApi? api,
    MessagingGateway? messaging,
  }) {
    if (tokenStore == null && api == null) {
      tokenStore = SecureTokenStore();
      api = HttpFarmerApi(tokenStore: tokenStore);
      // Production-only: constructing the real gateway is safe, but its
      // methods touch Firebase platform channels, which tests cannot mock.
      messaging = FirebaseMessagingGateway();
    } else if (tokenStore == null || api == null) {
      throw ArgumentError(
        'Provide both tokenStore and api (test wiring), or neither '
        '(production wiring).',
      );
    }
    this.tokenStore = tokenStore;
    this.api = api;
    this.messaging = messaging;
    auth = AuthRepository(api: api, tokenStore: tokenStore);
    eventRepository = EventRepository(api: api);
    cameraRepository = CameraRepository(api: api);
    notifications = NotificationRepository(api: api);
  }

  /// Production bundle: secure on-device token storage + real HTTP client
  /// + Firebase messaging.
  factory AppServices.production() => AppServices();

  late final TokenStore tokenStore;
  late final FarmerApi api;
  late final AuthRepository auth;
  late final EventRepository eventRepository;
  late final CameraRepository cameraRepository;
  late final NotificationRepository notifications;

  /// Push gateway. `null` in test wiring that injected none — no push
  /// registration, no tap routing, everything else unchanged.
  late final MessagingGateway? messaging;
}
