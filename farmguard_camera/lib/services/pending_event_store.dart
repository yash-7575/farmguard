import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// A confirmed detection event waiting to be uploaded to the backend.
///
/// The event is persisted locally until the server confirms the upload, so
/// it survives app restarts and network outages. Mutations (attempts,
/// backoff schedule, errors) go through [copyWith] + `PendingEventStore.
/// replace` to keep the model immutable.
class PendingEvent {
  PendingEvent({
    required this.eventId,
    this.cameraId = '',
    this.detectionType = 'person',
    required this.confidence,
    required this.personCount,
    required this.capturedAt,
    required this.createdAt,
    this.boundingBox,
    this.imageBytes,
    this.imageContentType,
    this.imageObjectKey,
    this.sourceType = 'LIVE',
    this.attempts = 0,
    this.nextAttemptAt,
    this.lastError,
  });

  /// UUIDv4 generated at confirmation time. Doubles as the idempotency
  /// key: it never changes across retries.
  final String eventId;

  /// Camera identifier; filled in during the wiring task (defaulted '' for
  /// now).
  final String cameraId;

  /// What was detected. Only presence classes are used ('person').
  final String detectionType;

  /// Confidence of the best detection in the triggering frame.
  final double confidence;

  /// Number of qualifying detections in the triggering frame.
  final int personCount;

  /// UTC ISO-8601 timestamp of when presence was confirmed.
  final String capturedAt;

  /// Local creation timestamp (for ordering and diagnostics).
  final DateTime createdAt;

  /// Normalized bounding box of the best detection, when available.
  final ({double left, double top, double width, double height})?
  boundingBox;

  /// Snapshot bytes for the event, if the capture task produced one. The
  /// queue tolerates null images.
  final Uint8List? imageBytes;

  /// MIME type of [imageBytes], when present.
  final String? imageContentType;

  /// R2 object key of the already-uploaded snapshot
  /// (`events/<yyyy-MM>/<uuid>.jpg`), cached after a successful image
  /// upload so retries never re-upload the bytes. Null until the image
  /// upload succeeds.
  final String? imageObjectKey;

  /// How the event was produced ('LIVE' for the camera pipeline).
  final String sourceType;

  /// Number of upload attempts made so far.
  final int attempts;

  /// Earliest instant of the next attempt; null means unscheduled (either
  /// not yet scheduled or permanently failed).
  final DateTime? nextAttemptAt;

  /// Description of the last upload failure, when any.
  final String? lastError;

  PendingEvent copyWith({
    String? cameraId,
    String? detectionType,
    double? confidence,
    int? personCount,
    String? capturedAt,
    ({double left, double top, double width, double height})? boundingBox,
    Uint8List? imageBytes,
    bool clearImage = false,
    String? imageContentType,
    String? imageObjectKey,
    String? sourceType,
    int? attempts,
    DateTime? nextAttemptAt,
    bool clearNextAttemptAt = false,
    String? lastError,
    bool clearLastError = false,
  }) {
    return PendingEvent(
      eventId: eventId,
      cameraId: cameraId ?? this.cameraId,
      detectionType: detectionType ?? this.detectionType,
      confidence: confidence ?? this.confidence,
      personCount: personCount ?? this.personCount,
      capturedAt: capturedAt ?? this.capturedAt,
      createdAt: createdAt,
      boundingBox: boundingBox ?? this.boundingBox,
      imageBytes: clearImage ? null : (imageBytes ?? this.imageBytes),
      // clearImage drops the whole snapshot (bytes + MIME): the image
      // failed permanently (e.g. HTTP 413 too large) and must not be
      // retried, while the event metadata still uploads.
      imageContentType:
          clearImage ? null : (imageContentType ?? this.imageContentType),
      imageObjectKey: imageObjectKey ?? this.imageObjectKey,
      sourceType: sourceType ?? this.sourceType,
      attempts: attempts ?? this.attempts,
      nextAttemptAt: clearNextAttemptAt
          ? null
          : (nextAttemptAt ?? this.nextAttemptAt),
      lastError: clearLastError ? null : (lastError ?? this.lastError),
    );
  }

  @override
  String toString() =>
      'PendingEvent($eventId, type=$detectionType, attempts=$attempts)';
}

/// Local persistence for pending events.
///
/// The production implementation is file-backed (path_provider) and arrives
/// with the later wiring task; tests and the queue use
/// [InMemoryPendingEventStore]. Pure Dart only.
abstract class PendingEventStore {
  /// Persists a new event.
  Future<void> save(PendingEvent event);

  /// Loads every persisted event (used to restore state at startup).
  Future<List<PendingEvent>> loadAll();

  /// Removes an event once the server has confirmed its upload.
  Future<void> delete(String eventId);

  /// Overwrites an already-persisted event (attempts/backoff updates).
  Future<void> replace(PendingEvent event);
}

/// Ephemeral in-memory implementation used by tests (and until the
/// file-backed store is wired).
class InMemoryPendingEventStore implements PendingEventStore {
  final Map<String, PendingEvent> _events = {};

  @override
  Future<void> save(PendingEvent event) async {
    _events[event.eventId] = event;
  }

  @override
  Future<List<PendingEvent>> loadAll() async =>
      _events.values.map((event) => event.copyWith()).toList();

  @override
  Future<void> delete(String eventId) async {
    _events.remove(eventId);
  }

  @override
  Future<void> replace(PendingEvent event) async {
    if (!_events.containsKey(event.eventId)) {
      throw StateError('Cannot replace unknown event ${event.eventId}');
    }
    _events[event.eventId] = event;
  }
}

/// Callback fired when the image upload produced a durable R2 object key.
/// The queue persists the key on the pending event (`store.replace`) so a
/// crash between the image upload and the alert POST never re-uploads
/// the bytes on retry.
typedef OnImageKeyObtained = Future<void> Function(
    String eventId, String objectKey);

/// Callback fired when the snapshot was dropped because it can never
/// upload successfully (e.g. HTTP 413 too large, HTTP 400 rejected). The
/// queue persists the event without the image so the retry delivers the
/// detection metadata imageless instead of failing forever.
typedef OnImageDropped = Future<void> Function(String eventId);

/// Backend HTTP client for confirmed events.
///
/// Implementations return `true` only when the server has durably accepted
/// the event (that is when the local copy may be deleted). Any failure —
/// thrown exception or `false` — leaves the event pending. The later
/// wiring task provides the real HTTP implementation.
abstract class UploadClient {
  Future<bool> uploadEvent(
    PendingEvent event, {
    OnImageKeyObtained? onImageKeyObtained,
    OnImageDropped? onImageDropped,
  });
}

/// Scripted upload client for tests.
///
/// Outcomes are consumed in order per call; the last outcome repeats once
/// the script is exhausted. Records every attempted event id so tests can
/// assert on the attempt sequence.
class FakeUploadClient implements UploadClient {
  FakeUploadClient({List<bool>? outcomes, this.throws = const []})
    : outcomes = outcomes ?? [true];
  /// Outcome per call: `true` = server confirmed, `false` = rejected.
  final List<bool> outcomes;

  /// Per-call exceptions to throw (before consulting [outcomes]).
  final List<Object?> throws;

  final List<String> attemptedEventIds = [];
  final List<PendingEvent> attemptedEvents = [];

  int _callIndex = 0;

  @override
  Future<bool> uploadEvent(
    PendingEvent event, {
    OnImageKeyObtained? onImageKeyObtained,
    OnImageDropped? onImageDropped,
  }) {
    attemptedEventIds.add(event.eventId);
    attemptedEvents.add(event);
    final index = _callIndex++;
    if (index < throws.length && throws[index] != null) {
      throw throws[index]!;
    }
    final outcome = index < outcomes.length
        ? outcomes[index]
        : outcomes.last;
    return Future<bool>.value(outcome);
  }
}
