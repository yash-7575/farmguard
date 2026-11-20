import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:farmguard_farmer/models/models.dart';
import 'package:farmguard_farmer/services/api/exceptions.dart';
import 'package:farmguard_farmer/services/api/farmer_api.dart';
import 'package:farmguard_farmer/services/messaging/messaging_gateway.dart';

import 'helpers/api_fixtures.dart';
import 'helpers/widget_pump.dart';

/// Stage 7 push-messaging tests, run entirely on fakes
/// ([FakeMessagingGateway] + [FakeFarmerApi]) — no Firebase platform
/// channel is ever touched, per the hard constraint on widget tests.
///
/// Covers: permission → device registration, declined permission, token
/// refresh re-registration, logout unregistration, and notification-tap
/// routing (known / deleted / no-event-id).
void main() {
  Future<void> signIn(WidgetTester tester) async {
    await tester.enterText(find.byType(TextFormField).at(0), 'kiran@farm.test');
    await tester.enterText(find.byType(TextFormField).at(1), 'hunter2222');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('device registration', () {
    testWidgets('permission granted + token → registerDevice with platform '
        'android', (WidgetTester tester) async {
      final FakeMessagingGateway gateway =
          FakeMessagingGateway(granted: true, token: 'fcm-token-1');
      final api = demoApi();
      await pumpApp(tester, api: api, token: null, gateway: gateway);

      await signIn(tester);

      expect(find.text('Detections today'), findsOneWidget);
      expect(api.registerDeviceCalls, 1);
      expect(api.registerTokens, <String>['fcm-token-1']);
      expect(api.registerPlatforms, <String>['android']);
    });

    testWidgets('permission declined → no registration, app functional',
        (WidgetTester tester) async {
      final FakeMessagingGateway gateway =
          FakeMessagingGateway(granted: false, token: 'fcm-token-1');
      final api = demoApi();
      await pumpApp(tester, api: api, token: null, gateway: gateway);

      await signIn(tester);

      expect(find.text('Detections today'), findsOneWidget);
      expect(api.registerDeviceCalls, 0);
    });

    testWidgets('token refresh → re-registered (two registrations total)',
        (WidgetTester tester) async {
      final FakeMessagingGateway gateway =
          FakeMessagingGateway(granted: true, token: 'fcm-token-1');
      final api = demoApi();
      await pumpApp(tester, api: api, gateway: gateway);
      await settle(tester);

      expect(api.registerDeviceCalls, 1);
      expect(api.registerTokens.first, 'fcm-token-1');

      // FCM rotates the token → the session re-registers with the backend.
      gateway.refreshController.add('fcm-token-2');
      await settle(tester);

      expect(api.registerDeviceCalls, 2);
      expect(api.registerTokens.last, 'fcm-token-2');
      expect(api.registerPlatforms.last, 'android');
    });
  });

  group('logout', () {
    testWidgets('logout → unregisterDevice with the token, session cleared',
        (WidgetTester tester) async {
      final FakeMessagingGateway gateway =
          FakeMessagingGateway(granted: true, token: 'fcm-token-1');
      final api = demoApi();
      final (_, _, store) =
          await pumpApp(tester, api: api, gateway: gateway);
      await settle(tester);

      await tapNav(tester, 'Settings');
      await tester.tap(find.text('Log out'));
      await settle(tester);

      expect(api.unregisterDeviceCalls, 1);
      expect(api.unregisterTokens, <String>['fcm-token-1']);
      expect(find.text('Sign in'), findsOneWidget);
      expect(find.text('Detections today'), findsNothing);
      expect(await store.readToken(), isNull);
    });

    testWidgets('logout with unregister failing → session still cleared',
        (WidgetTester tester) async {
      final FakeMessagingGateway gateway =
          FakeMessagingGateway(granted: true, token: 'fcm-token-1');
      final api = demoApi()
        ..unregisterDeviceError = const ApiException(
          statusCode: 503,
          code: 'server_error',
          message: 'Service unavailable.',
        );
      final (_, _, store) =
          await pumpApp(tester, api: api, gateway: gateway);
      await settle(tester);

      await tapNav(tester, 'Settings');
      await tester.tap(find.text('Log out'));
      await settle(tester);

      // Best-effort unregister attempted, failure swallowed, logout done.
      expect(api.unregisterDeviceCalls, 1);
      expect(find.text('Sign in'), findsOneWidget);
      expect(await store.readToken(), isNull);
    });
  });

  group('notification tap routing', () {
    FakeFarmerApi apiWithEvent(String eventId) => FakeFarmerApi(
          authResult: authResult(),
          cameras: <FarmCamera>[apiCamera(id: 'cam-1', name: 'Alpha Cam')],
          eventDetail: EventDetail(
            event: apiEvent(id: eventId, cameraId: 'cam-1'),
            cameraName: 'Alpha Cam',
            cameraLocation: 'Farm entrance, north boundary',
          ),
        );

    testWidgets('tap with known eventId → detail screen shown',
        (WidgetTester tester) async {
      final FakeMessagingGateway gateway = FakeMessagingGateway();
      final api = apiWithEvent('evt-9');
      await pumpApp(tester, api: api, gateway: gateway);
      await settle(tester);

      gateway.tapController.add(
        const FcmTap(eventId: 'evt-9', title: 'Person detected'),
      );
      await settle(tester);

      expect(find.text('Detection details'), findsOneWidget);
      expect(find.text('Person detected'), findsWidgets);
    });

    testWidgets('tap with unknown eventId (404) → snackbar, stays on tab',
        (WidgetTester tester) async {
      final FakeMessagingGateway gateway = FakeMessagingGateway();
      final api = demoApi()
        ..getEventError = const ApiException(
          statusCode: 404,
          code: 'not_found',
          message: 'Event not found.',
        );
      await pumpApp(tester, api: api, gateway: gateway);
      await settle(tester);

      gateway.tapController.add(const FcmTap(eventId: 'evt-gone'));
      await settle(tester);

      expect(find.text('Detection details'), findsNothing);
      expect(find.text('Detections today'), findsOneWidget);
      expect(find.text('Event no longer available'), findsOneWidget);
    });

    testWidgets('tap without eventId → no-op', (WidgetTester tester) async {
      final FakeMessagingGateway gateway = FakeMessagingGateway();
      final api = apiWithEvent('evt-9');
      await pumpApp(tester, api: api, gateway: gateway);
      await settle(tester);

      gateway.tapController.add(const FcmTap(title: 'Nothing to route'));
      await settle(tester);

      expect(find.text('Detection details'), findsNothing);
      expect(find.text('Detections today'), findsOneWidget);
      expect(api.getEventCalls, 0);
    });

    testWidgets('cold-start-style tap while on another tab → opens detail '
        'over it', (WidgetTester tester) async {
      final FakeMessagingGateway gateway = FakeMessagingGateway();
      final api = apiWithEvent('evt-7');
      await pumpApp(tester, api: api, gateway: gateway);
      await settle(tester);

      await tapNav(tester, 'Cameras');
      expect(find.text('Alpha Cam'), findsOneWidget);

      gateway.tapController.add(const FcmTap(eventId: 'evt-7'));
      await settle(tester);

      expect(find.text('Detection details'), findsOneWidget);

      // Back returns to the tab the farmer was on.
      await tester.pageBack();
      await settle(tester);
      await settle(tester);
      expect(find.text('Detection details'), findsNothing);
    });
  });
}
