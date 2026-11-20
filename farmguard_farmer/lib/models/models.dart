/// Domain models for the FarmGuard Farmer frontend (Phase 1: local mock data).
library;

/// A farm security camera.
class FarmCamera {
  final String id;
  final String name;
  final String location;

  /// Whether the camera is reachable right now.
  final bool isOnline;

  /// Whether the camera is currently included in person-detection monitoring.
  final bool isMonitoring;

  /// Last time the app saw this camera connected. `null` if never connected.
  final DateTime? lastConnected;

  const FarmCamera({
    required this.id,
    required this.name,
    required this.location,
    required this.isOnline,
    required this.isMonitoring,
    required this.lastConnected,
  });
}

/// A normalized bounding box drawn over a captured frame.
///
/// All values are fractions of the image width/height (0.0–1.0), so the box
/// stays aligned at any rendered size.
class DetectionBox {
  final double left;
  final double top;
  final double width;
  final double height;

  const DetectionBox({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });
}

/// A person-detection event captured by a camera.
class DetectionEvent {
  final String id;
  final String cameraId;
  final DateTime timestamp;

  /// Detection confidence between 0.0 and 1.0.
  final double confidence;

  /// Bundled asset path of the captured frame.
  final String imagePath;
  final List<DetectionBox> boxes;

  /// Mutated when the farmer opens the event (mark-as-viewed).
  bool isViewed;

  /// Whether this event is a staged demo record rather than a live camera
  /// detection. Mock data records are demo by default; API-mapped events
  /// are constructed with `isDemo: false`.
  ///
  /// UI rule: demo records must always be labelled "DEMO" wherever shown.
  /// A "LIVE" label may only appear for events created with `isDemo: false`
  /// straight from the backend — it must never be fabricated.
  final bool isDemo;

  DetectionEvent({
    required this.id,
    required this.cameraId,
    required this.timestamp,
    required this.confidence,
    required this.imagePath,
    required this.boxes,
    required this.isViewed,
    this.isDemo = true,
  });

  bool get isNew => !isViewed;
}
