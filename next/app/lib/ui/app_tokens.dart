import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppSpacing {
  const AppSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
}

class AppRadius {
  const AppRadius._();

  static const double sm = 4;
  static const double md = 8;
  static const double lg = 12;
}

class AppIconSize {
  const AppIconSize._();

  static const double sm = 18;
  static const double md = 24;
  static const double lg = 48;
}

class AppDensity {
  const AppDensity._();

  static const double bannerHPad = AppSpacing.md;
  static const double bannerVPad = AppSpacing.sm;
  static const double statusBarHeight = 32;
}

/// Project color palette. dark-first; no light variant in v0.
///
/// Hex values are settled in CLAUDE.md and the design tasks; consumers
/// should reach for `Theme.of(context).colorScheme` first and only refer
/// to these raw values when wiring a non-Material surface.
class AppColors {
  const AppColors._();

  /// Page background. Near-black, intentionally not pure `#000` so OLED
  /// burn-in concerns coexist with avoiding the hard-edge "void" look.
  static const Color surface = Color(0xFF0E0F11);

  /// Lowest container layer above the page surface (cards, sticky bars).
  static const Color surfaceContainerLow = Color(0xFF131517);

  /// Default container (panel chrome, nav bar background).
  static const Color surfaceContainer = Color(0xFF16181B);

  /// One step higher (raised cards, header chips).
  static const Color surfaceContainerHigh = Color(0xFF1E2125);

  /// Highest container (popovers, focused inputs).
  static const Color surfaceContainerHighest = Color(0xFF24272C);

  /// Single brand accent. Terminal-green: signals "primary action" and
  /// matches the "developer workbench" character of the product.
  static const Color primary = Color(0xFF7CE38B);

  /// Hairline divider / 1px border. Chosen to read as a line, not a fill.
  static const Color outline = Color(0xFF2A2D31);

  /// Slightly stronger outline for focused inputs / active chips.
  static const Color outlineVariant = Color(0xFF3A3E44);

  /// Primary text.
  static const Color onSurface = Color(0xFFE6E8EB);

  /// Secondary text (timestamps, captions, dimmed metadata).
  static const Color onSurfaceVariant = Color(0xFF9097A0);

  /// Text painted on top of `primary` (high-contrast for accessibility on
  /// the bright green accent).
  static const Color onPrimary = Color(0xFF052E0E);

  /// Error / destructive accent.
  static const Color error = Color(0xFFFF6B6B);
  static const Color onError = Color(0xFF330000);
}

/// Single canonical entry point for any code-like surface (paths,
/// branches, shas, terminal labels, diff content). Always prefer this
/// over `fontFamily: 'monospace'`, which silently picks an unpredictable
/// platform monospace and breaks the visual contract.
class AppText {
  const AppText._();

  static TextStyle mono({
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
    double? height,
    TextDecoration? decoration,
    Color? decorationColor,
    double? decorationThickness,
    FontStyle? fontStyle,
  }) {
    return GoogleFonts.jetBrainsMono(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      height: height,
      decoration: decoration,
      decorationColor: decorationColor,
      decorationThickness: decorationThickness,
      fontStyle: fontStyle,
    );
  }
}
