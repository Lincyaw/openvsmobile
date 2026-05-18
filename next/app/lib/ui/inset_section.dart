// iOS-style inset-grouped section (Batch 2 — §4.3).
//
// Carries the "Settings-app / mini-program" visual identity: an optional
// caption-style title rendered above a single rounded surface, with
// 1px hairline dividers between rows. The renderer uses this when a
// plugin author emits `UiSection { variant: 'inset' }`; the host's
// SettingsTab uses the same widget directly (without going through the
// JSON wire format) so the visual primitive stays one source of truth.
//
// Why a separate file: ui_renderer.dart is the wire→Material adapter
// layer. Lifting the inset visual into its own widget lets non-plugin
// surfaces (the host's Settings tab) consume it without round-tripping
// through UiNode.

import 'package:flutter/material.dart';

import 'app_tokens.dart';

/// iOS-Settings inset-grouped container.
///
/// Geometry per the design doc:
/// * outer horizontal padding matches the surrounding ListView gutter
/// * single rounded surface for all rows (`AppRadius.lg`)
/// * 1px hairline divider painted between adjacent rows (no leading
///   indent — full-width is the iOS Settings look)
/// * optional caption-style title above the surface, in the
///   `onSurfaceVariant` text color
class InsetSection extends StatelessWidget {
  /// Optional group title. Rendered above the surface in caption type;
  /// omitting it removes the slot entirely so adjacent inset sections
  /// stack without a phantom gap.
  final String? title;

  /// One or more rows to render inside the rounded surface. Empty list
  /// is valid (the surface still paints — useful for placeholder states
  /// in dev) but unusual in production trees.
  final List<Widget> children;

  /// Hook for widget tests — locates the rendered group by name without
  /// needing to walk the widget tree manually.
  final Key? surfaceKey;

  const InsetSection({
    super.key,
    this.title,
    required this.children,
    this.surfaceKey,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // `outlineVariant` is the M3 token tuned for in-surface separators
    // (lighter than `outline`, which is calibrated for strokes/borders);
    // matches the iOS-hairline weight we want for inset row dividers.
    final dividerColor = scheme.outlineVariant;

    // Inject hairline dividers between adjacent rows so the inset
    // surface reads as a grouped list. We don't draw separators above
    // the first row or below the last — those would compete with the
    // surface's own rounded border.
    final laidOutChildren = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        laidOutChildren.add(
          Divider(
            key: ValueKey<String>('inset-section-divider:$i'),
            height: 1,
            thickness: 1,
            color: dividerColor,
          ),
        );
      }
      laidOutChildren.add(children[i]);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null && title!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(
                left: AppSpacing.md,
                bottom: AppSpacing.xs,
                top: AppSpacing.sm,
              ),
              child: Text(
                title!.toUpperCase(),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      letterSpacing: 0.6,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          Material(
            key: surfaceKey,
            color: scheme.surfaceContainer,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: laidOutChildren,
            ),
          ),
        ],
      ),
    );
  }
}
