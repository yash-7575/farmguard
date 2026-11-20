import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import '../../firebase_options.dart';

/// One tappable notification, flattened from an FCM [RemoteMessage].
///
/// The backend's push payload is `notification: {title, body}` plus
/// `data: {event_id, camera_id}` (see the backend `fcm.ts` service); this
/// class is the app-side shape the UI routes on.
class FcmTap {
  /// Detection event to open, or `null` when the payload carries none
  /// (taps without one are a no-op).
  final String? eventId;

  /// Camera that produced the event, when present in the data payload.
  final String? cameraId;

  /// Notification title / body (also read from data for data-only pushes).
  final String? title;
  final String? body;

  const FcmTap({this.eventId, this.cameraId, this.title, this.body});
}

/// Injectable push-messaging seam (the same idiom as [TokenStore]).
///
/// The production implementation touches the Firebase platform channels,
/// which widget tests cannot mock — so all messaging code sits behind this
/// interface and tests inject a fake ([FakeMessagingGateway] in
/// `test/helpers/api_fixtures.dart`). The real implementation is only ever
/// constructed in [AppServices.production].
abstract class MessagingGateway {
  /// Initializes Firebase (with `DefaultFirebaseOptions.currentPlatform`),
  /// registers the background isolate handler and prompts for notification
  /// permission.
  ///
  /// Returns whether the user granted permission. Declined → the caller
  /// skips registration silently; the app stays fully functional.
  Future<bool> initializeAndRequestPermission();

  /// The current FCM registration token, or `null` when unavailable
  /// (e.g. Play services missing).
  Future<String?> getToken();

  /// Fires whenever FCM rotates the registration token; the caller
  /// re-registers with the backend on every event.
  Stream<String> get tokenRefresh;

  /// Notification taps: while the app runs (user tapped a backgrounded
  /// notification) and on cold start (app launched from terminated state —
  /// delivered to the first listener after [initializeAndRequestPermission]).
  Stream<FcmTap> get taps;
}

/// Background/terminated data-message handler. Must be a top-level
/// function (the FCM plugin re-enters it on a background isolate).
///
/// Notification payloads are displayed in the system tray by FCM itself and
/// their taps are routed through [MessagingGateway.taps] once the app
/// resumes. Data-only messages while backgrounded are a future enhancement
/// — this handler intentionally does nothing beyond existing.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {}

/// Production [MessagingGateway] over `firebase_messaging`.
///
/// Constructed only inside [AppServices.production]; tests never build it
/// (its methods touch platform channels and would hang the test runner).
class FirebaseMessagingGateway implements MessagingGateway {
  /// Taps that arrive while nobody listens (e.g. `onMessageOpenedApp`
  /// between login and the shell mounting) are buffered here and replayed
  /// to the first listener.
  final StreamController<FcmTap> _incoming = StreamController<FcmTap>.broadcast();

  /// Cold-start tap captured during initialization; replayed once, to the
  /// first listener of [taps].
  FcmTap? _pendingInitialTap;
  bool _initialDelivered = false;

  bool _initialized = false;
  bool _granted = false;
  StreamSubscription<RemoteMessage>? _openedAppSub;

  @override
  Future<bool> initializeAndRequestPermission() async {
    if (_initialized) return _granted;
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    // Background isolate handler per the firebase_messaging docs (Android:
    // data-only messages while the app is backgrounded/terminated).
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    final NotificationSettings settings =
        await FirebaseMessaging.instance.requestPermission();
    final AuthorizationStatus status = settings.authorizationStatus;
    _granted = status == AuthorizationStatus.authorized ||
        status == AuthorizationStatus.provisional;

    if (_granted) {
      // Cold start: the app was launched from terminated state by a
      // notification tap. Buffer it until [taps] gets its first listener.
      try {
        final RemoteMessage? initial =
            await FirebaseMessaging.instance.getInitialMessage();
        if (initial != null) _pendingInitialTap = _tapFromMessage(initial);
      } catch (_) {
        // Best-effort: a failed initial-message lookup must not break login.
      }
      // Background → foreground resumption via a notification tap.
      _openedAppSub = FirebaseMessaging.onMessageOpenedApp.listen(
        (RemoteMessage message) => _incoming.add(_tapFromMessage(message)),
      );
    }
    _initialized = true;
    return _granted;
  }

  @override
  Future<String?> getToken() async {
    // firebase_messaging 17.x deprecates getToken in favour of the FID
    // register()/onRegistered flow; the FarmGuard backend routes pushes by
    // the classic FCM registration token, so that is what we hand it.
    // ignore: deprecated_member_use
    return FirebaseMessaging.instance.getToken();
  }

  @override
  Stream<String> get tokenRefresh {
    // See getToken — same deprecation, same reason.
    // ignore: deprecated_member_use
    return FirebaseMessaging.instance.onTokenRefresh;
  }

  @override
  Stream<FcmTap> get taps {
    late final StreamSubscription<FcmTap> subscription;
    late final StreamController<FcmTap> controller;
    controller = StreamController<FcmTap>(
      onListen: () {
        final FcmTap? pending = _pendingInitialTap;
        if (pending != null && !_initialDelivered) {
          _initialDelivered = true;
          controller.add(pending);
        }
        subscription = _incoming.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
      },
      onCancel: () => subscription.cancel(),
    );
    return controller.stream;
  }

  /// Releases the plugin subscriptions. Production shutdown only.
  void dispose() {
    _openedAppSub?.cancel();
    _incoming.close();
  }

  static FcmTap _tapFromMessage(RemoteMessage message) {
    final Map<String, dynamic> data = message.data;
    final RemoteNotification? notification = message.notification;
    return FcmTap(
      eventId: data['event_id'],
      cameraId: data['camera_id'],
      title: notification?.title ?? data['title'],
      body: notification?.body ?? data['body'],
    );
  }
}
