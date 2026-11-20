/// Maps raw backend API rows onto the existing domain models.
///
/// Asset-backed mock records keep their `assets/detections/...` paths
/// untouched; backend frames get a NON-asset `api:` marker scheme so the UI
/// layer can branch on it later (`Image.asset` for demo asset paths,
/// authenticated fetch via [EventRepository.getImage] for `api:` paths).
library;

import '../models/models.dart';
import '../services/api/farmer_api.dart';

/// URI path prefix marking frames that live on the backend and must be
/// fetched with the farmer's auth token.
const String kApiImagePathPrefix = 'api:';

/// Marker image path for a backend frame: `api:/api/v1/images/<eventId>`.
/// Never a loadable asset path — the UI branches on [kApiImagePathPrefix].
String apiImagePath(String eventId) => 'api:/api/v1/images/$eventId';

/// Tolerant ISO-8601 parse → UTC. `null`/empty input → `null`.
DateTime? parseIso8601Utc(String? value) {
  if (value == null || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toUtc();
}

/// How recent a camera heartbeat (`last_seen_at`) must be for the camera to
/// count as online. The backend only flips `status` when it notices a
/// disconnect, so a stale heartbeat means the camera is gone even if the row
/// still says `online`/`monitoring`.
const Duration kCameraOnlineThreshold = Duration(seconds: 120);

/// Camera JSON row → domain [FarmCamera].
///
/// Status mapping:
/// - `offline` → isOnline false, isMonitoring false;
/// - `online` → isOnline true, isMonitoring false;
/// - `monitoring` → isOnline true, isMonitoring true.
///
/// The status alone is not trusted: a camera also needs a heartbeat within
/// [kCameraOnlineThreshold] (`last_seen_at`, compared against [now] — defaults
/// to the current UTC time). A stale or missing heartbeat degrades to offline,
/// and monitoring off, so the UI never claims a camera is live when it isn't.
/// `last_seen_at` null (never connected) → lastConnected null.
FarmCamera toFarmCamera(Map<String, dynamic> row, {DateTime? now}) {
  final status = (row['status'] as String?) ?? 'offline';
  final DateTime? lastConnected =
      parseIso8601Utc(row['last_seen_at'] as String?);
  final DateTime reference = (now ?? DateTime.now()).toUtc();
  final bool heartbeatFresh = lastConnected != null &&
      reference.difference(lastConnected) <= kCameraOnlineThreshold;
  return FarmCamera(
    id: row['id'] as String? ?? '',
    name: row['camera_name'] as String? ?? '',
    location: row['location'] as String? ?? '',
    isOnline:
        (status == 'online' || status == 'monitoring') && heartbeatFresh,
    isMonitoring: status == 'monitoring' && heartbeatFresh,
    lastConnected: lastConnected,
  );
}

/// Event JSON row (typed as [ApiDetectionEvent], already parsed by
/// [HttpFarmerApi]) → domain [DetectionEvent].
///
/// - timestamp = detected_at (UTC; already tolerance-parsed by the HTTP
///   layer);
/// - isViewed = viewed_at != null;
/// - boxes: bounding_box null → empty list;
/// - imagePath = `api:/api/v1/images/<id>` marker (see above);
/// - isDemo: LIVE rows map to `false`; DEMO rows to `true` — the backend
///   source_type is the truth, and the UI must always label DEMO records
///   "DEMO" and never fabricate a "LIVE" label.
DetectionEvent toDetectionEvent(ApiDetectionEvent row) {
  return DetectionEvent(
    id: row.id,
    cameraId: row.cameraId,
    timestamp: row.detectedAt,
    confidence: row.confidence,
    isViewed: row.viewedAt != null,
    boxes: _boxes(row.boundingBox),
    imagePath: apiImagePath(row.id),
    isDemo: row.sourceType == 'DEMO',
  );
}

List<DetectionBox> _boxes(List<ApiBoundingBox>? raw) {
  if (raw == null) return const <DetectionBox>[];
  return <DetectionBox>[
    for (final box in raw)
      DetectionBox(
        left: box.left,
        top: box.top,
        width: box.width,
        height: box.height,
      ),
  ];
}
