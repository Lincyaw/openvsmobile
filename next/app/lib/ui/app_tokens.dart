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

/// Alpha channels used by the inline-banner builder (Batch 2 §4.3).
/// Both surfaces are derived from the banner's accent color: `wash` is
/// the low-opacity fill so the banner reads as "tinted" rather than
/// "loud", and `border` is the slightly stronger 1px hairline that
/// keeps the banner edge visible against `scheme.surface`. Promoted to
/// constants so a future palette pass has a single source of truth
/// instead of two magic alphas drifting through the renderer.
class AppBannerOpacity {
  const AppBannerOpacity._();

  /// ~15% — accent washed over surface for the banner background.
  static const int wash = 38;

  /// ~40% — accent at slightly higher opacity for the 1px border.
  static const int border = 102;
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
///
/// Also owns the UI font-family fallback chain. Inter (and JetBrains
/// Mono) have no CJK glyph coverage, so without a fallback Han text
/// falls through to whatever the Android system picks — often a heavier
/// sans that clashes with Inter's weight. Layering Noto Sans SC as a
/// fallback gives a PingFang-SC-like look on all devices.
class AppText {
  const AppText._();

  /// Family name used as a per-`TextStyle` `fontFamilyFallback` so CJK
  /// glyphs render with Noto Sans SC instead of the system default. Read
  /// off a live `GoogleFonts.notoSansSc()` style so the runtime-cached
  /// family name (which `google_fonts` mangles with a hash) stays in
  /// sync with what the loader registered.
  static List<String> get uiFontFamilyFallback {
    final fam = GoogleFonts.notoSansSc().fontFamily;
    return fam == null ? const <String>[] : <String>[fam];
  }

  /// Mono counterpart: when a code surface mixes Han characters (path
  /// comments, CJK strings in source), fall back to Noto Sans SC so the
  /// glyphs stay visually compatible with the surrounding UI font. The
  /// Latin/mono characters still render through JetBrains Mono.
  static List<String> get monoFontFamilyFallback => uiFontFamilyFallback;

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
    ).copyWith(fontFamilyFallback: monoFontFamilyFallback);
  }
}

// ---------------------------------------------------------------------
// StyleSlot tokens (Batch 1 — design §4.3 cross-cutting principles).
//
// Plugin authors pick from a small named set instead of hard-coding
// numbers / hex colors; the Flutter host owns the pixel/color mapping.
// The SDK side mirrors these as TypeScript string-literal unions; this
// file is the renderer's resolver.
// ---------------------------------------------------------------------

enum SpacingToken { none, xs, sm, md, lg, xl }
enum RadiusToken { none, sm, md, lg, pill }
/// Container background tier — matches the doc spec
/// (`default | elevated | muted | inverse`). `default` is the bare
/// surface (no chrome); `elevated` is the raised card layer.
enum SurfaceToken { defaultSurface, elevated, muted, inverse }
/// Semantic accent — matches the doc spec (`brand | info | success |
/// warning | danger | muted`). `brand` resolves to the plugin's
/// `themeColor` if declared, falling back to the app brand.
enum AccentToken { brand, info, success, warning, danger, muted }
enum SizeToken { xs, sm, md, lg, xl }

SpacingToken? spacingTokenFromString(String? raw) {
  if (raw == null) return null;
  switch (raw) {
    case 'none':
      return SpacingToken.none;
    case 'xs':
      return SpacingToken.xs;
    case 'sm':
      return SpacingToken.sm;
    case 'md':
      return SpacingToken.md;
    case 'lg':
      return SpacingToken.lg;
    case 'xl':
      return SpacingToken.xl;
  }
  throw FormatException('Unknown SpacingToken: $raw');
}

RadiusToken? radiusTokenFromString(String? raw) {
  if (raw == null) return null;
  switch (raw) {
    case 'none':
      return RadiusToken.none;
    case 'sm':
      return RadiusToken.sm;
    case 'md':
      return RadiusToken.md;
    case 'lg':
      return RadiusToken.lg;
    case 'pill':
      return RadiusToken.pill;
  }
  throw FormatException('Unknown RadiusToken: $raw');
}

SurfaceToken? surfaceTokenFromString(String? raw) {
  if (raw == null) return null;
  switch (raw) {
    case 'default':
      return SurfaceToken.defaultSurface;
    case 'elevated':
      return SurfaceToken.elevated;
    case 'muted':
      return SurfaceToken.muted;
    case 'inverse':
      return SurfaceToken.inverse;
  }
  throw FormatException('Unknown SurfaceToken: $raw');
}

AccentToken? accentTokenFromString(String? raw) {
  if (raw == null) return null;
  switch (raw) {
    case 'brand':
      return AccentToken.brand;
    case 'info':
      return AccentToken.info;
    case 'success':
      return AccentToken.success;
    case 'warning':
      return AccentToken.warning;
    case 'danger':
      return AccentToken.danger;
    case 'muted':
      return AccentToken.muted;
  }
  throw FormatException('Unknown AccentToken: $raw');
}

SizeToken? sizeTokenFromString(String? raw) {
  if (raw == null) return null;
  switch (raw) {
    case 'xs':
      return SizeToken.xs;
    case 'sm':
      return SizeToken.sm;
    case 'md':
      return SizeToken.md;
    case 'lg':
      return SizeToken.lg;
    case 'xl':
      return SizeToken.xl;
  }
  throw FormatException('Unknown SizeToken: $raw');
}

/// Resolver: token → concrete pixel / color / radius value, using the
/// surrounding [BuildContext]'s theme for color lookups. The resolver is
/// stateless; methods are static so callers don't pay for an instance.
class StyleSlotResolver {
  const StyleSlotResolver._();

  /// Spacing token → pixels. Maps onto the existing `AppSpacing` scale so
  /// numeric (`gap: 8`) and tokenized (`gap: 'sm'`) callers share the
  /// same canonical values.
  static double spacing(SpacingToken token) {
    switch (token) {
      case SpacingToken.none:
        return 0;
      case SpacingToken.xs:
        return AppSpacing.xs;
      case SpacingToken.sm:
        return AppSpacing.sm;
      case SpacingToken.md:
        return AppSpacing.md;
      case SpacingToken.lg:
        return AppSpacing.lg;
      case SpacingToken.xl:
        return AppSpacing.xl;
    }
  }

  /// Either form of `gap` / `size` / `padding`: number passes through,
  /// token resolves via [spacing].
  static double spacingSlot({double? numeric, SpacingToken? token}) {
    if (token != null) return spacing(token);
    return numeric ?? 0;
  }

  /// Radius token → pixels. `pill` is a sentinel large value that, when
  /// fed into a `BorderRadius.circular`, produces a fully-rounded edge
  /// on any reasonable widget height.
  static double radius(RadiusToken token) {
    switch (token) {
      case RadiusToken.none:
        return 0;
      case RadiusToken.sm:
        return AppRadius.sm;
      case RadiusToken.md:
        return AppRadius.md;
      case RadiusToken.lg:
        return AppRadius.lg;
      case RadiusToken.pill:
        return 999;
    }
  }

  /// Size token (icons, avatars, hit-targets) → pixels.
  static double size(SizeToken token) {
    switch (token) {
      case SizeToken.xs:
        return 12;
      case SizeToken.sm:
        return AppIconSize.sm;
      case SizeToken.md:
        return AppIconSize.md;
      case SizeToken.lg:
        return AppIconSize.lg;
      case SizeToken.xl:
        return 64;
    }
  }

  static double sizeSlot({double? numeric, SizeToken? token}) {
    if (token != null) return size(token);
    return numeric ?? size(SizeToken.md);
  }

  /// Container background color for a [SurfaceToken]. The four values
  /// map onto the app's surface-container scale: `default` is the bare
  /// page surface; `elevated` is the raised card layer; `muted` is the
  /// dim background for embedded content; `inverse` is the high-contrast
  /// inverse surface (used by tooltips, snackbars).
  static Color surface(BuildContext context, SurfaceToken token) {
    final scheme = Theme.of(context).colorScheme;
    switch (token) {
      case SurfaceToken.defaultSurface:
        return scheme.surface;
      case SurfaceToken.elevated:
        return scheme.surfaceContainerHigh;
      case SurfaceToken.muted:
        return scheme.surfaceContainerLow;
      case SurfaceToken.inverse:
        return scheme.inverseSurface;
    }
  }

  /// Accent token → semantic color. `brand` resolves to the surrounding
  /// theme's primary, so the per-plugin theme override (Batch 1) flips
  /// `brand` on a panel-by-panel basis without touching the global scheme.
  /// `muted` is the dim-text / outline color for de-emphasized accents.
  ///
  /// Brightness-aware: info / success / warning each carry a tuned pair
  /// so the same token reads as ≥4.5:1 contrast on both light and dark
  /// surface containers. The dark-mode values are the bright-on-dark
  /// (500-weight) hue; the light-mode values are the darker (700-weight)
  /// hue tuned for legibility on a near-white surface.
  static Color accent(BuildContext context, AccentToken token) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    switch (token) {
      case AccentToken.brand:
        return scheme.primary;
      case AccentToken.info:
        return isDark
            ? const Color(0xFF3B82F6) // blue-500
            : const Color(0xFF1D4ED8); // blue-700
      case AccentToken.success:
        return isDark
            ? const Color(0xFF22C55E) // green-500
            : const Color(0xFF15803D); // green-700
      case AccentToken.warning:
        return isDark
            ? const Color(0xFFF59E0B) // amber-500
            : const Color(0xFFB45309); // amber-700
      case AccentToken.danger:
        return scheme.error;
      case AccentToken.muted:
        return scheme.onSurfaceVariant;
    }
  }
}

/// Plugin-level brand color (manifest `themeColor`). Resolves the seven
/// named hues to a concrete Color the renderer can hand to a scoped
/// `Theme` so `AccentToken.brand` lookups inside the plugin panel use
/// the plugin's color instead of the app default.
Color? resolvePluginThemeColor(String? raw) {
  if (raw == null) return null;
  switch (raw) {
    case 'teal':
      return const Color(0xFF14B8A6);
    case 'blue':
      return const Color(0xFF3B82F6);
    case 'green':
      return const Color(0xFF22C55E);
    case 'orange':
      return const Color(0xFFF97316);
    case 'red':
      return const Color(0xFFEF4444);
    case 'purple':
      return const Color(0xFFA855F7);
    case 'mono':
      // "mono" = no chroma; resolved to a neutral that still reads as
      // an accent against the app's surface containers.
      return const Color(0xFF6B7280);
  }
  return null;
}
