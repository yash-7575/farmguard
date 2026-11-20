// Widget tests for Phase 2B heartbeat + session reconciliation inside
// HomeScreen: the startup session refresh, immediate heartbeat on entering
// monitoring, 401-driven unpairing (camera removed by the farmer) and the
// camera-side Disconnect action.
//
// All cloud dependencies are fakes — no platform channels, no real HTTP.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farmguard_camera/main.dart';
import 'package:farmguard_camera/screens/home_screen.dart';
import 'package:farmguard_camera/services/api_client.dart';
import 'package:farmguard_camera/services/cloud_services.dart';
import 'package:farmguard_camera/services/device_registration.dart';
import 'package:farmguard_camera/services/model_gateway.dart';
import 'package:farmguard_camera/services/pending_event_store.dart';
import 'package:material_ui/material_ui.dart';

/// Scripted API + upload client.
class _ScriptedApi implements FarmGuardApi, UploadClient {
  HeartbeatOutcome heartbeatOutcome = HeartbeatOutcome.ok;
  int heartbeats = 0;
  String? lastHeartbeatStatus;
  CameraSessionInfo? session;
  Object? sessionError;
  bool unpairResult = true;
  int unpairs = 0;

  @override
  Future<PairedCameraResult> redeemPairingCode({
    required String code,
    required String deviceIdentifier,
    required String cameraName,
    String? location,
  }) async =>
      throw UnimplementedError();

  @override
  Future<bool> sendHeartbeat(String cameraId) async =>
      await sendHeartbeatDetailed(cameraId) == HeartbeatOutcome.ok;

  @override
  Future<HeartbeatOutcome> sendHeartbeatDetailed(
    String cameraId, {
    String status = 'monitoring',
  }) async {
    heartbeats++;
    lastHeartbeatStatus = status;
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
  Future<bool> sendAlert(String cameraId, PendingEvent event) async => true;

  @override
  Future<bool> uploadEvent(
    PendingEvent event, {
    OnImageKeyObtained? onImageKeyObtained,
    OnImageDropped? onImageDropped,
  }) async =>
      true;
}

class _FakeDeviceIdSource implements DeviceIdSource {
  const _FakeDeviceIdSource();

  @override
  Future<String> get id async => 'test-device-1';
}

class _PathModelGateway implements ModelGateway {
  const _PathModelGateway();

  @override
  Future<bool> isModelAvailableLocally(String modelId) async => true;

  @override
  Future<String> resolveModel(String modelId) async =>
      '/tmp/farmguard_test_model.tflite';
}

CloudServices _bundle(
  _ScriptedApi api,
  InMemoryCameraRegistrationStore store, {
  bool backgroundEnabled = true,
}) =>
    CloudServices(
      api: api,
      registrationStore: store,
      deviceIdSource: const _FakeDeviceIdSource(),
      backgroundEnabled: backgroundEnabled,
    );

Future<void> _pumpFrames(WidgetTester tester, [int frames = 8]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('farmguard_camera/settings'),
      (call) async {
        if (call.method == 'requestCameraPermission') {
          return 'granted';
        }
        return null;
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('yolo_single_image_channel'),
      (call) async {
        if (call.method == 'inspectModel') {
          return <String, Object?>{'task': 'detect', 'imgsz': 640};
        }
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('farmguard_camera/settings'),
      null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('yolo_single_image_channel'),
      null,
    );
  });

  testWidgets('startup session refresh stores farmer details and goes online',
      (tester) async {
    final store = InMemoryCameraRegistrationStore();
    await store.save(
      token: 'camera-token',
      cameraId: 'cam-9',
      cameraName: 'North Gate Cam',
    );
    final api = _ScriptedApi()
      ..session = const CameraSessionInfo(
        cameraId: 'cam-9',
        cameraName: 'North Gate Cam',
        location: 'North fence',
        farmerId: 'farmer-1',
        farmerName: 'Asha',
        farmerEmailMasked: 'a***@example.com',
      );

    await tester.pumpWidget(FarmGuardApp(cloudServices: _bundle(api, store)));
    await _pumpFrames(tester);

    expect(find.text('North Gate Cam'), findsOneWidget);
    expect(find.text('Account: Asha (a***@example.com)'), findsOneWidget);
    expect(find.text('Camera ID: cam-9'), findsOneWidget);
    expect(find.text('Online'), findsOneWidget);

    final saved = await store.load();
    expect(saved, isNotNull);
    expect(saved!.farmerId, 'farmer-1');
    expect(saved.farmerName, 'Asha');
    expect(saved.farmerEmailMasked, 'a***@example.com');
    expect(saved.location, 'North fence');
  });

  testWidgets('startup session refresh 401 drops the registration and shows '
      'the removal notice', (tester) async {
    final store = InMemoryCameraRegistrationStore();
    await store.save(
      token: 'camera-token',
      cameraId: 'cam-9',
      cameraName: 'North Gate Cam',
    );
    final api = _ScriptedApi()
      ..sessionError =
          PermanentUploadException('unauthorized', 'Camera is no longer paired.');

    await tester.pumpWidget(FarmGuardApp(cloudServices: _bundle(api, store)));
    await _pumpFrames(tester);

    expect(find.text('Not paired'), findsOneWidget);
    expect(
      find.text('This camera was removed from the farmer account. '
          'Pair again to reconnect.'),
      findsOneWidget,
    );
    expect(await store.load(), isNull);
  });

  testWidgets('entering monitoring sends an immediate heartbeat',
      (tester) async {
    final store = InMemoryCameraRegistrationStore();
    await store.save(
      token: 'camera-token',
      cameraId: 'cam-9',
      cameraName: 'North Gate Cam',
    );
    final api = _ScriptedApi();

    await tester.pumpWidget(FarmGuardApp(
      modelGateway: const _PathModelGateway(),
      cloudServices: _bundle(api, store),
    ));
    await _pumpFrames(tester);
    // The startup session refresh returned null → no heartbeat yet.
    expect(api.heartbeats, 0);

    await tester.tap(find.text('Start Monitoring'));
    for (var frame = 0; frame < 40; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (find.text('Initializing camera & detection…').evaluate().isNotEmpty) {
        break;
      }
    }

    final state = tester.state<HomeScreenState>(find.byType(HomeScreen));
    state.debugNotifyNativeReady();
    await _pumpFrames(tester, 3);

    expect(find.text('Monitoring'), findsOneWidget);
    expect(api.heartbeats, 1);
    expect(api.lastHeartbeatStatus, 'monitoring');
    expect(find.text('Online'), findsOneWidget);

    await state.stopMonitoring();
    await tester.pump();
  });

  testWidgets('heartbeat 401 unpairs the camera locally', (tester) async {
    final store = InMemoryCameraRegistrationStore();
    await store.save(
      token: 'camera-token',
      cameraId: 'cam-9',
      cameraName: 'North Gate Cam',
    );
    final api = _ScriptedApi()
      ..heartbeatOutcome = HeartbeatOutcome.unauthorized;

    await tester.pumpWidget(FarmGuardApp(cloudServices: _bundle(api, store)));
    await _pumpFrames(tester);

    final state = tester.state<HomeScreenState>(find.byType(HomeScreen));
    await state.debugSendHeartbeat();
    await _pumpFrames(tester, 2);

    expect(find.text('Not paired'), findsOneWidget);
    expect(
      find.text('Camera was disconnected by the farmer account.'),
      findsOneWidget,
    );
    expect(find.text('Pair this camera'), findsOneWidget);
    expect(await store.load(), isNull);
  });

  testWidgets('transient heartbeat failure marks the backend offline',
      (tester) async {
    final store = InMemoryCameraRegistrationStore();
    await store.save(
      token: 'camera-token',
      cameraId: 'cam-9',
      cameraName: 'North Gate Cam',
    );
    final api = _ScriptedApi()
      ..heartbeatOutcome = HeartbeatOutcome.transientError;

    await tester.pumpWidget(FarmGuardApp(cloudServices: _bundle(api, store)));
    await _pumpFrames(tester);

    final state = tester.state<HomeScreenState>(find.byType(HomeScreen));
    await state.debugSendHeartbeat();
    await _pumpFrames(tester, 2);

    // Still paired, but the backend is not reachable.
    expect(find.text('North Gate Cam'), findsOneWidget);
    expect(state.debugBackendOnline, isFalse);
    expect(find.text('Online'), findsNothing);
    expect(await store.load(), isNotNull);
  });

  testWidgets('Disconnect confirms, unpairs on the server and clears the '
      'registration', (tester) async {
    final store = InMemoryCameraRegistrationStore();
    await store.save(
      token: 'camera-token',
      cameraId: 'cam-9',
      cameraName: 'North Gate Cam',
    );
    final api = _ScriptedApi()
      ..session = const CameraSessionInfo(
        cameraId: 'cam-9',
        cameraName: 'North Gate Cam',
        farmerName: 'Asha',
      );

    await tester.pumpWidget(FarmGuardApp(cloudServices: _bundle(api, store)));
    await _pumpFrames(tester);

    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Disconnect North Gate Cam?'),
      findsOneWidget,
    );
    expect(find.text('Cancel'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Disconnect'));
    await tester.pumpAndSettle();

    expect(api.unpairs, 1);
    expect(find.text('Not paired'), findsOneWidget);
    expect(find.text('Pair this camera'), findsOneWidget);
    expect(await store.load(), isNull);
  });

  testWidgets('Disconnect can be cancelled', (tester) async {
    final store = InMemoryCameraRegistrationStore();
    await store.save(
      token: 'camera-token',
      cameraId: 'cam-9',
      cameraName: 'North Gate Cam',
    );
    final api = _ScriptedApi();

    await tester.pumpWidget(FarmGuardApp(cloudServices: _bundle(api, store)));
    await _pumpFrames(tester);

    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(api.unpairs, 0);
    expect(find.text('North Gate Cam'), findsOneWidget);
    expect(await store.load(), isNotNull);
  });
}
