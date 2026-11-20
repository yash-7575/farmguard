import 'dart:typed_data';

import '../../models/models.dart';

/// Auth response payload shared by register / login / me.
class AuthResult {
  final String token;
  final String farmerId;
  final String farmerName;

  /// The farmer's account email, when the backend returns it. Empty for
  /// payloads that omit the field — the UI treats '' as "not shown".
  final String email;

  const AuthResult({
    required this.token,
    required this.farmerId,
    required this.farmerName,
    this.email = '',
  });
}

/// A normalized bounding box exactly as the backend reports it (already
/// parsed; values are fractions 0.0–1.0 of the frame).
class ApiBoundingBox {
  final double left;
  final double top;
  final double width;
  final double height;

  const ApiBoundingBox({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });
}

/// One detection event row as returned by the alerts endpoints, with the
/// raw JSON fields kept intact. `lib/data/event_codec.dart` maps this to the
/// domain [DetectionEvent].
class ApiDetectionEvent {
  final String id;
  final String farmerId;
  final String cameraId;

  /// What was detected, e.g. `person`.
  final String detectionType;

  /// 0.0–1.0 model confidence.
  final double confidence;

  /// Backend storage object key of the captured frame, or `null` when the
  /// frame is not available.
  final String? imageObjectKey;

  /// Image MIME type (e.g. `image/jpeg`), or `null`.
  final String? imageContentType;

  /// Frame size in bytes, or `null`.
  final int? imageSize;

  /// Parsed bounding boxes; `null` when the event carries none.
  final List<ApiBoundingBox>? boundingBox;

  /// `LIVE` for real camera detections, `DEMO` for staged ones.
  final String sourceType;

  /// When the frame was captured (ISO-8601).
  final DateTime detectedAt;

  /// When the backend stored the event (ISO-8601).
  final DateTime createdAt;

  /// When the farmer marked the event viewed, or `null`.
  final DateTime? viewedAt;

  /// Server-side deduplication key.
  final String idempotencyKey;

  const ApiDetectionEvent({
    required this.id,
    required this.farmerId,
    required this.cameraId,
    required this.detectionType,
    required this.confidence,
    required this.imageObjectKey,
    required this.imageContentType,
    required this.imageSize,
    required this.boundingBox,
    required this.sourceType,
    required this.detectedAt,
    required this.createdAt,
    required this.viewedAt,
    required this.idempotencyKey,
  });
}

/// One page of events, newest first, plus the cursor to fetch the previous
/// (older) page. `null` when there are no older events.
class EventsPage {
  final List<ApiDetectionEvent> events;
  final String? nextBefore;

  const EventsPage({required this.events, required this.nextBefore});
}

/// A single event with its camera's display info, as returned by
/// `GET /alerts/{id}`.
class EventDetail {
  final ApiDetectionEvent event;
  final String cameraName;
  final String cameraLocation;

  const EventDetail({
    required this.event,
    required this.cameraName,
    required this.cameraLocation,
  });
}

/// A freshly generated camera pairing code. The code is 6 digits, valid for
/// 5 minutes from `expiresAt` and single-use — it is consumed by the
/// camera's redeem call (POST /api/v1/pairing/redeem).
class PairingCodeResult {
  final String code;

  /// When the code stops working (ISO-8601 from the backend, parsed).
  final DateTime expiresAt;

  const PairingCodeResult({required this.code, required this.expiresAt});
}

/// Farmer-facing backend API. Implemented by [HttpFarmerApi] in production;
/// tests fake this (usually with `package:http/testing.dart` MockClient) so
/// nothing ever touches a platform channel.
abstract class FarmerApi {
  /// Creates a farmer account. Duplicate email → 409 `email_taken`.
  Future<AuthResult> register(String name, String email, String password);

  /// Signs in. Bad credentials → 401 `invalid_credentials`.
  Future<AuthResult> login(String email, String password);

  /// Returns the signed-in farmer's info (requires a valid token).
  Future<AuthResult> me();

  /// All cameras owned by the signed-in farmer.
  Future<List<FarmCamera>> listCameras();

  /// Removes a camera from the farmer's account (`DELETE /cameras/{id}`).
  /// Unknown / foreign id → 404 [ApiException]; 401 → session expiry.
  Future<void> deleteCamera(String id);

  /// One page of detection events, newest first.
  Future<EventsPage> listEvents({int limit = 20, String? before, String? cameraId});

  /// A single event plus its camera name/location. Unknown/foreign → 404.
  Future<EventDetail> getEvent(String id);

  /// Marks the event viewed, returning the updated row.
  Future<ApiDetectionEvent> markViewed(String id);

  /// Raw JPEG bytes of the event's captured frame. Throws [ApiException] on
  /// 404 (frame unavailable) / 401 (bad token) — the caller decides how to
  /// render those cases.
  Future<Uint8List?> getImageBytes(String eventId);

  /// Registers this device's FCM token so the backend can push detection
  /// alerts (upsert keyed by token). Backend: 201 with the device row.
  Future<void> registerDevice(String token, {String platform = 'android'});

  /// Removes this device's FCM token (logout). Idempotent server-side.
  Future<void> unregisterDevice(String token);

  /// Generates a 6-digit pairing code to link a new farm camera.
  /// Requires a valid token; 401 → [ApiException.isUnauthorized] (session
  /// expiry), network/5xx → transient and safe to retry.
  Future<PairingCodeResult> createPairingCode();
}
