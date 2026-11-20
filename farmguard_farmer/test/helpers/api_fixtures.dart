/// Canned JSON matching the FarmGuard backend contract exactly, plus a
/// configurable [FakeFarmerApi] for repository tests. Pure Dart throughout.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:farmguard_farmer/models/models.dart';
import 'package:farmguard_farmer/services/api/exceptions.dart';
import 'package:farmguard_farmer/services/api/farmer_api.dart';
import 'package:farmguard_farmer/services/api/token_store.dart';
import 'package:farmguard_farmer/services/messaging/messaging_gateway.dart';

// ---------------------------------------------------------------------------
// JSON row builders (shape per the backend contract)
// ---------------------------------------------------------------------------

Map<String, dynamic> farmerJson({
  String id = 'farmer-1',
  String name = 'Kiran',
  String email = 'kiran@farm.test',
}) =>
    <String, dynamic>{'id': id, 'name': name, 'email': email};

Map<String, dynamic> authData({String token = 'tok-123'}) =>
    <String, dynamic>{'token': token, 'farmer': farmerJson()};

/// Sentinel for [cameraRow]'s `lastSeenAt`: lets an omitted argument default
/// to "just now" (computed at call time) while an explicit `null` still
/// means "never connected". A compile-time default cannot be dynamic, and a
/// fixed timestamp would age past the 120 s online threshold.
const Object _lastSeenUnset = Object();

Map<String, dynamic> cameraRow({
  String id = 'cam-1',
  String farmerId = 'farmer-1',
  String cameraName = 'Main Gate',
  String location = 'Farm entrance, north boundary',
  String status = 'online',
  Object? lastSeenAt = _lastSeenUnset,
  String createdAt = '2026-10-01T06:00:00.000Z',
}) {
  // Default: a heartbeat from right now, so a `status: 'online'` fixture is
  // genuinely online under `kCameraOnlineThreshold`. Pass a literal string
  // for a fixed timestamp, or `null` for "never connected".
  final String? lastSeen = identical(lastSeenAt, _lastSeenUnset)
      ? DateTime.now().toUtc().toIso8601String()
      : lastSeenAt as String?;
  return <String, dynamic>{
    'id': id,
    'farmer_id': farmerId,
    'camera_name': cameraName,
    'location': location,
    'status': status,
    'last_seen_at': lastSeen,
    'created_at': createdAt,
  };
}

/// Detection event row exactly as `GET /alerts` returns it.
Map<String, dynamic> eventRow({
  String id = 'evt-1',
  String farmerId = 'farmer-1',
  String cameraId = 'cam-1',
  String detectionType = 'person',
  double confidence = 0.93,
  String? imageObjectKey = 'images/evt-1.jpg',
  String? imageContentType = 'image/jpeg',
  int? imageSize = 1024,
  List<Map<String, dynamic>>? boundingBox = const <Map<String, dynamic>>[
    <String, dynamic>{'left': 0.2, 'top': 0.3, 'width': 0.4, 'height': 0.5},
  ],
  String sourceType = 'LIVE',
  String detectedAt = '2026-11-18T10:15:00.000Z',
  String createdAt = '2026-11-18T10:15:01.000Z',
  String? viewedAt,
  String idempotencyKey = 'idem-1',
}) =>
    <String, dynamic>{
      'id': id,
      'farmer_id': farmerId,
      'camera_id': cameraId,
      'detection_type': detectionType,
      'confidence': confidence,
      'image_object_key': imageObjectKey,
      'image_content_type': imageContentType,
      'image_size': imageSize,
      'bounding_box': boundingBox,
      'source_type': sourceType,
      'detected_at': detectedAt,
      'created_at': createdAt,
      'viewed_at': viewedAt,
      'idempotency_key': idempotencyKey,
    };

Map<String, dynamic> detailData({String? eventId}) =>
    <String, dynamic>{
      'event': eventRow(id: eventId ?? 'evt-1'),
      'camera': <String, dynamic>{
        'id': 'cam-1',
        'name': 'Main Gate',
        'location': 'Farm entrance, north boundary',
      },
    };

// ---------------------------------------------------------------------------
// Envelope responses
// ---------------------------------------------------------------------------

http.Response jsonResponse(Map<String, dynamic> envelope, {int status = 200}) =>
    http.Response(
      // Encoded text, so the HTTP layer parses real JSON strings like in
      // production.
      jsonEncode(envelope),
      status,
      headers: <String, String>{'content-type': 'application/json'},
    );

http.Response errorResponse(
  String code,
  String message, {
  int status = 400,
}) =>
    jsonResponse(
      <String, dynamic>{
        'ok': false,
        'error': <String, dynamic>{'code': code, 'message': message},
      },
      status: status,
    );

http.Response bytesResponse(
  List<int> bytes, {
  int status = 200,
  String contentType = 'image/jpeg',
}) =>
    http.Response.bytes(
      bytes,
      status,
      headers: <String, String>{'content-type': contentType},
    );

// ---------------------------------------------------------------------------
// Typed DTO builders (for FakeFarmerApi)
// ---------------------------------------------------------------------------

ApiBoundingBox apiBox({double l = 0.2, double t = 0.3, double w = 0.4, double h = 0.5}) =>
    ApiBoundingBox(left: l, top: t, width: w, height: h);

ApiDetectionEvent apiEvent({
  String id = 'evt-1',
  String cameraId = 'cam-1',
  String sourceType = 'LIVE',
  double confidence = 0.93,
  List<ApiBoundingBox>? boxes = const [],
  String? viewedAt,
}) =>
    ApiDetectionEvent(
      id: id,
      farmerId: 'farmer-1',
      cameraId: cameraId,
      detectionType: 'person',
      confidence: confidence,
      imageObjectKey: 'images/$id.jpg',
      imageContentType: 'image/jpeg',
      imageSize: 1024,
      boundingBox: boxes,
      sourceType: sourceType,
      detectedAt: DateTime.utc(2026, 11, 18, 10, 15),
      createdAt: DateTime.utc(2026, 11, 18, 10, 15, 1),
      viewedAt: viewedAt == null ? null : DateTime.utc(2026, 11, 18, 12),
      idempotencyKey: 'idem-$id',
    );

FarmCamera apiCamera({
  String id = 'cam-1',
  String name = 'Main Gate',
  bool isOnline = true,
  bool isMonitoring = true,
  DateTime? lastConnected,
}) =>
    FarmCamera(
      id: id,
      name: name,
      location: 'Farm entrance, north boundary',
      isOnline: isOnline,
      isMonitoring: isMonitoring,
      lastConnected: lastConnected,
    );

// ---------------------------------------------------------------------------
// Configurable fake API for repository tests
// ---------------------------------------------------------------------------

/// [FarmerApi] fake with canned responses and call counters. Pure Dart —
/// never touches a platform channel.
///
/// Error hooks (`loginError`, `registerError`, `meError`, `camerasError`,
/// `eventsError`) throw the given object from the matching method instead of
/// returning canned data. `camerasError` and `eventsError` are mutable so
/// widget tests can simulate a transient failure followed by a recovery.
class FakeFarmerApi implements FarmerApi {
  FakeFarmerApi({
    this.authResult,
    List<FarmCamera>? cameras,
    List<ApiDetectionEvent>? events,
    this.nextBefore,
    this.eventDetail,
    this.viewedEvent,
    this.imageBytes,
    this.imageError,
    this.loginError,
    this.registerError,
    this.meError,
    this.camerasError,
    this.deleteCameraError,
    this.eventsError,
    this.getEventError,
    this.registerDeviceError,
    this.unregisterDeviceError,
    this.pairingCode,
    this.pairingError,
  }) : cameras = cameras ?? <FarmCamera>[],
       events = events ?? <ApiDetectionEvent>[];

  final AuthResult? authResult;
  final List<FarmCamera> cameras;
  final List<ApiDetectionEvent> events;
  final String? nextBefore;
  final EventDetail? eventDetail;
  final ApiDetectionEvent? viewedEvent;
  final Uint8List? imageBytes;

  /// When set, [getImageBytes] throws this instead of returning bytes.
  final Object? imageError;

  /// Error hooks — see the class doc. Throwables, usually [ApiException]s.
  final Object? loginError;
  final Object? registerError;
  final Object? meError;

  /// Mutable so tests can fail one fetch, then clear the field and retry.
  Object? camerasError;

  /// When set, [deleteCamera] throws this instead of removing the camera.
  ApiException? deleteCameraError;
  Object? eventsError;
  Object? getEventError;
  Object? registerDeviceError;
  Object? unregisterDeviceError;

  /// Canned pairing-code result. Mutable so a regenerate test can change
  /// the second code; `null` → [createPairingCode] completes with an
  /// invalid_response-shaped failure unless [pairingError] is set.
  PairingCodeResult? pairingCode;

  /// When set, [createPairingCode] throws this instead. Mutable for
  /// transient-failure-then-recovery tests.
  Object? pairingError;

  // Call counters / captured arguments.
  int listEventsCalls = 0;
  final List<int?> limits = <int?>[];
  final List<String?> befores = <String?>[];
  final List<String?> cameraIds = <String?>[];
  int imageCalls = 0;
  final List<String> imageEventIds = <String>[];
  int markViewedCalls = 0;
  final List<String> viewedIds = <String>[];
  int registerDeviceCalls = 0;
  final List<String> registerTokens = <String>[];
  final List<String> registerPlatforms = <String>[];
  int unregisterDeviceCalls = 0;
  final List<String> unregisterTokens = <String>[];
  int getEventCalls = 0;
  final List<String> getEventIds = <String>[];
  int createPairingCodeCalls = 0;
  final List<PairingCodeResult> pairingResults = <PairingCodeResult>[];

  /// Ids passed to [deleteCamera], in call order (including failed attempts).
  final List<String> deletedCameraIds = <String>[];

  @override
  Future<AuthResult> register(String name, String email, String password) async {
    if (registerError != null) throw registerError!;
    return authResult!;
  }

  @override
  Future<AuthResult> login(String email, String password) async {
    if (loginError != null) throw loginError!;
    return authResult!;
  }

  @override
  Future<AuthResult> me() async {
    if (meError != null) throw meError!;
    return authResult!;
  }

  @override
  Future<List<FarmCamera>> listCameras() async {
    if (camerasError != null) throw camerasError!;
    return cameras;
  }

  @override
  Future<void> deleteCamera(String id) async {
    deletedCameraIds.add(id);
    if (deleteCameraError != null) throw deleteCameraError!;
    // Keep subsequent listCameras() calls truthful.
    cameras.removeWhere((FarmCamera camera) => camera.id == id);
  }

  @override
  Future<EventsPage> listEvents({
    int limit = 20,
    String? before,
    String? cameraId,
  }) async {
    if (eventsError != null) throw eventsError!;
    listEventsCalls++;
    limits.add(limit);
    befores.add(before);
    cameraIds.add(cameraId);
    return EventsPage(events: events, nextBefore: nextBefore);
  }

  @override
  Future<EventDetail> getEvent(String id) async {
    getEventCalls++;
    getEventIds.add(id);
    if (getEventError != null) throw getEventError!;
    return eventDetail!;
  }

  @override
  Future<ApiDetectionEvent> markViewed(String id) async {
    markViewedCalls++;
    viewedIds.add(id);
    return viewedEvent ?? apiEvent(id: id, viewedAt: 'marked');
  }

  @override
  Future<Uint8List?> getImageBytes(String eventId) async {
    imageCalls++;
    imageEventIds.add(eventId);
    if (imageError != null) {
      throw imageError!;
    }
    return imageBytes;
  }

  @override
  Future<void> registerDevice(String token, {String platform = 'android'}) async {
    if (registerDeviceError != null) throw registerDeviceError!;
    registerDeviceCalls++;
    registerTokens.add(token);
    registerPlatforms.add(platform);
  }

  @override
  Future<void> unregisterDevice(String token) async {
    unregisterDeviceCalls++;
    unregisterTokens.add(token);
    if (unregisterDeviceError != null) throw unregisterDeviceError!;
  }

  @override
  Future<PairingCodeResult> createPairingCode() async {
    createPairingCodeCalls++;
    if (pairingError != null) throw pairingError!;
    if (pairingCode == null) {
      throw const ApiException(
        statusCode: 0,
        code: 'invalid_response',
        message: 'FakeFarmerApi has no pairingCode canned result.',
      );
    }
    pairingResults.add(pairingCode!);
    return pairingCode!;
  }
}

/// Recording in-memory store for auth tests.
class RecordingTokenStore extends InMemoryTokenStore {
  int saves = 0;
  int clears = 0;
  final List<String> savedTokens = <String>[];

  @override
  Future<void> saveToken(String token) async {
    saves++;
    savedTokens.add(token);
    await super.saveToken(token);
  }

  @override
  Future<void> clear() async {
    clears++;
    await super.clear();
  }
}

/// Convenience [AuthResult] builder for repository tests.
AuthResult authResult({
  String token = 'tok-123',
  String farmerId = 'farmer-1',
  String farmerName = 'Kiran',
  String email = 'kiran@farm.test',
}) =>
    AuthResult(
      token: token,
      farmerId: farmerId,
      farmerName: farmerName,
      email: email,
    );

/// A [FarmerApi] that throws a canned [ApiException] from every method —
/// used to verify repositories pass backend errors through untouched.
class ThrowingApi implements FarmerApi {
  const ThrowingApi({
    this.statusCode = 401,
    this.code = 'unauthorized',
    this.message = 'Token invalid or expired.',
  });

  final int statusCode;
  final String code;
  final String message;

  ApiException _error() =>
      ApiException(statusCode: statusCode, code: code, message: message);

  @override
  Never register(String name, String email, String password) => throw _error();

  @override
  Never login(String email, String password) => throw _error();

  @override
  Never me() => throw _error();

  @override
  Never listCameras() => throw _error();

  @override
  Never deleteCamera(String id) => throw _error();

  @override
  Never listEvents({int limit = 20, String? before, String? cameraId}) =>
      throw _error();

  @override
  Never getEvent(String id) => throw _error();

  @override
  Never markViewed(String id) => throw _error();

  @override
  Never getImageBytes(String eventId) => throw _error();

  @override
  Never registerDevice(String token, {String platform = 'android'}) =>
      throw _error();

  @override
  Never unregisterDevice(String token) => throw _error();

  @override
  Never createPairingCode() => throw _error();
}

/// [MessagingGateway] fake for widget tests — pure Dart, drives the same
/// contract the production [FirebaseMessagingGateway] implements: init +
/// permission, token, token-refresh stream, and tap stream (which carries
/// cold-start and background taps in production).
class FakeMessagingGateway implements MessagingGateway {
  FakeMessagingGateway({
    this.granted = true,
    this.token = 'fcm-token-1',
    this.initError,
  });

  /// What [initializeAndRequestPermission] reports (permission outcome).
  final bool granted;

  /// What [getToken] returns; `null` simulates a missing token.
  final String? token;

  /// When set, [initializeAndRequestPermission] throws this.
  final Object? initError;

  int initCalls = 0;
  int getTokenCalls = 0;

  /// Drive this to simulate FCM rotating the registration token.
  final StreamController<String> refreshController =
      StreamController<String>.broadcast();

  /// Drive this to deliver notification taps (background and cold-start
  /// taps arrive on this same stream in production).
  final StreamController<FcmTap> tapController =
      StreamController<FcmTap>.broadcast();

  @override
  Future<bool> initializeAndRequestPermission() async {
    initCalls++;
    if (initError != null) throw initError!;
    return granted;
  }

  @override
  Future<String?> getToken() async {
    getTokenCalls++;
    return token;
  }

  @override
  Stream<String> get tokenRefresh => refreshController.stream;

  @override
  Stream<FcmTap> get taps => tapController.stream;
}
