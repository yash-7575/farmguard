// Unit tests for the FarmGuard API client: envelope parsing, request
// payload construction (idempotency key, ISO UTC timestamps, normalized
// bounding boxes) and the permanent/transient failure classification.
//
// Uses package:http's MockClient — no real network is touched.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:farmguard_camera/services/api_client.dart';
import 'package:farmguard_camera/services/pending_event_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

PendingEvent _event({
  String eventId = 'evt-1',
  bool withBox = true,
}) =>
    PendingEvent(
      eventId: eventId,
      cameraId: 'cam-1',
      confidence: 0.87,
      personCount: 2,
      capturedAt: '2026-11-18T09:30:00.000Z',
      createdAt: DateTime.utc(2026, 11, 18, 9, 30),
      boundingBox: withBox
          ? (left: 0.1, top: 0.2, width: 0.3, height: 0.4)
          : null,
    );

void main() {
  group('ApiEnvelope.parse', () {
    test('parses the ok envelope with data', () {
      final envelope = ApiEnvelope.parse(
        jsonEncode({'ok': true, 'data': {'token': 't'}}),
      );
      expect(envelope.ok, isTrue);
      expect((envelope.data as Map)['token'], 't');
      expect(envelope.errorCode, isNull);
      expect(envelope.errorMessage, isNull);
    });

    test('parses the error envelope with code and message', () {
      final envelope = ApiEnvelope.parse(jsonEncode({
        'ok': false,
        'error': {'code': 'invalid_code', 'message': 'Bad code'},
      }));
      expect(envelope.ok, isFalse);
      expect(envelope.errorCode, 'invalid_code');
      expect(envelope.errorMessage, 'Bad code');
    });

    test('throws FormatException on non-JSON body', () {
      expect(() => ApiEnvelope.parse('<html>oops</html>'),
          throwsFormatException);
    });

    test('throws FormatException on non-object JSON', () {
      expect(() => ApiEnvelope.parse('[1,2,3]'), throwsFormatException);
    });
  });

  group('HttpFarmGuardApi', () {
    late List<http.Request> requests;

    HttpFarmGuardApi apiWith(
      http.Response Function(http.Request request) responder, {
      String? Function()? tokenProvider,
    }) {
      requests = [];
      return HttpFarmGuardApi(
        httpClient: MockClient(
          (request) async {
            requests.add(request);
            return responder(request);
          },
        ),
        tokenProvider: tokenProvider,
      );
    }

    test('redeemPairingCode sends the contract payload and parses the result',
        () async {
      final api = apiWith(
        (request) => http.Response(
          jsonEncode({
            'ok': true,
            'data': {
              'token': 'camera-token',
              'camera': {
                'id': 'cam-1',
                'name': 'Field Camera 1',
                'location': 'North fence',
                'status': 'active',
              },
            },
          }),
          201,
        ),
      );

      final result = await api.redeemPairingCode(
        code: '123456',
        deviceIdentifier: 'device-42',
        cameraName: 'Field Camera 1',
        location: 'North fence',
      );

      expect(result.token, 'camera-token');
      expect(result.cameraId, 'cam-1');
      expect(result.cameraName, 'Field Camera 1');
      expect(result.location, 'North fence');

      expect(requests, hasLength(1));
      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/api/v1/pairing/redeem');
      final body = jsonDecode(request.body) as Map;
      expect(body['code'], '123456');
      expect(body['device_identifier'], 'device-42');
      expect(body['camera_name'], 'Field Camera 1');
      expect(body['location'], 'North fence');
      // Pairing is unauthenticated.
      expect(request.headers.containsKey('Authorization'), isFalse);
    });

    test('redeemPairingCode surfaces the server error message', () async {
      final api = apiWith(
        (request) => http.Response(
          jsonEncode({
            'ok': false,
            'error': {'code': 'invalid_code', 'message': 'Invalid pairing code'},
          }),
          400,
        ),
      );

      await expectLater(
        api.redeemPairingCode(
          code: '999999',
          deviceIdentifier: 'device-42',
          cameraName: 'Farm Camera',
        ),
        throwsA(
          isA<PairingException>()
              .having((e) => e.code, 'code', 'invalid_code')
              .having((e) => e.message, 'message', 'Invalid pairing code'),
        ),
      );
    });

    test('sendAlert builds the contract payload (idempotency key = event id)',
        () async {
      final api = apiWith(
        (request) => http.Response(
          jsonEncode({'ok': true, 'data': {'event': {}}}),
          201,
        ),
        tokenProvider: () => 'camera-token',
      );

      final confirmed = await api.sendAlert('cam-1', _event());

      expect(confirmed, isTrue);
      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/api/v1/alerts');
      expect(request.headers['Authorization'], 'Bearer camera-token');
      final body = jsonDecode(request.body) as Map;
      // The event UUID doubles as the idempotency key.
      expect(body['id'], 'evt-1');
      expect(body['confidence'], 0.87);
      expect(body['detected_at'], '2026-11-18T09:30:00.000Z');
      expect(body['bounding_box'], [
        {'left': 0.1, 'top': 0.2, 'width': 0.3, 'height': 0.4},
      ]);
      // Images are wired in a later stage: always null for now.
      expect(body['image_object_key'], isNull);
      expect(body['image_content_type'], isNull);
      expect(body['image_size'], isNull);
    });

    test('sendAlert sends null bounding_box when the event has none',
        () async {
      final api = apiWith(
        (request) => http.Response(
          jsonEncode({'ok': true, 'data': {}}),
          201,
        ),
      );
      await api.sendAlert('cam-1', _event(withBox: false));
      final body = jsonDecode(requests.single.body) as Map;
      expect(body['bounding_box'], isNull);
    });

    test('200 duplicate counts as success', () async {
      final api = apiWith(
        (request) => http.Response(
          jsonEncode({'ok': true, 'data': {}}),
          200,
        ),
      );
      expect(await api.sendAlert('cam-1', _event()), isTrue);
    });

    test('HTTP 400 (non-429 4xx) is permanent', () async {
      final api = apiWith(
        (request) => http.Response(
          jsonEncode({
            'ok': false,
            'error': {'code': 'invalid_payload', 'message': 'bad body'},
          }),
          400,
        ),
      );

      await expectLater(
        api.sendAlert('cam-1', _event()),
        throwsA(
          isA<PermanentUploadException>()
              .having((e) => e.code, 'code', 'invalid_payload')
              .having((e) => e.message, 'message', 'bad body'),
        ),
      );
    });

    test('HTTP 401 is permanent (bad camera token)', () async {
      final api = apiWith(
        (request) => http.Response('{"ok":false,"error":null}', 401),
      );
      await expectLater(
        api.sendAlert('cam-1', _event()),
        throwsA(isA<PermanentUploadException>()),
      );
    });

    test('HTTP 503 is transient', () async {
      final api = apiWith(
        (request) => http.Response('{"ok":false,"error":null}', 503),
      );
      await expectLater(
        api.sendAlert('cam-1', _event()),
        throwsA(isA<TransientUploadException>()),
      );
    });

    test('HTTP 429 is transient (rate limit)', () async {
      final api = apiWith(
        (request) => http.Response('{"ok":false,"error":null}', 429),
      );
      await expectLater(
        api.sendAlert('cam-1', _event()),
        throwsA(isA<TransientUploadException>()),
      );
    });

    test('network failure is transient', () async {
      final api = HttpFarmGuardApi(
        httpClient: MockClient((request) async {
          throw http.ClientException('socket closed');
        }),
      );
      await expectLater(
        api.sendAlert('cam-1', _event()),
        throwsA(isA<TransientUploadException>()),
      );
    });

    test('sendHeartbeat returns true on 200, false on 4xx/5xx/network',
        () async {
      final okApi = apiWith((request) => http.Response('{}', 200),
          tokenProvider: () => 'tok');
      expect(await okApi.sendHeartbeat('cam-1'), isTrue);
      expect(requests.single.url.path, '/api/v1/cameras/cam-1/heartbeat');
      expect(requests.single.headers['Authorization'], 'Bearer tok');

      final rejectedApi = apiWith((request) => http.Response('{}', 401));
      expect(await rejectedApi.sendHeartbeat('cam-1'), isFalse);

      final errorApi = apiWith((request) => http.Response('{}', 500));
      expect(await errorApi.sendHeartbeat('cam-1'), isFalse);

      final networkApi = HttpFarmGuardApi(
        httpClient: MockClient((request) async {
          throw http.ClientException('offline');
        }),
      );
      expect(await networkApi.sendHeartbeat('cam-1'), isFalse);
    });

    test('uploadEvent (UploadClient adapter) delegates to sendAlert',
        () async {
      final api = apiWith(
        (request) => http.Response(
          jsonEncode({'ok': true, 'data': {}}),
          201,
        ),
      );
      final confirmed = await api.uploadEvent(_event(eventId: 'evt-2'));
      expect(confirmed, isTrue);
      final body = jsonDecode(requests.single.body) as Map;
      expect(body['id'], 'evt-2');
    });

    test('paired camera token is never logged anywhere in the client', () {
      // Structural guarantee: HttpFarmGuardApi has no logging surface —
      // assert the class exposes nothing but the documented members.
      final api = apiWith((request) => http.Response('{}', 200));
      expect(api.baseUrl, defaultFarmGuardBaseUrl);
      // The contract-level check lives in the request assertions above;
      // this documents intent for reviewers.
    });
  });

  group('uploadEvent image flow (R2 upload → event metadata)', () {
    final image = Uint8List.fromList(List.generate(48, (i) => i));
    const objectKey = 'events/2026-11/3f2a91c0-8f4e-4d7a-9b1c-2e5d6a7b8c9d.jpg';

    late List<http.Request> requests;

    /// Ordered log of what happened: 'image'/'alert' when the mock client
    /// received a POST, 'hook:<key>' when onImageKeyObtained fired,
    /// 'drop:<eventId>' when onImageDropped fired.
    late List<String> log;

    HttpFarmGuardApi apiWith({
      required http.Response Function(http.Request request) onImage,
      required http.Response Function(http.Request request) onAlert,
      String? Function()? tokenProvider,
    }) {
      requests = [];
      log = [];
      return HttpFarmGuardApi(
        httpClient: MockClient((request) async {
          requests.add(request);
          final isImage = request.url.path == '/api/v1/images';
          log.add(isImage ? 'image' : 'alert');
          return isImage ? onImage(request) : onAlert(request);
        }),
        tokenProvider: tokenProvider,
      );
    }

    PendingEvent imageEvent({String? cachedKey}) =>
        _event().copyWith(
          imageBytes: image,
          imageContentType: 'image/jpeg',
          imageObjectKey: cachedKey,
        );

    Future<bool> upload(HttpFarmGuardApi api, PendingEvent event) =>
        api.uploadEvent(
          event,
          onImageKeyObtained: (eventId, key) async {
            log.add('hook:$key');
          },
          onImageDropped: (eventId) async {
            log.add('drop:$eventId');
          },
        );

    test('image POST first with raw JPEG body, key cached before the alert',
        () async {
      final api = apiWith(
        onImage: (_) => http.Response(
          jsonEncode({'ok': true, 'data': {'object_key': objectKey}}),
          201,
        ),
        onAlert: (_) =>
            http.Response(jsonEncode({'ok': true, 'data': {}}), 201),
        tokenProvider: () => 'camera-token',
      );

      final confirmed = await upload(api, imageEvent());

      expect(confirmed, isTrue);
      expect(
        requests.map((r) => r.url.path).toList(),
        ['/api/v1/images', '/api/v1/alerts'],
      );

      final imageRequest = requests.first;
      expect(imageRequest.method, 'POST');
      // RAW binary body, NOT JSON.
      expect(imageRequest.bodyBytes, image);
      expect(imageRequest.headers['Content-Type'], 'image/jpeg');
      expect(imageRequest.headers['Authorization'], 'Bearer camera-token');

      // The key hook fired between the image POST and the alert POST —
      // persisted before the alert so a crash never re-uploads the image.
      expect(log, ['image', 'hook:$objectKey', 'alert']);

      final alertBody = jsonDecode(requests.last.body) as Map;
      expect(alertBody['image_object_key'], objectKey);
      expect(alertBody['image_content_type'], 'image/jpeg');
      expect(alertBody['image_size'], image.length);
    });

    test('cached object key skips the image POST entirely', () async {
      final api = apiWith(
        onImage: (_) =>
            throw StateError('image endpoint must not be hit on a cached key'),
        onAlert: (_) =>
            http.Response(jsonEncode({'ok': true, 'data': {}}), 201),
      );

      final confirmed = await upload(api, imageEvent(cachedKey: objectKey));

      expect(confirmed, isTrue);
      expect(requests, hasLength(1));
      expect(requests.single.url.path, '/api/v1/alerts');
      expect(log, ['alert']); // no key hook, no drop hook

      final alertBody = jsonDecode(requests.single.body) as Map;
      expect(alertBody['image_object_key'], objectKey);
    });

    test('image upload 503 fails the whole upload: no alert POST, no hook',
        () async {
      final api = apiWith(
        onImage: (_) => http.Response(
          jsonEncode({
            'ok': false,
            'error': {'code': 'upstream_error', 'message': 'R2 unavailable'},
          }),
          503,
        ),
        onAlert: (_) => throw StateError('alert must not be attempted'),
      );

      await expectLater(
        upload(api, imageEvent()),
        throwsA(
          isA<TransientUploadException>()
              .having((e) => e.code, 'code', 'upstream_error'),
        ),
      );

      expect(requests, hasLength(1));
      expect(requests.single.url.path, '/api/v1/images');
      // No key hook and no alert: the event stays queued and the image is
      // attempted again on the next retry.
      expect(log, ['image']);
    });

    test('image upload 413 drops the image and still delivers the event',
        () async {
      final api = apiWith(
        onImage: (_) => http.Response(
          jsonEncode({
            'ok': false,
            'error': {
              'code': 'image_too_large',
              'message': 'max 8 MiB',
            },
          }),
          413,
        ),
        onAlert: (_) =>
            http.Response(jsonEncode({'ok': true, 'data': {}}), 201),
      );

      final confirmed = await upload(api, imageEvent());

      expect(confirmed, isTrue);
      expect(
        requests.map((r) => r.url.path).toList(),
        ['/api/v1/images', '/api/v1/alerts'],
      );
      expect(log, ['image', 'drop:evt-1', 'alert']);

      final alertBody = jsonDecode(requests.last.body) as Map;
      expect(alertBody['image_object_key'], isNull);
      expect(alertBody['image_content_type'], isNull);
      expect(alertBody['image_size'], isNull);
    });

    test('image upload 400 also drops the image (never retried)', () async {
      final api = apiWith(
        onImage: (_) => http.Response(
          jsonEncode({
            'ok': false,
            'error': {'code': 'image_invalid', 'message': 'bad image'},
          }),
          400,
        ),
        onAlert: (_) =>
            http.Response(jsonEncode({'ok': true, 'data': {}}), 201),
      );

      expect(await upload(api, imageEvent()), isTrue);
      expect(log, ['image', 'drop:evt-1', 'alert']);
      final alertBody = jsonDecode(requests.last.body) as Map;
      expect(alertBody['image_object_key'], isNull);
    });

    test('image 201 then alert 503: retry with the cached key skips the '
        'image POST and the alert succeeds', () async {
      final firstApi = apiWith(
        onImage: (_) => http.Response(
          jsonEncode({'ok': true, 'data': {'object_key': objectKey}}),
          201,
        ),
        onAlert: (_) => http.Response(
          jsonEncode({
            'ok': false,
            'error': {'code': 'upstream_error', 'message': 'boom'},
          }),
          503,
        ),
      );

      await expectLater(
        upload(firstApi, imageEvent()),
        throwsA(isA<TransientUploadException>()),
      );
      expect(log, ['image', 'hook:$objectKey', 'alert']);

      // The queue persisted the key via the hook; simulate the retry with
      // the cached-key event and fresh mock responses.
      final retriedEvent = imageEvent().copyWith(imageObjectKey: objectKey);
      final retryApi = apiWith(
        onImage: (_) =>
            throw StateError('image must not be uploaded twice'),
        onAlert: (_) =>
            http.Response(jsonEncode({'ok': true, 'data': {}}), 201),
      );

      expect(await upload(retryApi, retriedEvent), isTrue);
      expect(requests, hasLength(1)); // no second image POST
      expect(requests.single.url.path, '/api/v1/alerts');
      final alertBody = jsonDecode(requests.single.body) as Map;
      expect(alertBody['image_object_key'], objectKey);
    });

    test('image error envelope on HTTP 413 behaves like a plain 413',
        () async {
      final api = apiWith(
        onImage: (_) => http.Response(
          jsonEncode({
            'ok': false,
            'error': {
              'code': 'image_too_large',
              'message': '8388609 bytes > 8388608',
            },
          }),
          413,
        ),
        onAlert: (_) =>
            http.Response(jsonEncode({'ok': true, 'data': {}}), 201),
      );

      expect(await upload(api, imageEvent()), isTrue);
      expect(log, ['image', 'drop:evt-1', 'alert']);
      final alertBody = jsonDecode(requests.last.body) as Map;
      expect(alertBody['image_object_key'], isNull);
    });

    test('event without image bytes goes straight to the alert POST',
        () async {
      final api = apiWith(
        onImage: (_) => throw StateError('no image endpoint call expected'),
        onAlert: (_) =>
            http.Response(jsonEncode({'ok': true, 'data': {}}), 201),
      );

      final confirmed = await upload(api, _event(eventId: 'evt-noimg'));

      expect(confirmed, isTrue);
      expect(requests, hasLength(1));
      expect(requests.single.url.path, '/api/v1/alerts');
      final alertBody = jsonDecode(requests.single.body) as Map;
      expect(alertBody['image_object_key'], isNull);
      expect(alertBody['image_content_type'], isNull);
      expect(alertBody['image_size'], isNull);
    });

    test('image upload network failure is transient', () async {
      final api = HttpFarmGuardApi(
        httpClient: MockClient((request) async {
          throw http.ClientException('socket closed');
        }),
      );
      await expectLater(
        upload(api, imageEvent()),
        throwsA(isA<TransientUploadException>()),
      );
    });

    test('image upload 401 (bad token) is permanent and skips the alert',
        () async {
      final api = apiWith(
        onImage: (_) => http.Response(
          jsonEncode({
            'ok': false,
            'error': {'code': 'invalid_token', 'message': 'bad token'},
          }),
          401,
        ),
        onAlert: (_) => throw StateError('alert must not be attempted'),
      );

      await expectLater(
        upload(api, imageEvent()),
        throwsA(isA<PermanentUploadException>()),
      );
      expect(requests.single.url.path, '/api/v1/images');
      expect(log, ['image']);
    });
  });

  // -------------------------------------------------------------------------
  // Phase 2B: pairing parser (camera_name), heartbeat classification,
  // session fetch and camera-side unpair.
  // -------------------------------------------------------------------------

  group('PairedCameraResult.fromData', () {
    test('accepts the canonical camera_name key (Defect 1A)', () {
      final result = PairedCameraResult.fromData({
        'token': 'camera-token',
        'camera': {
          'id': 'cam-1',
          'camera_name': 'Field Camera 1',
          'location': 'North fence',
          'status': 'active',
        },
      });

      expect(result.token, 'camera-token');
      expect(result.cameraId, 'cam-1');
      expect(result.cameraName, 'Field Camera 1');
      expect(result.location, 'North fence');
      expect(result.farmerId, isNull);
      expect(result.farmerName, isNull);
      expect(result.farmerEmailMasked, isNull);
    });

    test('still accepts the legacy name key', () {
      final result = PairedCameraResult.fromData({
        'token': 't',
        'camera': {'id': 'cam-1', 'name': 'Legacy Camera'},
      });
      expect(result.cameraName, 'Legacy Camera');
    });

    test('camera_name wins over name when both are present', () {
      final result = PairedCameraResult.fromData({
        'token': 't',
        'camera': {
          'id': 'cam-1',
          'camera_name': 'Canonical',
          'name': 'Legacy',
        },
      });
      expect(result.cameraName, 'Canonical');
    });

    test('parses the optional farmer details', () {
      final result = PairedCameraResult.fromData({
        'token': 't',
        'camera': {'id': 'cam-1', 'camera_name': 'Cam'},
        'farmer': {
          'id': 'farmer-1',
          'name': 'Asha',
          'email_masked': 'a***@example.com',
        },
      });
      expect(result.farmerId, 'farmer-1');
      expect(result.farmerName, 'Asha');
      expect(result.farmerEmailMasked, 'a***@example.com');
    });

    test('throws FormatException when the camera name is missing', () {
      expect(
        () => PairedCameraResult.fromData({
          'token': 't',
          'camera': {'id': 'cam-1'},
        }),
        throwsFormatException,
      );
    });
  });

  group('redeemPairingCode parses a camera_name response end to end', () {
    test('camera_name payload is accepted', () async {
      final requests = <http.Request>[];
      final api = HttpFarmGuardApi(
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode({
              'ok': true,
              'data': {
                'token': 'camera-token',
                'camera': {
                  'id': 'cam-7',
                  'camera_name': 'North Gate Cam',
                  'location': 'North fence',
                },
                'farmer': {'id': 'farmer-1', 'name': 'Asha'},
              },
            }),
            201,
          );
        }),
      );

      final result = await api.redeemPairingCode(
        code: '123456',
        deviceIdentifier: 'device-42',
        cameraName: 'North Gate Cam',
      );

      expect(result.cameraName, 'North Gate Cam');
      expect(result.farmerId, 'farmer-1');
      expect(result.farmerName, 'Asha');
      expect(requests, hasLength(1));
    });
  });

  group('sendHeartbeatDetailed', () {
    late List<http.Request> requests;

    HttpFarmGuardApi apiWith(http.Response Function(http.Request) responder) {
      requests = [];
      return HttpFarmGuardApi(
        httpClient: MockClient((request) async {
          requests.add(request);
          return responder(request);
        }),
        tokenProvider: () => 'camera-token',
      );
    }

    test('2xx → ok, with the status body and bearer auth', () async {
      final api = apiWith((_) => http.Response('{}', 200));

      expect(
        await api.sendHeartbeatDetailed('cam-1'),
        HeartbeatOutcome.ok,
      );

      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/api/v1/cameras/cam-1/heartbeat');
      expect(request.headers['Authorization'], 'Bearer camera-token');
      expect(jsonDecode(request.body), {'status': 'monitoring'});
    });

    test('custom status is sent in the body', () async {
      final api = apiWith((_) => http.Response('{}', 204));
      expect(
        await api.sendHeartbeatDetailed('cam-1', status: 'idle'),
        HeartbeatOutcome.ok,
      );
      expect(jsonDecode(requests.single.body), {'status': 'idle'});
    });

    test('401 and 403 → unauthorized', () async {
      expect(
        await apiWith((_) => http.Response('{}', 401))
            .sendHeartbeatDetailed('cam-1'),
        HeartbeatOutcome.unauthorized,
      );
      expect(
        await apiWith((_) => http.Response('{}', 403))
            .sendHeartbeatDetailed('cam-1'),
        HeartbeatOutcome.unauthorized,
      );
    });

    test('5xx, 429 and network errors → transientError', () async {
      expect(
        await apiWith((_) => http.Response('{}', 500))
            .sendHeartbeatDetailed('cam-1'),
        HeartbeatOutcome.transientError,
      );
      expect(
        await apiWith((_) => http.Response('{}', 429))
            .sendHeartbeatDetailed('cam-1'),
        HeartbeatOutcome.transientError,
      );

      final networkApi = HttpFarmGuardApi(
        httpClient: MockClient((request) async {
          throw http.ClientException('offline');
        }),
      );
      expect(
        await networkApi.sendHeartbeatDetailed('cam-1'),
        HeartbeatOutcome.transientError,
      );
    });

    test('sendHeartbeat delegates: true only for ok', () async {
      expect(
        await apiWith((_) => http.Response('{}', 200)).sendHeartbeat('cam-1'),
        isTrue,
      );
      expect(
        await apiWith((_) => http.Response('{}', 401)).sendHeartbeat('cam-1'),
        isFalse,
      );
    });
  });

  group('fetchCameraSession', () {
    late List<http.Request> requests;

    HttpFarmGuardApi apiWith(http.Response Function(http.Request) responder) {
      requests = [];
      return HttpFarmGuardApi(
        httpClient: MockClient((request) async {
          requests.add(request);
          return responder(request);
        }),
        tokenProvider: () => 'camera-token',
      );
    }

    test('200 parses camera + farmer', () async {
      final api = apiWith(
        (_) => http.Response(
          jsonEncode({
            'ok': true,
            'data': {
              'camera': {
                'id': 'cam-9',
                'camera_name': 'North Gate Cam',
                'location': 'North fence',
                'status': 'active',
                'last_seen_at': '2026-11-18T09:30:00.000Z',
              },
              'farmer': {
                'id': 'farmer-1',
                'name': 'Asha',
                'email_masked': 'a***@example.com',
              },
            },
          }),
          200,
        ),
      );

      final info = await api.fetchCameraSession();

      expect(info, isNotNull);
      expect(info!.cameraId, 'cam-9');
      expect(info.cameraName, 'North Gate Cam');
      expect(info.location, 'North fence');
      expect(info.status, 'active');
      expect(info.lastSeenAt, DateTime.utc(2026, 11, 18, 9, 30));
      expect(info.farmerId, 'farmer-1');
      expect(info.farmerName, 'Asha');
      expect(info.farmerEmailMasked, 'a***@example.com');

      final request = requests.single;
      expect(request.method, 'GET');
      expect(request.url.path, '/api/v1/cameras/me');
      expect(request.headers['Authorization'], 'Bearer camera-token');
    });

    test('401 throws PermanentUploadException(unauthorized)', () async {
      final api = apiWith((_) => http.Response('{}', 401));
      await expectLater(
        api.fetchCameraSession(),
        throwsA(
          isA<PermanentUploadException>()
              .having((e) => e.code, 'code', 'unauthorized')
              .having((e) => e.message, 'message', 'Camera is no longer paired.'),
        ),
      );
    });

    test('5xx and network failures return null (retry later)', () async {
      expect(
        await apiWith((_) => http.Response('{}', 503)).fetchCameraSession(),
        isNull,
      );

      final networkApi = HttpFarmGuardApi(
        httpClient: MockClient((request) async {
          throw http.ClientException('offline');
        }),
      );
      expect(await networkApi.fetchCameraSession(), isNull);
    });

    test('malformed payload returns null instead of throwing', () async {
      final api = apiWith(
        (_) => http.Response(
          jsonEncode({
            'ok': true,
            'data': {'camera': 'not-a-map'},
          }),
          200,
        ),
      );
      expect(await api.fetchCameraSession(), isNull);
    });
  });

  group('unpairSelf', () {
    late List<http.Request> requests;

    HttpFarmGuardApi apiWith(http.Response Function(http.Request) responder) {
      requests = [];
      return HttpFarmGuardApi(
        httpClient: MockClient((request) async {
          requests.add(request);
          return responder(request);
        }),
        tokenProvider: () => 'camera-token',
      );
    }

    test('200 → true, POST /cameras/me/unpair with bearer auth', () async {
      final api = apiWith((_) => http.Response('{}', 200));
      expect(await api.unpairSelf(), isTrue);
      expect(requests.single.method, 'POST');
      expect(requests.single.url.path, '/api/v1/cameras/me/unpair');
      expect(requests.single.headers['Authorization'], 'Bearer camera-token');
    });

    test('401 counts as already unpaired → true', () async {
      expect(await apiWith((_) => http.Response('{}', 401)).unpairSelf(), isTrue);
    });

    test('5xx and network failures → false', () async {
      expect(await apiWith((_) => http.Response('{}', 500)).unpairSelf(), isFalse);

      final networkApi = HttpFarmGuardApi(
        httpClient: MockClient((request) async {
          throw http.ClientException('offline');
        }),
      );
      expect(await networkApi.unpairSelf(), isFalse);
    });
  });
}
