import '../../services/api/farmer_api.dart';
import '../../services/api/token_store.dart';

/// Authentication flows for the farmer app.
///
/// Login/register persist the returned token in the injectable [TokenStore]
/// (the same store [HttpFarmerApi] reads its Bearer header from); logout
/// clears it. Errors surface as [ApiException] unchanged — e.g. 409
/// `email_taken` from register, 401 `invalid_credentials` from login.
///
/// Pure Dart; tests inject a fake [FarmerApi] plus [InMemoryTokenStore].
class AuthRepository {
  AuthRepository({required this.api, required this.tokenStore});

  final FarmerApi api;
  final TokenStore tokenStore;

  /// Creates an account and persists the session token.
  Future<AuthResult> register(String name, String email, String password) =>
      _persist(() => api.register(name, email, password));

  /// Signs in and persists the session token.
  Future<AuthResult> login(String email, String password) =>
      _persist(() => api.login(email, password));

  /// Validates the stored token against the backend, returning the
  /// farmer's info. Throws [ApiException] (401) when the token is
  /// missing/expired — the caller routes back to login.
  Future<AuthResult> me() => api.me();

  /// Clears the stored session token.
  Future<void> logout() => tokenStore.clear();

  Future<AuthResult> _persist(Future<AuthResult> Function() call) async {
    final result = await call();
    await tokenStore.saveToken(result.token);
    return result;
  }
}
