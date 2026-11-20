import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:farmguard_farmer/data/event_codec.dart';
import 'package:farmguard_farmer/data/repositories/auth_repository.dart';
import 'package:farmguard_farmer/data/repositories/event_repository.dart';
import 'package:farmguard_farmer/models/models.dart';
import 'package:farmguard_farmer/services/api/exceptions.dart';
import 'package:farmguard_farmer/services/api/farmer_api.dart';

import '../../helpers/api_fixtures.dart';

void main() {
  group('EventRepository', () {
    test('fetchFirstPage converts rows to domain events, newest first',
        () async {
      final api = FakeFarmerApi(
        events: <ApiDetectionEvent>[
          apiEvent(id: 'evt-new'),
          apiEvent(id: 'evt-old', sourceType: 'DEMO'),
        ],
        nextBefore: '2026-11-18T10:00:00.000Z',
      );
      final repository = EventRepository(api: api, pageSize: 20);

      final events = await repository.fetchFirstPage();

      expect(api.listEventsCalls, 1);
      expect(api.limits.single, 20);
      // Order is whatever the server sent: newest first is preserved.
      expect(events.map((e) => e.id), <String>['evt-new', 'evt-old']);
      expect(events[0].isDemo, isFalse);
      expect(events[0].imagePath, 'api:/api/v1/images/evt-new');
      expect(events[1].isDemo, isTrue);
    });

    test('fetchFirstPage passes camera filter', () async {
      final api = FakeFarmerApi();
      final repository = EventRepository(api: api);

      await repository.fetchFirstPage(cameraId: 'cam-7');

      expect(api.cameraIds.single, 'cam-7');
    });

    test('fetchPage sends before cursor and camera filter', () async {
      final api = FakeFarmerApi();
      final repository = EventRepository(api: api, pageSize: 10);

      final events = await repository.fetchPage(
        '2026-11-17T00:00:00.000Z',
        cameraId: 'cam-2',
      );

      expect(api.befores.single, '2026-11-17T00:00:00.000Z');
      expect(api.limits.single, 10);
      expect(api.cameraIds.single, 'cam-2');
      expect(events, isEmpty);
    });

    test('markViewed returns the updated domain event (isViewed true)',
        () async {
      final api = FakeFarmerApi(
        viewedEvent: apiEvent(id: 'evt-1', viewedAt: 'yes'),
      );
      final repository = EventRepository(api: api);

      final event = await repository.markViewed('evt-1');

      expect(event.id, 'evt-1');
      expect(event.isViewed, isTrue);
    });

    test('getImage fetches bytes and serves repeats from cache', () async {
      final bytes = Uint8List.fromList(<int>[9, 8, 7]);
      final api = FakeFarmerApi(imageBytes: bytes);
      final repository = EventRepository(api: api);
      final event = backendEvent('evt-1');

      expect(await repository.getImage(event), bytes);
      expect(api.imageCalls, 1);
      expect(api.imageEventIds.single, 'evt-1');

      // Second call served from cache — no extra API hit.
      expect(await repository.getImage(event), bytes);
      expect(api.imageCalls, 1);
    });

    test('asset-backed demo events skip the network entirely', () async {
      final api = FakeFarmerApi(imageBytes: Uint8List.fromList(<int>[1]));
      final repository = EventRepository(api: api);
      final event = DetectionEvent(
        id: 'FG-0184',
        cameraId: 'cam-1',
        timestamp: DateTime.now(),
        confidence: 0.9,
        imagePath: 'assets/detections/detection_5.png',
        isViewed: false,
        boxes: const <DetectionBox>[],
      );

      expect(await repository.getImage(event), isNull);
      expect(api.imageCalls, 0);
    });

    test('getImage 404 → ApiException rethrown, nothing cached', () async {
      final api = FakeFarmerApi(
        imageError: const ApiException(
          statusCode: 404,
          code: 'not_found',
          message: 'Frame unavailable.',
        ),
      );
      final repository = EventRepository(api: api);
      final event = backendEvent('evt-1');

      final first = await expectApiError(() => repository.getImage(event));
      expect(first.statusCode, 404);
      expect(api.imageCalls, 1);

      // Retry also goes to the API (404 responses are not cached).
      await expectApiError(() => repository.getImage(event));
      expect(api.imageCalls, 2);
    });

    test('LRU cache evicts the oldest entry beyond maxCachedImages',
        () async {
      final api = FakeFarmerApi(imageBytes: Uint8List.fromList(<int>[1, 2]));
      final repository = EventRepository(api: api, maxCachedImages: 2);
      final a = backendEvent('a');
      final b = backendEvent('b');
      final c = backendEvent('c');

      await repository.getImage(a);
      await repository.getImage(b);
      // Third fetch evicts `a` (oldest, never touched).
      await repository.getImage(c);
      await repository.getImage(a); // cache miss → API hit
      expect(api.imageCalls, 4);

      // `b` and `c` (most recent insertions) stay cached.
      await repository.getImage(c);
      await repository.getImage(b);
      expect(api.imageCalls, 5);
    });

    test('listEvents errors pass through as ApiException unchanged',
        () async {
      final repository = EventRepository(api: const ThrowingApi());

      final error = await expectApiError(() => repository.fetchFirstPage());
      expect(error.statusCode, 401);
      expect(error.isUnauthorized, isTrue);
    });
  });

  group('CameraRepository', () {
    test('fetchCameras returns the API cameras', () async {
      final api = FakeFarmerApi(cameras: <FarmCamera>[apiCamera(id: 'cam-1')]);
      final repository = CameraRepository(api: api);

      final cameras = await repository.fetchCameras();

      expect(cameras.single.id, 'cam-1');
      expect(cameras.single.name, 'Main Gate');
    });

    test('deleteCamera delegates to the API and the camera disappears',
        () async {
      final api = FakeFarmerApi(
        cameras: <FarmCamera>[
          apiCamera(id: 'cam-1', name: 'Main Gate'),
          apiCamera(id: 'cam-2', name: 'Pump House'),
        ],
      );
      final repository = CameraRepository(api: api);

      await repository.deleteCamera('cam-1');

      expect(api.deletedCameraIds, <String>['cam-1']);
      final remaining = await repository.fetchCameras();
      expect(remaining.map((FarmCamera c) => c.id), <String>['cam-2']);
    });

    test('deleteCamera passes ApiException through unchanged', () async {
      final repository = CameraRepository(api: const ThrowingApi());

      final error = await expectApiError(
        () => repository.deleteCamera('cam-1'),
      );

      expect(error.statusCode, 401);
      expect(error.isUnauthorized, isTrue);
    });
  });

  group('AuthRepository', () {
    test('login persists token in the token store', () async {
      final store = RecordingTokenStore();
      final api = FakeFarmerApi(authResult: authResult(token: 'tok-login'));
      final repository = AuthRepository(api: api, tokenStore: store);

      final result = await repository.login('kiran@farm.test', 'hunter2222');

      expect(result.token, 'tok-login');
      expect(store.saves, 1);
      expect(store.savedTokens.single, 'tok-login');
      expect(await store.readToken(), 'tok-login');
    });

    test('register persists token; logout clears it', () async {
      final store = RecordingTokenStore();
      final api = FakeFarmerApi(authResult: authResult(token: 'tok-reg'));
      final repository = AuthRepository(api: api, tokenStore: store);

      await repository.register('Kiran', 'kiran@farm.test', 'hunter2222');
      expect(store.saves, 1);
      expect(await store.readToken(), 'tok-reg');

      await repository.logout();
      expect(store.clears, 1);
      expect(await store.readToken(), isNull);
    });

    test('me() returns farmer info and does not persist anything', () async {
      final store = RecordingTokenStore();
      final api = FakeFarmerApi(authResult: authResult(token: 'tok-me'));
      final repository = AuthRepository(api: api, tokenStore: store);

      final result = await repository.me();

      expect(result.farmerName, 'Kiran');
      expect(store.saves, 0);
      expect(store.clears, 0);
    });

    test('API auth errors surface unchanged (401)', () async {
      final repository = AuthRepository(
        api: const ThrowingApi(),
        tokenStore: RecordingTokenStore(),
      );

      final error = await expectApiError(() => repository.me());
      expect(error.statusCode, 401);
    });
  });
}

/// Builds a backend-flavoured domain event (api: image scheme) the same way
/// the codec would produce it.
DetectionEvent backendEvent(String id) => DetectionEvent(
      id: id,
      cameraId: 'cam-1',
      timestamp: DateTime.utc(2026, 11, 18, 10, 15),
      confidence: 0.9,
      imagePath: apiImagePath(id),
      isViewed: false,
      boxes: const <DetectionBox>[],
    );

/// Runs [call] and expects an [ApiException]; returns it after asserting the
/// status code. Fails the test if no ApiException is thrown.
Future<ApiException> expectApiError(
  Future<Object?> Function() call, {
  int? statusCode,
}) async {
  try {
    await call();
    fail('Expected an ApiException but none was thrown.');
  } on ApiException catch (e) {
    if (statusCode != null) expect(e.statusCode, statusCode);
    return e;
  }
}
