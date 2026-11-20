// Widget tests for the CloudStatusCard and the PairingDialog. Everything
// is driven by plain values and fakes — no platform channels.

import 'package:flutter_test/flutter_test.dart';
import 'package:farmguard_camera/services/api_client.dart';
import 'package:farmguard_camera/services/device_registration.dart';
import 'package:farmguard_camera/widgets/cloud_status_card.dart';
import 'package:farmguard_camera/widgets/pairing_dialog.dart';
import 'package:material_ui/material_ui.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: Scaffold(body: child),
    );

void main() {
  group('CloudStatusCard', () {
    DateTime Function() clockAt(DateTime now) => () => now;

    testWidgets('unpaired shows the pairing action and offline state',
        (tester) async {
      await tester.pumpWidget(_wrap(CloudStatusCard(
        paired: false,
        state: CloudSyncState.offline,
        pendingCount: 0,
        failedCount: 0,
        lastSyncAt: null,
        onPair: () {},
      )));

      expect(find.text('Not paired'), findsOneWidget);
      expect(find.text('Pair this camera'), findsOneWidget);
      expect(find.text('Offline'), findsOneWidget);
      expect(find.text('Last sync: Never'), findsOneWidget);
      expect(find.textContaining('pending'), findsNothing);
      expect(find.textContaining('failed'), findsNothing);
    });

    testWidgets('paired idle state shows the camera name', (tester) async {
      await tester.pumpWidget(_wrap(CloudStatusCard(
        paired: true,
        cameraName: 'Field Camera 1',
        state: CloudSyncState.idle,
        pendingCount: 0,
        failedCount: 0,
        lastSyncAt: null,
      )));

      expect(find.text('Field Camera 1'), findsOneWidget);
      expect(find.text('Idle'), findsOneWidget);
      expect(find.text('Pair this camera'), findsNothing);
    });

    testWidgets('uploading state shows the pending count', (tester) async {
      await tester.pumpWidget(_wrap(CloudStatusCard(
        paired: true,
        cameraName: 'Field Camera 1',
        state: CloudSyncState.uploading,
        pendingCount: 3,
        failedCount: 0,
        lastSyncAt: null,
      )));

      expect(find.text('Uploading'), findsOneWidget);
      expect(find.text('3 pending'), findsOneWidget);
    });

    testWidgets('failed events show count and retry action', (tester) async {
      await tester.pumpWidget(_wrap(CloudStatusCard(
        paired: true,
        cameraName: 'Field Camera 1',
        state: CloudSyncState.idle,
        pendingCount: 0,
        failedCount: 2,
        lastSyncAt: null,
        onRetry: () {},
      )));

      expect(find.text('2 failed — kept on this device'), findsOneWidget);
      expect(find.text('Retry now'), findsOneWidget);
    });

    testWidgets('last sync renders relative time', (tester) async {
      final now = DateTime.utc(2026, 11, 18, 12, 0);
      await tester.pumpWidget(_wrap(CloudStatusCard(
        paired: true,
        cameraName: 'Cam',
        state: CloudSyncState.idle,
        pendingCount: 0,
        failedCount: 0,
        lastSyncAt: now.subtract(const Duration(minutes: 2)),
        now: clockAt(now),
      )));

      expect(find.text('Last sync: 2 min ago'), findsOneWidget);
    });

    testWidgets('just-now sync renders as "Just now"', (tester) async {
      final now = DateTime.utc(2026, 11, 18, 12, 0);
      await tester.pumpWidget(_wrap(CloudStatusCard(
        paired: true,
        cameraName: 'Cam',
        state: CloudSyncState.idle,
        pendingCount: 0,
        failedCount: 0,
        lastSyncAt: now.subtract(const Duration(seconds: 10)),
        now: clockAt(now),
      )));

      expect(find.text('Last sync: Just now'), findsOneWidget);
    });
  });

  group('PairingDialog', () {
    testWidgets('success pops with the registration', (tester) async {
      CameraRegistration? popped;

      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () async {
              popped = await showDialog<CameraRegistration>(
                context: context,
                builder: (_) => PairingDialog(
                  onRedeem: (code, cameraName, location) async {
                    return const CameraRegistration(
                      token: 'tok',
                      cameraId: 'cam-1',
                      cameraName: 'Field Camera 1',
                      location: 'North fence',
                    );
                  },
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      )));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Name is prefilled with the suggestion.
      expect(find.text('Farm Camera'), findsOneWidget);

      await tester.enterText(find.byType(TextField).at(0), '123456');
      await tester.enterText(find.byType(TextField).at(1), 'Field Camera 1');
      await tester.enterText(find.byType(TextField).at(2), 'North fence');

      await tester.tap(find.text('Pair'));
      await tester.pumpAndSettle();

      expect(find.byType(PairingDialog), findsNothing);
      expect(popped, isNotNull);
      expect(popped!.cameraId, 'cam-1');
      expect(popped!.cameraName, 'Field Camera 1');
      expect(popped!.location, 'North fence');
    });

    testWidgets('failure shows the server message inline', (tester) async {
      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () => showDialog<CameraRegistration>(
              context: context,
              builder: (_) => PairingDialog(
                onRedeem: (code, cameraName, location) async {
                  throw PairingException('invalid_code', 'Invalid pairing code');
                },
              ),
            ),
            child: const Text('open'),
          ),
        ),
      )));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(0), '999999');
      await tester.tap(find.text('Pair'));
      await tester.pumpAndSettle();

      // Dialog stays open and the server message is shown inline.
      expect(find.byType(PairingDialog), findsOneWidget);
      expect(find.text('Invalid pairing code'), findsOneWidget);
    });

    testWidgets('invalid code is rejected before any call', (tester) async {
      var called = false;
      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () => showDialog<CameraRegistration>(
              context: context,
              builder: (_) => PairingDialog(
                onRedeem: (code, cameraName, location) async {
                  called = true;
                  throw StateError('must not be called');
                },
              ),
            ),
            child: const Text('open'),
          ),
        ),
      )));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(0), '12ab56');
      // digitsOnly filter strips the letters → '1256', too short.
      await tester.tap(find.text('Pair'));
      await tester.pumpAndSettle();

      expect(called, isFalse);
      expect(find.text('Enter the 6-digit pairing code.'), findsOneWidget);
      expect(find.byType(PairingDialog), findsOneWidget);
    });
  });
}
