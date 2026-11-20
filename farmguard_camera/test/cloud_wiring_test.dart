// Widget tests for the full cloud wiring inside HomeScreen/FarmGuardApp:
// pairing through the UI, the detection-engine → PendingEvent →
// UploadQueue → UploadClient flow, and the UploadQueue's handling of
// permanent upload failures. All dependencies are fakes — no platform
// channels, no timers (the queue is pumped manually).

import 'package:flutter_test/flutter_test.dart';
import 'package:farmguard_camera/main.dart';
import 'package:farmguard_camera/services/api_client.dart';
import 'package:farmguard_camera/services/cloud_services.dart';
import 'package:farmguard_camera/services/device_registration.dart';
import 'package:farmguard_camera/services/detection_event_engine.dart';
import 'package:farmguard_camera/services/pending_event_store.dart';
import 'package:farmguard_camera/services/upload_queue.dart';
import 'package:farmguard_camera/widgets/pairing_dialog.dart';
import 'package:material_ui/material_ui.dart';

/// Fake API + upload client: records calls, scripted outcomes.
class FakeFarmGuardApi implements FarmGuardApi, UploadClient {
  PairedCameraResult? nextResult;
  Object? nextError;
  int heartbeats = 0;
  HeartbeatOutcome heartbeatOutcome = HeartbeatOutcome.ok;
  CameraSessionInfo? session;
  Object? sessionError;
  bool unpairResult = true;
  int unpairs = 0;
  final redeemed = <({String code, String deviceIdentifier, String cameraName})>[];
  final uploaded = <PendingEvent>[];

  @override
  Future<PairedCameraResult> redeemPairingCode({
    required String code,
    required String deviceIdentifier,
    required String cameraName,
    String? location,
  }) async {
    redeemed.add((
      code: code,
      deviceIdentifier: deviceIdentifier,
      cameraName: cameraName,
    ));
    final error = nextError;
    if (error != null) {
      throw error;
    }
    return nextResult!;
  }

  @override
  Future<bool> sendHeartbeat(String cameraId) async =>
      await sendHeartbeatDetailed(cameraId) == HeartbeatOutcome.ok;

  @override
  Future<HeartbeatOutcome> sendHeartbeatDetailed(
    String cameraId, {
    String status = 'monitoring',
  }) async {
    heartbeats++;
    return heartbeatOutcome;
  }

  @override
  Future<CameraSessionInfo?> fetchCameraSession() async {
    final error = sessionError;
    if (error != null) {
      throw error;
    }
    return session;
  }

  @override
  Future<bool> unpairSelf() async {
    unpairs++;
    return unpairResult;
  }

  @override
  Future<bool> sendAlert(String cameraId, PendingEvent event) async {
    uploaded.add(event);
    return true;
  }

  @override
  Future<bool> uploadEvent(
    PendingEvent event, {
    OnImageKeyObtained? onImageKeyObtained,
    OnImageDropped? onImageDropped,
  }) => sendAlert('', event);
}

class _FakeDeviceIdSource implements DeviceIdSource {
  const _FakeDeviceIdSource();

  @override
  Future<String> get id async => 'test-device-1';
}

void main() {
  CloudServices bundleWith(FakeFarmGuardApi api,
      {InMemoryCameraRegistrationStore? registrationStore}) {
    return CloudServices(
      api: api,
      registrationStore:
          registrationStore ?? InMemoryCameraRegistrationStore(),
      deviceIdSource: const _FakeDeviceIdSource(),
    );
  }

  testWidgets('idle app with fakes: UI unchanged + Pair this camera visible',
      (tester) async {
    final bundle = bundleWith(FakeFarmGuardApi());
    await tester.pumpWidget(FarmGuardApp(cloudServices: bundle));
    await tester.pump();

    expect(find.text('Camera on standby'), findsOneWidget);
    expect(find.text('Start Monitoring'), findsOneWidget);
    expect(find.text('Pair this camera'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('Last sync: Never'), findsOneWidget);
  });

  testWidgets('pairing success: status card shows the camera name',
      (tester) async {
    final api = FakeFarmGuardApi()
      ..nextResult = const PairedCameraResult(
        token: 'camera-token',
        cameraId: 'cam-1',
        cameraName: 'Field Camera 1',
      );
    final bundle = bundleWith(api);
    await tester.pumpWidget(FarmGuardApp(cloudServices: bundle));
    await tester.pump();

    await tester.tap(find.text('Pair this camera'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), '123456');
    await tester.enterText(find.byType(TextField).at(1), 'Field Camera 1');
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();

    // Dialog closed, card shows the camera name, cloud state is idle.
    expect(find.byType(PairingDialog), findsNothing);
    expect(find.text('Field Camera 1'), findsOneWidget);
    expect(find.text('Idle'), findsOneWidget);
    expect(find.text('Pair this camera'), findsNothing);

    // The API received the injected device id and the entered code.
    expect(api.redeemed, hasLength(1));
    expect(api.redeemed.single.code, '123456');
    expect(api.redeemed.single.deviceIdentifier, 'test-device-1');
  });

  testWidgets('pairing failure: server error message shown inline',
      (tester) async {
    final api = FakeFarmGuardApi()
      ..nextError = PairingException('invalid_code', 'Invalid pairing code');
    final bundle = bundleWith(api);
    await tester.pumpWidget(FarmGuardApp(cloudServices: bundle));
    await tester.pump();

    await tester.tap(find.text('Pair this camera'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), '999999');
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();

    // Dialog stays open with the error inline; card stays unpaired.
    expect(find.byType(PairingDialog), findsOneWidget);
    expect(find.text('Invalid pairing code'), findsOneWidget);
    expect(find.text('Not paired'), findsOneWidget);
  });

  testWidgets('existing registration is restored at startup',
      (tester) async {
    final registrationStore = InMemoryCameraRegistrationStore();
    await registrationStore.save(
      token: 'camera-token',
      cameraId: 'cam-9',
      cameraName: 'North Gate Cam',
    );
    final bundle = bundleWith(
      FakeFarmGuardApi(),
      registrationStore: registrationStore,
    );

    await tester.pumpWidget(FarmGuardApp(cloudServices: bundle));
    await tester.pump();

    expect(find.text('North Gate Cam'), findsOneWidget);
    expect(find.text('Idle'), findsOneWidget);
    expect(find.text('Pair this camera'), findsNothing);
  });

  testWidgets('engine event → PendingEvent → fake UploadClient with the '
      'right id and cameraId', (tester) async {
    final api = FakeFarmGuardApi();
    final registrationStore = InMemoryCameraRegistrationStore();
    await registrationStore.save(
      token: 'camera-token',
      cameraId: 'cam-1',
      cameraName: 'Field Camera 1',
    );
    final bundle = bundleWith(api, registrationStore: registrationStore);

    await tester.pumpWidget(FarmGuardApp(cloudServices: bundle));
    await tester.pump();

    // Drive the engine directly (the same engine the screen listens to):
    // 5 person-present frames confirm 1 event (3-of-5 window policy).
    final engine = bundle.engine;
    final events = <ConfirmedEvent>[];
    engine.eventStream.listen(events.add);
    for (var frame = 0; frame < 5; frame++) {
      engine.processFrame([
        (
          className: 'person',
          confidence: 0.92,
          box: (left: 0.1, top: 0.2, width: 0.3, height: 0.4),
        ),
      ]);
    }
    // Broadcast-stream delivery and the async enqueue complete in
    // microtasks: one pump flushes them.
    await tester.pump();
    expect(events, hasLength(1));
    expect(bundle.queue.pendingCount, 1);

    // The queue is pumped manually in tests.
    await bundle.queue.processDue();

    expect(api.uploaded, hasLength(1));
    final uploaded = api.uploaded.single;
    expect(uploaded.eventId, events.single.eventId);
    expect(uploaded.cameraId, 'cam-1');
    expect(uploaded.detectionType, 'person');
    expect(uploaded.confidence, 0.92);
    expect(uploaded.personCount, 1);
    // UTC ISO-8601, from the engine's confirmedAt.
    expect(uploaded.capturedAt, endsWith('Z'));
    expect(DateTime.parse(uploaded.capturedAt).isUtc, isTrue);
    expect(
      uploaded.boundingBox,
      (left: 0.1, top: 0.2, width: 0.3, height: 0.4),
    );
    // No controller mounted in tests → capture skipped, no image.
    expect(uploaded.imageBytes, isNull);

    // Server confirmed → event deleted, sync time recorded.
    expect(bundle.queue.pendingCount, 0);
    expect(bundle.queue.lastSyncAt, isNotNull);
  });

  testWidgets('unpaired confirmed events are not enqueued', (tester) async {
    final api = FakeFarmGuardApi();
    final bundle = bundleWith(api);

    await tester.pumpWidget(FarmGuardApp(cloudServices: bundle));
    await tester.pump();

    final engine = bundle.engine;
    for (var frame = 0; frame < 5; frame++) {
      engine.processFrame([
        (className: 'person', confidence: 0.9, box: null),
      ]);
    }
    await tester.pump();

    expect(bundle.queue.pendingCount, 0);
    expect(api.uploaded, isEmpty);
  });

  testWidgets('permanent upload failure marks the event failed after one '
      'attempt and Retry now reschedules it', (tester) async {
    // Pure-Dart queue test: a PermanentUploadException must not burn the
    // remaining attempts.
    final store = InMemoryPendingEventStore();
    final client = FakeUploadClient(outcomes: [true], throws: [
      PermanentUploadException('invalid_token', 'bad token'),
    ]);
    final queue = UploadQueue(store: store, client: client);
    await queue.enqueue(PendingEvent(
      eventId: 'evt-perm',
      confidence: 0.9,
      personCount: 1,
      capturedAt: DateTime.utc(2026, 11, 18, 9, 30).toIso8601String(),
      createdAt: DateTime.utc(2026, 11, 18, 9, 30),
    ));

    await queue.processDue();

    expect(queue.failedCount, 1);
    expect(queue.pendingCount, 0);
    expect(store.loadAll(), completion(hasLength(1)));

    // Retry now resets the attempt counter and the upload succeeds.
    await queue.retryFailed();
    expect(queue.pendingCount, 1);
    expect(queue.failedCount, 0);
    await queue.processDue();
    expect(queue.pendingCount, 0);
    expect(client.attemptedEventIds, ['evt-perm', 'evt-perm']);
  });
}
