/// Widget-test pump helpers: build the real app tree with a fake-backed
/// [AppServices] bundle so no platform channel is ever touched (Flutter
/// 3.50 widget tests hang forever on unmocked channels).
///
/// NOTE: these tests run on demo data — [demoApi] mirrors the original
/// MockData world (4 cameras, 3 online, no live events) so the original
/// UI contract strings ('3 / 4', 'Main Gate', 'Offline', 'New') stay
/// truthful.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:farmguard_farmer/main.dart';
import 'package:farmguard_farmer/models/models.dart';
import 'package:farmguard_farmer/services/app_services.dart';

import 'api_fixtures.dart';

/// Fake backend mirroring the demo dataset: 4 cameras (3 online), no live
/// events. Override per test as needed.
FakeFarmerApi demoApi() => FakeFarmerApi(
      authResult: authResult(),
      cameras: <FarmCamera>[
        apiCamera(
          id: 'cam-1',
          name: 'Main Gate',
          isOnline: true,
          isMonitoring: true,
          lastConnected: DateTime.now().subtract(const Duration(minutes: 2)),
        ),
        apiCamera(
          id: 'cam-2',
          name: 'Cow Shed',
          isOnline: true,
          isMonitoring: true,
          lastConnected: DateTime.now().subtract(const Duration(minutes: 41)),
        ),
        apiCamera(
          id: 'cam-3',
          name: 'North Crop Field',
          isOnline: true,
          isMonitoring: true,
          lastConnected: DateTime.now().subtract(const Duration(minutes: 12)),
        ),
        apiCamera(
          id: 'cam-4',
          name: 'Pump House',
          isOnline: false,
          isMonitoring: true,
          lastConnected: DateTime.now().subtract(const Duration(hours: 26)),
        ),
      ],
    );

/// Pumps the app with an authenticated cold start ([token] saved before
/// boot) or the login screen ([token] null), and flushes the auth gate +
/// initial repository fetches.
///
/// [gateway] injects a push-messaging fake; `null` (the default) means no
/// gateway — push registration and tap routing are skipped entirely.
///
/// The Home tab has a repeating pulse animation, so tests use fixed pumps
/// instead of pumpAndSettle.
Future<(AppServices, FakeFarmerApi, RecordingTokenStore)> pumpApp(
  WidgetTester tester, {
  FakeFarmerApi? api,
  String? token = 'tok-123',
  FakeMessagingGateway? gateway,
}) async {
  final RecordingTokenStore store = RecordingTokenStore();
  if (token != null) {
    await store.saveToken(token);
  }
  final FakeFarmerApi effectiveApi = api ?? demoApi();
  final AppServices services = AppServices(
    tokenStore: store,
    api: effectiveApi,
    messaging: gateway,
  );
  await tester.pumpWidget(FarmGuardApp(services: services));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 400));
  return (services, effectiveApi, store);
}

/// Two fixed pumps to flush a frame and a navigation/tab transition.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Taps a bottom-navigation destination by label.
Future<void> tapNav(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await settle(tester);
}
