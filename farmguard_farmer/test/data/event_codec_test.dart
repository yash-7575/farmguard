import 'package:flutter_test/flutter_test.dart';

import 'package:farmguard_farmer/data/event_codec.dart';
import 'package:farmguard_farmer/models/models.dart';
import 'package:farmguard_farmer/services/api/farmer_api.dart';

void main() {
  group('apiImagePath', () {
    test('builds the non-asset api: marker scheme', () {
      expect(apiImagePath('evt-9'), 'api:/api/v1/images/evt-9');
      expect(
        apiImagePath('evt-9').startsWith(kApiImagePathPrefix),
        isTrue,
      );
    });
  });

  group('toFarmCamera', () {
    test('status mapping and null-safe last_seen_at', () {
      // Uses a JSON row map directly — the camera row is never pre-typed.
      final row = <String, dynamic>{
        'id': 'cam-1',
        'camera_name': 'Main Gate',
        'location': 'North boundary',
        'status': 'monitoring',
        'last_seen_at': '2026-11-18T09:00:00.000Z',
      };

      // Fixed reference time so the fixture heartbeat is inside the online
      // window regardless of when the suite runs.
      final camera = toFarmCamera(row, now: DateTime.utc(2026, 11, 18, 9, 1));

      expect(camera.id, 'cam-1');
      expect(camera.name, 'Main Gate');
      expect(camera.location, 'North boundary');
      expect(camera.isOnline, isTrue);
      expect(camera.isMonitoring, isTrue);
      expect(camera.lastConnected, DateTime.utc(2026, 11, 18, 9));
    });

    test('offline camera with never-seen timestamp', () {
      final camera = toFarmCamera(<String, dynamic>{
        'id': 'cam-2',
        'camera_name': 'Pump House',
        'location': 'Canal',
        'status': 'offline',
        'last_seen_at': null,
      });

      expect(camera.isOnline, isFalse);
      expect(camera.isMonitoring, isFalse);
      expect(camera.lastConnected, isNull);
    });

    test('fresh heartbeat (<= 120 s) keeps status online/monitoring', () {
      final DateTime now = DateTime.utc(2026, 11, 19, 12);
      final FarmCamera online = toFarmCamera(
        <String, dynamic>{
          'id': 'cam-3',
          'camera_name': 'Cow Shed',
          'location': 'South field',
          'status': 'online',
          'last_seen_at': now
              .subtract(const Duration(seconds: 90))
              .toIso8601String(),
        },
        now: now,
      );
      final FarmCamera monitoring = toFarmCamera(
        <String, dynamic>{
          'id': 'cam-4',
          'camera_name': 'North Crop Field',
          'location': 'North field',
          'status': 'monitoring',
          'last_seen_at': now
              .subtract(const Duration(seconds: 120))
              .toIso8601String(),
        },
        now: now,
      );

      expect(online.isOnline, isTrue);
      expect(online.isMonitoring, isFalse);
      // Exactly at the threshold still counts as online.
      expect(monitoring.isOnline, isTrue);
      expect(monitoring.isMonitoring, isTrue);
      expect(kCameraOnlineThreshold, const Duration(seconds: 120));
    });

    test('stale heartbeat (> 120 s) → offline even when status says online',
        () {
      final DateTime now = DateTime.utc(2026, 11, 19, 12);
      final FarmCamera camera = toFarmCamera(
        <String, dynamic>{
          'id': 'cam-5',
          'camera_name': 'Main Gate',
          'location': 'North boundary',
          'status': 'monitoring',
          'last_seen_at': now
              .subtract(const Duration(seconds: 121))
              .toIso8601String(),
        },
        now: now,
      );

      expect(camera.isOnline, isFalse);
      expect(camera.isMonitoring, isFalse);
      // The heartbeat time itself is still reported for "last connected".
      expect(
        camera.lastConnected,
        now.subtract(const Duration(seconds: 121)),
      );
    });

    test('null heartbeat → offline even when status says online', () {
      final DateTime now = DateTime.utc(2026, 11, 19, 12);
      final FarmCamera camera = toFarmCamera(
        <String, dynamic>{
          'id': 'cam-6',
          'camera_name': 'Pump House',
          'location': 'Canal',
          'status': 'online',
          'last_seen_at': null,
        },
        now: now,
      );

      expect(camera.isOnline, isFalse);
      expect(camera.isMonitoring, isFalse);
      expect(camera.lastConnected, isNull);
    });
  });

  group('toDetectionEvent', () {
    test('maps a LIVE row to domain fields with api: image scheme', () {
      final row = ApiDetectionEvent(
        id: 'evt-1',
        farmerId: 'farmer-1',
        cameraId: 'cam-1',
        detectionType: 'person',
        confidence: 0.93,
        imageObjectKey: 'images/evt-1.jpg',
        imageContentType: 'image/jpeg',
        imageSize: 1024,
        boundingBox: const <ApiBoundingBox>[
          ApiBoundingBox(left: 0.2, top: 0.3, width: 0.4, height: 0.5),
        ],
        sourceType: 'LIVE',
        detectedAt: DateTime.utc(2026, 11, 18, 10, 15),
        createdAt: DateTime.utc(2026, 11, 18, 10, 15, 1),
        viewedAt: null,
        idempotencyKey: 'idem-1',
      );

      final event = toDetectionEvent(row);

      expect(event.id, 'evt-1');
      expect(event.cameraId, 'cam-1');
      expect(event.timestamp, DateTime.utc(2026, 11, 18, 10, 15));
      expect(event.confidence, 0.93);
      expect(event.imagePath, 'api:/api/v1/images/evt-1');
      expect(event.isViewed, isFalse);
      expect(event.isDemo, isFalse);
      expect(event.boxes, hasLength(1));
      expect(event.boxes[0].left, 0.2);
      expect(event.boxes[0].top, 0.3);
      expect(event.boxes[0].width, 0.4);
      expect(event.boxes[0].height, 0.5);
    });

    test('null bounding_box → empty box list; viewed_at set → isViewed', () {
      final row = ApiDetectionEvent(
        id: 'evt-2',
        farmerId: 'farmer-1',
        cameraId: 'cam-2',
        detectionType: 'person',
        confidence: 0.5,
        imageObjectKey: null,
        imageContentType: null,
        imageSize: null,
        boundingBox: null,
        sourceType: 'LIVE',
        detectedAt: DateTime.utc(2026, 11, 18),
        createdAt: DateTime.utc(2026, 11, 18),
        viewedAt: DateTime.utc(2026, 11, 18, 12),
        idempotencyKey: 'idem-2',
      );

      final event = toDetectionEvent(row);

      expect(event.boxes, isEmpty);
      expect(event.isViewed, isTrue);
      expect(event.isDemo, isFalse);
    });

    test('DEMO source_type rows map to isDemo true (always labelled DEMO)',
        () {
      final row = ApiDetectionEvent(
        id: 'evt-3',
        farmerId: 'farmer-1',
        cameraId: 'cam-1',
        detectionType: 'person',
        confidence: 0.99,
        imageObjectKey: null,
        imageContentType: null,
        imageSize: null,
        boundingBox: null,
        sourceType: 'DEMO',
        detectedAt: DateTime.utc(2026, 11, 18),
        createdAt: DateTime.utc(2026, 11, 18),
        viewedAt: null,
        idempotencyKey: 'idem-3',
      );

      expect(toDetectionEvent(row).isDemo, isTrue);
    });
  });

  group('mock records', () {
    test('mock-style construction defaults to isDemo true', () {
      // Exactly how mock_data.dart constructs events — no isDemo argument.
      final event = DetectionEvent(
        id: 'FG-0184',
        cameraId: 'cam-crop-field',
        timestamp: DateTime.now(),
        confidence: 0.96,
        imagePath: 'assets/detections/detection_5.png',
        isViewed: false,
        boxes: <DetectionBox>[],
      );

      expect(event.isDemo, isTrue);
      // Asset path is untouched and distinguishable from api: markers.
      expect(event.imagePath, startsWith('assets/'));
      expect(event.imagePath.startsWith(kApiImagePathPrefix), isFalse);
    });
  });

  group('parseIso8601Utc', () {
    test('null/empty → null; ISO strings → UTC', () {
      expect(parseIso8601Utc(null), isNull);
      expect(parseIso8601Utc(''), isNull);
      expect(
        parseIso8601Utc('2026-11-18T10:15:00.000Z'),
        DateTime.utc(2026, 11, 18, 10, 15),
      );
    });
  });
}
