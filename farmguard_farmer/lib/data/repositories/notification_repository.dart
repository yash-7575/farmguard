import '../../services/api/farmer_api.dart';

/// Registers and unregisters this device's FCM token with the backend so
/// the Workers deployment can push detection alerts to it
/// (`POST/DELETE /api/v1/notifications/*`).
///
/// Pure Dart with an injectable [FarmerApi]; errors surface as
/// [ApiException] unchanged — the caller decides (401 → session expiry,
/// transient → silent skip).
class NotificationRepository {
  NotificationRepository({required this.api});

  final FarmerApi api;

  /// Upserts the device row keyed by FCM token (a phone can move between
  /// farmers). Backend returns 201; idempotent on repeat calls.
  Future<void> registerDevice(String token, {String platform = 'android'}) =>
      api.registerDevice(token, platform: platform);

  /// Removes the device row for [token]. Idempotent server-side.
  Future<void> unregisterDevice(String token) => api.unregisterDevice(token);
}
