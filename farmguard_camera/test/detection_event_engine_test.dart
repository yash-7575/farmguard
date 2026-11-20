import 'package:flutter_test/flutter_test.dart';
import 'package:farmguard_camera/config/detection_config.dart';
import 'package:farmguard_camera/services/detection_event_engine.dart';

const _defaultConfig = DetectionConfig();

EngineDetection _person(
  double confidence, {
  ({double left, double top, double width, double height})? box,
}) => (className: 'person', confidence: confidence, box: box);

EngineDetection _other(String className, double confidence) =>
    (className: className, confidence: confidence, box: null);

void main() {
  group('DetectionEventEngine', () {
    test('3-of-5 person frames confirms exactly one event', () {
      var now = DateTime.utc(2026, 1, 1, 12, 0, 0);
      final events = <ConfirmedEvent>[];
      final engine = DetectionEventEngine(
        config: _defaultConfig,
        clock: () => now,
        onEvent: events.add,
      );

      engine.processFrame([]);
      engine.processFrame([_person(0.9)]);
      engine.processFrame([]);
      engine.processFrame([_person(0.9)]);
      engine.processFrame([_person(0.9)]);

      expect(events.length, 1);
      expect(engine.eventCount, 1);
      expect(
        events.single.confirmedAt,
        DateTime.utc(2026, 1, 1, 12, 0, 0),
      );
      expect(events.single.confidence, closeTo(0.9, 1e-9));
    });

    test('2-of-5 person frames never confirms', () {
      final events = <ConfirmedEvent>[];
      var now = DateTime.utc(2026, 1, 1);
      final engine = DetectionEventEngine(
        clock: () => now,
        onEvent: events.add,
      );

      engine.processFrame([_person(0.9)]);
      engine.processFrame([]);
      engine.processFrame([]);
      engine.processFrame([_person(0.9)]);
      engine.processFrame([]);
      engine.processFrame([_person(0.9)]); // still only 2 of last 5

      expect(events, isEmpty);
      expect(engine.eventCount, 0);
    });

    test('continuous presence emits the second event only after cooldown', () {
      var now = DateTime.utc(2026, 1, 1, 8, 0, 0);
      final events = <ConfirmedEvent>[];
      final engine = DetectionEventEngine(
        clock: () => now,
        onEvent: events.add,
      );

      // Confirm the first event (window of 5 fills with person frames).
      for (var i = 0; i < 5; i++) {
        engine.processFrame([_person(0.9)]);
      }
      expect(events.length, 1);

      // More person frames immediately after: window stays satisfied, but
      // cooldown blocks a duplicate event.
      for (var i = 0; i < 5; i++) {
        engine.processFrame([_person(0.9)]);
      }
      expect(events.length, 1);

      // Cooldown not yet elapsed (29s later) — still blocked.
      now = DateTime.utc(2026, 1, 1, 8, 0, 29);
      engine.processFrame([_person(0.9)]);
      expect(events.length, 1);

      // Cooldown elapsed (next frame at +31s) — second event confirms.
      now = DateTime.utc(2026, 1, 1, 8, 0, 31);
      engine.processFrame([_person(0.9)]);
      expect(events.length, 2);
      expect(events[1].confirmedAt, now);
      expect(engine.lastConfirmedAt, now);
    });

    test('non-person classes and low confidences never confirm', () {
      final events = <ConfirmedEvent>[];
      final engine = DetectionEventEngine(
        clock: () => DateTime.utc(2026, 1, 1),
        onEvent: events.add,
      );

      for (var i = 0; i < 6; i++) {
        engine.processFrame([
          _other('cow', 0.99),
          _other('car', 0.95),
          _person(0.49), // below threshold
          _person(0.30), // below threshold
        ]);
      }

      expect(events, isEmpty);
      expect(engine.eventCount, 0);
    });

    test('threshold boundary: confidence exactly at threshold counts', () {
      final events = <ConfirmedEvent>[];
      final engine = DetectionEventEngine(
        clock: () => DateTime.utc(2026, 1, 1),
        onEvent: events.add,
      );

      for (var i = 0; i < 5; i++) {
        engine.processFrame([_person(0.50)]);
      }

      expect(events.length, 1);
      expect(events.single.confidence, closeTo(0.5, 1e-9));
    });

    test('event payload sanity: UTC timestamp, uuid format, box, count', () {
      final now = DateTime.utc(2026, 3, 14, 15, 9, 26);
      final events = <ConfirmedEvent>[];
      final engine = DetectionEventEngine(
        clock: () => now,
        onEvent: events.add,
      );

      engine.processFrame([_person(0.80)]);
      engine.processFrame([_person(0.85)]);
      // Triggering frame: its best detection provides confidence and box.
      engine.processFrame([
        _person(0.87),
        _person(
          0.92,
          box: (left: 0.1, top: 0.2, width: 0.3, height: 0.4),
        ),
        _person(0.86),
        _other('dog', 0.8),
      ]);

      expect(events.length, 1);
      final event = events.single;
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(event.eventId),
        isTrue,
      );
      expect(event.confirmedAt.isUtc, isTrue);
      expect(event.confirmedAt, now);
      expect(event.confidence, closeTo(0.92, 1e-9));
      expect(event.personCount, 3);
      expect(event.boundingBox, isNotNull);
      expect(event.boundingBox!.left, closeTo(0.1, 1e-9));
      expect(event.boundingBox!.top, closeTo(0.2, 1e-9));
      expect(event.boundingBox!.width, closeTo(0.3, 1e-9));
      expect(event.boundingBox!.height, closeTo(0.4, 1e-9));
    });

    test('box is null when the qualifying detection had no box', () {
      final events = <ConfirmedEvent>[];
      final engine = DetectionEventEngine(
        clock: () => DateTime.utc(2026, 1, 1),
        onEvent: events.add,
      );

      engine.processFrame([_person(0.9)]);
      engine.processFrame([_person(0.9)]);
      engine.processFrame([_person(0.9)]);

      expect(events.single.boundingBox, isNull);
    });

    test('event is also delivered on the broadcast stream', () async {
      final events = <ConfirmedEvent>[];
      final engine = DetectionEventEngine(clock: () => DateTime.utc(2026));
      final subscription = engine.eventStream.listen(events.add);
      addTearDown(subscription.cancel);

      for (var i = 0; i < 3; i++) {
        engine.processFrame([_person(0.9)]);
      }
      await Future<void>.delayed(Duration.zero);

      expect(events.length, 1);
    });

    test('custom config tightens confirmation and cooldown', () {
      var now = DateTime.utc(2026, 1, 1);
      final events = <ConfirmedEvent>[];
      final engine = DetectionEventEngine(
        config: const DetectionConfig(
          confirmationWindow: 3,
          confirmationMinimum: 2,
          cooldown: Duration(seconds: 5),
        ),
        clock: () => now,
        onEvent: events.add,
      );

      engine.processFrame([_person(0.9)]); // 1/3 — below minimum
      expect(events.length, 0);
      engine.processFrame([_person(0.9)]); // 2/3 → confirm
      expect(events.length, 1);

      engine.processFrame([_person(0.9)]); // in cooldown
      expect(events.length, 1);

      now = now.add(const Duration(seconds: 6));
      engine.processFrame([_person(0.9)]); // 3/3 + cooldown elapsed
      expect(events.length, 2);
    });

    test('rejects minimum greater than window', () {
      expect(
        () => DetectionEventEngine(
          config: const DetectionConfig(
            confirmationWindow: 3,
            confirmationMinimum: 4,
          ),
        ),
        throwsArgumentError,
      );
    });
  });
}
