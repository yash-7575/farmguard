/// Pairing-code UI tests (Stage: in-app camera pairing): the Cameras tab's
/// "Pair a camera" action opens the pairing-code dialog, which generates
/// the 6-digit code, shows an expiry countdown and offers regeneration.
/// All tests run on fake-backed services (no platform channels) — the same
/// idiom as the camera app's PairingDialog tests.
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:farmguard_farmer/models/models.dart';
import 'package:farmguard_farmer/services/api/exceptions.dart';
import 'package:farmguard_farmer/services/api/farmer_api.dart';
import 'package:farmguard_farmer/widgets/pairing_code_dialog.dart';

import 'helpers/api_fixtures.dart';
import 'helpers/widget_pump.dart';

void main() {
  // Dialog-level tests inject a mutable clock the test advances manually
  // (works regardless of fake-async DateTime patching); the ticker still
  // fires via tester.pump.
  final DateTime fixedNow = DateTime.utc(2026, 11, 18, 10);

  /// The injected clock the dialog reads; tests advance this manually.
  DateTime clockTime = fixedNow;

  PairingCodeResult codeAt(DateTime expiresAt) =>
      PairingCodeResult(code: '428913', expiresAt: expiresAt);

  Future<void> openDialog(
    WidgetTester tester, {
    required Future<PairingCodeResult> Function() onCreateCode,
    VoidCallback? onSessionExpired,
  }) async {
    clockTime = fixedNow; // tests share this mutable clock — reset per test
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => Center(
              child: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (BuildContext dialogContext) => PairingCodeDialog(
                    onCreateCode: onCreateCode,
                    onSessionExpired: onSessionExpired,
                    now: () => clockTime,
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump(); // route in
    await tester.pump(); // async generate flushed
  }

  group('PairingCodeDialog (dialog level, injected clock)', () {
    testWidgets('shows the code large with an mm:ss countdown that ticks',
        (WidgetTester tester) async {
      await openDialog(
        tester,
        onCreateCode: () async => codeAt(fixedNow.add(const Duration(minutes: 5))),
      );

      expect(find.text('428913'), findsOneWidget);
      expect(find.text('Expires in 05:00'), findsOneWidget);

      clockTime = fixedNow.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Expires in 04:59'), findsOneWidget);
    });

    testWidgets('already-expired code → expired state, code hidden, '
        'Generate new code offered', (WidgetTester tester) async {
      await openDialog(
        tester,
        onCreateCode: () async =>
            codeAt(fixedNow.subtract(const Duration(seconds: 1))),
      );

      expect(find.text('This code has expired.'), findsOneWidget);
      expect(find.text('428913'), findsNothing);
      expect(find.textContaining('Expires in'), findsNothing);
      final button = find.widgetWithText(FilledButton, 'Generate new code');
      expect(button, findsOneWidget);
    });

    testWidgets('countdown reaching zero flips to the expired state and '
        'stops the ticker', (WidgetTester tester) async {
      await openDialog(
        tester,
        onCreateCode: () async => codeAt(fixedNow.add(const Duration(seconds: 2))),
      );

      clockTime = fixedNow.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('This code has expired.'), findsOneWidget);
      expect(find.textContaining('Expires in'), findsNothing);

      // Ticker stopped: further time passing must not crash or change state.
      clockTime = fixedNow.add(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('This code has expired.'), findsOneWidget);
    });

    testWidgets('transient error → inline message + Retry; retry succeeds',
        (WidgetTester tester) async {
      const ApiException boom = ApiException(
        statusCode: 503,
        code: 'server_error',
        message: 'Service unavailable.',
      );
      var calls = 0;
      await openDialog(
        tester,
        onCreateCode: () async {
          calls++;
          if (calls == 1) throw boom;
          return codeAt(fixedNow.add(const Duration(minutes: 5)));
        },
      );

      expect(find.text('Service unavailable.'), findsOneWidget);
      expect(find.text('428913'), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
      await tester.pump();
      await tester.pump();

      expect(find.text('428913'), findsOneWidget);
      expect(calls, 2);
    });

    testWidgets('401 → dialog pops and onSessionExpired fires',
        (WidgetTester tester) async {
      var sessionExpiredCalls = 0;
      await openDialog(
        tester,
        onCreateCode: () async => throw const ApiException(
          statusCode: 401,
          code: 'unauthorized',
          message: 'Token invalid or expired.',
        ),
        onSessionExpired: () => sessionExpiredCalls++,
      );

      expect(find.byType(PairingCodeDialog), findsNothing);
      expect(sessionExpiredCalls, 1);
    });

    testWidgets('regenerate → second call renders the new code with a '
        'reset countdown', (WidgetTester tester) async {
      var calls = 0;
      await openDialog(
        tester,
        onCreateCode: () async {
          calls++;
          return calls == 1
              ? codeAt(fixedNow.add(const Duration(minutes: 5)))
              : PairingCodeResult(
                  code: '552230',
                  expiresAt: fixedNow.add(const Duration(minutes: 5)),
                );
        },
      );

      expect(find.text('428913'), findsOneWidget);
      await tester.tap(find.text('Generate new code'));
      await tester.pump();
      await tester.pump();

      expect(calls, 2);
      expect(find.text('552230'), findsOneWidget);
      expect(find.text('Expires in 05:00'), findsOneWidget);
    });

    testWidgets('Close pops the dialog (ticker cancelled on dispose)',
        (WidgetTester tester) async {
      await openDialog(
        tester,
        onCreateCode: () async => codeAt(fixedNow.add(const Duration(minutes: 5))),
      );

      await tester.tap(find.text('Close'));
      await tester.pump();

      expect(find.byType(PairingCodeDialog), findsNothing);
      // No timers left ticking — pumping further must be safe.
      clockTime = fixedNow.add(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('Cameras tab pairing entry (shell level, fake-backed app)', () {
    testWidgets("'Pair a camera' card opens the dialog → api called → code "
        '+ countdown rendered', (WidgetTester tester) async {
      final api = demoApi()
        ..pairingCode = PairingCodeResult(
          code: '428913',
          expiresAt: DateTime.now().add(const Duration(minutes: 4, seconds: 59)),
        );
      await pumpApp(tester, api: api);

      await tapNav(tester, 'Cameras');
      // Discoverable at the top of the camera list.
      expect(find.text('Pair a camera'), findsOneWidget);

      await tester.tap(find.text('Pair a camera'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(api.createPairingCodeCalls, 1);
      expect(find.text('428913'), findsOneWidget);
      expect(find.textContaining('Expires in 04:5'), findsOneWidget);
      expect(find.textContaining('Pair this camera'), findsOneWidget);
    });

    testWidgets('regenerate from the shell → second api call, new code',
        (WidgetTester tester) async {
      final api = demoApi()
        ..pairingCode = PairingCodeResult(
          code: '428913',
          expiresAt: DateTime.now().add(const Duration(minutes: 5)),
        );
      await pumpApp(tester, api: api);

      await tapNav(tester, 'Cameras');
      await tester.tap(find.text('Pair a camera'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      api.pairingCode = PairingCodeResult(
        code: '552230',
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      );
      await tester.tap(find.text('Generate new code'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(api.createPairingCodeCalls, 2);
      expect(find.text('552230'), findsOneWidget);
    });

    testWidgets('401 while generating → session-expiry path back to login',
        (WidgetTester tester) async {
      final api = demoApi()
        ..pairingError = const ApiException(
          statusCode: 401,
          code: 'unauthorized',
          message: 'Token invalid or expired.',
        );
      await pumpApp(tester, api: api);

      await tapNav(tester, 'Cameras');
      await tester.tap(find.text('Pair a camera'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Dialog popped and the session cleared → login screen.
      expect(find.byType(PairingCodeDialog), findsNothing);
      expect(find.text('Sign in'), findsOneWidget);
      expect(find.text('Detections today'), findsNothing);
    });

    testWidgets('no cameras yet → empty state offers Pair a camera',
        (WidgetTester tester) async {
      final api = FakeFarmerApi(
        authResult: authResult(),
        cameras: <FarmCamera>[],
        pairingCode: PairingCodeResult(
          code: '428913',
          expiresAt: DateTime.now().add(const Duration(minutes: 5)),
        ),
      );
      await pumpApp(tester, api: api);

      await tapNav(tester, 'Cameras');
      expect(find.text('No cameras yet'), findsOneWidget);

      await tester.tap(find.text('Pair a camera'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(api.createPairingCodeCalls, 1);
      expect(find.text('428913'), findsOneWidget);
    });
  });
}
