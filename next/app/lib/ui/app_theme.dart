// Centralised `ThemeData` for the app. Owns the light + dark colour
// schemes, the Inter UI typography (via google_fonts), the de-elevated /
// sharp-cornered chrome treatment, and the dense ListTile defaults so
// every screen inherits the same look without each widget redeclaring it.
//
// Token values (spacing, radius, raw hex) live in `app_tokens.dart`; this
// file is the wiring, not the source of truth for numbers. Light and
// dark share the same density / shape / spacing — only colours diverge.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_tokens.dart';

/// Bundle of every colour role the theme builder consumes. The two
/// concrete instances live below as [_darkPalette] and [_lightPalette];
/// they map straight onto [AppColors] / [AppColorsLight] respectively
/// so the brightness selector and the ColorScheme wiring stay 1:1 with
/// the raw token classes.
class _ThemePalette {
  final Brightness brightness;
  final Color primary;
  final Color onPrimary;
  final Color primaryContainer;
  final Color onPrimaryContainer;
  final Color tertiary;
  final Color onTertiary;
  final Color tertiaryContainer;
  final Color onTertiaryContainer;
  final Color error;
  final Color onError;
  final Color errorContainer;
  final Color onErrorContainer;
  final Color surface;
  final Color onSurface;
  final Color surfaceContainerLow;
  final Color surfaceContainer;
  final Color surfaceContainerHigh;
  final Color surfaceContainerHighest;
  final Color onSurfaceVariant;
  final Color outline;
  final Color outlineVariant;

  const _ThemePalette({
    required this.brightness,
    required this.primary,
    required this.onPrimary,
    required this.primaryContainer,
    required this.onPrimaryContainer,
    required this.tertiary,
    required this.onTertiary,
    required this.tertiaryContainer,
    required this.onTertiaryContainer,
    required this.error,
    required this.onError,
    required this.errorContainer,
    required this.onErrorContainer,
    required this.surface,
    required this.onSurface,
    required this.surfaceContainerLow,
    required this.surfaceContainer,
    required this.surfaceContainerHigh,
    required this.surfaceContainerHighest,
    required this.onSurfaceVariant,
    required this.outline,
    required this.outlineVariant,
  });
}

const _ThemePalette _darkPalette = _ThemePalette(
  brightness: Brightness.dark,
  primary: AppColors.primary,
  onPrimary: AppColors.onPrimary,
  primaryContainer: Color(0xFF1F3A24),
  onPrimaryContainer: AppColors.primary,
  tertiary: Color(0xFFE6C76A),
  onTertiary: Color(0xFF2A1F00),
  tertiaryContainer: Color(0xFF3A2F0A),
  onTertiaryContainer: Color(0xFFE6C76A),
  error: AppColors.error,
  onError: AppColors.onError,
  errorContainer: Color(0xFF3A1414),
  onErrorContainer: AppColors.error,
  surface: AppColors.surface,
  onSurface: AppColors.onSurface,
  surfaceContainerLow: AppColors.surfaceContainerLow,
  surfaceContainer: AppColors.surfaceContainer,
  surfaceContainerHigh: AppColors.surfaceContainerHigh,
  surfaceContainerHighest: AppColors.surfaceContainerHighest,
  onSurfaceVariant: AppColors.onSurfaceVariant,
  outline: AppColors.outline,
  outlineVariant: AppColors.outlineVariant,
);

const _ThemePalette _lightPalette = _ThemePalette(
  brightness: Brightness.light,
  primary: AppColorsLight.primary,
  onPrimary: AppColorsLight.onPrimary,
  // Container tints stay in the green family but de-saturated so dense
  // "primary" panels don't compete with content. Mirrors the dark
  // palette's `#1F3A24` recipe (a tint of the brand hue at low chroma).
  primaryContainer: Color(0xFFCDE9D9),
  onPrimaryContainer: Color(0xFF0E3D24),
  tertiary: Color(0xFF8A6B12),
  onTertiary: Color(0xFFFFFFFF),
  tertiaryContainer: Color(0xFFF3E5B8),
  onTertiaryContainer: Color(0xFF3A2F0A),
  error: AppColorsLight.error,
  onError: AppColorsLight.onError,
  errorContainer: Color(0xFFF8D7D7),
  onErrorContainer: Color(0xFF6A1414),
  surface: AppColorsLight.surface,
  onSurface: AppColorsLight.onSurface,
  surfaceContainerLow: AppColorsLight.surfaceContainerLow,
  surfaceContainer: AppColorsLight.surfaceContainer,
  surfaceContainerHigh: AppColorsLight.surfaceContainerHigh,
  surfaceContainerHighest: AppColorsLight.surfaceContainerHighest,
  onSurfaceVariant: AppColorsLight.onSurfaceVariant,
  outline: AppColorsLight.outline,
  outlineVariant: AppColorsLight.outlineVariant,
);

class AppTheme {
  const AppTheme._();

  /// Dark `ThemeData`. Wired into `MaterialApp.darkTheme`.
  static ThemeData dark() => _build(_darkPalette);

  /// Light `ThemeData`. Wired into `MaterialApp.theme`. Same density /
  /// shape / spacing as [dark]; the two only differ in colour.
  static ThemeData light() => _build(_lightPalette);

  static ThemeData _build(_ThemePalette p) {
    final scheme = ColorScheme(
      brightness: p.brightness,
      primary: p.primary,
      onPrimary: p.onPrimary,
      primaryContainer: p.primaryContainer,
      onPrimaryContainer: p.onPrimaryContainer,
      secondary: p.primary,
      onSecondary: p.onPrimary,
      secondaryContainer: p.primaryContainer,
      onSecondaryContainer: p.onPrimaryContainer,
      tertiary: p.tertiary,
      onTertiary: p.onTertiary,
      tertiaryContainer: p.tertiaryContainer,
      onTertiaryContainer: p.onTertiaryContainer,
      error: p.error,
      onError: p.onError,
      errorContainer: p.errorContainer,
      onErrorContainer: p.onErrorContainer,
      surface: p.surface,
      onSurface: p.onSurface,
      surfaceContainerLowest: p.surface,
      surfaceContainerLow: p.surfaceContainerLow,
      surfaceContainer: p.surfaceContainer,
      surfaceContainerHigh: p.surfaceContainerHigh,
      surfaceContainerHighest: p.surfaceContainerHighest,
      surfaceDim: p.surface,
      surfaceBright: p.surfaceContainerHigh,
      onSurfaceVariant: p.onSurfaceVariant,
      outline: p.outline,
      outlineVariant: p.outlineVariant,
      shadow: Colors.transparent,
      scrim: Colors.black54,
      inverseSurface: p.onSurface,
      onInverseSurface: p.surface,
      inversePrimary: p.primary,
    );

    // Build the text theme from Inter, then re-apply the surface text
    // colour so every role inherits the high-contrast onSurface for the
    // active brightness — Google Fonts' default `interTextTheme()`
    // returns black-on-everything which is unreadable on a near-black
    // background and over-bold on a near-white one.
    //
    // On top of the Inter base we bump body/title/label roles roughly
    // one step in size + weight so the UI reads at "macOS Finder list"
    // density rather than Material-default airy-and-thin, and we layer
    // Noto Sans SC as `fontFamilyFallback` so CJK glyphs render with a
    // PingFang-SC-like face instead of whatever the OS picks.
    final baseTextTheme = ThemeData(brightness: p.brightness).textTheme;
    final interTextTheme = GoogleFonts.interTextTheme(baseTextTheme);
    final cjkFallback = AppText.uiFontFamilyFallback;
    TextStyle? bump(
      TextStyle? style, {
      required double sizeDelta,
      required FontWeight weight,
    }) {
      if (style == null) return null;
      final base = style.fontSize ?? 14;
      return style.copyWith(
        fontSize: base + sizeDelta,
        fontWeight: weight,
        fontFamilyFallback: cjkFallback,
      );
    }

    final tunedTextTheme = interTextTheme.copyWith(
      // Display + headline keep Material's geometry; just wire fallback.
      displayLarge: interTextTheme.displayLarge?.copyWith(
        fontFamilyFallback: cjkFallback,
      ),
      displayMedium: interTextTheme.displayMedium?.copyWith(
        fontFamilyFallback: cjkFallback,
      ),
      displaySmall: interTextTheme.displaySmall?.copyWith(
        fontFamilyFallback: cjkFallback,
      ),
      headlineLarge: interTextTheme.headlineLarge?.copyWith(
        fontFamilyFallback: cjkFallback,
      ),
      headlineMedium: interTextTheme.headlineMedium?.copyWith(
        fontFamilyFallback: cjkFallback,
      ),
      headlineSmall: interTextTheme.headlineSmall?.copyWith(
        fontFamilyFallback: cjkFallback,
      ),
      titleLarge: bump(
        interTextTheme.titleLarge,
        sizeDelta: 1,
        weight: FontWeight.w600,
      ),
      titleMedium: bump(
        interTextTheme.titleMedium,
        sizeDelta: 1,
        weight: FontWeight.w600,
      ),
      titleSmall: bump(
        interTextTheme.titleSmall,
        sizeDelta: 1,
        weight: FontWeight.w600,
      ),
      bodyLarge: bump(
        interTextTheme.bodyLarge,
        sizeDelta: 0,
        weight: FontWeight.w500,
      ),
      bodyMedium: bump(
        interTextTheme.bodyMedium,
        sizeDelta: 1,
        weight: FontWeight.w500,
      ),
      bodySmall: bump(
        interTextTheme.bodySmall,
        sizeDelta: 1,
        weight: FontWeight.w500,
      ),
      labelLarge: bump(
        interTextTheme.labelLarge,
        sizeDelta: 1,
        weight: FontWeight.w600,
      ),
      labelMedium: bump(
        interTextTheme.labelMedium,
        sizeDelta: 1,
        weight: FontWeight.w600,
      ),
      labelSmall: bump(
        interTextTheme.labelSmall,
        sizeDelta: 1,
        weight: FontWeight.w600,
      ),
    );
    final textTheme = tunedTextTheme.apply(
      bodyColor: p.onSurface,
      displayColor: p.onSurface,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: p.brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: p.surface,
      canvasColor: p.surface,
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      iconTheme: IconThemeData(size: AppIconSize.md, color: p.onSurface),
      visualDensity: const VisualDensity(horizontal: 0, vertical: -1),
      splashFactory: InkRipple.splashFactory,
      // Page transitions: opt out of the default ZoomPageTransitionsBuilder
      // on Android. Zoom participates in Android 14+ predictive-back, so a
      // slow edge-swipe drags the top route under the user's finger before
      // it commits — we want back to be binary (fires or cancels), with no
      // intermediate visual. FadeForwardsPageTransitionsBuilder is M3-spec
      // and does not implement predictive-back, so the gesture commits or
      // is dropped without a follow-finger preview.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        },
      ),
      // Flat chrome — no Material elevation drops. Layers separate via
      // 1px outline borders and surface-container tints, not shadows.
      appBarTheme: AppBarTheme(
        backgroundColor: p.surface,
        foregroundColor: p.onSurface,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        toolbarHeight: 52,
        centerTitle: false,
        titleTextStyle: textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: p.onSurface,
        ),
        iconTheme: IconThemeData(size: AppIconSize.md, color: p.onSurface),
        actionsIconTheme: IconThemeData(
          size: AppIconSize.md,
          color: p.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        color: p.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: p.outline, width: 1),
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
      ),
      dividerTheme: DividerThemeData(color: p.outline, thickness: 1, space: 1),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: p.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        height: 56,
        indicatorColor: p.surfaceContainerHigh,
        labelTextStyle: WidgetStatePropertyAll(
          textTheme.labelSmall?.copyWith(color: p.onSurfaceVariant) ??
              const TextStyle(),
        ),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: p.primary, size: AppIconSize.md);
          }
          return IconThemeData(color: p.onSurfaceVariant, size: AppIconSize.md);
        }),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: p.surfaceContainerLow,
        selectedItemColor: p.primary,
        unselectedItemColor: p.onSurfaceVariant,
        elevation: 0,
        type: BottomNavigationBarType.fixed,
        showSelectedLabels: true,
        showUnselectedLabels: true,
      ),
      listTileTheme: ListTileThemeData(
        dense: true,
        iconColor: p.onSurfaceVariant,
        textColor: p.onSurface,
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        minVerticalPadding: AppSpacing.sm,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.surfaceContainer,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        hintStyle: textTheme.bodyMedium?.copyWith(color: p.onSurfaceVariant),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          borderSide: BorderSide(color: p.outline, width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          borderSide: BorderSide(color: p.outline, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          borderSide: BorderSide(color: p.primary, width: 1),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          borderSide: BorderSide(color: p.error, width: 1),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          borderSide: BorderSide(color: p.error, width: 1),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: p.primary,
          foregroundColor: p.onPrimary,
          elevation: 0,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm,
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: p.primary,
          foregroundColor: p.onPrimary,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.onSurface,
          side: BorderSide(color: p.outline, width: 1),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: p.primary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: p.surfaceContainer,
        selectedColor: p.surfaceContainerHigh,
        side: BorderSide(color: p.outline, width: 1),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        labelStyle: textTheme.labelMedium ?? const TextStyle(),
        secondaryLabelStyle: textTheme.labelMedium ?? const TextStyle(),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: 2,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: p.outline, width: 1),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: p.surfaceContainerHigh,
        contentTextStyle: TextStyle(color: p.onSurface),
        behavior: SnackBarBehavior.floating,
        elevation: 0,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: p.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: p.outline, width: 1),
        ),
        textStyle: textTheme.bodySmall?.copyWith(color: p.onSurface),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: p.primary),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return p.onPrimary;
          return p.onSurfaceVariant;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return p.primary;
          return p.surfaceContainerHigh;
        }),
      ),
      checkboxTheme: CheckboxThemeData(
        side: BorderSide(color: p.outline, width: 1),
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return p.primary;
          return Colors.transparent;
        }),
        checkColor: WidgetStatePropertyAll(p.onPrimary),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm / 2),
        ),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return p.primary;
          return p.onSurfaceVariant;
        }),
      ),
    );
  }
}
