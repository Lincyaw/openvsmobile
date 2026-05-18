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

/// Project color palette — dark variant.
///
/// Hex values are settled in CLAUDE.md and the design tasks; consumers
/// should reach for `Theme.of(context).colorScheme` first and only refer
/// to these raw values when wiring a non-Material surface. `AppColors`
/// stays the canonical dark palette for back-compat with widgets that
/// still pull tokens directly; brightness-aware surfaces look up via
/// `colorScheme` and re-render across the light / dark `ThemeData`s
/// wired in `app_theme.dart`.
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

/// Project color palette — light variant. Same token *roles* as
/// [AppColors] (same field names, same downstream semantics); only the
/// hex values differ. Surfaces sit a hair off pure white to avoid the
/// glare of `#FFFFFF` on AMOLED panels and to keep 1px outline borders
/// visible. The brand green is darkened so primary buttons / accents
/// keep ≥4.5:1 contrast against `surface` and white-on-primary text
/// remains readable.
class AppColorsLight {
  const AppColorsLight._();

  /// Page background. Near-white, slightly cool — keeps a perceptible
  /// edge against pure-white system chrome and avoids the AMOLED glare
  /// of `#FFFFFF`.
  static const Color surface = Color(0xFFFAFAFB);

  /// Lowest container layer above the page surface.
  static const Color surfaceContainerLow = Color(0xFFF2F3F5);

  /// Default container (panel chrome, nav bar background).
  static const Color surfaceContainer = Color(0xFFEAECEF);

  /// One step higher (raised cards, header chips, selected nav indicator).
  static const Color surfaceContainerHigh = Color(0xFFE0E3E7);

  /// Highest container (popovers, focused inputs, tooltip body).
  static const Color surfaceContainerHighest = Color(0xFFD4D8DD);

  /// Brand accent — darker forest-green so it has ≥4.5:1 contrast on a
  /// white surface and white text on top stays readable. Same hue family
  /// as the dark palette's `#7CE38B` so the brand identity carries over.
  static const Color primary = Color(0xFF1F7A48);

  /// Hairline divider / 1px border on light surfaces.
  static const Color outline = Color(0xFFD8DCE0);

  /// Slightly stronger outline for focused inputs / active chips.
  static const Color outlineVariant = Color(0xFFC2C7CD);

  /// Primary text.
  static const Color onSurface = Color(0xFF1A1C1E);

  /// Secondary text (timestamps, captions, dimmed metadata).
  static const Color onSurfaceVariant = Color(0xFF5C636B);

  /// Text painted on top of `primary` — white reads cleanly on the
  /// darker forest green.
  static const Color onPrimary = Color(0xFFFFFFFF);

  /// Error / destructive accent — darker red so it stays loud on white.
  static const Color error = Color(0xFFC12B2B);
  static const Color onError = Color(0xFFFFFFFF);
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
