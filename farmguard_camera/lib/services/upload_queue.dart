import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../config/detection_config.dart';
import 'api_client.dart';
import 'pending_event_store.dart';

/// Reliable upload queue for confirmed detection events.
///
/// Persists every event immediately, retries failed uploads with
/// exponential backoff + jitter, and only deletes an event from the store
/// after the server confirms it. Permanently failed events are kept and
/// exposed via [failedEvents] — nothing is ever deleted silently.
///
/// Pure Dart + `ChangeNotifier` only. Time is injectable:
/// - the production timer is started explicitly with [start] (tests never
///   call it);
/// - tests drive the queue manually with [processDue] and an explicit
///   `now`, or inject a clock for [enqueue] scheduling.
class UploadQueue extends ChangeNotifier {
  UploadQueue({
    required this.store,
    required this.client,
    this.config = const DetectionConfig(),
    DateTime Function()? clock,
    Random? jitterRandom,
  }) : _clock = clock ?? DateTime.now,
       _jitterRandom = jitterRandom ?? Random();

  final PendingEventStore store;
  final UploadClient client;
  final DetectionConfig config;
  final DateTime Function() _clock;
  final Random _jitterRandom;

  /// In-memory view of the store, kept in sync on every mutation.
  final List<PendingEvent> _events = [];

  /// UTC instant of the most recent server confirmation (null before the
  /// first success).
  DateTime? _lastSyncAt;

  Timer? _timer;

  DateTime? get lastSyncAt => _lastSyncAt;

  /// Events not yet permanently failed (pending or awaiting their next
  /// attempt), oldest first.
  List<PendingEvent> get pendingEvents => List.unmodifiable(_events);

  /// Number of events still waiting for a confirmed upload (permanently
  /// failed events are not counted).
  int get pendingCount => _events.where((event) => !_isFailed(event)).length;

  /// Number of permanently failed events (kept for inspection, never
  /// auto-retried, never deleted silently).
  int get failedCount => _events.where(_isFailed).length;

  /// Permanently failed events.
  List<PendingEvent> get failedEvents =>
      _events.where(_isFailed).toList();

  /// Whether an event has exhausted its attempts.
  bool _isFailed(PendingEvent event) =>
      event.attempts >= config.uploadMaxAttempts;

  /// Loads persisted events back into the queue (call at app startup so
  /// events survive restarts). Restored events keep their idempotency key
  /// and their backoff schedule; an event that was persisted without a
  /// schedule (e.g. the app stopped right after enqueueing) is scheduled
  /// due immediately so it cannot be stranded by a restart.
  Future<void> restore() async {
    final persisted = await store.loadAll();
    final known = _events.map((event) => event.eventId).toSet();
    for (final event in persisted) {
      if (known.contains(event.eventId)) {
        continue;
      }
      var restored = event;
      if (!_isFailed(event) && event.nextAttemptAt == null) {
        restored = event.copyWith(nextAttemptAt: _clock());
        await store.replace(restored);
      }
      _events.add(restored);
    }
    notifyListeners();
  }

  /// Enqueues a new event: persists it immediately and schedules its first
  /// attempt as due at `now`.
  Future<void> enqueue(PendingEvent event) async {
    await store.save(event);
    _events.add(event.copyWith(nextAttemptAt: _clock()));
    notifyListeners();
  }

  /// Attempts every event whose [PendingEvent.nextAttemptAt] is due at or
  /// before [now], in schedule order. Events scheduled in the future and
  /// permanently failed events are skipped.
  ///
  /// Returns the number of upload attempts performed.
  Future<int> processDue({DateTime? now}) async {
    final at = now ?? _clock();
    final due = _events
        .where(
          (event) =>
              !_isFailed(event) &&
              event.nextAttemptAt != null &&
              !event.nextAttemptAt!.isAfter(at),
        )
        .toList()
      ..sort(
        (a, b) => a.nextAttemptAt!.compareTo(b.nextAttemptAt!),
      );

    var attempts = 0;
    for (final event in due) {
      attempts++;
      var updated = event.copyWith(attempts: event.attempts + 1);
      var confirmed = false;
      String? error;
      var permanent = false;
      try {
        confirmed = await client.uploadEvent(
          updated,
          onImageKeyObtained: (eventId, objectKey) async {
            // Cache the R2 object key on the pending event (persisted via
            // store.replace before the alert POST) so a crash between the
            // image upload and the alert never re-uploads the bytes.
            updated = updated.copyWith(imageObjectKey: objectKey);
            await store.replace(updated);
          },
          onImageDropped: (eventId) async {
            // The image can never upload (413/400): drop the bytes and
            // MIME so the event delivers imageless on this and any
            // later attempt.
            updated = updated.copyWith(clearImage: true);
            await store.replace(updated);
          },
        );
      } on PermanentUploadException catch (e) {
        // The server rejected the event for a reason retrying cannot fix:
        // mark it permanently failed right away instead of burning the
        // remaining attempts.
        error = e.toString();
        permanent = true;
      } catch (e) {
        error = e.toString();
      }

      if (confirmed) {
        // Server confirmed: safe to delete locally.
        await store.delete(updated.eventId);
        _events.remove(event);
        _lastSyncAt = at;
      } else {
        error ??= 'upload rejected';
        updated = updated.copyWith(
          lastError: error,
          attempts: permanent ? config.uploadMaxAttempts : null,
          nextAttemptAt: permanent
              ? null
              : _isFailed(updated)
                  // Exhausted: unschedule permanently, keep persisted.
                  ? null
                  : at.add(_backoffDelay(updated.attempts)),
          clearNextAttemptAt: permanent || _isFailed(updated),
        );
        await store.replace(updated);
        final index = _events.indexOf(event);
        _events[index] = updated;
      }
      notifyListeners();
    }
    return attempts;
  }

  /// Retry delay after the n-th failed attempt: `base * multiplier^n`
  /// capped at [DetectionConfig.uploadMaxBackoff], plus up to
  /// `jitter * delay` of random jitter. The first retry therefore comes
  /// `base` after the failure (n is zero-based: `attempts - 1`).
  Duration _backoffDelay(int attempts) {
    final exponent = attempts - 1;
    final baseMicros = config.uploadBackoffBase.inMicroseconds.toDouble();
    final capped = min(
      config.uploadMaxBackoff.inMicroseconds.toDouble(),
      baseMicros * pow(config.uploadBackoffMultiplier, exponent).toDouble(),
    );
    final jitterFraction =
        config.uploadBackoffJitter * _jitterRandom.nextDouble();
    return Duration(
      microseconds: (capped * (1 + jitterFraction)).round(),
    );
  }

  /// Reschedules every permanently failed event for an immediate retry,
  /// resetting its attempt counter (the idempotency key is untouched).
  /// Returns the number of events rescheduled.
  Future<int> retryFailed() async {
    final at = _clock();
    var count = 0;
    for (var index = 0; index < _events.length; index++) {
      final event = _events[index];
      if (!_isFailed(event)) {
        continue;
      }
      final updated = event.copyWith(attempts: 0, nextAttemptAt: at);
      _events[index] = updated;
      await store.replace(updated);
      count++;
    }
    if (count > 0) {
      notifyListeners();
    }
    return count;
  }

  /// Starts the production timer. Tests drive [processDue] manually and
  /// simply never call this.
  void start({Duration interval = const Duration(seconds: 5)}) {
    _timer ??= Timer.periodic(interval, (_) => processDue());
  }

  /// Stops the production timer.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
