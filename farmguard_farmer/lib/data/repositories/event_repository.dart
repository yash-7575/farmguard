import 'dart:typed_data';

import '../../models/models.dart';
import '../../services/api/exceptions.dart';
import '../../services/api/farmer_api.dart';
import '../event_codec.dart';

/// A page of domain events plus the cursor needed to fetch the next (older)
/// page. `nextBefore` is `null` when there are no older events.
class EventListPage {
  final List<DetectionEvent> events;
  final String? nextBefore;

  const EventListPage({required this.events, required this.nextBefore});
}

/// Fetches detection events from the backend, converts them to domain
/// [DetectionEvent]s and caches frame bytes.
///
/// Pure Dart with an injectable [FarmerApi]; no platform channels, so tests
/// fake the API freely. Errors are surfaced as [ApiException] unchanged —
/// the UI layer decides loading/error states.
class EventRepository {
  EventRepository({
    required this.api,
    this.pageSize = 20,
    this.maxCachedImages = 12,
  });

  final FarmerApi api;

  /// Events requested per page (backend accepts 1–50).
  final int pageSize;

  /// Maximum number of frames held in the in-memory LRU cache.
  final int maxCachedImages;

  /// LRU cache of fetched frame bytes, keyed by event id. Details and tiles
  /// both need the bytes, so a small cache avoids duplicate fetches.
  final Map<String, Uint8List> _imageCache = <String, Uint8List>{};

  /// First (newest) page of events, newest first. Optionally filtered to a
  /// single camera.
  Future<List<DetectionEvent>> fetchFirstPage({String? cameraId}) async {
    final page = await api.listEvents(limit: pageSize, cameraId: cameraId);
    return _convert(page.events);
  }

  /// Like [fetchFirstPage], but also returns the pagination cursor so the
  /// UI can offer a "load more" affordance.
  Future<EventListPage> fetchFirstPageWithCursor({String? cameraId}) async {
    final page = await api.listEvents(limit: pageSize, cameraId: cameraId);
    return EventListPage(
      events: _convert(page.events),
      nextBefore: page.nextBefore,
    );
  }

  /// Older page ending strictly before the [before] cursor (ISO-8601,
  /// typically [EventsPage.nextBefore] of the previous fetch).
  Future<List<DetectionEvent>> fetchPage(
    String before, {
    String? cameraId,
  }) async {
    final page = await api.listEvents(
      limit: pageSize,
      before: before,
      cameraId: cameraId,
    );
    return _convert(page.events);
  }

  /// Like [fetchPage], but also returns the next (older) cursor.
  Future<EventListPage> fetchPageWithCursor(
    String before, {
    String? cameraId,
  }) async {
    final page = await api.listEvents(
      limit: pageSize,
      before: before,
      cameraId: cameraId,
    );
    return EventListPage(
      events: _convert(page.events),
      nextBefore: page.nextBefore,
    );
  }

  /// Fetches a single event by id and converts it to the domain model.
  /// Unknown / foreign id → 404 [ApiException] from the API, passed
  /// through unchanged (the caller decides: e.g. a push tap on a deleted
  /// event degrades to a no-op).
  Future<DetectionEvent> getEvent(String id) async {
    final detail = await api.getEvent(id);
    return toDetectionEvent(detail.event);
  }

  /// Marks the event viewed server-side and returns the updated domain
  /// event (`isViewed` true).
  Future<DetectionEvent> markViewed(String id) async {
    final row = await api.markViewed(id);
    return toDetectionEvent(row);
  }

  /// Frame bytes for [event].
  ///
  /// Backend events (imagePath `api:…`) are fetched through the API with a
  /// small LRU cache in front. Asset-backed demo events return `null`
  /// without a network call — the UI loads those with `Image.asset`.
  ///
  /// The API throws [ApiException] for 404 (frame unavailable) and 401 (bad
  /// token); this method rethrows unchanged so the caller decides (show a
  /// placeholder vs. force re-login). Bytes are cached only on success.
  Future<Uint8List?> getImage(DetectionEvent event) async {
    final cached = _imageCache.remove(event.id);
    if (cached != null) {
      // LRU touch: re-insert at the newest end.
      _imageCache[event.id] = cached;
      return cached;
    }
    if (!event.imagePath.startsWith(kApiImagePathPrefix)) {
      return null;
    }
    final bytes = await api.getImageBytes(event.id);
    if (bytes != null) {
      _imageCache[event.id] = bytes;
      while (_imageCache.length > maxCachedImages) {
        _imageCache.remove(_imageCache.keys.first);
      }
    }
    return bytes;
  }

  List<DetectionEvent> _convert(List<ApiDetectionEvent> rows) =>
      <DetectionEvent>[for (final row in rows) toDetectionEvent(row)];
}

/// Fetches the signed-in farmer's cameras. Pure Dart, injectable API.
class CameraRepository {
  CameraRepository({required this.api});

  final FarmerApi api;

  /// All cameras owned by the signed-in farmer.
  Future<List<FarmCamera>> fetchCameras() => api.listCameras();

  /// Unpairs the camera from the farmer's account. Historical detection
  /// events are untouched — only the camera record is deleted.
  Future<void> deleteCamera(String id) => api.deleteCamera(id);
}
