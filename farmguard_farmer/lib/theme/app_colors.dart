import 'package:material_ui/material_ui.dart';

/// Central design tokens for the FarmGuard Farmer app.
///
/// All colors are hand-tuned Material 3 roles: emerald green as the brand
/// color, white / warm off-white surfaces and warm neutral ink.
abstract final class AppColors {
  // ── Brand: emerald green ────────────────────────────────────────────────
  /// Primary actions, active states. Dark enough for white-on-top contrast.
  static const Color emerald = Color(0xFF047857);

  /// Brighter emerald for accents, dots and progress fills on light surfaces.
  static const Color emeraldBright = Color(0xFF10B981);

  /// Tinted container for icon chips, indicators and emphasized cards.
  static const Color emeraldContainer = Color(0xFFD8F4E7);

  static const Color onEmeraldContainer = Color(0xFF074233);

  // ── Surfaces: white & warm off-white ────────────────────────────────────
  /// App background (warm off-white).
  static const Color background = Color(0xFFFAF8F3);

  /// Card / bar surfaces (pure white).
  static const Color card = Color(0xFFFFFFFF);

  /// Muted wells inside cards (thumbnails, avatars, code chips).
  static const Color surfaceMuted = Color(0xFFF3F1EA);

  // ── Ink: warm neutral text ──────────────────────────────────────────────
  static const Color ink = Color(0xFF20241F);

  static const Color inkMuted = Color(0xFF5E6B60);

  /// Subtle card borders.
  static const Color border = Color(0xFFE6E2D8);

  static const Color borderStrong = Color(0xFFCFCABC);

  // ── Status colors (extended semantic palette) ──────────────────────────
  static const Color online = Color(0xFF0E9F6E);

  static const Color onlineContainer = Color(0xFFDCF6EA);

  static const Color offline = Color(0xFFDC2F2F);

  static const Color offlineContainer = Color(0xFFFCE7E4);

  static const Color paused = Color(0xFFB26500);

  static const Color pausedContainer = Color(0xFFFBEDD9);
}
