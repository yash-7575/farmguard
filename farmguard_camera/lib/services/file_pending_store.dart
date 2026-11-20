import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'pending_event_store.dart';

/// Injectable access to platform directories — the only platform touch in
/// the file store (same pattern as the [ModelGateway] abstraction). Tests
/// inject a gateway backed by a real temporary directory.
abstract class PathGateway {
  Future<Directory> appDocuments();
}

/// Production gateway delegating to path_provider.
class PluginPathGateway implements PathGateway {
  const PluginPathGateway();

  @override
  Future<Directory> appDocuments() => getApplicationDocumentsDirectory();
}

/// File-backed [PendingEventStore]: one `<eventId>.json` per event plus an
/// optional `<eventId>.jpg` for the snapshot bytes, under
/// `<appDocuments>/farmguard/pending/`.
///
/// Writes are atomic (temp file + rename). Loading tolerates corrupt
/// files — they are skipped, never crash the app. All logic is pure Dart;
/// the only platform dependency is the injected [PathGateway].
class FilePendingEventStore implements PendingEventStore {
  FilePendingEventStore({PathGateway? pathGateway})
      : _pathGateway = pathGateway ?? const PluginPathGateway();

  static const _folderPath = 'farmguard/pending';

  final PathGateway _pathGateway;

  Future<Directory> _pendingDirectory() async {
    final documents = await _pathGateway.appDocuments();
    return Directory('${documents.path}/$_folderPath');
  }

  @override
  Future<void> save(PendingEvent event) async {
    final directory = await _pendingDirectory();
    await directory.create(recursive: true);
    await _writeAtomic(
      File('${directory.path}/${event.eventId}.json'),
      utf8.encode(_encodeEvent(event)),
    );
    final image = event.imageBytes;
    if (image != null) {
      await _writeAtomic(
        File('${directory.path}/${event.eventId}.jpg'),
        image,
      );
    } else {
      // The event no longer carries snapshot bytes (e.g. the image was
      // dropped after a permanent image-upload failure): remove the
      // stale snapshot so a later load does not resurrect it.
      try {
        final stale = File('${directory.path}/${event.eventId}.jpg');
        if (await stale.exists()) {
          await stale.delete();
        }
      } on FileSystemException {
        // Best effort; a stale file is harmless (loadAll tolerates it).
      }
    }
  }

  @override
  Future<List<PendingEvent>> loadAll() async {
    final directory = await _pendingDirectory();
    if (!await directory.exists()) {
      return const [];
    }
    final events = <PendingEvent>[];
    await for (final entry in directory.list()) {
      if (entry is! File || !entry.path.endsWith('.json')) {
        continue; // image files and leftover .tmp files are not events
      }
      try {
        final event = await _decodeEventFile(entry, directory);
        if (event != null) {
          events.add(event);
        }
      } catch (_) {
        // Corrupt or unreadable file: skip it, never crash.
      }
    }
    return events;
  }

  @override
  Future<void> delete(String eventId) async {
    final directory = await _pendingDirectory();
    for (final suffix in const ['.json', '.jpg']) {
      final file = File('${directory.path}/$eventId$suffix');
      try {
        if (await file.exists()) {
          await file.delete();
        }
      } on FileSystemException {
        // Best effort; a stale file is harmless (loadAll skips it).
      }
    }
  }

  @override
  Future<void> replace(PendingEvent event) => save(event);

  /// Atomic write: bytes go to a temp sibling first, then the temp file is
  /// renamed over the target so a crash never leaves a half-written event.
  Future<void> _writeAtomic(File target, List<int> bytes) async {
    final temp = File('${target.path}.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(target.path);
  }

  // ---- codec ------------------------------------------------------------

  String _encodeEvent(PendingEvent event) {
    final box = event.boundingBox;
    return jsonEncode({
      'eventId': event.eventId,
      'cameraId': event.cameraId,
      'detectionType': event.detectionType,
      'confidence': event.confidence,
      'personCount': event.personCount,
      'capturedAt': event.capturedAt,
      'createdAt': event.createdAt.toUtc().toIso8601String(),
      'boundingBox': box == null
          ? null
          : {
              'left': box.left,
              'top': box.top,
              'width': box.width,
              'height': box.height,
            },
      'imageContentType': event.imageContentType,
      'imageObjectKey': event.imageObjectKey,
      'sourceType': event.sourceType,
      'attempts': event.attempts,
      'nextAttemptAt': event.nextAttemptAt?.toUtc().toIso8601String(),
      'lastError': event.lastError,
    });
  }

  Future<PendingEvent?> _decodeEventFile(
    File file,
    Directory directory,
  ) async {
    final raw = await file.readAsString();
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('event file is not a JSON object');
    }

    String stringField(String key) {
      final value = decoded[key];
      if (value is! String) {
        throw FormatException('event field $key missing');
      }
      return value;
    }

    String? optionalString(String key) {
      final value = decoded[key];
      return value is String ? value : null;
    }

    final eventId = stringField('eventId');
    final boxMap = decoded['boundingBox'];
    ({double left, double top, double width, double height})? boundingBox;
    if (boxMap is Map) {
      boundingBox = (
        left: (boxMap['left'] as num).toDouble(),
        top: (boxMap['top'] as num).toDouble(),
        width: (boxMap['width'] as num).toDouble(),
        height: (boxMap['height'] as num).toDouble(),
      );
    }

    // Snapshot bytes live in the sibling .jpg file; a missing or corrupt
    // image degrades to null image bytes, the event itself still loads.
    Uint8List? imageBytes;
    final imageFile = File('${directory.path}/$eventId.jpg');
    if (await imageFile.exists()) {
      try {
        imageBytes = await imageFile.readAsBytes();
      } on FileSystemException {
        imageBytes = null;
      }
    }

    final createdAtRaw = stringField('createdAt');
    final nextAttemptAtRaw = optionalString('nextAttemptAt');
    return PendingEvent(
      eventId: eventId,
      cameraId: optionalString('cameraId') ?? '',
      detectionType: optionalString('detectionType') ?? 'person',
      confidence: (decoded['confidence'] as num?)?.toDouble() ?? 0,
      personCount: (decoded['personCount'] as num?)?.toInt() ?? 0,
      capturedAt: stringField('capturedAt'),
      createdAt: DateTime.parse(createdAtRaw),
      boundingBox: boundingBox,
      imageBytes: imageBytes,
      imageContentType: optionalString('imageContentType'),
      imageObjectKey: optionalString('imageObjectKey'),
      sourceType: optionalString('sourceType') ?? 'LIVE',
      attempts: (decoded['attempts'] as num?)?.toInt() ?? 0,
      nextAttemptAt: nextAttemptAtRaw == null
          ? null
          : DateTime.tryParse(nextAttemptAtRaw),
      lastError: optionalString('lastError'),
    );
  }
}
