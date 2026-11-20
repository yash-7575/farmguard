import 'package:flutter/foundation.dart';

/// Immutable snapshot of the detection statistics shown in the UI.
class DetectionSnapshot {
  const DetectionSnapshot({
    this.personCount = 0,
    this.fps = 0,
    this.inferenceMs = 0,
    this.frameCount = 0,
  });

  /// Number of `person` detections in the latest frame (0+; multiple people
  /// in one frame are all counted).
  final int personCount;

  /// Smoothed inference stream rate, in frames per second.
  final double fps;

  /// Smoothed native per-frame processing time, in milliseconds.
  final double inferenceMs;

  /// Total frames received since monitoring started.
  final int frameCount;
}

/// A single detection delivered by the YOLO view, reduced to the fields the
/// statistics tracker needs. Kept lightweight so the service stays
/// unit-testable without any platform dependency.
typedef DetectionItem = ({String className, double confidence});

/// Tracks person detections and performance metrics for the monitoring UI.
///
/// Pure Dart + `ChangeNotifier` only: no platform channels, no I/O — all
/// inputs are provided by the caller, which makes this class directly
/// unit-testable and keeps the UI thread work trivial.
///
/// Detection policy: the COCO `person` class is the only class the
/// application logic counts. No identity recognition is performed.
class DetectionStatsTracker extends ChangeNotifier {
  DetectionSnapshot _snapshot = const DetectionSnapshot();

  DetectionSnapshot get snapshot => _snapshot;

  /// Exponential smoothing factor: 20% of the newest sample, 80% history.
  static const double _smoothing = 0.2;

  /// Records the detections of one analyzed frame.
  void recordDetections(Iterable<DetectionItem> detections) {
    var people = 0;
    for (final detection in detections) {
      if (detection.className == 'person') {
        people++;
      }
    }
    _snapshot = DetectionSnapshot(
      personCount: people,
      fps: _snapshot.fps,
      inferenceMs: _snapshot.inferenceMs,
      frameCount: _snapshot.frameCount + 1,
    );
    notifyListeners();
  }

  /// Records native performance metrics for the current frame.
  void recordMetrics({required double fps, required double inferenceMs}) {
    if (!_metricsSeen) {
      _metricsSeen = true;
      _snapshot = DetectionSnapshot(
        personCount: _snapshot.personCount,
        fps: fps,
        inferenceMs: inferenceMs,
        frameCount: _snapshot.frameCount,
      );
      notifyListeners();
      return;
    }
    _snapshot = DetectionSnapshot(
      personCount: _snapshot.personCount,
      fps: _smooth(_snapshot.fps, fps),
      inferenceMs: _smooth(_snapshot.inferenceMs, inferenceMs),
      frameCount: _snapshot.frameCount,
    );
    notifyListeners();
  }

  /// Clears all statistics (used when monitoring stops).
  void reset() {
    _snapshot = const DetectionSnapshot();
    _metricsSeen = false;
    notifyListeners();
  }

  double _smooth(double previous, double next) =>
      previous * (1 - _smoothing) + next * _smoothing;

  /// Whether any metric sample has been recorded yet. The first sample is
  /// adopted directly instead of being smoothed up from zero.
  bool _metricsSeen = false;
}
