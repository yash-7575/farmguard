import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:farmguard_camera/config/detection_config.dart';
import 'package:farmguard_camera/services/pending_event_store.dart';
import 'package:farmguard_camera/services/upload_queue.dart';

final _utcIsoPattern = RegExp(
  r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$',
);

const _noJitter = DetectionConfig(uploadBackoffJitter: 0);

PendingEvent _event(
  String id, {
  double confidence = 0.9,
  Uint8List? image,
}) => PendingEvent(
  eventId: id,
  confidence: confidence,
  personCount: 1,
  capturedAt: DateTime.utc(2026, 1, 1, 9, 30).toIso8601String(),
  createdAt: DateTime.utc(2026, 1, 1, 9, 30),
  boundingBox: (left: 0.1, top: 0.2, width: 0.3, height: 0.4),
  imageBytes: image,
  imageContentType: image == null ? null : 'image/jpeg',
);

/// Upload client mimicking the image-flow contract of the real client:
/// it "uploads" the image (fires [OnImageKeyObtained]) only when the
/// event carries bytes and no cached key — or, with [dropImage], fires
/// [OnImageDropped] instead — and the alert outcome comes from
/// [outcomes] in order (last repeats).
class _ImageFlowClient implements UploadClient {
  _ImageFlowClient({required this.outcomes, this.dropImage = false});

  final List<bool> outcomes;
  final bool dropImage;

  final List<PendingEvent> seen = [];

  /// Cached keys observed on events that already carried one (i.e. the
  /// image was NOT re-uploaded for them).
  final List<String> uploadedImageKeys = [];
  int callCount = 0;

  @override
  Future<bool> uploadEvent(
    PendingEvent event, {
    OnImageKeyObtained? onImageKeyObtained,
    OnImageDropped? onImageDropped,
  }) async {
    seen.add(event);
    final index = min(callCount++, outcomes.length - 1);
    if (event.imageBytes != null && event.imageObjectKey == null) {
      if (dropImage) {
        await onImageDropped?.call(event.eventId);
      } else {
        await onImageKeyObtained?.call(
          event.eventId,
          'events/2026-11/cached.jpg',
        );
      }
    } else if (event.imageObjectKey != null) {
      uploadedImageKeys.add(event.imageObjectKey!);
    }
    return outcomes[index];
  }
}

void main() {
  group('UploadQueue', () {
    test('enqueue persists to the store and is immediately due', () async {
      final store = InMemoryPendingEventStore();
      var now = DateTime.utc(2026, 1, 1, 10, 0);
      final client = FakeUploadClient(outcomes: [false]);
      final queue = UploadQueue(store: store, client: client, clock: () => now);

      await queue.enqueue(_event('evt-1'));

      expect((await store.loadAll()).length, 1);
      expect(queue.pendingCount, 1);
      expect(queue.failedCount, 0);

      // First attempt happens on the first processDue.
      final attempts = await queue.processDue(now: now);
      expect(attempts, 1);
      expect(client.attemptedEventIds, ['evt-1']);
      expect(queue.pendingCount, 1); // attempt failed, still pending
    });

    test('success deletes from the store and sets lastSyncAt', () async {
      final store = InMemoryPendingEventStore();
      var now = DateTime.utc(2026, 1, 1, 10, 0);
      final client = FakeUploadClient(outcomes: [true]);
      final queue = UploadQueue(store: store, client: client, clock: () => now);

      await queue.enqueue(_event('evt-ok'));
      await queue.processDue(now: now);

      expect(await store.loadAll(), isEmpty);
      expect(queue.pendingCount, 0);
      expect(queue.failedCount, 0);
      expect(queue.lastSyncAt, now);
    });

    test('failure increments attempts and reschedules with growing delays', () async {
      final store = InMemoryPendingEventStore();
      var now = DateTime.utc(2026, 1, 1, 10, 0);
      final client = FakeUploadClient(outcomes: [false, false, false]);
      final queue = UploadQueue(
        store: store,
        client: client,
        clock: () => now,
        config: _noJitter, // deterministic exact delays
      );

      await queue.enqueue(_event('evt-r'));

      // Attempt 1 fails → retry in exactly base (1.5s).
      await queue.processDue(now: now);
      var stored = (await store.loadAll()).single;
      expect(stored.attempts, 1);
      expect(
        stored.nextAttemptAt!.difference(now),
        const Duration(milliseconds: 1500),
      );

      // Attempt 2 fails → retry in base * 2 = 3s.
      now = stored.nextAttemptAt!;
      await queue.processDue(now: now);
      stored = (await store.loadAll()).single;
      expect(stored.attempts, 2);
      expect(
        stored.nextAttemptAt!.difference(now),
        const Duration(milliseconds: 3000),
      );

      // Attempt 3 fails → retry in base * 4 = 6s.
      now = stored.nextAttemptAt!;
      await queue.processDue(now: now);
      stored = (await store.loadAll()).single;
      expect(stored.attempts, 3);
      expect(
        stored.nextAttemptAt!.difference(now),
        const Duration(milliseconds: 6000),
      );
      expect(stored.lastError, isNotNull);
    });

    test('backoff is capped at maxBackoff', () async {
      final store = InMemoryPendingEventStore();
      var now = DateTime.utc(2026, 1, 1, 10, 0);
      final client = FakeUploadClient(outcomes: List.filled(12, false));
      final queue = UploadQueue(
        store: store,
        client: client,
        clock: () => now,
        config: _noJitter,
      );

      await queue.enqueue(_event('evt-cap'));

      var maxDelay = Duration.zero;
      for (var i = 0; i < 8; i++) {
        await queue.processDue(now: now);
        final stored = (await store.loadAll()).single;
        if (stored.nextAttemptAt == null) {
          break; // permanently failed
        }
        maxDelay = stored.nextAttemptAt!.difference(now);
        now = stored.nextAttemptAt!;
      }
      expect(maxDelay, lessThanOrEqualTo(const Duration(seconds: 60)));
      // Cap was actually reached, not just never exceeded.
      expect(maxDelay, greaterThan(const Duration(seconds: 50)));
    });

    test('jitter widens the computed delay (non-deterministic component)', () async {
      final store1 = InMemoryPendingEventStore();
      final store2 = InMemoryPendingEventStore();
      final now = DateTime.utc(2026, 1, 1, 10, 0);
      final queue1 = UploadQueue(
        store: store1,
        client: FakeUploadClient(outcomes: [false]),
        clock: () => now,
        jitterRandom: Random(1),
      );
      final queue2 = UploadQueue(
        store: store2,
        client: FakeUploadClient(outcomes: [false]),
        clock: () => now,
        jitterRandom: Random(3),
      );

      await queue1.enqueue(_event('evt-j1'));
      await queue2.enqueue(_event('evt-j2'));
      await queue1.processDue(now: now);
      await queue2.processDue(now: now);

      final delay1 = (await store1.loadAll()).single.nextAttemptAt!
          .difference(now);
      final delay2 = (await store2.loadAll()).single.nextAttemptAt!
          .difference(now);

      // Base is 1.5s, jitter adds up to 50%: both must land in range and
      // different seeds must produce different delays.
      expect(delay1.inMilliseconds, inExclusiveRange(1500, 2250));
      expect(delay2.inMilliseconds, inExclusiveRange(1500, 2250));
      expect(delay1, isNot(delay2));
    });

    test('maxAttempts marks permanently failed, keeps it, never retries', () async {
      final store = InMemoryPendingEventStore();
      var now = DateTime.utc(2026, 1, 1, 10, 0);
      final client = FakeUploadClient(outcomes: List.filled(12, false));
      final queue = UploadQueue(
        store: store,
        client: client,
        clock: () => now,
        config: _noJitter,
      );

      await queue.enqueue(_event('evt-dead'));

      // Drive 8 attempts (the default maxAttempts).
      for (var i = 0; i < 8; i++) {
        await queue.processDue(now: now);
        final stored = (await store.loadAll()).single;
        if (stored.nextAttemptAt != null) {
          now = stored.nextAttemptAt!;
        }
      }

      final stored = (await store.loadAll()).single;
      expect(stored.attempts, 8);
      expect(stored.nextAttemptAt, isNull);
      expect(stored.lastError, isNotNull);
      expect(queue.failedCount, 1);
      expect(queue.pendingCount, 0);
      expect(queue.failedEvents.single.eventId, 'evt-dead');

      // Even far in the future, no further attempts are made.
      now = now.add(const Duration(hours: 24));
      await queue.processDue(now: now);
      expect(client.attemptedEventIds.length, 8);
    });

    test('processDue skips events scheduled in the future', () async {
      final store = InMemoryPendingEventStore();
      var now = DateTime.utc(2026, 1, 1, 10, 0);
      final client = FakeUploadClient(outcomes: [false]);
      final queue = UploadQueue(store: store, client: client, clock: () => now);

      await queue.enqueue(_event('evt-f'));
      await queue.processDue(now: now); // fails → scheduled ~1.5s ahead

      final stored = (await store.loadAll()).single;
      final scheduledAt = stored.nextAttemptAt!;
      expect(scheduledAt.isAfter(now), isTrue);

      // Only ~0.5s later: not due yet, nothing attempted.
      await queue.processDue(
        now: now.add(const Duration(milliseconds: 500)),
      );
      expect(client.attemptedEventIds.length, 1);

      // At exactly the scheduled instant: due and attempted.
      await queue.processDue(now: scheduledAt);
      expect(client.attemptedEventIds.length, 2);
    });

    test('retry succeeds after earlier failures (network-returns scenario)', () async {
      final store = InMemoryPendingEventStore();
      var now = DateTime.utc(2026, 1, 1, 10, 0);
      final client = FakeUploadClient(outcomes: [false, false, true]);
      final queue = UploadQueue(store: store, client: client, clock: () => now);

      await queue.enqueue(_event('evt-net'));

      for (var i = 0; i < 5; i++) {
        await queue.processDue(now: now);
        final stored = await store.loadAll();
        if (stored.isEmpty) {
          break;
        }
        final next = stored.single.nextAttemptAt;
        if (next == null) {
          break;
        }
        now = next;
      }

      expect(client.attemptedEventIds.length, 3);
      // Same id every attempt — idempotency key is stable.
      expect(client.attemptedEventIds, everyElement('evt-net'));
      expect(await store.loadAll(), isEmpty);
      expect(queue.pendingCount, 0);
      expect(queue.failedCount, 0);
      expect(queue.lastSyncAt, isNotNull);
    });

    test('thrown upload errors count as failures and are recorded', () async {
      final store = InMemoryPendingEventStore();
      var now = DateTime.utc(2026, 1, 1, 10, 0);
      final client = FakeUploadClient(
        outcomes: [true],
        throws: [StateError('socket closed')],
      );
      final queue = UploadQueue(store: store, client: client, clock: () => now);

      await queue.enqueue(_event('evt-err'));
      await queue.processDue(now: now);

      final stored = (await store.loadAll()).single;
      expect(stored.attempts, 1);
      expect(stored.lastError, contains('socket closed'));
      expect(queue.pendingCount, 1);

      // Next attempt succeeds.
      now = stored.nextAttemptAt!;
      await queue.processDue(now: now);
      expect(await store.loadAll(), isEmpty);
      expect(queue.lastSyncAt, now);
    });

    test('eventId never changes across attempts (idempotency key)', () async {
      final store = InMemoryPendingEventStore();
      var now = DateTime.utc(2026, 1, 1, 10, 0);
      final client = FakeUploadClient(outcomes: [false, false, true]);
      final queue = UploadQueue(store: store, client: client, clock: () => now);

      await queue.enqueue(_event('evt-idem'));

      for (var i = 0; i < 5 && client.attemptedEventIds.length < 3; i++) {
        await queue.processDue(now: now);
        final stored = await store.loadAll();
        if (stored.isEmpty) {
          break;
        }
        final next = stored.single.nextAttemptAt;
        if (next == null) {
          break;
        }
        now = next;
      }

      expect(client.attemptedEventIds, everyElement('evt-idem'));
      // The upload client saw the identical event object each time —
      // nothing was regenerated between attempts.
      for (final attempted in client.attemptedEvents) {
        expect(attempted.eventId, 'evt-idem');
      }
      expect(queue.pendingEvents, isEmpty);
    });

    test('restore() reloads persisted events so they survive restarts', () async {
      final store = InMemoryPendingEventStore();
      var now = DateTime.utc(2026, 1, 1, 10, 0);
      final client = FakeUploadClient(outcomes: [true]);
      final queue = UploadQueue(store: store, client: client, clock: () => now);

      await queue.enqueue(_event('evt-keep'));
      await queue.processDue(now: now);
      expect(await store.loadAll(), isEmpty);

      // Simulate a restart: an event persisted by an earlier session.
      await store.save(_event('evt-restart'));
      final newQueue = UploadQueue(store: store, client: client, clock: () => now);
      await newQueue.restore();
      expect(newQueue.pendingCount, 1);
      expect(newQueue.pendingEvents.single.eventId, 'evt-restart');

      await newQueue.processDue(now: now);
      expect(client.attemptedEventIds.last, 'evt-restart');
      expect(await store.loadAll(), isEmpty);
    });

    test('multiple events are attempted in schedule order', () async {
      final store = InMemoryPendingEventStore();
      var now = DateTime.utc(2026, 1, 1, 10, 0);
      final client = FakeUploadClient(outcomes: [true, true]);
      final queue = UploadQueue(store: store, client: client, clock: () => now);

      await queue.enqueue(_event('evt-a'));
      now = now.add(const Duration(seconds: 1)); // distinct schedule times
      await queue.enqueue(_event('evt-b'));

      await queue.processDue(now: now);

      expect(client.attemptedEventIds, ['evt-a', 'evt-b']);
      expect(await store.loadAll(), isEmpty);
      expect(queue.pendingCount, 0);
    });

    test('queue tolerates events without an image snapshot', () async {
      final store = InMemoryPendingEventStore();
      var now = DateTime.utc(2026, 1, 1, 10, 0);
      final client = FakeUploadClient(outcomes: [true]);
      final queue = UploadQueue(store: store, client: client, clock: () => now);

      await queue.enqueue(_event('evt-noimg'));
      await queue.processDue(now: now);

      // The client saw the image-less event and the server accepted it.
      expect(client.attemptedEvents.single.imageBytes, isNull);
      expect(await store.loadAll(), isEmpty);
    });

    test('queue persists the image object key from the hook so a retry '
        'never re-uploads the image', () async {
      const objectKey = 'events/2026-11/cached.jpg';
      final store = InMemoryPendingEventStore();
      var now = DateTime.utc(2026, 1, 1, 10, 0);
      // First attempt: key obtained but the alert fails; second attempt:
      // the alert succeeds. The fake only "uploads" the image when the
      // event has no cached key, mimicking the real client.
      final client = _ImageFlowClient(outcomes: [false, true]);
      final queue = UploadQueue(store: store, client: client, clock: () => now);

      final image = Uint8List.fromList([1, 2, 3]);
      await queue.enqueue(_event('evt-img', image: image));
      await queue.processDue(now: now);

      // After the failed attempt the key is persisted on the pending event.
      var persisted = (await store.loadAll()).single;
      expect(persisted.imageObjectKey, objectKey);
      expect(queue.pendingEvents.single.imageObjectKey, objectKey);
      expect(persisted.imageBytes, image); // bytes kept until delivered

      // Second attempt (after the backoff delay): alert succeeds; the
      // client saw the cached key and did not re-upload the image.
      await queue.processDue(now: now.add(const Duration(minutes: 2)));
      expect(client.uploadedImageKeys, [objectKey]);
      expect(client.seen.last.imageObjectKey, objectKey);
      expect(await store.loadAll(), isEmpty);
    });

    test('queue persists a dropped image (413/400) so the retry is '
        'imageless', () async {
      final store = InMemoryPendingEventStore();
      var now = DateTime.utc(2026, 1, 1, 10, 0);
      final client = _ImageFlowClient(outcomes: [false, true], dropImage: true);
      final queue = UploadQueue(store: store, client: client, clock: () => now);

      await queue.enqueue(_event('evt-drop', image: Uint8List.fromList([9])));
      await queue.processDue(now: now);

      // After the failed attempt the image is gone from the pending event.
      final persisted = (await store.loadAll()).single;
      expect(persisted.imageBytes, isNull);
      expect(persisted.imageContentType, isNull);
      expect(queue.pendingEvents.single.imageBytes, isNull);

      // Second attempt (after the backoff delay) succeeds without any
      // image attached.
      await queue.processDue(now: now.add(const Duration(minutes: 2)));
      expect(client.seen.last.imageBytes, isNull);
      expect(await store.loadAll(), isEmpty);
    });

    test('capturedAt is a UTC ISO-8601 string', () {
      final event = _event('evt-ts');
      expect(_utcIsoPattern.hasMatch(event.capturedAt), isTrue);
      expect(DateTime.parse(event.capturedAt).isUtc, isTrue);
    });
  });
}
