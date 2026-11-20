// Widget tests for the FarmGuard Camera monitoring state machine.
//
// The camera-permission channel is mocked; the model resolver and platform
// view are not — in the test environment their platform channels are absent,
// which exercises the graceful error path. Live detection itself can only be
// verified on a physical Android device.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:farmguard_camera/main.dart';
import 'package:farmguard_camera/services/detection_stats.dart';
import 'package:farmguard_camera/services/model_gateway.dart';
import 'package:farmguard_camera/widgets/detection_stats_bar.dart';

/// Gateway that always fails, simulating download/load errors.
class _FailingModelGateway implements ModelGateway {
  const _FailingModelGateway();
  @override
  Future<bool> isModelAvailableLocally(String modelId) async => false;

  @override
  Future<String> resolveModel(String modelId) async =>
      throw Exception('Simulated model download failure');
}

void main() {
  // Permission-channel mock shared by the state-machine tests below.
  Future<Object?>? Function(MethodCall)? permissionHandler;

  setUp(() {
    permissionHandler = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('farmguard_camera/settings'),
      (call) async {
        switch (call.method) {
          case 'requestCameraPermission':
            return permissionHandler?.call(call) ?? 'granted';
          case 'openAppSettings':
            return null;
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
  });

  testWidgets('idle screen shows placeholder and start control',
      (WidgetTester tester) async {
    await tester.pumpWidget(const FarmGuardApp());

    expect(find.text('FarmGuard Camera'), findsWidgets);
    expect(find.text('Smart Farm Surveillance'), findsOneWidget);
    expect(find.text('Camera on standby'), findsOneWidget);
    expect(find.text('Start Monitoring'), findsOneWidget);
  });

  testWidgets('permission denial shows the denied state',
      (WidgetTester tester) async {
    permissionHandler = (_) async => 'denied';
    await tester.pumpWidget(const FarmGuardApp());

    await tester.tap(find.text('Start Monitoring'));
    await tester.pumpAndSettle();

    expect(find.text('Camera permission denied'), findsOneWidget);
    expect(find.text('Try Again'), findsOneWidget);
  });

  testWidgets('repeated denial risk shows the permanently-denied state',
      (WidgetTester tester) async {
    permissionHandler = (_) async => 'permanentlyDenied';
    await tester.pumpWidget(const FarmGuardApp());

    await tester.tap(find.text('Start Monitoring'));
    await tester.pumpAndSettle();

    expect(find.text('Camera access is turned off'), findsOneWidget);
    expect(find.text('Open Settings'), findsOneWidget);
    expect(find.text('Try Again'), findsOneWidget);
  });

  testWidgets('model load failure shows the error state gracefully',
      (WidgetTester tester) async {
    // Permission granted, but the model gateway fails → the failure must
    // land in the error state with a retry action.
    permissionHandler = (_) async => 'granted';
    await tester.pumpWidget(const FarmGuardApp(
      modelGateway: _FailingModelGateway(),
    ));

    await tester.tap(find.text('Start Monitoring'));
    await tester.pumpAndSettle();

    expect(find.text('Camera error'), findsOneWidget);
    expect(find.textContaining('Simulated model download failure'),
        findsOneWidget);
    expect(find.text('Try Again'), findsOneWidget);
  });

  testWidgets('stats bar renders model, count, fps and latency',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        ),
        home: Scaffold(
          body: DetectionStatsBar(
            snapshot: const DetectionSnapshot(
              personCount: 3,
              fps: 14.5,
              inferenceMs: 33.2,
              frameCount: 100,
            ),
            modelLabel: 'YOLO26s · W8A32',
          ),
        ),
      ),
    );

    expect(find.text('YOLO26s · W8A32'), findsOneWidget);
    expect(find.text('People: 3'), findsOneWidget);
    expect(find.text('14.5 FPS'), findsOneWidget);
    expect(find.text('33.2 ms'), findsOneWidget);
  });
}
