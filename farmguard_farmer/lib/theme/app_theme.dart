import 'package:material_ui/material_ui.dart';

import 'app_colors.dart';

/// Material 3 light theme for FarmGuard Farmer.
///
/// Adapted from the `mobile-android-design` skill: a full M3 color scheme,
/// the M3 type scale (same roles and sizes as the Compose reference) and the
/// M3 shape system, mapped onto Flutter's [ThemeData] component themes.
abstract final class AppTheme {
  static ThemeData light() {
    const ColorScheme scheme = ColorScheme.light(
      // Brand
      primary: AppColors.emerald,
      onPrimary: Colors.white,
      primaryContainer: AppColors.emeraldContainer,
      onPrimaryContainer: AppColors.onEmeraldContainer,
      // Secondary: desaturated green for less prominent emphasis
      secondary: Color(0xFF3E6B58),
      onSecondary: Colors.white,
      secondaryContainer: Color(0xFFDCEAE1),
      onSecondaryContainer: Color(0xFF12382A),
      // Tertiary: warm earth accent
      tertiary: Color(0xFF8A6B2D),
      onTertiary: Colors.white,
      tertiaryContainer: Color(0xFFF7E7C4),
      onTertiaryContainer: Color(0xFF3F2F0B),
      // Error
      error: Color(0xFFB3261E),
      onError: Colors.white,
      errorContainer: Color(0xFFFCE8E6),
      onErrorContainer: Color(0xFF410E0B),
      // Surfaces: warm off-white background, white cards
      surface: AppColors.background,
      onSurface: AppColors.ink,
      surfaceContainerLowest: AppColors.card,
      surfaceContainerLow: Color(0xFFFCFBF8),
      surfaceContainer: Color(0xFFF6F4EC),
      surfaceContainerHigh: Color(0xFFF1EEE6),
      surfaceContainerHighest: Color(0xFFEBE8DF),
      onSurfaceVariant: AppColors.inkMuted,
      outline: Color(0xFFB8B2A6),
      outlineVariant: AppColors.border,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      splashFactory: InkSparkle.splashFactory,
      textTheme: _textTheme(scheme),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: _textTheme(scheme).titleLarge,
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLowest,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        elevation: 0,
        backgroundColor: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primaryContainer,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: scheme.onPrimaryContainer);
          }
          return IconThemeData(color: scheme.onSurfaceVariant);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: scheme.primary,
            );
          }
          return TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: scheme.onSurfaceVariant,
          );
        }),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return scheme.surfaceContainerHighest;
          }
          return Colors.white;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return scheme.primary;
          return scheme.surfaceContainerHighest;
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return Colors.transparent;
          return scheme.outline;
        }),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.onSurface,
        contentTextStyle: TextStyle(color: scheme.surface, fontSize: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(999),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLowest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
      ),
    );
  }

  /// M3 type scale (roles and sizes match the skill's Compose reference):
  /// bolder headlines for hierarchy, default Roboto elsewhere.
  static TextTheme _textTheme(ColorScheme scheme) {
    final TextTheme base = Typography.material2021(
      platform: TargetPlatform.android,
    ).black;
    return base.copyWith(
      headlineMedium: base.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
      ),
      headlineSmall: base.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
      ),
      titleLarge: base.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      titleMedium: base.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
      ),
      titleSmall: base.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      labelLarge: base.labelLarge?.copyWith(fontWeight: FontWeight.w700),
      labelMedium: base.labelMedium?.copyWith(fontWeight: FontWeight.w600),
      labelSmall: base.labelSmall?.copyWith(fontWeight: FontWeight.w600),
    );
  }
}
