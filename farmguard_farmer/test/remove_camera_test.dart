/// Remove-camera flow: card action → confirmation dialog → backend delete →
/// list refresh / snackbar. Fake-backed app only — no platform channels.
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:farmguard_farmer/models/models.dart';
import 'package:farmguard_farmer/services/api/exceptions.dart';

import 'helpers/api_fixtures.dart';
import 'helpers/widget_pump.dart';

/// Taps the card's "Remove Camera" action and flushes the dialog transition.
Future<void> openRemoveDialog(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Remove Camera'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Taps the dialog's confirming "Remove Camera" button and flushes the delete
/// request, list refresh and snackbar animation.
Future<void> confirmRemove(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, 'Remove Camera'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

FakeFarmerApi oneCameraApi({String name = 'Alpha Cam'}) => FakeFarmerApi(
      authResult: authResult(),
      cameras: <FarmCamera>[apiCamera(id: 'cam-1', name: name)],
    );

void main() {
  group('remove camera', () {
    testWidgets('camera card shows the short camera id', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, api: oneCameraApi());

      await tapNav(tester, 'Cameras');

      expect(find.text('ID: cam-1'), findsOneWidget);
      // Location text stays its own widget (no concatenation).
      expect(find.text('Farm entrance, north boundary'), findsOneWidget);
    });

    testWidgets('tapping Remove Camera opens the confirmation dialog', (
      WidgetTester tester,
    ) async {
      final FakeFarmerApi api = oneCameraApi();
      await pumpApp(tester, api: api);

      await tapNav(tester, 'Cameras');
      await openRemoveDialog(tester);

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.text(
          'Remove Alpha Cam? This will disconnect the camera from your '
          'account. You will need to pair it again to reconnect.',
        ),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
      // Nothing is deleted until the farmer confirms.
      expect(api.deletedCameraIds, isEmpty);
    });

    testWidgets('Cancel closes the dialog and keeps the camera', (
      WidgetTester tester,
    ) async {
      final FakeFarmerApi api = oneCameraApi();
      await pumpApp(tester, api: api);

      await tapNav(tester, 'Cameras');
      await openRemoveDialog(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await settle(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(api.deletedCameraIds, isEmpty);
      expect(find.text('Alpha Cam'), findsOneWidget);
      expect(find.text('ID: cam-1'), findsOneWidget);
    });

    testWidgets('confirming deletes, refreshes the list and shows a snackbar',
        (WidgetTester tester) async {
      final FakeFarmerApi api = oneCameraApi();
      await pumpApp(tester, api: api);

      await tapNav(tester, 'Cameras');
      await openRemoveDialog(tester);
      await confirmRemove(tester);

      expect(api.deletedCameraIds, <String>['cam-1']);
      // Camera gone from the refreshed list → empty state.
      expect(find.text('Alpha Cam'), findsNothing);
      expect(find.text('No cameras yet'), findsOneWidget);
      expect(find.text('Alpha Cam removed.'), findsOneWidget);
    });

    testWidgets('failed removal keeps the camera and shows the error', (
      WidgetTester tester,
    ) async {
      final FakeFarmerApi api = oneCameraApi()
        ..deleteCameraError = const ApiException(
          statusCode: 500,
          code: 'server_error',
          message: 'Service unavailable.',
        );
      await pumpApp(tester, api: api);

      await tapNav(tester, 'Cameras');
      await openRemoveDialog(tester);
      await confirmRemove(tester);

      expect(api.deletedCameraIds, <String>['cam-1']);
      expect(find.text('Service unavailable.'), findsOneWidget);
      // The camera is still there — nothing was removed locally.
      expect(find.text('Alpha Cam'), findsOneWidget);
      expect(find.text('ID: cam-1'), findsOneWidget);
    });

    testWidgets('401 while removing → session expiry back to login', (
      WidgetTester tester,
    ) async {
      final FakeFarmerApi api = oneCameraApi()
        ..deleteCameraError = const ApiException(
          statusCode: 401,
          code: 'unauthorized',
          message: 'Token invalid or expired.',
        );
      await pumpApp(tester, api: api);

      await tapNav(tester, 'Cameras');
      await openRemoveDialog(tester);
      await confirmRemove(tester);

      expect(find.text('Sign in'), findsOneWidget);
      expect(find.text('Detections today'), findsNothing);
    });
  });
}
