// Widget tests for the Phase 2B startup flow:
//
// 1. Defect 2A: the detection preview must sit DIRECTLY inside Expanded so
//    ClipRRect → Stack(fit: StackFit.expand) → YOLOView get tight, bounded
//    constraints. Inside the old Center → SingleChildScrollView wrapper the
//    height was unbounded and the preview crashed on layout.
// 2. Defect 2B: `onModelLoad` alone must NOT report live monitoring (it
//    fires before the native camera/LiteRT pipeline starts). Monitoring is
//    only entered on the first native inference callback, and a 20 s
//    watchdog fails the mount when that callback never arrives.
//
// The plugin's `inspectModel` channel is mocked so YOLOView's own model
// resolution succeeds; no native platform view is created and no real
// model file is read.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farmguard_camera/main.dart';
import 'package:farmguard_camera/screens/home_screen.dart';
import 'package:farmguard_camera/services/api_client.dart';
import 'package:farmguard_camera/services/cloud_services.dart';
import 'package:farmguard_camera/services/device_registration.dart';
import 'package:farmguard_camera/services/model_gateway.dart';
import 'package:farmguard_camera/services/pending_event_store.dart';
import 'package:farmguard_camera/widgets/camera_status_views.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

/// Model gateway that resolves instantly to a local path (no download).
class _PathModelGateway implements ModelGateway {
  const _PathModelGateway({this.cached = true});

  final bool cached;

  @override
  Future<bool> isModelAvailableLocally(String modelId) async => cached;

  @override
  Future<String> resolveModel(String modelId) async =>
      '/tmp/farmguard_test_model.tflite';
}

/// Minimal API/upload fake: nothing cloud-related happens in these tests.
class _SilentApi implements FarmGuardApi, UploadClient {
  @override
  Future<PairedCameraResult> redeemPairingCode({
    required String code,
    required String deviceIdentifier,
    required String cameraName,
    String? location,
  }) async =>
      throw UnimplementedError();

  @override
  Future<bool> sendHeartbeat(String cameraId) async => true;

  @override
  Future<HeartbeatOutcome> sendHeartbeatDetailed(
    String cameraId, {
    String status = 'monitoring',
  }) async =>
      HeartbeatOutcome.ok;

  @override
  Future<CameraSessionInfo?> fetchCameraSession() async => null;

  @override
  Future<bool> unpairSelf() async => true;

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

CloudServices _inertBundle() => CloudServices(
      api: _SilentApi(),
      registrationStore: InMemoryCameraRegistrationStore(),
      deviceIdSource: const _FakeDeviceIdSource(),
      backgroundEnabled: false,
    );

/// Pumps frames until the native preview is mounted and its `onModelLoad`
/// callback has been delivered. Never uses pumpAndSettle (the 20 s startup
/// watchdog would be drained by it).
Future<void> _pumpUntilPreview(WidgetTester tester) async {
  for (var frame = 0; frame < 40; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (find.byType(YOLOView).evaluate().isNotEmpty &&
        find.text('Initializing camera & detection…').evaluate().isNotEmpty) {
      return;
    }
  }
  fail('detection preview never mounted');
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
    // YOLOView resolves its model path through the plugin's static
    // inspectModel method; answer it so no platform channel is missing.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('yolo_single_image_channel'),
      (call) async {
        if (call.method == 'inspectModel') {
          return <String, Object?>{
            'task': 'detect',
            'imgsz': 640,
            'names': <String, Object?>{'0': 'person'},
          };
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

  testWidgets('detection preview is bounded and outside any scroll view',
      (tester) async {
    await tester.pumpWidget(FarmGuardApp(
      modelGateway: const _PathModelGateway(),
      cloudServices: _inertBundle(),
    ));

    await tester.tap(find.text('Start Monitoring'));
    await _pumpUntilPreview(tester);

    expect(find.byType(YOLOView), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Defect 2A regression: the preview must not be inside a scroll view.
    expect(
      find.ancestor(
        of: find.byType(YOLOView),
        matching: find.byType(SingleChildScrollView),
      ),
      findsNothing,
    );
    // ... and it must be clipped by the rounded card, which only gets a
    // finite size from the tight Expanded constraints.
    expect(
      find.ancestor(
        of: find.byType(YOLOView),
        matching: find.byType(ClipRRect),
      ),
      findsWidgets,
    );
    final size = tester.getSize(find.byType(YOLOView));
    expect(size.height.isFinite, isTrue);
    expect(size.height, greaterThan(0));

    await tester
        .state<HomeScreenState>(find.byType(HomeScreen))
        .stopMonitoring();
    await tester.pump();
  });

  testWidgets('idle and error status views still scroll (unchanged)',
      (tester) async {
    await tester.pumpWidget(FarmGuardApp(
      modelGateway: const _PathModelGateway(),
      cloudServices: _inertBundle(),
    ));

    expect(
      find.ancestor(
        of: find.byType(IdlePlaceholderView),
        matching: find.byType(SingleChildScrollView),
      ),
      findsOneWidget,
    );
  });

  testWidgets('onModelLoad alone keeps initializing; first native callback '
      'promotes to monitoring and cancels the watchdog', (tester) async {
    await tester.pumpWidget(FarmGuardApp(
      modelGateway: const _PathModelGateway(),
      cloudServices: _inertBundle(),
    ));

    await tester.tap(find.text('Start Monitoring'));
    await _pumpUntilPreview(tester);

    final state = tester.state<HomeScreenState>(find.byType(HomeScreen));

    // The model file is loaded, but no native inference callback yet:
    // still initializing, with an explicit overlay and a cancel action.
    expect(state.debugStartupStage, MonitoringStartupStage.initializingCamera);
    expect(find.text('Initializing camera & detection…'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Monitoring'), findsNothing);
    expect(find.text('Stop Monitoring'), findsNothing);

    // First native callback (as delivered by onResult/onPerformanceMetrics).
    state.debugNotifyNativeReady();
    await tester.pump();

    expect(find.text('Monitoring'), findsOneWidget);
    expect(find.text('Stop Monitoring'), findsOneWidget);
    expect(find.text('Initializing camera & detection…'), findsNothing);

    // The watchdog was cancelled: well past 20 s we are still monitoring.
    await tester.pump(const Duration(seconds: 25));
    expect(find.text('Monitoring'), findsOneWidget);
    expect(find.text('Camera error'), findsNothing);

    await state.stopMonitoring();
    await tester.pump();
  });

  testWidgets('20 s startup watchdog fails the mount when the native '
      'pipeline never reports a callback', (tester) async {
    await tester.pumpWidget(FarmGuardApp(
      modelGateway: const _PathModelGateway(),
      cloudServices: _inertBundle(),
    ));

    await tester.tap(find.text('Start Monitoring'));
    await _pumpUntilPreview(tester);

    expect(find.text('Initializing camera & detection…'), findsOneWidget);

    // Nothing arrives from native for 20 s → retryable error, view torn
    // down (no endless "Initializing…").
    await tester.pump(const Duration(seconds: 21));

    expect(find.text('Camera error'), findsOneWidget);
    expect(
      find.textContaining('timed out during initialization'),
      findsOneWidget,
    );
    expect(find.text('Try Again'), findsOneWidget);
    expect(find.byType(YOLOView), findsNothing);
    expect(find.text('Cancel'), findsNothing);
    expect(find.text('Start Monitoring'), findsOneWidget);
  });

  testWidgets('cancel during initializing returns to idle', (tester) async {
    await tester.pumpWidget(FarmGuardApp(
      modelGateway: const _PathModelGateway(),
      cloudServices: _inertBundle(),
    ));

    await tester.tap(find.text('Start Monitoring'));
    await _pumpUntilPreview(tester);

    await tester.tap(find.text('Cancel'));
    await tester.pump();

    expect(find.text('Camera on standby'), findsOneWidget);
    expect(find.text('Start Monitoring'), findsOneWidget);
    expect(find.byType(YOLOView), findsNothing);
  });

  testWidgets('an uncached model also ends in the camera-init stage',
      (tester) async {
    await tester.pumpWidget(FarmGuardApp(
      modelGateway: const _PathModelGateway(cached: false),
      cloudServices: _inertBundle(),
    ));

    await tester.tap(find.text('Start Monitoring'));
    await _pumpUntilPreview(tester);

    final state = tester.state<HomeScreenState>(find.byType(HomeScreen));
    expect(state.debugStartupStage, MonitoringStartupStage.initializingCamera);
    expect(find.text('Initializing camera & detection…'), findsOneWidget);

    await state.stopMonitoring();
    await tester.pump();
  });
}
