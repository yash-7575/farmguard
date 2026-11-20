import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:farmguard_farmer/data/mock_data.dart';
import 'package:farmguard_farmer/models/models.dart';
import 'package:farmguard_farmer/services/api/farmer_api.dart';
import 'package:farmguard_farmer/screens/detection_detail_screen.dart';
import 'package:farmguard_farmer/services/api/exceptions.dart';

import 'helpers/api_fixtures.dart';
import 'helpers/widget_pump.dart';

/// Stage 6 pt 2 UI wiring tests: auth gate, login, async states, live
/// images, LIVE/DEMO labels, account section. All run on fake-backed
/// services (no platform channels); demo MockData records stay visible
/// beneath live events as the source of truth for both.
void main() {
  // Reusable credentials for the login flow tests.
  Future<void> fillLoginForm(WidgetTester tester) async {
    await tester.enterText(find.byType(TextFormField).at(0), 'kiran@farm.test');
    await tester.enterText(find.byType(TextFormField).at(1), 'hunter2222');
    await tester.pump();
  }

  group('auth gate & login', () {
    testWidgets('cold start without token → login; login → MainShell home',
        (WidgetTester tester) async {
      final api = FakeFarmerApi(authResult: authResult());
      await pumpApp(tester, api: api, token: null);

      // Login screen is up, not the shell.
      expect(find.text('Sign in'), findsOneWidget);
      expect(find.text('Detections today'), findsNothing);

      await fillLoginForm(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Authenticated → main shell home.
      expect(find.text('Detections today'), findsOneWidget);
      expect(find.text('Recent detections'), findsOneWidget);
    });

    testWidgets('failed login (401) → inline error, stays on login',
        (WidgetTester tester) async {
      final api = FakeFarmerApi(
        authResult: authResult(),
        loginError: const ApiException(
          statusCode: 401,
          code: 'invalid_credentials',
          message: 'Invalid email or password.',
        ),
      );
      await pumpApp(tester, api: api, token: null);

      await fillLoginForm(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Incorrect email or password.'), findsOneWidget);
      // Still on the login screen.
      expect(find.text('Detections today'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
    });

    testWidgets('register duplicate email (409) → inline error',
        (WidgetTester tester) async {
      final api = FakeFarmerApi(
        authResult: authResult(),
        registerError: const ApiException(
          statusCode: 409,
          code: 'email_taken',
          message: 'Email already registered.',
        ),
      );
      await pumpApp(tester, api: api, token: null);

      // Toggle to register mode.
      await tester.tap(find.text('New to FarmGuard? Create an account'));
      await tester.pump();

      await tester.enterText(find.byType(TextFormField).at(0), 'Kiran');
      await tester.enterText(find.byType(TextFormField).at(1), 'kiran@farm.test');
      await tester.enterText(find.byType(TextFormField).at(2), 'hunter2222');
      await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.text('An account with this email already exists. '
            'Try signing in instead.'),
        findsOneWidget,
      );
      expect(find.text('Detections today'), findsNothing);
    });
  });

  group('events: live-first ordering, chips, pagination', () {
    testWidgets('Home shows live events first; History shows LIVE/DEMO chips',
        (WidgetTester tester) async {
      final api = FakeFarmerApi(
        authResult: authResult(),
        cameras: <FarmCamera>[
          apiCamera(id: 'cam-1', name: 'Alpha Cam'),
          apiCamera(id: 'cam-2', name: 'Beta Cam'),
        ],
        events: <ApiDetectionEvent>[
          apiEvent(id: 'evt-1', cameraId: 'cam-1'),
          apiEvent(id: 'evt-2', cameraId: 'cam-2', sourceType: 'DEMO'),
        ],
      );
      await pumpApp(tester, api: api);

      // History tab: live evt-1 (Alpha Cam) above backend DEMO evt-2
      // (Beta Cam), demo MockData records below.
      await tapNav(tester, 'History');
      expect(find.text('LIVE'), findsWidgets);
      expect(find.text('DEMO'), findsWidgets);

      final alpha = find.descendant(
        of: find.byType(ListView),
        matching: find.textContaining('Alpha Cam'),
      );
      final beta = find.descendant(
        of: find.byType(ListView),
        matching: find.textContaining('Beta Cam'),
      );
      expect(alpha, findsOneWidget);
      expect(beta, findsOneWidget);
      expect(
        tester.getTopLeft(alpha.first).dy,
        lessThan(tester.getTopLeft(beta.first).dy),
      );

      // Home tab: live event tiles come before demo tiles (top-3 recent).
      await tapNav(tester, 'Home');
      final homeAlpha = find.descendant(
        of: find.byType(SingleChildScrollView),
        matching: find.textContaining('Alpha Cam'),
      );
      final homeBeta = find.descendant(
        of: find.byType(SingleChildScrollView),
        matching: find.textContaining('Beta Cam'),
      );
      expect(homeAlpha, findsOneWidget);
      expect(homeBeta, findsOneWidget);
      expect(
        tester.getTopLeft(homeAlpha.first).dy,
        lessThan(tester.getTopLeft(homeBeta.first).dy),
      );
    });

    testWidgets("History 'Load more' refetches with the before cursor",
        (WidgetTester tester) async {
      final api = FakeFarmerApi(
        authResult: authResult(),
        events: <ApiDetectionEvent>[apiEvent(id: 'evt-1')],
        nextBefore: '2026-11-18T00:00:00.000Z',
      );
      await pumpApp(tester, api: api);

      await tapNav(tester, 'History');
      // Scroll the appended affordance into view, then tap it.
      await tester.scrollUntilVisible(
        find.text('Load more'),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('Load more'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // First fetch had no before; the load-more call carries the cursor.
      expect(api.listEventsCalls, 2);
      expect(api.befores.first, isNull);
      expect(api.befores.last, '2026-11-18T00:00:00.000Z');
    });
  });

  group('images & mark-viewed', () {
    testWidgets("api: event renders Image.memory and calls markViewed",
        (WidgetTester tester) async {
      final api = FakeFarmerApi(
        authResult: authResult(),
        cameras: <FarmCamera>[
          apiCamera(id: 'cam-1', name: 'Alpha Cam'),
        ],
        events: <ApiDetectionEvent>[apiEvent(id: 'evt-1', cameraId: 'cam-1')],
        imageBytes: base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='),
        viewedEvent: apiEvent(id: 'evt-1', viewedAt: 'marked'),
      );
      await pumpApp(tester, api: api);

      await tapNav(tester, 'History');
      final titleInList = find.descendant(
        of: find.byType(ListView),
        matching: find.text('Person detected'),
      );
      await tester.tap(titleInList.first, warnIfMissed: false);
      await settle(tester);

      expect(find.text('Detection details'), findsOneWidget);
      // Fire-and-forget markViewed hit the fake backend exactly once.
      expect(api.markViewedCalls, 1);
      expect(api.viewedIds, <String>['evt-1']);

      // The frame came through the api: path as memory bytes.
      final images = find.descendant(
        of: find.byType(DetectionDetailScreen),
        matching: find.byWidgetPredicate(
          (Widget w) => w is Image && w.image is MemoryImage,
        ),
      );
      expect(images, findsOneWidget);

      await tester.pageBack();
      await settle(tester);
    });

    testWidgets('asset demo event still renders Image.asset',
        (WidgetTester tester) async {
      await pumpApp(tester); // demo dataset: no live events

      await tapNav(tester, 'History');
      final titleInList = find.descendant(
        of: find.byType(ListView),
        matching: find.text('Person detected'),
      );
      await tester.tap(titleInList.first, warnIfMissed: false);
      await settle(tester);

      final images = find.descendant(
        of: find.byType(DetectionDetailScreen),
        matching: find.byWidgetPredicate(
          (Widget w) => w is Image && w.image is AssetImage,
        ),
      );
      expect(images, findsOneWidget);
      final image = tester.widget<Image>(images.first);
      expect(
        (image.image as AssetImage).assetName,
        startsWith('assets/detections/'),
      );
    });

    testWidgets("api: image 404 → 'no image' placeholder, no crash",
        (WidgetTester tester) async {
      final api = FakeFarmerApi(
        authResult: authResult(),
        cameras: <FarmCamera>[
          apiCamera(id: 'cam-1', name: 'Alpha Cam'),
        ],
        events: <ApiDetectionEvent>[apiEvent(id: 'evt-1', cameraId: 'cam-1')],
        imageError: const ApiException(
          statusCode: 404,
          code: 'not_found',
          message: 'Frame unavailable.',
        ),
        viewedEvent: apiEvent(id: 'evt-1', viewedAt: 'marked'),
      );
      await pumpApp(tester, api: api);

      await tapNav(tester, 'History');
      final titleInList = find.descendant(
        of: find.byType(ListView),
        matching: find.text('Person detected'),
      );
      await tester.tap(titleInList.first, warnIfMissed: false);
      await settle(tester);

      expect(find.byType(DetectionDetailScreen), findsOneWidget);
      expect(find.text('No image'), findsOneWidget);
    });
  });

  group('cameras tab', () {
    testWidgets('renders fake camera names/statuses; transient error → '
        'Retry refetches', (WidgetTester tester) async {
      final api = FakeFarmerApi(
        authResult: authResult(),
        camerasError: const ApiException(
          statusCode: 503,
          code: 'server_error',
          message: 'Service unavailable.',
        ),
        cameras: <FarmCamera>[
          apiCamera(id: 'cam-1', name: 'Main Gate', isOnline: true),
          apiCamera(id: 'cam-4', name: 'Pump House', isOnline: false),
        ],
      );
      await pumpApp(tester, api: api);

      await tapNav(tester, 'Cameras');
      expect(find.text("Couldn't load cameras"), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Main Gate'), findsNothing);

      // Recover the backend and retry.
      api.camerasError = null;
      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Main Gate'), findsOneWidget);
      expect(find.text('Online'), findsOneWidget);
      expect(find.text('Pump House'), findsOneWidget);
      expect(find.text('Offline'), findsOneWidget);
    });
  });

  group('session & account', () {
    testWidgets('unauthorized mid-session → returns to login',
        (WidgetTester tester) async {
      final api = FakeFarmerApi(
        authResult: authResult(),
        eventsError: const ApiException(
          statusCode: 401,
          code: 'unauthorized',
          message: 'Token invalid or expired.',
        ),
      );
      final (_, _, store) = await pumpApp(tester, api: api);

      // Events load hit a 401 → session cleared, login screen shown.
      await settle(tester);
      expect(find.text('Sign in'), findsOneWidget);
      expect(find.text('Detections today'), findsNothing);
      expect(store.clears, greaterThanOrEqualTo(1));
    });

    testWidgets('Settings account section shows farmer; logout → login',
        (WidgetTester tester) async {
      final (_, _, store) = await pumpApp(tester); // demo dataset

      await tapNav(tester, 'Settings');
      expect(find.text('Account'), findsOneWidget);
      expect(find.text('Kiran'), findsOneWidget);
      expect(find.text('kiran@farm.test'), findsOneWidget);
      expect(find.text('Log out'), findsOneWidget);

      await tester.tap(find.text('Log out'));
      await settle(tester);

      expect(find.text('Sign in'), findsOneWidget);
      expect(find.text('Detections today'), findsNothing);
      expect(store.clears, greaterThanOrEqualTo(1));
      expect(await store.readToken(), isNull);
    });
  });

  // Sanity: demo records are always present beneath live data.
  test('demo records retained in MockData (source for the DEMO tiles)',
      () {
    expect(MockData.events, isNotEmpty);
    expect(
      MockData.events.every((e) => e.imagePath.startsWith('assets/')),
      isTrue,
    );
  });
}
