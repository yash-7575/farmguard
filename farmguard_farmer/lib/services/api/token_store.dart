import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Injectable storage for the backend auth token.
///
/// The platform-backed implementation touches a platform channel, so every
/// service that needs the token takes this interface and tests always inject
/// [InMemoryTokenStore] instead. [SecureTokenStore] is only ever constructed
/// in production code paths — never in tests.
abstract class TokenStore {
  /// The stored auth token, or `null` when the farmer is signed out.
  Future<String?> readToken();

  /// Persists [token], replacing any previous one.
  Future<void> saveToken(String token);

  /// Removes the stored token (logout / invalidated session).
  Future<void> clear();
}

/// Production store backed by `flutter_secure_storage` (encrypted on-device
/// keychain storage). The storage handle is created lazily so that merely
/// referencing this class has no platform side effects.
class SecureTokenStore implements TokenStore {
  SecureTokenStore({FlutterSecureStorage? storage})
    : _storageOverride = storage;

  final FlutterSecureStorage? _storageOverride;
  FlutterSecureStorage? _storage;

  FlutterSecureStorage get _impl =>
      _storageOverride ?? (_storage ??= const FlutterSecureStorage());

  /// Single key so the token survives app restarts.
  static const String _tokenKey = 'farmguard_auth_token';

  @override
  Future<String?> readToken() => _impl.read(key: _tokenKey);

  @override
  Future<void> saveToken(String token) =>
      _impl.write(key: _tokenKey, value: token);

  @override
  Future<void> clear() async {
    await _impl.delete(key: _tokenKey);
  }
}

/// In-memory store for tests and short-lived sessions. Pure Dart, no
/// platform channels — widget-safe.
class InMemoryTokenStore implements TokenStore {
  String? _token;

  @override
  Future<String?> readToken() async => _token;

  @override
  Future<void> saveToken(String token) async {
    _token = token;
  }

  @override
  Future<void> clear() async {
    _token = null;
  }
}
