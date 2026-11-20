import 'dart:math';

/// Generates RFC 4122 version 4 (random) UUIDs.
///
/// Hand-rolled so the project needs no `uuid` package: uses
/// [Random.secure] by default and follows the standard format
/// `8-4-4-4-12` hex digits with the version nibble fixed to `4` and the
/// variant nibble constrained to `8`, `9`, `a` or `b`.
String generateUuidV4([Random? random]) {
  final rng = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
  final hex = bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-'
      '${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-'
      '${hex.substring(20, 32)}';
}
