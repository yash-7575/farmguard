import '../models/models.dart';

/// Local mock data for the FarmGuard Farmer frontend.
///
/// Timestamps are computed relative to "now" so the dashboard and history
/// always look live. No networking, no persistence — Phase 1 mock only.
abstract final class MockData {
  static DateTime _ago(Duration d) => DateTime.now().subtract(d);

  static final List<FarmCamera> cameras = <FarmCamera>[
    FarmCamera(
      id: 'cam-main-gate',
      name: 'Main Gate',
      location: 'Farm entrance, north boundary',
      isOnline: true,
      isMonitoring: true,
      lastConnected: _ago(const Duration(minutes: 2)),
    ),
    FarmCamera(
      id: 'cam-cow-shed',
      name: 'Cow Shed',
      location: 'Livestock area, east side',
      isOnline: true,
      isMonitoring: true,
      lastConnected: _ago(const Duration(minutes: 41)),
    ),
    FarmCamera(
      id: 'cam-crop-field',
      name: 'North Crop Field',
      location: 'Irrigated field, north boundary',
      isOnline: true,
      isMonitoring: true,
      lastConnected: _ago(const Duration(minutes: 12)),
    ),
    FarmCamera(
      id: 'cam-pump-house',
      name: 'Pump House',
      location: 'Canal water pump station',
      isOnline: false,
      isMonitoring: true,
      lastConnected: _ago(const Duration(hours: 26)),
    ),
  ];

  /// Newest first.
  static final List<DetectionEvent> events = <DetectionEvent>[
    DetectionEvent(
      id: 'FG-0184',
      cameraId: 'cam-crop-field',
      timestamp: _ago(const Duration(minutes: 34)),
      confidence: 0.96,
      imagePath: 'assets/detections/detection_5.png',
      isViewed: false,
      boxes: <DetectionBox>[
        DetectionBox(left: 0.445, top: 0.425, width: 0.19, height: 0.23),
      ],
    ),
    DetectionEvent(
      id: 'FG-0183',
      cameraId: 'cam-main-gate',
      timestamp: _ago(const Duration(hours: 2, minutes: 8)),
      confidence: 0.92,
      imagePath: 'assets/detections/detection_1.png',
      isViewed: false,
      boxes: <DetectionBox>[
        DetectionBox(left: 0.50, top: 0.435, width: 0.13, height: 0.26),
      ],
    ),
    DetectionEvent(
      id: 'FG-0182',
      cameraId: 'cam-pump-house',
      timestamp: _ago(const Duration(hours: 5, minutes: 26)),
      confidence: 0.88,
      imagePath: 'assets/detections/detection_4.png',
      isViewed: true,
      boxes: <DetectionBox>[
        DetectionBox(left: 0.60, top: 0.44, width: 0.085, height: 0.20),
        DetectionBox(left: 0.655, top: 0.465, width: 0.07, height: 0.175),
      ],
    ),
    DetectionEvent(
      id: 'FG-0181',
      cameraId: 'cam-cow-shed',
      timestamp: _ago(const Duration(hours: 7, minutes: 41)),
      confidence: 0.97,
      imagePath: 'assets/detections/detection_3.png',
      isViewed: true,
      boxes: <DetectionBox>[
        DetectionBox(left: 0.245, top: 0.43, width: 0.11, height: 0.29),
      ],
    ),
    DetectionEvent(
      id: 'FG-0176',
      cameraId: 'cam-pump-house',
      timestamp: _ago(const Duration(hours: 19, minutes: 55)),
      confidence: 0.94,
      imagePath: 'assets/detections/detection_2.png',
      isViewed: true,
      boxes: <DetectionBox>[
        DetectionBox(left: 0.545, top: 0.455, width: 0.125, height: 0.325),
      ],
    ),
    DetectionEvent(
      id: 'FG-0169',
      cameraId: 'cam-main-gate',
      timestamp: _ago(const Duration(hours: 29, minutes: 17)),
      confidence: 0.81,
      imagePath: 'assets/detections/detection_1.png',
      isViewed: true,
      boxes: <DetectionBox>[
        DetectionBox(left: 0.50, top: 0.435, width: 0.13, height: 0.26),
      ],
    ),
  ];

  static FarmCamera? cameraById(String id) {
    for (final FarmCamera camera in cameras) {
      if (camera.id == id) return camera;
    }
    return null;
  }

  static int todayCount(List<DetectionEvent> events, {DateTime? now}) {
    final DateTime reference = now ?? DateTime.now();
    int count = 0;
    for (final DetectionEvent event in events) {
      final DateTime value = event.timestamp;
      if (value.year == reference.year &&
          value.month == reference.month &&
          value.day == reference.day) {
        count++;
      }
    }
    return count;
  }
}
