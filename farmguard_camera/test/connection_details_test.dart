// Widget tests for the Phase 2B Connection Details section of the
// CloudStatusCard: camera name, farmer account, short camera id,
// connection status, last heartbeat and the disconnect action.
//
// Everything is plain values — no platform channels.

import 'package:flutter_test/flutter_test.dart';
import 'package:farmguard_camera/widgets/cloud_status_card.dart';
import 'package:material_ui/material_ui.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: Scaffold(body: child),
    );

void main() {
  group('CloudStatusCard connection details', () {
    DateTime Function() clockAt(DateTime now) => () => now;

    testWidgets('paired card shows camera, account and short camera id',
        (tester) async {
      await tester.pumpWidget(_wrap(CloudStatusCard(
        paired: true,
        cameraName: 'Field Camera 1',
        cameraId: 'abcdef12-3456-7890-abcd-ef1234567890',
        farmerName: 'Asha',
        farmerEmailMasked: 'a***@example.com',
        state: CloudSyncState.idle,
        pendingCount: 0,
        failedCount: 0,
        lastSyncAt: null,
      )));

      expect(find.text('Paired · '), findsOneWidget);
      expect(find.text('Field Camera 1'), findsOneWidget);
      expect(find.text('Account: Asha (a***@example.com)'), findsOneWidget);
      // Only the first 8 characters of the id are shown.
      expect(find.text('Camera ID: abcdef12'), findsOneWidget);
      expect(find.text('Pair this camera'), findsNothing);
    });

    testWidgets('account row shows the masked email when the name is missing',
        (tester) async {
      await tester.pumpWidget(_wrap(CloudStatusCard(
        paired: true,
        cameraName: 'Cam',
        farmerEmailMasked: 'a***@example.com',
        state: CloudSyncState.idle,
        pendingCount: 0,
        failedCount: 0,
        lastSyncAt: null,
      )));

      expect(find.text('Account: a***@example.com'), findsOneWidget);
      expect(find.textContaining('Camera ID:'), findsNothing);
    });

    testWidgets('short camera ids are shown in full', (tester) async {
      await tester.pumpWidget(_wrap(CloudStatusCard(
        paired: true,
        cameraName: 'Cam',
        cameraId: 'cam-1',
        state: CloudSyncState.idle,
        pendingCount: 0,
        failedCount: 0,
        lastSyncAt: null,
      )));

      expect(find.text('Camera ID: cam-1'), findsOneWidget);
    });

    testWidgets('backendOnline renders Online and the heartbeat relative time',
        (tester) async {
      final now = DateTime.utc(2026, 11, 18, 12, 0);
      await tester.pumpWidget(_wrap(CloudStatusCard(
        paired: true,
        cameraName: 'Cam',
        state: CloudSyncState.idle,
        pendingCount: 0,
        failedCount: 0,
        lastSyncAt: null,
        backendOnline: true,
        lastHeartbeatAt: now.subtract(const Duration(minutes: 5)),
        now: clockAt(now),
      )));

      expect(find.text('Online'), findsOneWidget);
      // Last sync uses the latest of lastSyncAt and lastHeartbeatAt.
      expect(find.text('Last sync: 5 min ago'), findsOneWidget);
    });

    testWidgets('idle with a previous sync counts as Online', (tester) async {
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

      expect(find.text('Online'), findsOneWidget);
      expect(find.text('Last sync: 2 min ago'), findsOneWidget);
    });

    testWidgets('offline backend without a sync stays Idle', (tester) async {
      await tester.pumpWidget(_wrap(CloudStatusCard(
        paired: true,
        cameraName: 'Cam',
        state: CloudSyncState.idle,
        pendingCount: 0,
        failedCount: 0,
        lastSyncAt: null,
      )));

      expect(find.text('Idle'), findsOneWidget);
      expect(find.text('Online'), findsNothing);
    });

    testWidgets('Disconnect is hidden without onUnpair and shown with it',
        (tester) async {
      await tester.pumpWidget(_wrap(CloudStatusCard(
        paired: true,
        cameraName: 'Cam',
        state: CloudSyncState.idle,
        pendingCount: 0,
        failedCount: 0,
        lastSyncAt: null,
      )));
      expect(find.text('Disconnect'), findsNothing);

      var disconnects = 0;
      await tester.pumpWidget(_wrap(CloudStatusCard(
        paired: true,
        cameraName: 'Cam',
        state: CloudSyncState.idle,
        pendingCount: 0,
        failedCount: 0,
        lastSyncAt: null,
        onUnpair: () => disconnects++,
      )));

      await tester.tap(find.text('Disconnect'));
      await tester.pump();

      expect(disconnects, 1);
    });

    testWidgets('unpaired card shows the notice text', (tester) async {
      await tester.pumpWidget(_wrap(CloudStatusCard(
        paired: false,
        state: CloudSyncState.offline,
        pendingCount: 0,
        failedCount: 0,
        lastSyncAt: null,
        onPair: () {},
        noticeText: 'Camera was disconnected by the farmer account.',
      )));

      expect(find.text('Not paired'), findsOneWidget);
      expect(find.text('Pair this camera'), findsOneWidget);
      expect(find.text('Camera was disconnected by the farmer account.'),
          findsOneWidget);
      expect(find.text('Disconnect'), findsNothing);
    });
  });
}
