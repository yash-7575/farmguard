import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'uuid.dart';

// ---------------------------------------------------------------------------
// Registration model + store
// ---------------------------------------------------------------------------

/// The pairing result persisted on the device: this camera's identity and
/// token for the FarmGuard backend, plus the (optional) farmer account
/// details shown in the Connection Details card.
///
/// [farmerId], [farmerName] and [farmerEmailMasked] are optional and
/// null-safe: registrations stored by earlier app versions do not contain
/// them and still parse.
class CameraRegistration {
  const CameraRegistration({
    required this.token,
    required this.cameraId,
    required this.cameraName,
    this.location,
    this.farmerId,
    this.farmerName,
    this.farmerEmailMasked,
  });

  final String token;
  final String cameraId;
  final String cameraName;
  final String? location;

  /// Server id of the farmer account this camera is paired to.
  final String? farmerId;

  /// Display name of the paired farmer account.
  final String? farmerName;

  /// Masked email of the paired farmer account (server-masked, e.g.
  /// `y***@example.com`). Never a full address.
  final String? farmerEmailMasked;

  Map<String, Object?> toJson() => {
        'token': token,
        'cameraId': cameraId,
        'cameraName': cameraName,
        if (location != null) 'location': location,
        if (farmerId != null) 'farmerId': farmerId,
        if (farmerName != null) 'farmerName': farmerName,
        if (farmerEmailMasked != null) 'farmerEmailMasked': farmerEmailMasked,
      };

  factory CameraRegistration.fromJson(Map<Object?, Object?> json) {
    final token = json['token'];
    final cameraId = json['cameraId'];
    final cameraName = json['cameraName'];
    if (token is! String || cameraId is! String || cameraName is! String) {
      throw const FormatException('registration fields missing');
    }
    final location = json['location'];
    final farmerId = json['farmerId'];
    final farmerName = json['farmerName'];
    final farmerEmailMasked = json['farmerEmailMasked'];
    return CameraRegistration(
      token: token,
      cameraId: cameraId,
      cameraName: cameraName,
      location: location is String ? location : null,
      farmerId: farmerId is String ? farmerId : null,
      farmerName: farmerName is String ? farmerName : null,
      farmerEmailMasked:
          farmerEmailMasked is String ? farmerEmailMasked : null,
    );
  }

  /// Copy with the given fields replaced; omitted (null) fields keep their
  /// current value.
  CameraRegistration copyWith({
    String? token,
    String? cameraId,
    String? cameraName,
    String? location,
    String? farmerId,
    String? farmerName,
    String? farmerEmailMasked,
  }) {
    return CameraRegistration(
      token: token ?? this.token,
      cameraId: cameraId ?? this.cameraId,
      cameraName: cameraName ?? this.cameraName,
      location: location ?? this.location,
      farmerId: farmerId ?? this.farmerId,
      farmerName: farmerName ?? this.farmerName,
      farmerEmailMasked: farmerEmailMasked ?? this.farmerEmailMasked,
    );
  }
}

/// Persistence for [CameraRegistration]. Injectable so tests use the
/// in-memory variant and never touch platform channels.
abstract class CameraRegistrationStore {
  Future<bool> save({
    required String token,
    required String cameraId,
    required String cameraName,
    String? location,
    String? farmerId,
    String? farmerName,
    String? farmerEmailMasked,
  });

  Future<CameraRegistration?> load();

  Future<void> clear();
}

/// Ephemeral implementation for tests.
class InMemoryCameraRegistrationStore implements CameraRegistrationStore {
  CameraRegistration? _registration;

  @override
  Future<bool> save({
    required String token,
    required String cameraId,
    required String cameraName,
    String? location,
    String? farmerId,
    String? farmerName,
    String? farmerEmailMasked,
  }) async {
    _registration = CameraRegistration(
      token: token,
      cameraId: cameraId,
      cameraName: cameraName,
      location: location,
      farmerId: farmerId,
      farmerName: farmerName,
      farmerEmailMasked: farmerEmailMasked,
    );
    return true;
  }

  @override
  Future<CameraRegistration?> load() async => _registration;

  @override
  Future<void> clear() async {
    _registration = null;
  }
}

/// Platform-backed store using shared_preferences.
///
/// Legacy store, kept only as the migration source: [SecureCameraRegistrationStore]
/// imports its entry into secure storage on first load for existing
/// installs. New production code should never read or write it directly.
class SharedPreferencesCameraRegistrationStore
    implements CameraRegistrationStore {
  static const legacyPrefsKey = 'farmguard.camera_registration';

  static const _key = legacyPrefsKey;

  @override
  Future<bool> save({
    required String token,
    required String cameraId,
    required String cameraName,
    String? location,
    String? farmerId,
    String? farmerName,
    String? farmerEmailMasked,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final registration = CameraRegistration(
      token: token,
      cameraId: cameraId,
      cameraName: cameraName,
      location: location,
      farmerId: farmerId,
      farmerName: farmerName,
      farmerEmailMasked: farmerEmailMasked,
    );
    await prefs.setString(_key, jsonEncode(registration.toJson()));
    return true;
  }

  @override
  Future<CameraRegistration?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return null;
      }
      return CameraRegistration.fromJson(decoded);
    } on FormatException {
      // Corrupt entry: treat as unpaired rather than crash.
      return null;
    }
  }

  @override
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}

// ---------------------------------------------------------------------------
// Secure (production) store — flutter_secure_storage
// ---------------------------------------------------------------------------

/// Pure decision logic for the SharedPreferences → secure-storage
/// migration, unit-testable without platform channels:
///
/// - a secure entry always wins ([importLegacy] false);
/// - otherwise, when a legacy plain-preferences entry exists, it is the
///   registration to import into secure storage ([importLegacy] true);
/// - corrupt entries parse to `null` rather than crashing.
({CameraRegistration? registration, bool importLegacy}) migrateRegistration(
    Map<Object?, Object?>? legacy, Map<Object?, Object?>? secure) {
  if (secure != null) {
    return (registration: _parseRegistration(secure), importLegacy: false);
  }
  if (legacy == null) {
    return (registration: null, importLegacy: false);
  }
  return (registration: _parseRegistration(legacy), importLegacy: true);
}

CameraRegistration? _parseRegistration(Map<Object?, Object?> raw) {
  try {
    return CameraRegistration.fromJson(raw);
  } on FormatException {
    return null;
  }
}

/// Platform-backed store using flutter_secure_storage: the camera token
/// is encrypted by the plugin — on Android with keys held in the Android
/// Keystore (EncryptedSharedPreferences/Keystore storage via the plugin),
/// on iOS/macOS the Keychain.
///
/// Migration for existing installs: [load] imports a legacy
/// [SharedPreferencesCameraRegistrationStore] entry into secure storage
/// and deletes the legacy key (decision logic in [migrateRegistration]).
/// Production-only path — tests use [InMemoryCameraRegistrationStore].
class SecureCameraRegistrationStore implements CameraRegistrationStore {
  SecureCameraRegistrationStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'farmguard.camera_registration';

  final FlutterSecureStorage _storage;

  @override
  Future<bool> save({
    required String token,
    required String cameraId,
    required String cameraName,
    String? location,
    String? farmerId,
    String? farmerName,
    String? farmerEmailMasked,
  }) async {
    final registration = CameraRegistration(
      token: token,
      cameraId: cameraId,
      cameraName: cameraName,
      location: location,
      farmerId: farmerId,
      farmerName: farmerName,
      farmerEmailMasked: farmerEmailMasked,
    );
    await _storage.write(key: _key, value: jsonEncode(registration.toJson()));
    return true;
  }

  @override
  Future<CameraRegistration?> load() async {
    final migration = migrateRegistration(
      _decode(await _readLegacyRaw()),
      _decode(await _storage.read(key: _key)),
    );
    if (migration.importLegacy) {
      final imported = migration.registration;
      if (imported != null) {
        await _storage.write(key: _key, value: jsonEncode(imported.toJson()));
      }
      await _deleteLegacy();
    }
    return migration.registration;
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _key);
    await _deleteLegacy();
  }

  Future<String?> _readLegacyRaw() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(SharedPreferencesCameraRegistrationStore.legacyPrefsKey);
  }

  Future<void> _deleteLegacy() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(SharedPreferencesCameraRegistrationStore.legacyPrefsKey);
  }

  static Map<Object?, Object?>? _decode(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? decoded : null;
    } on FormatException {
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// Device identifier
// ---------------------------------------------------------------------------

/// Tiny injectable key–value persistence surface for platform-backed
/// strings (device id today, more later if needed).
abstract class PreferencesStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Ephemeral implementation for tests.
class InMemoryPreferencesStore implements PreferencesStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

/// Platform-backed [PreferencesStore] using shared_preferences.
class SharedPreferencesPreferencesStore implements PreferencesStore {
  @override
  Future<String?> read(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key);
  }

  @override
  Future<void> write(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }

  @override
  Future<void> delete(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }
}

/// Platform-backed [PreferencesStore] using flutter_secure_storage (the
/// device identifier is persisted behind the platform keystore too), with
/// a one-time migration of legacy plain-preferences values: on read, if
/// secure storage has no value for [key] but the legacy shared-preferences
/// store does, the value is imported into secure storage and the legacy
/// key deleted. Production-only path — tests use [InMemoryPreferencesStore].
class SecurePreferencesStore implements PreferencesStore {
  SecurePreferencesStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) async {
    final secure = await _storage.read(key: key);
    if (secure != null) {
      return secure;
    }
    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getString(key);
    if (legacy == null) {
      return null;
    }
    await _storage.write(key: key, value: legacy);
    await prefs.remove(key);
    return legacy;
  }

  @override
  Future<void> write(String key, String value) {
    return _storage.write(key: key, value: value);
  }

  @override
  Future<void> delete(String key) async {
    await _storage.delete(key: key);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }
}

/// Source of the stable device identifier sent with pairing.
abstract class DeviceIdSource {
  Future<String> get id;
}

/// Locally generated UUIDv4 persisted via [PreferencesStore]: stable
/// across restarts, no Android-specific APIs needed.
///
/// TODO(device-id): a platform-provided identifier (e.g. SSAID) could be
/// used instead; the random UUID is privacy-friendly and sufficient for
/// pairing, so it stays for now.
class LocalDeviceIdSource implements DeviceIdSource {
  LocalDeviceIdSource({PreferencesStore? preferences})
      : _preferences = preferences ?? SharedPreferencesPreferencesStore();

  static const _key = 'farmguard.device_id';

  final PreferencesStore _preferences;
  String? _cached;

  @override
  Future<String> get id async {
    final cached = _cached;
    if (cached != null) {
      return cached;
    }
    final stored = await _preferences.read(_key);
    if (stored != null && stored.isNotEmpty) {
      _cached = stored;
      return stored;
    }
    final fresh = generateUuidV4();
    await _preferences.write(_key, fresh);
    _cached = fresh;
    return fresh;
  }
}
