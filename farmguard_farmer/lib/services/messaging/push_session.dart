import 'dart:async';

import '../../data/repositories/notification_repository.dart';
import '../api/exceptions.dart';
import 'messaging_gateway.dart';

/// One authenticated session's push lifecycle: permission prompt → device
/// registration → re-registration on token rotation → unregister at logout.
///
/// Pure Dart over the injectable [MessagingGateway] + [NotificationRepository]
/// — widget tests drive it through fakes. Everything except a 401 from the
/// backend is best-effort: a declined permission, missing token or transient
/// error leaves the app fully functional (push silently disabled).
class PushSession {
  PushSession({required this.gateway, required this.notifications});

  final MessagingGateway gateway;
  final NotificationRepository notifications;

  /// The token currently registered with the backend (updated on every
  /// refresh) — the one [stop] unregisters.
  String? _registeredToken;
  StreamSubscription<String>? _refreshSub;
  bool _stopped = false;

  /// Runs after a successful login/register (or bootstrap with a valid
  /// stored token).
  ///
  /// Rethrows a 401 [ApiException] from the register call so the caller can
  /// run the same session-expiry path as the data calls; every other
  /// failure is swallowed (push is best-effort).
  Future<void> start() async {
    _stopped = false;
    try {
      final bool granted = await gateway.initializeAndRequestPermission();
      if (!granted) return; // declined → skip registration silently
      final String? token = await gateway.getToken();
      if (token == null || token.isEmpty) return;
      _registeredToken = token;
      await notifications.registerDevice(token, platform: 'android');
      await _listenForRefreshes();
    } on ApiException catch (error) {
      if (error.isUnauthorized) rethrow;
      // 4xx/5xx/network → best-effort, stay silent.
    } catch (_) {
      // Gateway failure (e.g. Play services unavailable) must never break
      // the login/session flow.
    }
  }

  /// Re-registers with the backend on every FCM token rotation.
  Future<void> _listenForRefreshes() async {
    unawaited(_refreshSub?.cancel());
    _refreshSub = gateway.tokenRefresh.listen(
      _onTokenRefreshed,
      onError: (Object _) {}, // stream errors must not crash the app
    );
  }

  Future<void> _onTokenRefreshed(String token) async {
    if (_stopped || token.isEmpty) return;
    _registeredToken = token;
    try {
      await notifications.registerDevice(token, platform: 'android');
    } catch (_) {
      // Best-effort; the next refresh retries.
    }
  }

  /// Unregisters the current token with the backend and tears down the
  /// refresh subscription. Best-effort: never throws, so logout cannot
  /// fail because unregister did.
  Future<void> stop() async {
    _stopped = true;
    unawaited(_refreshSub?.cancel());
    _refreshSub = null;
    final String? token = _registeredToken;
    _registeredToken = null;
    if (token == null || token.isEmpty) return;
    try {
      await notifications.unregisterDevice(token);
    } catch (_) {}
  }
}
