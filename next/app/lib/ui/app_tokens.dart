// Design tokens for the next/ Flutter app.
//
// Centralised numeric / typographic constants so every screen pulls from the
// same scale instead of hard-coding values inline. The token shape mirrors
// the CSS-design-system convention (xs/sm/md/lg/xl steps for spacing, a
// fixed set of named text roles) and the numbers themselves align with
// Material 3 defaults — 4 dp grid, 24 dp icons, AppBar `titleLarge` for
// titles. New screens should consume these names rather than literal
// numbers; if a value is missing, extend the token set rather than
// reaching for a one-off magic number.
//
// Typography roles are thin wrappers over `Theme.of(context).textTheme` so
// they automatically honour the active Material 3 colour scheme + text
// theme (font scaling, contrast, dark mode). The `mono` role is the only
// one that overrides the family (monospace for terminal / code / diff
// content); everything else inherits the Material role unchanged.

import 'package:flutter/material.dart';

/// Spacing scale on a 4 dp grid. Use these instead of literal pixel values
/// in `EdgeInsets.all` / `SizedBox` / gap widgets.
class AppSpacing {
  const AppSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
}

/// Corner-radius scale. `sm` is the chip / pill default; `md` matches the
/// Material 3 card default; `lg` is for prominent surfaces.
class AppRadius {
  const AppRadius._();

  static const double sm = 4;
  static const double md = 8;
  static const double lg = 12;
}

/// Icon sizes. `md` is Material's default `IconTheme.size` (24); `sm` is
/// the inline / list-row size; `lg` is the empty-state hero size.
class AppIconSize {
  const AppIconSize._();

  static const double sm = 18;
  static const double md = 24;
  static const double lg = 48;
}

/// Density-related constants. Kept in one place so list-row height and
/// the status-bar / search-bar heights stay coordinated.
class AppDensity {
  const AppDensity._();

  /// Compact horizontal pad used by status / search / connection banners
  /// (matches Material's `ListTile.contentPadding` horizontal default).
  static const double bannerHPad = AppSpacing.md;

  /// Vertical pad used by the same banners — half of [bannerHPad] keeps
  /// them visually thin without losing the tap target.
  static const double bannerVPad = AppSpacing.sm;

  /// Sticky status-bar height (Files tab).
  static const double statusBarHeight = 32;
}

/// Typography roles. Each getter returns a `TextStyle` derived from the
/// active theme's text scheme; callers may `.copyWith(...)` for one-off
/// tweaks without inventing a new role. `mono` overrides the family for
/// code / diff / terminal content but inherits the active body size from
/// the surrounding role for visual consistency.
class AppText {
  const AppText._();

  static TextStyle title(BuildContext context) =>
      Theme.of(context).textTheme.titleMedium ?? const TextStyle(fontSize: 16);

  static TextStyle subtitle(BuildContext context) =>
      Theme.of(context).textTheme.titleSmall ?? const TextStyle(fontSize: 14);

  static TextStyle body(BuildContext context) =>
      Theme.of(context).textTheme.bodyMedium ?? const TextStyle(fontSize: 14);

  static TextStyle caption(BuildContext context) =>
      Theme.of(context).textTheme.bodySmall ?? const TextStyle(fontSize: 12);

  /// Monospace style for code / diff / terminal previews. Size tracks
  /// `bodySmall` so it sits comfortably alongside captions.
  static TextStyle mono(BuildContext context) {
    final base = Theme.of(context).textTheme.bodySmall ??
        const TextStyle(fontSize: 12);
    return base.copyWith(fontFamily: 'monospace');
  }
}
