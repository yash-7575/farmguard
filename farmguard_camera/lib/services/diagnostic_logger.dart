import 'package:flutter/foundation.dart';

/// Structured, sanitized diagnostics for the camera app.
///
/// Every event is printed as `[FarmGuardCamera] <event> <details>` so a
/// single `adb logcat` filter (`FarmGuardCamera`) shows the whole camera
/// lifecycle: pairing, session refresh, heartbeats, startup stages and
/// native readiness.
///
/// **Never** pass secrets in [details]: camera tokens, passwords and
/// 6-digit pairing codes must never reach the log. Camera ids, statuses,
/// error messages and booleans are fine.
void logCameraDiagnostic(
  String event, [
  Map<String, Object?> details = const {},
]) {
  debugPrint('[FarmGuardCamera] $event ${details.isEmpty ? '' : details}');
}
