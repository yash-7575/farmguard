import 'dart:convert';

import 'package:http/http.dart' as http;

import 'pending_event_store.dart';

/// Base URL of the FarmGuard backend.
///
/// Deployed 2026-11-18 via `wrangler deploy` (production Cloudflare account).
/// Single const in this file — update here if the Worker URL changes.
const String defaultFarmGuardBaseUrl =
    'https://farmguard-backend.yashsb-75.workers.dev';

// ---------------------------------------------------------------------------
// Upload failure classification
// ---------------------------------------------------------------------------

/// Base class for alert-upload failures that carry the server's error code.
class UploadException implements Exception {
  UploadException(this.code, this.message);

  /// Server error code (e.g. `invalid_token`) or a synthetic one
  /// (`network`, `http_503`).
  final String code;

  /// Human-readable message, safe to show in the UI.
  final String message;

  @override
  String toString() => '$runtimeType($code): $message';
}

/// The server rejected the alert for a reason retrying cannot fix
/// (e.g. HTTP 400 invalid payload, HTTP 401 bad token). The queue marks
/// the event permanently failed immediately instead of burning attempts.
class PermanentUploadException extends UploadException {
  PermanentUploadException(super.code, super.message);
}

/// The upload failed transiently (network error, HTTP 5xx, HTTP 429 rate
/// limit). The queue keeps the event and retries with backoff.
class TransientUploadException extends UploadException {
  TransientUploadException(super.code, super.message);
}

/// The pairing code could not be redeemed. [message] is the server's own
/// error message when available, so the dialog can show it inline.
class PairingException implements Exception {
  PairingException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'PairingException($code): $message';
}

// ---------------------------------------------------------------------------
// Envelope parsing
// ---------------------------------------------------------------------------

/// Parsed `{ok: true, data: ...}` / `{ok: false, error: {code, message}}`
/// envelope used by every FarmGuard API endpoint.
class ApiEnvelope {
  const ApiEnvelope({
    required this.ok,
    this.data,
    this.errorCode,
    this.errorMessage,
  });

  final bool ok;
  final Object? data;
  final String? errorCode;
  final String? errorMessage;

  /// Throws [FormatException] when the body is not a JSON object (the
  /// callers wrap that into their own domain exception).
  factory ApiEnvelope.parse(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const FormatException('response body is not JSON');
    }
    if (decoded is! Map) {
      throw const FormatException('response is not a JSON object');
    }
    final error = decoded['error'];
    return ApiEnvelope(
      ok: decoded['ok'] == true,
      data: decoded['data'],
      errorCode: error is Map ? error['code'] as String? : null,
      errorMessage: error is Map ? error['message'] as String? : null,
    );
  }
}

// ---------------------------------------------------------------------------
// Pairing result
// ---------------------------------------------------------------------------

/// Successful `POST /api/v1/pairing/redeem` response.
class PairedCameraResult {
  const PairedCameraResult({
    required this.token,
    required this.cameraId,
    required this.cameraName,
    this.location,
    this.farmerId,
    this.farmerName,
    this.farmerEmailMasked,
  });

  /// Camera token used as `Authorization: Bearer <token>` on every
  /// subsequent camera-authenticated call.
  final String token;

  final String cameraId;
  final String cameraName;
  final String? location;

  /// Farmer account the camera was paired to (present only when the
  /// server includes the `farmer` object in the redeem response).
  final String? farmerId;
  final String? farmerName;
  final String? farmerEmailMasked;

  /// Extracts the result from the envelope `data` object.
  ///
  /// The camera name is accepted under either key the backend has used:
  /// `camera.camera_name` (canonical) or `camera.name` (legacy). This is
  /// Defect 1A: requiring only `name` made every real pairing response fail
  /// with "Unexpected server response".
  factory PairedCameraResult.fromData(Object? data) {
    if (data is! Map) {
      throw const FormatException('pairing response data missing');
    }
    final camera = data['camera'];
    if (camera is! Map) {
      throw const FormatException('pairing response camera missing');
    }
    final token = data['token'];
    final id = camera['id'];
    final rawName = camera['camera_name'] ?? camera['name'];
    if (token is! String || id is! String || rawName is! String) {
      throw const FormatException('pairing response fields missing');
    }
    final farmer = data['farmer'];
    final farmerMap = farmer is Map ? farmer : const <Object?, Object?>{};
    return PairedCameraResult(
      token: token,
      cameraId: id,
      cameraName: rawName,
      location: _stringOrNull(camera['location']),
      farmerId: _stringOrNull(farmerMap['id']),
      farmerName: _stringOrNull(farmerMap['name']),
      farmerEmailMasked: _stringOrNull(farmerMap['email_masked']),
    );
  }
}

/// Result classification for a camera heartbeat.
enum HeartbeatOutcome {
  /// 2xx — the server recorded the heartbeat.
  ok,

  /// 401/403 — the camera token is no longer accepted (camera removed or
  /// unpaired by the farmer). The device must drop its registration.
  unauthorized,

  /// Network error, 5xx, 429 or any other status: retry later.
  transientError,
}

/// `GET /api/v1/cameras/me` response: the server's current view of this
/// camera and the farmer account it belongs to.
class CameraSessionInfo {
  const CameraSessionInfo({
    required this.cameraId,
    required this.cameraName,
    this.location,
    this.status = 'active',
    this.lastSeenAt,
    this.farmerId,
    this.farmerName,
    this.farmerEmailMasked,
  });

  final String cameraId;
  final String cameraName;
  final String? location;
  final String status;
  final DateTime? lastSeenAt;
  final String? farmerId;
  final String? farmerName;
  final String? farmerEmailMasked;

  /// Parses the envelope `data` object (`{camera: {...}, farmer: {...}}`).
  factory CameraSessionInfo.fromData(Object? data) {
    if (data is! Map) {
      throw const FormatException('camera session data missing');
    }
    final camera = data['camera'];
    if (camera is! Map) {
      throw const FormatException('camera session camera missing');
    }
    final id = camera['id'];
    final rawName = camera['camera_name'] ?? camera['name'];
    if (id is! String || rawName is! String) {
      throw const FormatException('camera session fields missing');
    }
    final farmer = data['farmer'];
    final farmerMap = farmer is Map ? farmer : const <Object?, Object?>{};
    final lastSeenAt = _stringOrNull(camera['last_seen_at']);
    return CameraSessionInfo(
      cameraId: id,
      cameraName: rawName,
      location: _stringOrNull(camera['location']),
      status: _stringOrNull(camera['status']) ?? 'active',
      lastSeenAt: lastSeenAt == null ? null : DateTime.tryParse(lastSeenAt),
      farmerId: _stringOrNull(farmerMap['id']),
      farmerName: _stringOrNull(farmerMap['name']),
      farmerEmailMasked: _stringOrNull(farmerMap['email_masked']),
    );
  }
}

/// Returns [value] when it is a non-empty string, otherwise null. Keeps
/// JSON parsing tolerant of nulls, numbers and empty strings.
String? _stringOrNull(Object? value) {
  if (value is String && value.isNotEmpty) {
    return value;
  }
  return null;
}

// ---------------------------------------------------------------------------
// API interface
// ---------------------------------------------------------------------------

/// FarmGuard backend API, abstracted so tests can fake it without any
/// real HTTP or platform dependency.
abstract class FarmGuardApi {
  /// Redeems a 6-digit pairing code for this device. Throws
  /// [PairingException] on failure (including the server's own message).
  Future<PairedCameraResult> redeemPairingCode({
    required String code,
    required String deviceIdentifier,
    required String cameraName,
    String? location,
  });

  /// Sends a heartbeat so the server can mark the camera as seen.
  /// Returns `true` only on a 2xx response.
  Future<bool> sendHeartbeat(String cameraId);

  /// Sends a heartbeat and classifies the outcome so the caller can react
  /// to an invalidated camera token (401/403) by dropping the registration.
  ///
  /// The default implementation adapts [sendHeartbeat], so existing API
  /// fakes keep working unchanged.
  Future<HeartbeatOutcome> sendHeartbeatDetailed(
    String cameraId, {
    String status = 'monitoring',
  }) async {
    final ok = await sendHeartbeat(cameraId);
    return ok ? HeartbeatOutcome.ok : HeartbeatOutcome.transientError;
  }

  /// Fetches the server's view of this camera (`GET /api/v1/cameras/me`).
  ///
  /// Returns null when the session cannot be read right now (network error
  /// or 5xx); throws [PermanentUploadException] with code `unauthorized`
  /// when the camera is no longer paired.
  Future<CameraSessionInfo?> fetchCameraSession() async => null;

  /// Asks the server to unpair this camera (`POST /api/v1/cameras/me/unpair`).
  /// Returns `true` when the camera is no longer paired afterwards (200 or
  /// an already-unpaired 401), `false` on a network/5xx failure.
  Future<bool> unpairSelf() async => false;

  /// Uploads a confirmed detection event. Returns `true` when the server
  /// durably accepted it (201 created or 200 duplicate — the event id is
  /// the idempotency key, so a duplicate means it was already stored).
  ///
  /// Failure classification:
  /// - HTTP 4xx except 429 → [PermanentUploadException];
  /// - network error, HTTP 5xx, HTTP 429 → [TransientUploadException]
  ///   (also `false`-equivalent for callers that only check outcome).
  Future<bool> sendAlert(String cameraId, PendingEvent event);
}

/// HTTP implementation of [FarmGuardApi] (and [UploadClient] for the
/// queue) against the fixed backend contract. Never logs tokens.
class HttpFarmGuardApi implements FarmGuardApi, UploadClient {
  HttpFarmGuardApi({
    http.Client? httpClient,
    this.baseUrl = defaultFarmGuardBaseUrl,
    this.tokenProvider,
  }) : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;
  final String baseUrl;

  /// Supplies the camera token for authenticated calls; typically reads
  /// the current registration (see `CloudServices`). When it returns
  /// null, no Authorization header is sent.
  final String? Function()? tokenProvider;

  Map<String, String> _headers({bool authenticated = false}) {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (authenticated) {
      final token = tokenProvider?.call();
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }
    }
    return headers;
  }

  Future<http.Response> _post(
    String path, {
    required Object? body,
    bool authenticated = false,
  }) {
    return _httpClient.post(
      Uri.parse('$baseUrl$path'),
      headers: _headers(authenticated: authenticated),
      body: jsonEncode(body),
    );
  }

  @override
  Future<PairedCameraResult> redeemPairingCode({
    required String code,
    required String deviceIdentifier,
    required String cameraName,
    String? location,
  }) async {
    http.Response response;
    try {
      response = await _post(
        '/api/v1/pairing/redeem',
        body: {
          'code': code,
          'device_identifier': deviceIdentifier,
          'camera_name': cameraName,
          if (location != null && location.isNotEmpty) 'location': location,
        },
      );
    } catch (_) {
      throw PairingException('network', 'Could not reach the FarmGuard server.');
    }
    ApiEnvelope envelope;
    try {
      envelope = ApiEnvelope.parse(response.body);
    } on FormatException {
      throw PairingException('invalid_response', 'Unexpected server response.');
    }
    if (!envelope.ok || response.statusCode >= 400) {
      throw PairingException(
        envelope.errorCode ?? 'pairing_failed',
        envelope.errorMessage ?? 'Pairing failed.',
      );
    }
    try {
      return PairedCameraResult.fromData(envelope.data);
    } on FormatException {
      throw PairingException('invalid_response', 'Unexpected server response.');
    }
  }

  @override
  Future<bool> sendHeartbeat(String cameraId) async {
    return await sendHeartbeatDetailed(cameraId) == HeartbeatOutcome.ok;
  }

  @override
  Future<HeartbeatOutcome> sendHeartbeatDetailed(
    String cameraId, {
    String status = 'monitoring',
  }) async {
    try {
      final response = await _post(
        '/api/v1/cameras/$cameraId/heartbeat',
        body: {'status': status},
        authenticated: true,
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return HeartbeatOutcome.ok;
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        return HeartbeatOutcome.unauthorized;
      }
      return HeartbeatOutcome.transientError;
    } catch (_) {
      return HeartbeatOutcome.transientError;
    }
  }

  @override
  Future<CameraSessionInfo?> fetchCameraSession() async {
    final http.Response response;
    try {
      response = await _httpClient.get(
        Uri.parse('$baseUrl/api/v1/cameras/me'),
        headers: _headers(authenticated: true),
      );
    } catch (_) {
      // Network failure: the camera keeps its registration and retries.
      return null;
    }
    if (response.statusCode == 401) {
      throw PermanentUploadException(
        'unauthorized',
        'Camera is no longer paired.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }
    ApiEnvelope envelope;
    try {
      envelope = ApiEnvelope.parse(response.body);
    } on FormatException {
      return null;
    }
    if (!envelope.ok) {
      return null;
    }
    try {
      return CameraSessionInfo.fromData(envelope.data);
    } on FormatException {
      return null;
    }
  }

  @override
  Future<bool> unpairSelf() async {
    try {
      final response = await _post(
        '/api/v1/cameras/me/unpair',
        body: const <String, Object?>{},
        authenticated: true,
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return true;
      }
      // 401 means the server already considers this camera unpaired.
      return response.statusCode == 401;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> sendAlert(String cameraId, PendingEvent event) async {
    final http.Response response;
    try {
      response = await _post(
        '/api/v1/alerts',
        body: _alertBody(event),
        authenticated: true,
      );
    } catch (error) {
      throw TransientUploadException('network', 'Upload failed: $error');
    }
    // 201 = created, 200 = duplicate (same event id already stored) —
    // both mean the server durably has the event.
    if (response.statusCode == 200 || response.statusCode == 201) {
      return true;
    }
    ApiEnvelope? envelope;
    try {
      envelope = ApiEnvelope.parse(response.body);
    } on FormatException {
      envelope = null;
    }
    final code = envelope?.errorCode ?? 'http_${response.statusCode}';
    final message = envelope?.errorMessage ??
        'Alert upload failed (HTTP ${response.statusCode}).';
    if (response.statusCode == 429 || response.statusCode >= 500) {
      throw TransientUploadException(code, message);
    }
    if (response.statusCode >= 400) {
      throw PermanentUploadException(code, message);
    }
    throw TransientUploadException(code, message);
  }

  /// Alert payload per the backend contract. The event id doubles as the
  /// idempotency key. Image fields are sent only when the event carries a
  /// cached R2 object key (uploaded via [uploadEvent]); otherwise they are
  /// null — the backend accepts nullable image fields, so imageless
  /// events (dropped snapshot or no capture) are first-class.
  Map<String, Object?> _alertBody(PendingEvent event) {
    final box = event.boundingBox;
    final hasImage = event.imageObjectKey != null;
    return {
      'id': event.eventId,
      'confidence': event.confidence,
      'bounding_box': box == null
          ? null
          : [
              {
                'left': box.left,
                'top': box.top,
                'width': box.width,
                'height': box.height,
              },
            ],
      'image_object_key': event.imageObjectKey,
      'image_content_type':
          hasImage ? (event.imageContentType ?? 'image/jpeg') : null,
      'image_size': hasImage ? event.imageBytes?.length : null,
      'detected_at': event.capturedAt,
    };
  }

  /// [UploadClient] adapter: the camera token already identifies the
  /// camera, so the camera id is not needed in the URL.
  ///
  /// Image flow (Stage 5 part 3):
  /// 1. Cached key present (`event.imageObjectKey != null`) → the image
  ///    POST is skipped entirely; the alert references the cached key.
  /// 2. Otherwise, snapshot bytes present → `POST /api/v1/images` with the
  ///    raw JPEG bytes. On 201 the returned `object_key` is handed to
  ///    [onImageKeyObtained] — persisted by the queue *before* the alert
  ///    POST, so a crash between the two leaves the key cached and a
  ///    retry never re-uploads the image.
  /// 3. Transient image failure (network, 5xx, 429, unparsable response)
  ///    → the whole upload fails with [TransientUploadException]; the
  ///    event stays queued and the image is attempted again later.
  /// 4. Permanent image failure (413 too large, 400 rejected) → the image
  ///    can never succeed, so it is dropped ([onImageDropped] fires, bytes
  ///    and MIME cleared) and the alert still uploads — imageless — so the
  ///    detection metadata reaches the farmer.
  /// 5. Other token/status failures classify exactly like the alert POST
  ///    (4xx → permanent, 429/5xx → transient).
  @override
  Future<bool> uploadEvent(
    PendingEvent event, {
    OnImageKeyObtained? onImageKeyObtained,
    OnImageDropped? onImageDropped,
  }) async {
    var working = event;
    if (working.imageObjectKey == null && working.imageBytes != null) {
      working = await _uploadImage(
        working,
        onImageKeyObtained: onImageKeyObtained,
        onImageDropped: onImageDropped,
      );
    }
    return sendAlert('', working);
  }

  /// Uploads the snapshot to `POST /api/v1/images` (raw JPEG body, camera
  /// token auth). Returns the event updated per the outcome: with the
  /// cached [PendingEvent.imageObjectKey] on success, or with the image
  /// dropped on a permanent image failure. Throws [UploadException] when
  /// the whole upload must be retried later.
  Future<PendingEvent> _uploadImage(
    PendingEvent event, {
    OnImageKeyObtained? onImageKeyObtained,
    OnImageDropped? onImageDropped,
  }) async {
    final bytes = event.imageBytes!;
    final http.Response response;
    try {
      response = await _httpClient.post(
        Uri.parse('$baseUrl/api/v1/images'),
        headers: _imageHeaders(),
        body: bytes,
      );
    } catch (error) {
      throw TransientUploadException('network', 'Image upload failed: $error');
    }

    if (response.statusCode == 201) {
      ApiEnvelope envelope;
      try {
        envelope = ApiEnvelope.parse(response.body);
      } on FormatException {
        throw TransientUploadException(
          'invalid_response',
          'Image upload response was not valid JSON.',
        );
      }
      if (!envelope.ok) {
        throw TransientUploadException(
          envelope.errorCode ?? 'image_upload_failed',
          envelope.errorMessage ?? 'Image upload failed.',
        );
      }
      final data = envelope.data;
      final objectKey = data is Map ? data['object_key'] : null;
      if (objectKey is! String || objectKey.isEmpty) {
        throw TransientUploadException(
          'invalid_response',
          'Image upload response is missing object_key.',
        );
      }
      // Persist the key BEFORE the alert POST (the hook does
      // store.replace on the queue side), so a crash between the two
      // leaves the key cached and retries never re-upload the image.
      if (onImageKeyObtained != null) {
        await onImageKeyObtained(event.eventId, objectKey);
      }
      return event.copyWith(imageObjectKey: objectKey);
    }

    if (response.statusCode == 413 || response.statusCode == 400) {
      // The image can never succeed (too large or rejected payload), so
      // dropping it loses nothing: the detection metadata still reaches
      // the farmer, just without the snapshot. Nothing fatal is recorded.
      if (onImageDropped != null) {
        await onImageDropped(event.eventId);
      }
      return event.copyWith(clearImage: true);
    }

    // Any other status classifies exactly like the alert endpoint.
    ApiEnvelope? envelope;
    try {
      envelope = ApiEnvelope.parse(response.body);
    } on FormatException {
      envelope = null;
    }
    final code = envelope?.errorCode ?? 'http_${response.statusCode}';
    final message = envelope?.errorMessage ??
        'Image upload failed (HTTP ${response.statusCode}).';
    if (response.statusCode == 429 || response.statusCode >= 500) {
      throw TransientUploadException(code, message);
    }
    if (response.statusCode >= 400) {
      throw PermanentUploadException(code, message);
    }
    throw TransientUploadException(code, message);
  }

  /// Headers for the raw image upload: JPEG content type + camera token.
  Map<String, String> _imageHeaders() {
    final headers = <String, String>{'Content-Type': 'image/jpeg'};
    final token = tokenProvider?.call();
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  /// Releases the underlying HTTP client.
  void close() {
    _httpClient.close();
  }
}
