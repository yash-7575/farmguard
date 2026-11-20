import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:farmguard_farmer/services/api/exceptions.dart';
import 'package:farmguard_farmer/services/api/http_farmer_api.dart';
import 'package:farmguard_farmer/services/api/token_store.dart';

import '../../helpers/api_fixtures.dart';

/// Fixture helper: builds the API with a MockClient and captures every
/// request for assertions.
class CapturingClient {
  CapturingClient(this.handler);

  // FutureOr so handlers can return a plain http.Response synchronously.
  final FutureOr<http.Response> Function(http.Request request) handler;
  final List<http.Request> requests = <http.Request>[];

  http.Client toClient() => MockClient((request) async {
        requests.add(request);
        return await handler(request);
      });
}

HttpFarmerApi apiWith(
  CapturingClient client, {
  TokenStore? tokenStore,
  Duration timeout = kFarmguardApiTimeout,
}) =>
    HttpFarmerApi(
      tokenStore: tokenStore ?? InMemoryTokenStore(),
      clientFactory: () => client.toClient(),
      timeout: timeout,
    );

/// success envelope helper
http.Response ok(Map<String, dynamic> data, {int status = 200}) =>
    jsonResponse(<String, dynamic>{'ok': true, 'data': data}, status: status);

void main() {
  group('envelope handling', () {
    test('unwraps success envelope for login and maps AuthResult',
        () async {
      final client = CapturingClient(
        (_) => ok(authData(token: 'tok-abc'), status: 200),
      );
      final api = apiWith(client);

      final result = await api.login('kiran@farm.test', 'password123');

      expect(result.token, 'tok-abc');
      expect(result.farmerId, 'farmer-1');
      expect(result.farmerName, 'Kiran');
      final request = client.requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/api/v1/auth/login');
      expect(request.body, '{"email":"kiran@farm.test","password":"password123"}');
    });

    test('error envelope maps to ApiException with server code and message',
        () async {
      final api = apiWith(
        CapturingClient(
          (_) => errorResponse(
            'invalid_credentials',
            'Email or password is incorrect.',
            status: 401,
          ),
        ),
      );

      final exception = await _catch(() => api.login('a@b.test', 'wrongpass'));

      expect(exception.statusCode, 401);
      expect(exception.code, 'invalid_credentials');
      expect(exception.message, 'Email or password is incorrect.');
      expect(exception.isUnauthorized, isTrue);
      expect(exception.isTransient, isFalse);
    });

    test('malformed (non-envelope) body → invalid_response ApiException',
        () async {
      final api = apiWith(
        CapturingClient(
          (_) => http.Response('<html>boom</html>', 200),
        ),
      );

      final exception = await _catch(() => api.me());
      expect(exception.code, 'invalid_response');
    });

    test('5xx with error envelope is transient', () async {
      final api = apiWith(
        CapturingClient(
          (_) => errorResponse('internal', 'boom', status: 500),
        ),
      );

      final exception = await _catch(() => api.listCameras());
      expect(exception.statusCode, 500);
      expect(exception.isTransient, isTrue);
      expect(exception.isUnauthorized, isFalse);
    });
  });

  group('auth endpoints', () {
    test('register posts body and maps 201 data', () async {
      final client = CapturingClient(
        (_) => ok(authData(token: 'tok-reg'), status: 201),
      );
      final api = apiWith(client);

      final result = await api.register('Kiran', 'kiran@farm.test', 'hunter2222');

      expect(result.token, 'tok-reg');
      expect(result.farmerName, 'Kiran');
      final request = client.requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/api/v1/auth/register');
      // Register never carries an Authorization header (no token yet).
      expect(request.headers.containsKey('Authorization'), isFalse);
    });

    test('register duplicate email 409 → ApiException email_taken',
        () async {
      final api = apiWith(
        CapturingClient(
          (_) => errorResponse('email_taken', 'Email already registered.',
              status: 409),
        ),
      );

      final exception = await _catch(
        () => api.register('Kiran', 'kiran@farm.test', 'hunter2222'),
      );
      expect(exception.statusCode, 409);
      expect(exception.code, 'email_taken');
      expect(exception.isUnauthorized, isFalse);
      expect(exception.isTransient, isFalse);
    });

    test('login bad credentials 401 → invalid_credentials', () async {
      final api = apiWith(
        CapturingClient(
          (_) => errorResponse('invalid_credentials', 'Nope.', status: 401),
        ),
      );

      final exception = await _catch(() => api.login('a@b.test', 'bad'));
      expect(exception.statusCode, 401);
      expect(exception.code, 'invalid_credentials');
    });

    test('me() sends stored Bearer token and returns farmer info', () async {
      final store = InMemoryTokenStore();
      await store.saveToken('tok-me');
      final client = CapturingClient(
        (_) => ok(<String, dynamic>{'farmer': farmerJson()}),
      );
      final api = apiWith(client, tokenStore: store);

      final result = await api.me();

      expect(result.farmerId, 'farmer-1');
      expect(result.farmerName, 'Kiran');
      expect(client.requests.single.method, 'GET');
      expect(client.requests.single.url.path, '/api/v1/auth/me');
      expect(client.requests.single.headers['Authorization'], 'Bearer tok-me');
    });
  });

  group('cameras', () {
    test('status mapping: offline / online / monitoring', () async {
      // Fresh heartbeats: the online/monitoring fixtures must be inside the
      // 120 s window no matter when the suite runs.
      final String freshSeen = DateTime.now().toUtc().toIso8601String();
      final api = apiWith(
        CapturingClient(
          (_) => ok(<String, dynamic>{
            'cameras': <dynamic>[
              cameraRow(id: 'cam-a', status: 'offline', lastSeenAt: null),
              cameraRow(id: 'cam-b', status: 'monitoring', lastSeenAt: freshSeen),
              cameraRow(id: 'cam-c', status: 'online', lastSeenAt: freshSeen),
            ],
          }),
        ),
      );

      final cameras = await api.listCameras();

      expect(cameras, hasLength(3));
      // offline → not online, not monitoring, never connected
      expect(cameras[0].id, 'cam-a');
      expect(cameras[0].isOnline, isFalse);
      expect(cameras[0].isMonitoring, isFalse);
      expect(cameras[0].lastConnected, isNull);
      // monitoring → online AND monitoring
      expect(cameras[1].isOnline, isTrue);
      expect(cameras[1].isMonitoring, isTrue);
      expect(
        cameras[1].lastConnected,
        DateTime.parse(freshSeen).toUtc(),
      );
      // online → online but not monitoring
      expect(cameras[2].isOnline, isTrue);
      expect(cameras[2].isMonitoring, isFalse);
    });

    test('stale heartbeat > 120 s maps to offline despite status online',
        () async {
      final api = apiWith(
        CapturingClient(
          (_) => ok(<String, dynamic>{
            'cameras': <dynamic>[
              cameraRow(
                id: 'cam-stale',
                status: 'monitoring',
                lastSeenAt: DateTime.now()
                    .toUtc()
                    .subtract(const Duration(minutes: 5))
                    .toIso8601String(),
              ),
            ],
          }),
        ),
      );

      final cameras = await api.listCameras();

      expect(cameras.single.isOnline, isFalse);
      expect(cameras.single.isMonitoring, isFalse);
      expect(cameras.single.lastConnected, isNotNull);
    });

    test('sends Authorization header from token store', () async {
      final store = InMemoryTokenStore();
      await store.saveToken('tok-42');
      final client = CapturingClient((_) => ok(<String, dynamic>{'cameras': []}));
      final api = apiWith(client, tokenStore: store);

      await api.listCameras();

      expect(
        client.requests.single.headers['Authorization'],
        'Bearer tok-42',
      );
    });
  });

  group('deleteCamera', () {
    test('sends DELETE /api/v1/cameras/<id> with the Bearer token', () async {
      final store = InMemoryTokenStore();
      await store.saveToken('tok-del');
      final client = CapturingClient(
        (_) => ok(<String, dynamic>{'deleted': true}),
      );
      final api = apiWith(client, tokenStore: store);

      await api.deleteCamera('cam-9');

      final request = client.requests.single;
      expect(request.method, 'DELETE');
      expect(request.url.path, '/api/v1/cameras/cam-9');
      expect(request.headers['Authorization'], 'Bearer tok-del');
    });

    test('404 unknown camera → ApiException not_found', () async {
      final api = apiWith(
        CapturingClient(
          (_) => errorResponse('not_found', 'Camera not found.', status: 404),
        ),
      );

      final exception = await _catch(() => api.deleteCamera('cam-x'));

      expect(exception.statusCode, 404);
      expect(exception.code, 'not_found');
      expect(exception.isUnauthorized, isFalse);
      expect(exception.isTransient, isFalse);
    });

    test('401 → ApiException with isUnauthorized (session expiry)', () async {
      final api = apiWith(
        CapturingClient(
          (_) => errorResponse(
            'unauthorized',
            'Token invalid or expired.',
            status: 401,
          ),
        ),
      );

      final exception = await _catch(() => api.deleteCamera('cam-1'));

      expect(exception.statusCode, 401);
      expect(exception.code, 'unauthorized');
      expect(exception.isUnauthorized, isTrue);
    });

    test('500 → transient ApiException', () async {
      final api = apiWith(
        CapturingClient(
          (_) => errorResponse('internal', 'boom', status: 500),
        ),
      );

      final exception = await _catch(() => api.deleteCamera('cam-1'));

      expect(exception.statusCode, 500);
      expect(exception.isTransient, isTrue);
      expect(exception.isUnauthorized, isFalse);
    });
  });

  group('events', () {
    test('maps rows correctly and passes next_before through', () async {
      final api = apiWith(
        CapturingClient(
          (_) => ok(<String, dynamic>{
            'events': <dynamic>[
              eventRow(id: 'evt-1', viewedAt: '2026-11-18T11:00:00.000Z'),
              eventRow(
                id: 'evt-2',
                confidence: 0.71,
                boundingBox: null,
                sourceType: 'DEMO',
              ),
            ],
            'next_before': '2026-11-18T10:15:00.000Z',
          }),
        ),
      );

      final page = await api.listEvents();

      expect(page.nextBefore, '2026-11-18T10:15:00.000Z');
      final first = page.events[0];
      expect(first.id, 'evt-1');
      expect(first.cameraId, 'cam-1');
      expect(first.detectionType, 'person');
      expect(first.confidence, 0.93);
      expect(first.sourceType, 'LIVE');
      expect(first.detectedAt, DateTime.utc(2026, 11, 18, 10, 15));
      expect(first.createdAt, DateTime.utc(2026, 11, 18, 10, 15, 1));
      expect(first.viewedAt, DateTime.utc(2026, 11, 18, 11));
      expect(first.boundingBox, hasLength(1));
      expect(first.boundingBox![0].left, 0.2);
      expect(first.boundingBox![0].top, 0.3);
      expect(first.boundingBox![0].width, 0.4);
      expect(first.boundingBox![0].height, 0.5);
      // null bounding_box → null boxes (codec maps to empty list)
      expect(page.events[1].boundingBox, isNull);
      expect(page.events[1].confidence, 0.71);
      expect(page.events[1].sourceType, 'DEMO');
    });

    test('query params: default limit, before, camera_id captured in URI',
        () async {
      final client = CapturingClient((_) => ok(<String, dynamic>{
            'events': <dynamic>[],
            'next_before': null,
          }));
      final api = apiWith(client);

      final firstPage = await api.listEvents();
      expect(firstPage.nextBefore, isNull);
      expect(client.requests.single.url.queryParameters['limit'], '20');
      expect(
        client.requests.single.url.queryParameters.containsKey('before'),
        isFalse,
      );

      await api.listEvents(
        limit: 50,
        before: '2026-11-18T10:00:00.000Z',
        cameraId: 'cam-9',
      );
      final uri = client.requests.last.url;
      expect(uri.path, '/api/v1/alerts');
      expect(uri.queryParameters['limit'], '50');
      expect(uri.queryParameters['before'], '2026-11-18T10:00:00.000Z');
      expect(uri.queryParameters['camera_id'], 'cam-9');
    });

    test('getEvent returns event detail with camera info', () async {
      final client = CapturingClient((_) => ok(detailData(eventId: 'evt-7')));
      final api = apiWith(client);

      final detail = await api.getEvent('evt-7');

      expect(detail.cameraName, 'Main Gate');
      expect(detail.cameraLocation, 'Farm entrance, north boundary');
      expect(detail.event.id, 'evt-7');
      expect(client.requests.single.url.path, '/api/v1/alerts/evt-7');
    });
  });

  group('markViewed', () {
    test('PATCHes viewed endpoint and returns updated row', () async {
      final client = CapturingClient(
        (_) => ok(<String, dynamic>{
          'event':
              eventRow(id: 'evt-1', viewedAt: '2026-11-18T12:00:00.000Z'),
          'updated': true,
        }),
      );
      final api = apiWith(client);

      final updated = await api.markViewed('evt-1');

      final request = client.requests.single;
      expect(request.method, 'PATCH');
      expect(request.url.path, '/api/v1/alerts/evt-1/viewed');
      expect(updated.viewedAt, DateTime.utc(2026, 11, 18, 12));
    });
  });

  group('getImageBytes', () {
    test('round-trips raw bytes without envelope parsing', () async {
      final bytes = Uint8List.fromList(<int>[1, 2, 3, 255, 0, 42]);
      final client = CapturingClient(
        (_) => bytesResponse(bytes),
      );
      final store = InMemoryTokenStore();
      await store.saveToken('tok-img');
      final api = apiWith(client, tokenStore: store);

      final result = await api.getImageBytes('evt-1');

      expect(result, bytes);
      final request = client.requests.single;
      expect(request.method, 'GET');
      expect(request.url.path, '/api/v1/images/evt-1');
      expect(request.headers['Authorization'], 'Bearer tok-img');
    });

    test('404 → ApiException not_found', () async {
      final api = apiWith(
        CapturingClient((_) => errorResponse('not_found', 'gone', status: 404)),
      );

      final exception = await _catch(() => api.getImageBytes('evt-1'));
      expect(exception.statusCode, 404);
      expect(exception.code, 'not_found');
      expect(exception.isTransient, isFalse);
    });
  });

  group('timeouts and network errors', () {
    test('slow response → transient timeout ApiException', () async {
      final api = apiWith(
        CapturingClient(
          (_) async {
            await Future<void>.delayed(const Duration(milliseconds: 300));
            return ok(<String, dynamic>{'cameras': []});
          },
        ),
        timeout: const Duration(milliseconds: 20),
      );

      final exception = await _catch(() => api.listCameras());
      expect(exception.statusCode, 0);
      expect(exception.code, 'timeout');
      expect(exception.isTransient, isTrue);
      expect(exception.isUnauthorized, isFalse);
    });

    test('ClientException (connection failure) → transient network error',
        () async {
      final api = apiWith(
        CapturingClient(
          (_) => throw http.ClientException('connection refused'),
        ),
      );

      final exception = await _catch(() => api.listCameras());
      expect(exception.statusCode, 0);
      expect(exception.code, 'network');
      expect(exception.isTransient, isTrue);
    });
  });

  group('device registration (push notifications)', () {
    test('registerDevice posts fcm_token + platform with the farmer auth '
        'header', () async {
      final client = CapturingClient(
        (_) => ok(<String, dynamic>{
          'device': <String, dynamic>{'id': 'dev-1'},
        }, status: 201),
      );
      final store = InMemoryTokenStore();
      await store.saveToken('tok-123');
      final api = apiWith(client, tokenStore: store);

      await api.registerDevice('fcm-token-1', platform: 'android');

      final request = client.requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/api/v1/notifications/register-device');
      expect(request.headers['Authorization'], 'Bearer tok-123');
      expect(
        jsonDecode(request.body),
        <String, dynamic>{'fcm_token': 'fcm-token-1', 'platform': 'android'},
      );
    });

    test('unregisterDevice sends DELETE with fcm_token and auth header',
        () async {
      final client = CapturingClient(
        (_) => ok(<String, dynamic>{'deleted': true}),
      );
      final store = InMemoryTokenStore();
      await store.saveToken('tok-123');
      final api = apiWith(client, tokenStore: store);

      await api.unregisterDevice('fcm-token-1');

      final request = client.requests.single;
      expect(request.method, 'DELETE');
      expect(request.url.path, '/api/v1/notifications/unregister-device');
      expect(request.headers['Authorization'], 'Bearer tok-123');
      expect(
        jsonDecode(request.body),
        <String, dynamic>{'fcm_token': 'fcm-token-1'},
      );
    });

    test('registerDevice 401 maps to unauthorized ApiException', () async {
      final api = apiWith(
        CapturingClient(
          (_) => errorResponse('unauthorized', 'Token invalid.', status: 401),
        ),
      );

      final exception = await _catch(() => api.registerDevice('fcm-token-1'));
      expect(exception.isUnauthorized, isTrue);
    });
  });

  group('pairing code', () {
    test('createPairingCode posts to /pairing/code with the auth header and '
        'parses code + expires_at', () async {
      final client = CapturingClient(
        (_) => ok(<String, dynamic>{
          'code': '428913',
          'expires_at': '2026-11-18T10:05:00.000Z',
        }, status: 201),
      );
      final store = InMemoryTokenStore();
      await store.saveToken('tok-123');
      final api = apiWith(client, tokenStore: store);

      final result = await api.createPairingCode();

      expect(result.code, '428913');
      expect(result.expiresAt, DateTime.utc(2026, 11, 18, 10, 5));
      final request = client.requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/api/v1/pairing/code');
      expect(request.headers['Authorization'], 'Bearer tok-123');
      expect(request.body, isEmpty);
    });

    test('createPairingCode 401 → unauthorized; 5xx → transient', () async {
      final unauthorized = apiWith(
        CapturingClient(
          (_) => errorResponse('unauthorized', 'Token invalid.', status: 401),
        ),
      );
      final transient = apiWith(
        CapturingClient(
          (_) => errorResponse('server_error', 'Down.', status: 503),
        ),
      );

      final unauth =
          await _catch(() => unauthorized.createPairingCode());
      expect(unauth.isUnauthorized, isTrue);
      final five =
          await _catch(() => transient.createPairingCode());
      expect(five.isTransient, isTrue);
    });

    test('missing code or expires_at → invalid_response', () async {
      final noCode = apiWith(
        CapturingClient((_) => ok(<String, dynamic>{
              'expires_at': '2026-11-18T10:05:00.000Z',
            }, status: 201)),
      );
      final noExpiry = apiWith(
        CapturingClient((_) => ok(<String, dynamic>{
              'code': '428913',
            }, status: 201)),
      );

      final first = await _catch(noCode.createPairingCode);
      expect(first.code, 'invalid_response');
      final second = await _catch(noExpiry.createPairingCode);
      expect(second.code, 'invalid_response');
    });
  });
}

/// Runs [call] and returns the thrown [ApiException]; fails the test if
/// nothing (or something else) is thrown.
Future<ApiException> _catch(Future<Object?> Function() call) async {
  try {
    await call();
    fail('Expected an ApiException but none was thrown.');
  } on ApiException catch (e) {
    return e;
  }
}
