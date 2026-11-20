// Unit tests for the camera registration store and the device id source,
// both exercised through their in-memory fakes (no platform channels).

import 'package:flutter_test/flutter_test.dart';
import 'package:farmguard_camera/services/device_registration.dart';

void main() {
  group('InMemoryCameraRegistrationStore', () {
    test('save/load round-trips the registration', () async {
      final store = InMemoryCameraRegistrationStore();
      expect(await store.load(), isNull);

      await store.save(
        token: 'camera-token',
        cameraId: 'cam-1',
        cameraName: 'Field Camera 1',
      );

      final registration = await store.load();
      expect(registration, isNotNull);
      expect(registration!.token, 'camera-token');
      expect(registration.cameraId, 'cam-1');
      expect(registration.cameraName, 'Field Camera 1');
    });

    test('save overwrites a previous registration', () async {
      final store = InMemoryCameraRegistrationStore();
      await store.save(token: 't1', cameraId: 'cam-1', cameraName: 'Old');
      await store.save(token: 't2', cameraId: 'cam-2', cameraName: 'New');

      final registration = await store.load();
      expect(registration!.token, 't2');
      expect(registration.cameraId, 'cam-2');
    });

    test('clear removes the registration', () async {
      final store = InMemoryCameraRegistrationStore();
      await store.save(token: 't', cameraId: 'cam-1', cameraName: 'Cam');
      await store.clear();
      expect(await store.load(), isNull);
    });

    test('CameraRegistration JSON round-trips', () {
      const registration = CameraRegistration(
        token: 't',
        cameraId: 'cam-1',
        cameraName: 'Cam',
        location: 'North fence',
      );
      final restored =
          CameraRegistration.fromJson(registration.toJson() as Map<Object?, Object?>);
      expect(restored.token, 't');
      expect(restored.cameraId, 'cam-1');
      expect(restored.cameraName, 'Cam');
      expect(restored.location, 'North fence');
    });

    test('farmer details round-trip through JSON', () {
      const registration = CameraRegistration(
        token: 't',
        cameraId: 'cam-1',
        cameraName: 'Cam',
        farmerId: 'farmer-1',
        farmerName: 'Asha',
        farmerEmailMasked: 'a***@example.com',
      );
      final json = registration.toJson();
      expect(json['farmerId'], 'farmer-1');
      expect(json['farmerName'], 'Asha');
      expect(json['farmerEmailMasked'], 'a***@example.com');

      final restored =
          CameraRegistration.fromJson(json as Map<Object?, Object?>);
      expect(restored.farmerId, 'farmer-1');
      expect(restored.farmerName, 'Asha');
      expect(restored.farmerEmailMasked, 'a***@example.com');
    });

    test('registrations stored without farmer fields still parse', () {
      final legacy = <Object?, Object?>{
        'token': 'legacy-token',
        'cameraId': 'cam-old',
        'cameraName': 'Old Cam',
      };
      final restored = CameraRegistration.fromJson(legacy);
      expect(restored.token, 'legacy-token');
      expect(restored.farmerId, isNull);
      expect(restored.farmerName, isNull);
      expect(restored.farmerEmailMasked, isNull);
    });

    test('copyWith replaces only the given fields', () {
      const registration = CameraRegistration(
        token: 't',
        cameraId: 'cam-1',
        cameraName: 'Cam',
        location: 'North fence',
      );
      final updated = registration.copyWith(
        cameraName: 'Renamed Cam',
        farmerName: 'Asha',
      );
      expect(updated.token, 't');
      expect(updated.cameraId, 'cam-1');
      expect(updated.cameraName, 'Renamed Cam');
      expect(updated.location, 'North fence');
      expect(updated.farmerName, 'Asha');
      expect(updated.farmerId, isNull);
    });

    test('store save persists the optional farmer details', () async {
      final store = InMemoryCameraRegistrationStore();
      await store.save(
        token: 't',
        cameraId: 'cam-1',
        cameraName: 'Cam',
        location: 'North fence',
        farmerId: 'farmer-1',
        farmerName: 'Asha',
        farmerEmailMasked: 'a***@example.com',
      );
      final registration = await store.load();
      expect(registration!.location, 'North fence');
      expect(registration.farmerId, 'farmer-1');
      expect(registration.farmerName, 'Asha');
      expect(registration.farmerEmailMasked, 'a***@example.com');
    });
  });

  group('LocalDeviceIdSource', () {
    test('returns a stable UUIDv4 across restarts (same storage)', () async {
      final storage = InMemoryPreferencesStore();
      final first = LocalDeviceIdSource(preferences: storage);
      final second = LocalDeviceIdSource(preferences: storage);

      final id1 = await first.id;
      final id2 = await second.id;

      expect(id1, id2);
      // RFC 4122 v4 shape.
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(id1),
        isTrue,
      );
    });

    test('different storage yields different ids', () async {
      final id1 = await LocalDeviceIdSource(
        preferences: InMemoryPreferencesStore(),
      ).id;
      final id2 = await LocalDeviceIdSource(
        preferences: InMemoryPreferencesStore(),
      ).id;
      expect(id1, isNot(id2));
    });

    test('caches within one instance (single storage read)', () async {
      final storage = _CountingPreferencesStore();
      final source = LocalDeviceIdSource(preferences: storage);
      expect(await source.id, await source.id);
      expect(storage.readCount, 1);
    });
  });

  group('migrateRegistration (SharedPreferences → secure storage)', () {
    Map<Object?, Object?> legacyJson(CameraRegistration registration) =>
        registration.toJson() as Map<Object?, Object?>;

    test('secure entry wins: no legacy import', () {
      final result = migrateRegistration(
        legacyJson(const CameraRegistration(
          token: 'legacy-token',
          cameraId: 'cam-old',
          cameraName: 'Old Cam',
        )),
        legacyJson(const CameraRegistration(
          token: 'secure-token',
          cameraId: 'cam-new',
          cameraName: 'New Cam',
        )),
      );
      expect(result.registration!.token, 'secure-token');
      expect(result.registration!.cameraId, 'cam-new');
      expect(result.importLegacy, isFalse);
    });

    test('legacy entry is the registration to import when secure is empty',
        () {
      final result = migrateRegistration(
        legacyJson(const CameraRegistration(
          token: 't',
          cameraId: 'cam-1',
          cameraName: 'Cam',
          location: 'North fence',
        )),
        null,
      );
      expect(result.importLegacy, isTrue);
      expect(result.registration!.token, 't');
      expect(result.registration!.cameraId, 'cam-1');
      expect(result.registration!.cameraName, 'Cam');
      expect(result.registration!.location, 'North fence');
    });

    test('absent on both sides: nothing to do', () {
      final result = migrateRegistration(null, null);
      expect(result.registration, isNull);
      expect(result.importLegacy, isFalse);
    });

    test('corrupt legacy entry: import still triggered, registration null '
        '(legacy key gets cleaned up)', () {
      final result = migrateRegistration(
        {'token': 3, 'cameraId': 'cam-1', 'cameraName': 'Cam'},
        null,
      );
      expect(result.registration, isNull);
      expect(result.importLegacy, isTrue);
    });

    test('corrupt secure entry wins over a valid legacy one (no re-import)',
        () {
      final result = migrateRegistration(
        legacyJson(const CameraRegistration(
          token: 't',
          cameraId: 'cam-1',
          cameraName: 'Cam',
        )),
        {'unexpected': 'shape'},
      );
      expect(result.registration, isNull);
      expect(result.importLegacy, isFalse);
    });
  });
}

class _CountingPreferencesStore implements PreferencesStore {
  final Map<String, String> _values = {};
  int readCount = 0;

  @override
  Future<String?> read(String key) async {
    readCount++;
    return _values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}
