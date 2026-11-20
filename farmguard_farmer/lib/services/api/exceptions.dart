/// Errors thrown by the FarmGuard backend API layer.
///
/// The backend wraps every JSON response in an envelope:
/// success `{ok: true, data: {...}}`, error `{ok: false, error: {code, message}}`.
/// Envelope errors are surfaced as an [ApiException] carrying the HTTP status
/// code plus the server's error code/message, so callers can branch on
/// [isUnauthorized] (401 → force re-login) and [isTransient] (network /
/// timeout / 5xx → safe to retry) without parsing strings.
class ApiException implements Exception {
  /// HTTP status code of the failing response, or `0` for errors that never
  /// produced an HTTP response (network failure, timeout, invalid payload).
  final int statusCode;

  /// Machine-readable error code: the server's `error.code` when the body
  /// carried an error envelope, otherwise a local code such as `network`,
  /// `timeout` or `invalid_response`.
  final String code;

  /// Human-readable message (safe to show; never contains tokens).
  final String message;

  const ApiException({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  /// Token rejected (expired / tampered / missing). The caller should clear
  /// the stored session and route back to login.
  bool get isUnauthorized => statusCode == 401;

  /// Network-level failure or server-side error: the request never completed
  /// or failed on the server, so retrying later is reasonable.
  bool get isTransient =>
      statusCode == 0 || statusCode >= 500;

  @override
  String toString() => 'ApiException($statusCode, $code): $message';
}
