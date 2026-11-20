// Unit tests for the detection statistics service.
//
// The service is pure Dart: no platform channels or I/O, so all behavior is
// exercised directly.

import 'package:flutter_test/flutter_test.dart';
import 'package:farmguard_camera/services/detection_stats.dart';

void main() {
  group('DetectionStatsTracker', () {
    test('counts only COCO person detections', () {
      final tracker = DetectionStatsTracker();

      tracker.recordDetections(const [
        (className: 'person', confidence: 0.91),
        (className: 'car', confidence: 0.84),
        (className: 'person', confidence: 0.73),
        (className: 'dog', confidence: 0.66),
      ]);

      expect(tracker.snapshot.personCount, 2);
      expect(tracker.snapshot.frameCount, 1);
    });

    test('multiple people in one frame are all counted', () {
      final tracker = DetectionStatsTracker();

      tracker.recordDetections(const [
        (className: 'person', confidence: 0.9),
        (className: 'person', confidence: 0.8),
        (className: 'person', confidence: 0.7),
        (className: 'person', confidence: 0.6),
      ]);

      expect(tracker.snapshot.personCount, 4);
    });

    test('frames without people report zero', () {
      final tracker = DetectionStatsTracker();

      tracker.recordDetections(const [
        (className: 'cow', confidence: 0.9),
        (className: 'tractor', confidence: 0.5),
      ]);

      expect(tracker.snapshot.personCount, 0);
      expect(tracker.snapshot.frameCount, 1);
    });

    test('metrics are exponentially smoothed', () {
      final tracker = DetectionStatsTracker();

      tracker.recordMetrics(fps: 10, inferenceMs: 40);
      expect(tracker.snapshot.fps, closeTo(10, 0.001));
      expect(tracker.snapshot.inferenceMs, closeTo(40, 0.001));

      // 20% of the new sample, 80% of the previous value.
      tracker.recordMetrics(fps: 20, inferenceMs: 20);
      expect(tracker.snapshot.fps, closeTo(12, 0.001));
      expect(tracker.snapshot.inferenceMs, closeTo(36, 0.001));

      tracker.recordMetrics(fps: 20, inferenceMs: 20);
      expect(tracker.snapshot.fps, closeTo(13.6, 0.001));
      expect(tracker.snapshot.inferenceMs, closeTo(32.8, 0.001));
    });

    test('detection recording does not clobber metrics and vice versa', () {
      final tracker = DetectionStatsTracker();

      tracker.recordMetrics(fps: 12, inferenceMs: 30);
      tracker.recordDetections(const [
        (className: 'person', confidence: 0.9),
      ]);

      expect(tracker.snapshot.fps, closeTo(12, 0.001));
      expect(tracker.snapshot.inferenceMs, closeTo(30, 0.001));
      expect(tracker.snapshot.personCount, 1);
    });

    test('reset clears all statistics and notifies listeners', () {
      final tracker = DetectionStatsTracker();
      var notified = 0;
      tracker.addListener(() => notified++);

      tracker.recordDetections(const [
        (className: 'person', confidence: 0.9),
      ]);
      tracker.recordMetrics(fps: 15, inferenceMs: 25);
      tracker.reset();

      expect(tracker.snapshot.personCount, 0);
      expect(tracker.snapshot.fps, 0);
      expect(tracker.snapshot.inferenceMs, 0);
      expect(tracker.snapshot.frameCount, 0);
      expect(notified, 3);
    });
  });
}
