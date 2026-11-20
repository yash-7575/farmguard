import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../data/event_codec.dart';
import '../../models/models.dart';
import 'exceptions.dart';
import 'farmer_api.dart';
import 'token_store.dart';

/// Base URL of the FarmGuard backend.
///
/// PLACEHOLDER — set to the real deployed Workers URL after deployment.
/// This is the single source of truth: every request in this file builds its
/// URI from this constant, so deployment is a one-line change here.
const String kFarmguardApiBaseUrl = 'https://farmguard-backend.yashsb-75.workers.dev';

/// Applied to every request. `package:http` does not time out by default,
/// so each call is wrapped with `.timeout`; expiry maps to a transient
/// [ApiException] (`timeout`).
const Duration kFarmguardApiTimeout = Duration(seconds: 15);

/// Production [FarmerApi] over `package:http`.
///
/// Backend contract (see `farmer_api.dart`):
/// - every JSON response is the envelope `{ok: true, data: ...}` on success
///   and `{ok: false, error: {code, message}}` on failure;
/// - auth is a `Authorization: Bearer <token>` header, with the token read
///   from the injectable [TokenStore] (tests inject [InMemoryTokenStore]);
/// - `GET /images/{id}` returns raw image bytes, not the envelope.
///
/// The [http.Client] is only created lazily on first request, so tests that
/// inject a MockClient never construct a real client and stay platform-free.
/// Tokens are never logged.
class HttpFarmerApi implements FarmerApi {
  HttpFarmerApi({
    required this.tokenStore,
    http.Client Function()? clientFactory,
    this.timeout = kFarmguardApiTimeout,
  }) : _clientFactory = clientFactory ?? http.Client.new;

  /// Source of the Bearer token for every authenticated request. Injectable
  /// so tests can supply [InMemoryTokenStore] and never touch platform
  /// channels; also lets callers swap/clear the session in one place.
  final TokenStore tokenStore;
  final http.Client Function() _clientFactory;

  /// Request timeout for all calls.
  final Duration timeout;

  http.Client? _client;
  http.Client get _http => _client ??= _clientFactory();

  // ---------------------------------------------------------------------------
  // FarmerApi
  // ---------------------------------------------------------------------------

  @override
  Future<AuthResult> register(String name, String email, String password) async {
    final data = await _jsonRequest(
      'POST',
      Uri.parse('$kFarmguardApiBaseUrl/api/v1/auth/register'),
      body: jsonEncode(<String, String>{
        'name': name,
        'email': email,
        'password': password,
      }),
      auth: false,
      jsonBody: true,
    );
    return _parseAuth(data);
  }

  @override
  Future<AuthResult> login(String email, String password) async {
    final data = await _jsonRequest(
      'POST',
      Uri.parse('$kFarmguardApiBaseUrl/api/v1/auth/login'),
      body: jsonEncode(<String, String>{'email': email, 'password': password}),
      auth: false,
      jsonBody: true,
    );
    return _parseAuth(data);
  }

  @override
  Future<AuthResult> me() async {
    final data = await _jsonRequest(
      'GET',
      Uri.parse('$kFarmguardApiBaseUrl/api/v1/auth/me'),
    );
    final farmer = _requireMap(data['farmer'], 'data.farmer');
    return AuthResult(
      token: await tokenStore.readToken() ?? '',
      farmerId: farmer['id'] as String,
      farmerName: farmer['name'] as String,
      email: (farmer['email'] as String?) ?? '',
    );
  }

  @override
  Future<List<FarmCamera>> listCameras() async {
    final data = await _jsonRequest(
      'GET',
      Uri.parse('$kFarmguardApiBaseUrl/api/v1/cameras'),
    );
    final rows = _requireList(data['cameras'], 'data.cameras');
    return <FarmCamera>[
      for (final row in rows) toFarmCamera(_requireMap(row, 'camera row')),
    ];
  }

  @override
  Future<void> deleteCamera(String id) async {
    await _jsonRequest(
      'DELETE',
      Uri.parse('$kFarmguardApiBaseUrl/api/v1/cameras/$id'),
    );
  }

  @override
  Future<EventsPage> listEvents({
    int limit = 20,
    String? before,
    String? cameraId,
  }) async {
    final query = <String, String>{'limit': '$limit'};
    if (before != null) query['before'] = before;
    if (cameraId != null) query['camera_id'] = cameraId;
    final uri = Uri.parse('$kFarmguardApiBaseUrl/api/v1/alerts')
        .replace(queryParameters: query);
    final data = await _jsonRequest('GET', uri);
    final rows = _requireList(data['events'], 'data.events');
    return EventsPage(
      events: <ApiDetectionEvent>[
        for (final row in rows) _parseEventRow(_requireMap(row, 'event row')),
      ],
      nextBefore: data['next_before'] as String?,
    );
  }

  @override
  Future<EventDetail> getEvent(String id) async {
    final data = await _jsonRequest(
      'GET',
      Uri.parse('$kFarmguardApiBaseUrl/api/v1/alerts/$id'),
    );
    final camera = _requireMap(data['camera'], 'data.camera');
    return EventDetail(
      event: _parseEventRow(_requireMap(data['event'], 'data.event')),
      cameraName: camera['name'] as String,
      cameraLocation: camera['location'] as String,
    );
  }

  @override
  Future<ApiDetectionEvent> markViewed(String id) async {
    final data = await _jsonRequest(
      'PATCH',
      Uri.parse('$kFarmguardApiBaseUrl/api/v1/alerts/$id/viewed'),
      jsonBody: true,
    );
    return _parseEventRow(_requireMap(data['event'], 'data.event'));
  }

  @override
  Future<Uint8List?> getImageBytes(String eventId) async {
    final uri = Uri.parse('$kFarmguardApiBaseUrl/api/v1/images/$eventId');
    // Raw bytes — no envelope parsing, no JSON decode.
    final response = await _run(() async {
      final headers = await _headers();
      return _http.get(uri, headers: headers);
    });
    if (response.statusCode != 200) {
      throw ApiException(
        statusCode: response.statusCode,
        code: response.statusCode == 404
            ? 'not_found'
            : response.statusCode == 401
                ? 'unauthorized'
                : 'image_unavailable',
        message: 'Frame for event $eventId unavailable '
            '(HTTP ${response.statusCode}).',
      );
    }
    return response.bodyBytes;
  }

  @override
  Future<void> registerDevice(String token, {String platform = 'android'}) async {
    await _jsonRequest(
      'POST',
      Uri.parse('$kFarmguardApiBaseUrl/api/v1/notifications/register-device'),
      body: jsonEncode(<String, String>{'fcm_token': token, 'platform': platform}),
      jsonBody: true,
    );
  }

  @override
  Future<void> unregisterDevice(String token) async {
    await _jsonRequest(
      'DELETE',
      Uri.parse('$kFarmguardApiBaseUrl/api/v1/notifications/unregister-device'),
      body: jsonEncode(<String, String>{'fcm_token': token}),
      jsonBody: true,
    );
  }

  @override
  Future<PairingCodeResult> createPairingCode() async {
    // The route reads no body (see farmguard-backend pairing.ts) — the
    // farmer token in the Authorization header is all it needs.
    final data = await _jsonRequest(
      'POST',
      Uri.parse('$kFarmguardApiBaseUrl/api/v1/pairing/code'),
    );
    final String? code = data['code'] as String?;
    final DateTime? expiresAt =
        parseIso8601Utc(data['expires_at'] as String?);
    if (code == null || expiresAt == null) {
      throw ApiException(
        statusCode: 0,
        code: 'invalid_response',
        message: 'Pairing-code response missing code or expiry.',
      );
    }
    return PairingCodeResult(code: code, expiresAt: expiresAt);
  }

  // ---------------------------------------------------------------------------
  // Envelope + row parsing
  // ---------------------------------------------------------------------------

  /// Sends a JSON-API request and unwraps the `{ok, data}` envelope.
  Future<Map<String, dynamic>> _jsonRequest(
    String method,
    Uri uri, {
    String? body,
    bool auth = true,
    bool jsonBody = false,
  }) async {
    final response = await _run(() async {
      final headers = await _headers(auth: auth, json: jsonBody);
      switch (method) {
        case 'GET':
          return _http.get(uri, headers: headers);
        case 'POST':
          return _http.post(uri, headers: headers, body: body, encoding: utf8);
        case 'PATCH':
          return _http.patch(
            uri,
            headers: headers,
            body: body ?? '',
            encoding: utf8,
          );
        case 'DELETE':
          return _http.delete(uri, headers: headers, body: body, encoding: utf8);
        default:
          throw StateError('Unsupported HTTP method: $method');
      }
    });
    return _unwrap(response);
  }

  /// Validates the response envelope: success → `data`, failure → throw
  /// [ApiException] carrying status + server error code/message.
  Map<String, dynamic> _unwrap(http.Response response) {
    final Map<String, dynamic>? body = _tryDecodeJson(response);
    if (body == null) {
      throw ApiException(
        statusCode: response.statusCode,
        code: 'invalid_response',
        message: 'Backend returned a non-JSON body (HTTP '
            '${response.statusCode}).',
      );
    }
    if (body['ok'] == true) {
      final data = body['data'];
      if (data is Map<String, dynamic>) return data;
      throw ApiException(
        statusCode: response.statusCode,
        code: 'invalid_response',
        message: 'Success envelope without a data object.',
      );
    }
    final error = body['error'];
    if (error is Map<String, dynamic>) {
      throw ApiException(
        statusCode: response.statusCode,
        code: (error['code'] as String?) ?? 'unknown',
        message: (error['message'] as String?) ?? 'Request failed.',
      );
    }
    throw ApiException(
      statusCode: response.statusCode,
      code: 'invalid_response',
      message: 'Malformed error envelope.',
    );
  }

  Map<String, dynamic>? _tryDecodeJson(http.Response response) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  AuthResult _parseAuth(Map<String, dynamic> data) {
    final farmer = _requireMap(data['farmer'], 'data.farmer');
    return AuthResult(
      token: data['token'] as String,
      farmerId: farmer['id'] as String,
      farmerName: farmer['name'] as String,
      email: (farmer['email'] as String?) ?? '',
    );
  }

  ApiDetectionEvent _parseEventRow(Map<String, dynamic> row) {
    final boxes = row['bounding_box'];
    return ApiDetectionEvent(
      id: row['id'] as String,
      farmerId: row['farmer_id'] as String,
      cameraId: row['camera_id'] as String,
      detectionType: row['detection_type'] as String,
      confidence: (row['confidence'] as num?)?.toDouble() ?? 0,
      imageObjectKey: row['image_object_key'] as String?,
      imageContentType: row['image_content_type'] as String?,
      imageSize: row['image_size'] as int?,
      boundingBox: boxes == null
          ? null
          : <ApiBoundingBox>[
              for (final box in boxes as List<dynamic>)
                ApiBoundingBox(
                  left: ((box as Map<String, dynamic>)['left'] as num? ?? 0)
                      .toDouble(),
                  top: (box['top'] as num? ?? 0).toDouble(),
                  width: (box['width'] as num? ?? 0).toDouble(),
                  height: (box['height'] as num? ?? 0).toDouble(),
                ),
            ],
      sourceType: row['source_type'] as String,
      // Tolerant: contract guarantees detected_at, but fall back to
      // created_at and finally the epoch so a malformed row cannot crash
      // the app.
      detectedAt:
          parseIso8601Utc(row['detected_at'] as String?) ??
              parseIso8601Utc(row['created_at'] as String?) ??
              DateTime.fromMillisecondsSinceEpoch(0),
      createdAt:
          parseIso8601Utc(row['created_at'] as String?) ??
              DateTime.fromMillisecondsSinceEpoch(0),
      viewedAt: parseIso8601Utc(row['viewed_at'] as String?),
      idempotencyKey: row['idempotency_key'] as String? ?? '',
    );
  }

  // ---------------------------------------------------------------------------
  // Transport helpers
  // ---------------------------------------------------------------------------

  /// Runs [operation] with the request timeout; network-level failures and
  /// timeouts become transient [ApiException]s instead of raw socket errors.
  Future<http.Response> _run(
    Future<http.Response> Function() operation,
  ) async {
    try {
      return await operation().timeout(timeout);
    } on TimeoutException {
      throw ApiException(
        statusCode: 0,
        code: 'timeout',
        message: 'Backend request timed out after ${timeout.inSeconds} s.',
      );
    } on http.ClientException catch (e) {
      throw ApiException(
        statusCode: 0,
        code: 'network',
        message: 'Network error: ${e.message}',
      );
    }
  }

  Future<Map<String, String>> _headers({
    bool auth = true,
    bool json = false,
  }) async {
    final headers = <String, String>{};
    if (json) headers['Content-Type'] = 'application/json; charset=utf-8';
    if (auth) {
      final token = await tokenStore.readToken();
      // Attached only when present; never logged.
      if (token != null) headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  Map<String, dynamic> _requireMap(Object? value, String what) {
    if (value is Map<String, dynamic>) return value;
    throw ApiException(
      statusCode: 0,
      code: 'invalid_response',
      message: 'Expected an object for $what.',
    );
  }

  List<dynamic> _requireList(Object? value, String what) {
    if (value is List<dynamic>) return value;
    throw ApiException(
      statusCode: 0,
      code: 'invalid_response',
      message: 'Expected a list for $what.',
    );
  }
}
