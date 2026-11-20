import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config/detection_config.dart';
import 'uuid.dart';

/// A single raw detection delivered for one processed frame.
///
/// The bounding box, when present, uses normalized coordinates (0..1).
/// Kept as a lightweight record so the engine stays unit-testable without
/// any platform dependency.
typedef EngineDetection =
    ({
      String className,
      double confidence,
      ({double left, double top, double width, double height})? box,
    });

/// One confirmed human-presence detection event.
///
/// Presence-only: nothing here identifies a person.
class ConfirmedEvent {
  const ConfirmedEvent({
    required this.eventId,
    required this.confirmedAt,
    required this.confidence,
    required this.personCount,
    this.boundingBox,
  });

  /// UUIDv4 used as the idempotency key when uploading.
  final String eventId;

  /// UTC instant at which presence was confirmed.
  final DateTime confirmedAt;

  /// Confidence of the triggering frame's best person detection.
  final double confidence;

  /// Number of qualifying person detections in the triggering frame.
  final int personCount;

  /// Normalized bounding box of the triggering frame's best person
  /// detection, or null when the model reported no box.
  final ({double left, double top, double width, double height})?
  boundingBox;
}

/// Confirms continuous human presence from a stream of processed frames
/// and emits detection events for the upload queue.
///
/// Pure Dart + `ChangeNotifier` only: no platform channels, no I/O. The
/// frame source pushes frames via [processFrame]; the clock is injectable
/// so cooldown behavior is fully deterministic in tests.
///
/// Confirmation policy (see [DetectionConfig]):
/// - only `person` detections with sufficient confidence count;
/// - presence is confirmed when enough of the last N processed frames were
///   person-present (`3` of `5` by default);
/// - after a confirmation a cooldown must elapse before the next
///   confirmation, so continuous presence yields one event per cooldown
///   period instead of a flood.
class DetectionEventEngine extends ChangeNotifier {
  DetectionEventEngine({
    this.config = const DetectionConfig(),
    this.onEvent,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    if (config.confirmationMinimum > config.confirmationWindow) {
      throw ArgumentError.value(
        config.confirmationMinimum,
        'confirmationMinimum',
        'cannot exceed confirmationWindow',
      );
    }
  }

  final DetectionConfig config;

  /// Optional synchronous callback invoked when an event is confirmed.
  final void Function(ConfirmedEvent event)? onEvent;

  final DateTime Function() _clock;

  /// Broadcast stream of confirmed events, for listeners registered after
  /// construction. Also delivered through [onEvent] for early subscribers.
  Stream<ConfirmedEvent> get eventStream => _eventController.stream;

  final StreamController<ConfirmedEvent> _eventController =
      StreamController<ConfirmedEvent>.broadcast();

  final List<bool> _window = [];

  DateTime? _lastConfirmedAt;
  int _eventCount = 0;

  /// UTC instant of the most recently confirmed event (null before the
  /// first confirmation).
  DateTime? get lastConfirmedAt => _lastConfirmedAt;

  /// Total number of events confirmed since monitoring started.
  int get eventCount => _eventCount;

  /// Whether the cooldown since the last confirmed event has elapsed (a
  /// null [lastConfirmedAt] means no event yet, so confirmation is free).
  bool get cooldownElapsed {
    final last = _lastConfirmedAt;
    if (last == null) {
      return true;
    }
    return _clock().difference(last) >= config.cooldown;
  }

  /// Processes one frame of raw detections.
  ///
  /// Only qualifying person detections (class + confidence threshold)
  /// influence the rolling window; the highest-confidence person detection
  /// provides the event's confidence and bounding box. Presence confirms
  /// as soon as [DetectionConfig.confirmationMinimum] of the frames in the
  /// rolling window were person-present (cooldown permitting).
  void processFrame(Iterable<EngineDetection> detections) {
    final people = <EngineDetection>[];
    for (final detection in detections) {
      if (detection.className != config.personClassName) {
        continue;
      }
      if (detection.confidence < config.confidenceThreshold) {
        continue;
      }
      people.add(detection);
    }
    people.sort((a, b) => b.confidence.compareTo(a.confidence));
    if (people.length > config.maxBoundingBoxes) {
      people.removeRange(config.maxBoundingBoxes, people.length);
    }

    _window.add(people.isNotEmpty);
    if (_window.length > config.confirmationWindow) {
      _window.removeRange(0, _window.length - config.confirmationWindow);
    }

    final presentFrames = _window.where((present) => present).length;
    final windowSatisfied = presentFrames >= config.confirmationMinimum;

    if (windowSatisfied && cooldownElapsed) {
      _confirm(people);
    }
  }

  /// Stops listening on the event stream. The engine itself stays usable
  /// for stats reads.
  @override
  void dispose() {
    _eventController.close();
    super.dispose();
  }

  void _confirm(List<EngineDetection> triggeringPeople) {
    final best = triggeringPeople.first;
    final event = ConfirmedEvent(
      eventId: generateUuidV4(),
      confirmedAt: _clock().toUtc(),
      confidence: best.confidence,
      personCount: triggeringPeople.length,
      boundingBox: best.box,
    );
    _window.clear();
    _lastConfirmedAt = event.confirmedAt;
    _eventCount++;
    onEvent?.call(event);
    _eventController.add(event);
    notifyListeners();
  }
}
