// Unit tests for the file-backed pending-event store: JSON round-trip,
// image bytes round-trip, atomic writes, delete and corrupt-file
// tolerance. Uses a fake PathGateway over a real temporary directory —
// no platform channels.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:farmguard_camera/services/file_pending_store.dart';
import 'package:farmguard_camera/services/pending_event_store.dart';

/// Gateway backed by a real temporary directory.
class _TempDirPathGateway implements PathGateway {
  _TempDirPathGateway(this.root);

  final Directory root;

  @override
  Future<Directory> appDocuments() async => root;
}

PendingEvent _event(
  String id, {
  Uint8List? image,
  int attempts = 0,
  DateTime? nextAttemptAt,
  String? lastError,
}) =>
    PendingEvent(
      eventId: id,
      cameraId: 'cam-1',
      confidence: 0.91,
      personCount: 1,
      capturedAt: '2026-11-18T09:30:00.000Z',
      createdAt: DateTime.utc(2026, 11, 18, 9, 30),
      boundingBox: (left: 0.1, top: 0.2, width: 0.3, height: 0.4),
      imageBytes: image,
      imageContentType: image == null ? null : 'image/jpeg',
      attempts: attempts,
      nextAttemptAt: nextAttemptAt,
      lastError: lastError,
    );

void main() {
  late Directory root;
  late FilePendingEventStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('farmguard_store_test');
    store = FilePendingEventStore(pathGateway: _TempDirPathGateway(root));
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  Directory pendingDir() =>
      Directory('${root.path}/farmguard/pending');

  test('save/loadAll round-trips every field', () async {
    final scheduled = DateTime.utc(2026, 11, 18, 9, 31);
    await store.save(
      _event(
        'evt-a',
        attempts: 2,
        nextAttemptAt: scheduled,
        lastError: 'boom',
      ),
    );

    final loaded = await store.loadAll();
    expect(loaded, hasLength(1));
    final event = loaded.single;
    expect(event.eventId, 'evt-a');
    expect(event.cameraId, 'cam-1');
    expect(event.detectionType, 'person');
    expect(event.confidence, 0.91);
    expect(event.personCount, 1);
    expect(event.capturedAt, '2026-11-18T09:30:00.000Z');
    expect(event.createdAt, DateTime.utc(2026, 11, 18, 9, 30));
    expect(
      event.boundingBox,
      (left: 0.1, top: 0.2, width: 0.3, height: 0.4),
    );
    expect(event.sourceType, 'LIVE');
    expect(event.attempts, 2);
    expect(event.nextAttemptAt, scheduled);
    expect(event.lastError, 'boom');
    expect(event.imageBytes, isNull);
  });

  test('image bytes round-trip through the sibling .jpg file', () async {
    final image = Uint8List.fromList(List.generate(64, (i) => i));
    await store.save(_event('evt-img', image: image));

    // The image file sits next to the JSON file.
    expect(
      File('${pendingDir().path}/evt-img.jpg').readAsBytesSync(),
      image,
    );

    final event = (await store.loadAll()).single;
    expect(event.imageBytes, image);
    expect(event.imageContentType, 'image/jpeg');
  });

  test('replace overwrites the persisted event', () async {
    await store.save(_event('evt-r'));
    final first = (await store.loadAll()).single;
    expect(first.attempts, 0);

    await store.replace(
      first.copyWith(attempts: 3, lastError: 'rejected'),
    );

    final loaded = await store.loadAll();
    expect(loaded, hasLength(1));
    expect(loaded.single.attempts, 3);
    expect(loaded.single.lastError, 'rejected');
  });

  test('delete removes both the JSON and the image file', () async {
    await store.save(_event('evt-del', image: Uint8List.fromList([1, 2, 3])));
    expect(pendingDir().listSync(), hasLength(2));

    await store.delete('evt-del');

    expect(await store.loadAll(), isEmpty);
    expect(pendingDir().listSync(), isEmpty);
  });

  test('event without image loads as null image bytes', () async {
    await store.save(_event('evt-noimg'));
    // No .jpg was written — the JSON alone persists.
    final event = (await store.loadAll()).single;
    expect(event.imageBytes, isNull);
    expect(event.imageContentType, isNull);
  });

  test('corrupt files are skipped, not crashing loadAll', () async {
    await store.save(_event('evt-good'));
    await File('${pendingDir().path}/corrupt.json')
        .writeAsString('{not valid json');
    await File('${pendingDir().path}/wrong-shape.json')
        .writeAsString('[1, 2, 3]');

    final loaded = await store.loadAll();
    expect(loaded, hasLength(1));
    expect(loaded.single.eventId, 'evt-good');
  });

  test('loadAll on a fresh (missing) directory returns empty', () async {
    final freshRoot =
        await Directory.systemTemp.createTemp('farmguard_empty');
    try {
      final freshStore = FilePendingEventStore(
        pathGateway: _TempDirPathGateway(freshRoot),
      );
      expect(await freshStore.loadAll(), isEmpty);
    } finally {
      await freshRoot.delete(recursive: true);
    }
  });

  test('writes are atomic: no .tmp leftovers remain after save', () async {
    await store.save(_event('evt-atomic', image: Uint8List.fromList([9])));
    final names = pendingDir().listSync().map((f) => f.path).toList();
    expect(names.where((name) => name.endsWith('.tmp')), isEmpty);
    expect(names, containsAll(<Matcher>[
      endsWith('evt-atomic.json'),
      endsWith('evt-atomic.jpg'),
    ]));
  });

  test('imageObjectKey round-trips through the JSON file', () async {
    final image = Uint8List.fromList([1, 2, 3]);
    await store.save(
      _event('evt-key', image: image).copyWith(
        imageObjectKey: 'events/2026-11/abc.jpg',
      ),
    );

    final event = (await store.loadAll()).single;
    expect(event.imageObjectKey, 'events/2026-11/abc.jpg');
    expect(event.imageBytes, image);
  });

  test('replacing an event without image bytes removes the stale .jpg',
      () async {
    // Simulate the drop-image path: bytes uploaded failed permanently, so
    // the queue persists the event imageless — the old snapshot must not
    // resurrect on the next load.
    await store.save(_event('evt-drop', image: Uint8List.fromList([1, 2, 3])));
    expect(File('${pendingDir().path}/evt-drop.jpg').existsSync(), isTrue);

    await store.replace(
      _event('evt-drop').copyWith(clearImage: true, lastError: 'dropped'),
    );

    expect(File('${pendingDir().path}/evt-drop.jpg').existsSync(), isFalse);
    final event = (await store.loadAll()).single;
    expect(event.imageBytes, isNull);
    expect(event.imageContentType, isNull);
    expect(event.lastError, 'dropped');
  });
}
