// Renderer for plugin-provided UI descriptors. Consumes a typed
// `UiNode` tree and renders Material widgets; emits `UiNodeEvent`s
// through an `onEvent` callback for the model layer to forward to the
// backend.
//
// Reconciliation contract (issue #59, design §4.3):
//   * Every widget is keyed by `ValueKey('ui:<id>')`. When the plugin
//     re-renders the same tree shape with mutated leaf values, Flutter
//     matches the new widgets to the existing Elements by Key, so focus,
//     scroll position, and animation state survive.
//   * Updates are full re-renders in v0; incremental `ui.update` patches
//     are reserved for v1 (CLAUDE.md §"Plugin model").

import 'dart:convert';
import 'dart:io' show File;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:markdown/markdown.dart' as md;

import 'app_tokens.dart';
import 'highlight_theme.dart';
import 'icon_catalog.dart';
import 'inset_section.dart';

import 'ui_node.dart';

/// Recursively renders a `UiNode` tree using Material widgets.
///
/// The callback is invoked from leaf widgets that produce events:
///   * `UiButton`    → `type: "tap"`
///   * `UiTextField` → `type: "changed"`, payload `{ "value": String }`
///
/// Container nodes never emit events themselves.
class UiRenderer extends StatelessWidget {
  final UiNode tree;
  final void Function(UiNodeEvent event) onEvent;

  /// Optional screen-local hook: long-press on a [UiAppGrid] tile fires
  /// with the surrounding grid id + the pressed tile's id. NOT part of
  /// the widget contract — used by the host's Plugins-tab launcher to
  /// surface a contextual action sheet (Enable/Disable/Copy path) the
  /// way iOS / WeChat launchers bind long-press. Plugin-authored panels
  /// leave this null and the gesture is a no-op.
  final void Function(String gridId, String tileId)? onAppTileLongPress;

  const UiRenderer({
    super.key,
    required this.tree,
    required this.onEvent,
    this.onAppTileLongPress,
  });

  @override
  Widget build(BuildContext context) => _render(context, tree);

  Widget _render(BuildContext context, UiNode node) {
    final key = ValueKey<String>('ui:${node.id}');
    switch (node) {
      case UiColumn(:final children, :final gap):
        return Column(
          key: key,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: _withGap(
            children.map((c) => _render(context, c)).toList(),
            _resolveSpacing(gap),
            axis: Axis.vertical,
          ),
        );
      case UiRow(:final children, :final gap):
        return Row(
          key: key,
          mainAxisSize: MainAxisSize.min,
          children: _withGap(
            children.map((c) => _render(context, c)).toList(),
            _resolveSpacing(gap),
            axis: Axis.horizontal,
          ),
        );
      case UiSection(:final title, :final variant, :final collapsible, :final children):
        // Dispatch on the optional `variant`. Omitted → `plain` so any
        // pre-Batch-2 tree (no variant on the wire) renders identically
        // to the old Section path. `card` reuses the renderer's Card
        // branch so the visual stays one source of truth.
        final v = variant ?? UiSectionVariant.plain;
        if (!collapsible) {
          switch (v) {
            case UiSectionVariant.plain:
              return _buildPlainSection(context, key, title, children);
            case UiSectionVariant.card:
              return _buildCardSection(context, key, title, children);
            case UiSectionVariant.inset:
              return _buildInsetSection(context, key, title, children);
          }
        }
        // Collapsible: stateful wrapper owns expand state keyed by the
        // section's node id. Re-render with the same id → State object
        // survives (Flutter reconciles by Key) → expand state persists.
        // Re-render with a different id → fresh State → default expanded.
        return _CollapsibleSection(
          key: ValueKey<String>('ui:${node.id}:collapsible'),
          title: title,
          renderBody: (bool expanded) {
            final body = expanded
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: children
                        .map((c) => _render(context, c))
                        .toList(),
                  )
                : const SizedBox.shrink();
            return body;
          },
          variant: v,
        );
      case UiCard(:final children):
        // Deprecated alias kept for one minor version. Delegates through
        // the same code path as `UiSection { variant: 'card' }` so a
        // future removal touches one place.
        return _buildCardSection(context, key, null, children);
      case UiList(:final items):
        // Non-scrollable: a `UiList` typically sits inside a Column whose
        // own scroll parent (or the panel host) provides the viewport.
        // shrinkWrap + NeverScrollableScrollPhysics matches the issue
        // brief and avoids nested-scroll surprises.
        return ListView.builder(
          key: key,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: items.length,
          itemBuilder: (_, i) => _render(context, items[i]),
        );
      case UiText(:final text, :final style):
        return Text(text, key: key, style: _textStyleFor(context, style));
      case UiSpacer(:final size):
        final s = _resolveSpacing(size) ?? 0.0;
        return SizedBox(key: key, height: s, width: s);
      case UiTextField(:final label, :final value, :final placeholder):
        return _UiTextFieldRenderer(
          key: key,
          nodeId: node.id,
          label: label,
          initialValue: value,
          placeholder: placeholder,
          onChanged: (v) => onEvent(UiNodeEvent(
            nodeId: node.id,
            type: 'changed',
            payload: {'value': v},
          )),
        );
      case UiButton(:final label, :final style):
        return _buildButton(key, node.id, label, style);
      case UiIcon():
        return _buildIcon(context, key, node);
      case UiBadge():
        return _buildBadge(context, key, node);
      case UiListTile():
        return _buildListTile(context, key, node);
      case UiAppGrid():
        return _buildAppGrid(context, key, node);
      case UiSwitch():
        return _UiSwitchRenderer(
          key: key,
          node: node,
          onEvent: onEvent,
        );
      case UiSelect():
        return _UiSelectRenderer(
          key: key,
          node: node,
          onEvent: onEvent,
        );
      case UiInlineBanner():
        return _buildBanner(context, key, node);
      case UiDivider():
        return _buildDivider(context, key, node);
      case UiImage():
        return _buildImage(context, key, node);
      case UiAvatar():
        return _buildAvatar(context, key, node);
      case UiMarkdown():
        return _buildMarkdown(context, key, node);
      case UiCodeBlock():
        return _buildCodeBlock(context, key, node);
      case UiProgress():
        return _buildProgress(context, key, node);
      case UiSpinner():
        return _buildSpinner(context, key, node);
      case UiGrid():
        return _buildGrid(context, key, node);
      case UiStack():
        return _buildStack(context, key, node);
      case UiAspect(:final ratio, :final child):
        return AspectRatio(
          key: key,
          aspectRatio: ratio,
          child: _render(context, child),
        );
      case UiFlex(:final flex, :final child):
        // Inside a Row/Column the wrapper turns into an `Expanded`
        // claiming `flex` shares; the renderer's _render dispatch is
        // unaware of the outer axis. To keep behavior predictable in
        // both contexts we expose the Expanded here and trust the
        // surrounding Row/Column to interpret it. Outside a Row/Column
        // Expanded would assert at layout time, so callers placing
        // UiFlex outside a flex container are misusing the widget;
        // that contract is documented on the SDK side.
        return Expanded(
          key: key,
          flex: flex <= 0 ? 1 : flex.round().clamp(1, 1 << 20),
          child: _render(context, child),
        );
      case UiScroll(:final axis, :final child):
        return SingleChildScrollView(
          key: key,
          scrollDirection: (axis ?? UiScrollAxis.vertical) ==
                  UiScrollAxis.horizontal
              ? Axis.horizontal
              : Axis.vertical,
          child: _render(context, child),
        );
      case UiTabBar():
        return _buildTabBar(context, key, node);
      case UiSearchField():
        return _UiSearchFieldRenderer(
          key: key,
          node: node,
          onEvent: onEvent,
        );
      case UiCheckbox():
        return _UiCheckboxRenderer(
          key: key,
          node: node,
          onEvent: onEvent,
        );
      case UiRadioGroup():
        return _UiRadioGroupRenderer(
          key: key,
          node: node,
          onEvent: onEvent,
        );
      case UiSlider():
        return _UiSliderRenderer(
          key: key,
          node: node,
          onEvent: onEvent,
        );
    }
  }

  // ---- Batch 2 container helpers ----

  Widget _buildPlainSection(
    BuildContext context,
    Key key,
    String? title,
    List<UiNode> children,
  ) {
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null && title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ...children.map((c) => _render(context, c)),
        ],
      ),
    );
  }

  Widget _buildCardSection(
    BuildContext context,
    Key key,
    String? title,
    List<UiNode> children,
  ) {
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null && title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(
                bottom: AppSpacing.sm,
                left: AppSpacing.xs,
              ),
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: children.map((c) => _render(context, c)).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInsetSection(
    BuildContext context,
    Key key,
    String? title,
    List<UiNode> children,
  ) {
    return InsetSection(
      key: key,
      title: title,
      children: children.map((c) => _render(context, c)).toList(),
    );
  }

  // ---- Batch 2 leaf helpers ----

  Widget _buildBanner(BuildContext context, Key key, UiInlineBanner node) {
    final scheme = Theme.of(context).colorScheme;
    final accent = _bannerAccentColor(context, node.accent);
    // Banner backgrounds are a low-opacity wash of the accent so the
    // surface reads as "tinted" rather than "loud" — matches the
    // iOS/Material 3 notification-banner pattern.
    final wash = Color.alphaBlend(
      accent.withAlpha(AppBannerOpacity.wash),
      scheme.surface,
    );
    final iconName = _bannerIconName(node.accent);
    final iconData = resolveIconByName(iconName) ?? Icons.info_outline;
    final dismissId = node.dismissEventId;
    final action = node.action;
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: wash,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: accent.withAlpha(AppBannerOpacity.border),
            width: 1,
          ),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2, right: AppSpacing.sm),
              child: Icon(iconData, color: accent, size: AppIconSize.md),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    node.title,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                  ),
                  if (node.body != null && node.body!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        node.body!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ),
                  if (action != null)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.xs),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: accent,
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.sm,
                              vertical: 0,
                            ),
                            minimumSize: const Size(0, 32),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () => onEvent(UiNodeEvent(
                            nodeId: node.id,
                            type: action.eventId,
                          )),
                          child: Text(action.label),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (dismissId != null)
              IconButton(
                tooltip: 'Dismiss',
                icon: Icon(
                  resolveIconByName('x') ?? Icons.close,
                  size: AppIconSize.sm,
                  color: scheme.onSurfaceVariant,
                ),
                onPressed: () => onEvent(UiNodeEvent(
                  nodeId: node.id,
                  type: dismissId,
                )),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDivider(BuildContext context, Key key, UiDivider node) {
    final orientation = node.orientation ?? UiDividerOrientation.horizontal;
    final scheme = Theme.of(context).colorScheme;
    switch (orientation) {
      case UiDividerOrientation.horizontal:
        return Divider(key: key, height: 1, thickness: 1, color: scheme.outline);
      case UiDividerOrientation.vertical:
        return VerticalDivider(
          key: key,
          width: 1,
          thickness: 1,
          color: scheme.outline,
        );
    }
  }

  Color _bannerAccentColor(BuildContext context, UiInlineBannerAccent accent) {
    switch (accent) {
      case UiInlineBannerAccent.info:
        return StyleSlotResolver.accent(context, AccentToken.info);
      case UiInlineBannerAccent.success:
        return StyleSlotResolver.accent(context, AccentToken.success);
      case UiInlineBannerAccent.warning:
        return StyleSlotResolver.accent(context, AccentToken.warning);
      case UiInlineBannerAccent.danger:
        return StyleSlotResolver.accent(context, AccentToken.danger);
    }
  }

  String _bannerIconName(UiInlineBannerAccent accent) {
    switch (accent) {
      case UiInlineBannerAccent.info:
        return 'info';
      case UiInlineBannerAccent.success:
        return 'check-circle';
      case UiInlineBannerAccent.warning:
        return 'alert-triangle';
      case UiInlineBannerAccent.danger:
        return 'alert-octagon';
    }
  }

  // ---- Batch 1 widgets ----

  Widget _buildIcon(BuildContext context, Key key, UiIcon node) {
    final data = resolveIconByName(node.name);
    final color = node.accent != null
        ? StyleSlotResolver.accent(context, node.accent!)
        : Theme.of(context).colorScheme.onSurface;
    final size = StyleSlotResolver.sizeSlot(
      numeric: node.size?.numeric,
      token: node.size?.token,
    );
    if (data == null) {
      // Unknown icon name → visible placeholder so a typo is debuggable
      // without crashing the panel.
      return Icon(Icons.help_outline, key: key, size: size, color: color);
    }
    return Icon(data, key: key, size: size, color: color);
  }

  Widget _buildBadge(BuildContext context, Key key, UiBadge node) {
    final accent = StyleSlotResolver.accent(
      context,
      node.accent ?? AccentToken.brand,
    );
    if (node.variant == UiBadgeVariant.dot) {
      return SizedBox(
        key: key,
        width: 8,
        height: 8,
        child: DecoratedBox(
          decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
        ),
      );
    }
    final label = node.text ?? (node.count != null ? '${node.count}' : '');
    final scheme = Theme.of(context).colorScheme;
    // Pick foreground for readable contrast. Each accent paints onto a
    // specific scheme color and must pair with the matched on-* role:
    //   * danger → onError (matches scheme.error background)
    //   * muted  → onSurface (matches the dim outline accent)
    //   * everything else → onPrimary (the bright-accent default)
    // Using onPrimary for danger is a contrast accident — the pair
    // isn't guaranteed to read as ≥4.5:1 against scheme.error.
    final Color fg;
    switch (node.accent) {
      case AccentToken.danger:
        fg = scheme.onError;
        break;
      case AccentToken.muted:
        fg = scheme.onSurface;
        break;
      default:
        fg = scheme.onPrimary;
        break;
    }
    return Container(
      key: key,
      padding: EdgeInsets.symmetric(
        horizontal: StyleSlotResolver.spacing(SpacingToken.sm) - 2,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: accent,
        borderRadius: BorderRadius.circular(
          StyleSlotResolver.radius(RadiusToken.pill),
        ),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: fg,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }

  Widget _buildListTile(BuildContext context, Key key, UiListTile node) {
    final tile = ListTile(
      leading: node.leading == null ? null : _render(context, node.leading!),
      title: Text(node.title),
      subtitle: node.subtitle == null ? null : Text(node.subtitle!),
      trailing: node.trailing == null ? null : _render(context, node.trailing!),
      onTap: node.onTapEvent == null
          ? null
          : () => onEvent(UiNodeEvent(
                nodeId: node.id,
                type: node.onTapEvent!,
              )),
    );
    final actions = node.swipeActions;
    if (actions == null || actions.isEmpty) {
      // No swipe-actions on the wire → render the bare Material tile;
      // adding a Slidable wrapper with no children would still draw the
      // pan gesture detector and trap parent scrolls.
      return KeyedSubtree(key: key, child: tile);
    }
    // Wrap in a Slidable so swipe-from-right reveals one button per
    // action, iOS Mail / Things 3 style. The endActionPane lives on the
    // right edge; commit threshold defaults to ~30% on `flutter_slidable`
    // — we widen it to 50% per the brief so a casual horizontal drag
    // doesn't accidentally fire a destructive action.
    return Slidable(
      // Group id ensures only one tile is open at a time across the
      // panel — opening a second row's actions collapses the first.
      key: ValueKey<String>('ui-tile-slidable:${node.id}'),
      groupTag: 'ui-tile-group',
      endActionPane: ActionPane(
        motion: const DrawerMotion(),
        extentRatio: actions.length == 1 ? 0.25 : 0.55,
        // dismissible: a single-action swipe-past-threshold fires the
        // action and closes the slidable. With multiple actions we
        // drop dismiss-on-fling (peek-and-pick is the whole point).
        dismissible: actions.length == 1
            ? DismissiblePane(
                closeOnCancel: true,
                onDismissed: () => onEvent(UiNodeEvent(
                  nodeId: node.id,
                  type: actions.first.eventId,
                )),
              )
            : null,
        children: [
          for (final action in actions)
            _swipeActionButton(context, key: node.id, action: action),
        ],
      ),
      child: KeyedSubtree(key: key, child: tile),
    );
  }

  /// Build one tap-target button inside a Slidable's action pane. Each
  /// button paints its accent color as the background and shows the icon
  /// + label stacked, matching the iOS Mail visual.
  Widget _swipeActionButton(
    BuildContext context, {
    required String key,
    required UiSwipeAction action,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final bg = action.accent != null
        ? StyleSlotResolver.accent(context, action.accent!)
        : scheme.primary;
    // Foreground pairing: every accent color in the palette pairs with
    // white at ≥4.5:1 contrast EXCEPT `muted`, which is intentionally
    // dim and reads better with onSurface. Same pairing rule as the
    // pill-badge contrast resolver above.
    final fg = action.accent == AccentToken.muted
        ? scheme.onSurface
        : Colors.white;
    final iconData = action.icon == null
        ? null
        : resolveIconByName(action.icon!);
    return SlidableAction(
      key: ValueKey<String>('ui-swipe-action:$key/${action.eventId}'),
      onPressed: (_) => onEvent(UiNodeEvent(
        nodeId: key,
        type: action.eventId,
      )),
      backgroundColor: bg,
      foregroundColor: fg,
      icon: iconData,
      label: action.label,
    );
  }

  Widget _buildAppGrid(BuildContext context, Key key, UiAppGrid node) {
    // App-grid is a non-scrolling grid that fills the width of its parent
    // viewport (the panel scroller already provides scrolling). Tile
    // geometry per design §4.3: 48-56px icon + caption beneath, touch
    // target ≥ 48dp.
    final columns = node.columns ?? _defaultColumnsFor(context);
    return LayoutBuilder(
      key: key,
      builder: (context, constraints) {
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AppSpacing.md),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: AppSpacing.md,
            crossAxisSpacing: AppSpacing.md,
            childAspectRatio: 0.85,
          ),
          itemCount: node.items.length,
          itemBuilder: (context, i) {
            final tile = node.items[i];
            final longPress = onAppTileLongPress;
            return _AppGridTile(
              tile: tile,
              gridId: node.id,
              onTap: () => onEvent(UiNodeEvent(
                nodeId: node.id,
                type: node.onLaunchEvent ?? 'launch',
                payload: {'tileId': tile.id},
              )),
              onLongPress: longPress == null
                  ? null
                  : () => longPress(node.id, tile.id),
            );
          },
        );
      },
    );
  }

  static int _defaultColumnsFor(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    return w >= 600 ? 5 : 3;
  }

  Widget _buildButton(
    Key key,
    String nodeId,
    String label,
    UiButtonStyleKind? style,
  ) {
    void emit() => onEvent(UiNodeEvent(nodeId: nodeId, type: 'tap'));
    switch (style ?? UiButtonStyleKind.primary) {
      case UiButtonStyleKind.primary:
        return ElevatedButton(
          key: key,
          onPressed: emit,
          child: Text(label),
        );
      case UiButtonStyleKind.secondary:
        return OutlinedButton(
          key: key,
          onPressed: emit,
          child: Text(label),
        );
      case UiButtonStyleKind.danger:
        // FilledButton.tonal per the issue spec — keeps the v0 vocabulary
        // small while still differentiating from primary/secondary.
        return FilledButton.tonal(
          key: key,
          onPressed: emit,
          child: Text(label),
        );
    }
  }

  TextStyle? _textStyleFor(BuildContext c, UiTextStyleKind? style) {
    final theme = Theme.of(c).textTheme;
    switch (style ?? UiTextStyleKind.body) {
      case UiTextStyleKind.body:
        return theme.bodyMedium;
      case UiTextStyleKind.title:
        return theme.titleLarge;
      case UiTextStyleKind.caption:
        return theme.bodySmall;
      case UiTextStyleKind.mono:
        return AppText.mono(
          fontSize: theme.bodyMedium?.fontSize,
          color: theme.bodyMedium?.color,
          height: theme.bodyMedium?.height,
        );
    }
  }

  List<Widget> _withGap(List<Widget> children, double? gap,
      {required Axis axis}) {
    if (gap == null || gap <= 0 || children.length < 2) return children;
    final spacer = SizedBox(
      width: axis == Axis.horizontal ? gap : 0,
      height: axis == Axis.vertical ? gap : 0,
    );
    final out = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) out.add(spacer);
      out.add(children[i]);
    }
    return out;
  }

  static double? _resolveSpacing(SpacingSlot? slot) {
    if (slot == null) return null;
    return StyleSlotResolver.spacingSlot(
      numeric: slot.numeric,
      token: slot.token,
    );
  }

  // ---- Batch 3 widgets (§4.3) — rich display ----

  Widget _buildImage(BuildContext context, Key key, UiImage node) {
    // `size` is the longest-edge constraint. Default to a sensible
    // "thumbnail" so a plugin that forgets to specify one doesn't
    // accidentally render a full-bleed image inside a Settings row.
    final size = node.size != null
        ? StyleSlotResolver.sizeSlot(
            numeric: node.size!.numeric,
            token: node.size!.token,
          )
        : 96.0;
    final fit = _resolveImageFit(node.fit);
    final provider = _imageProvider(node.src);
    if (provider == null) {
      // Unknown / unsupported URL scheme. Render the broken-image
      // placeholder so the failure is visible without crashing.
      return _brokenImage(context, key, size);
    }
    return SizedBox(
      key: key,
      width: size,
      height: size,
      child: Image(
        image: provider,
        fit: fit,
        // ErrorBuilder collapses a load failure into the same broken-
        // image placeholder, so an unreachable URL behaves the same
        // way as an unknown scheme.
        errorBuilder: (ctx, _, _) => _brokenImage(ctx, null, size),
      ),
    );
  }

  Widget _brokenImage(BuildContext context, Key? key, double size) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: key,
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: scheme.outline, width: 1),
      ),
      child: Icon(
        Icons.broken_image_outlined,
        size: size * 0.4,
        color: scheme.onSurfaceVariant,
      ),
    );
  }

  BoxFit _resolveImageFit(UiImageFit? fit) {
    switch (fit ?? UiImageFit.cover) {
      case UiImageFit.cover:
        return BoxFit.cover;
      case UiImageFit.contain:
        return BoxFit.contain;
      case UiImageFit.fill:
        return BoxFit.fill;
    }
  }

  /// Dispatches `src` to a Flutter `ImageProvider`. Returns null for
  /// unknown / unsupported schemes; the renderer paints the broken-image
  /// placeholder in that case.
  ///
  /// `file://` URLs reach this code path **only** after the host has
  /// already validated them against the plugin's fs capability and the
  /// active workspace root. The client trusts that gate; it does not
  /// re-validate here.
  ImageProvider? _imageProvider(String src) {
    if (src.startsWith('https://') || src.startsWith('http://')) {
      return NetworkImage(src);
    }
    if (src.startsWith('data:')) {
      final comma = src.indexOf(',');
      if (comma <= 0) return null;
      final meta = src.substring(5, comma); // strip "data:"
      final body = src.substring(comma + 1);
      if (!meta.contains(';base64')) return null;
      try {
        final bytes = base64Decode(body);
        return MemoryImage(Uint8List.fromList(bytes));
      } catch (_) {
        return null;
      }
    }
    if (src.startsWith('file://')) {
      final path = Uri.tryParse(src)?.toFilePath();
      if (path == null) return null;
      return FileImage(File(path));
    }
    return null;
  }

  Widget _buildAvatar(BuildContext context, Key key, UiAvatar node) {
    final size = node.size != null
        ? StyleSlotResolver.sizeSlot(
            numeric: node.size!.numeric,
            token: node.size!.token,
          )
        : 40.0;
    final src = node.src;
    if (src != null && src.isNotEmpty) {
      final provider = _imageProvider(src);
      if (provider != null) {
        return SizedBox(
          key: key,
          width: size,
          height: size,
          child: ClipOval(
            child: Image(
              image: provider,
              fit: BoxFit.cover,
              width: size,
              height: size,
              errorBuilder: (ctx, _, _) =>
                  _initialAvatar(ctx, null, node, size),
            ),
          ),
        );
      }
      // Unknown URL scheme → fall through to initial fallback so the
      // avatar always reads as a circle of *something*.
    }
    return _initialAvatar(context, key, node, size);
  }

  Widget _initialAvatar(
    BuildContext context,
    Key? key,
    UiAvatar node,
    double size,
  ) {
    final initial = node.initial ?? '';
    final glyph = _avatarGlyph(initial);
    final color = node.accent != null
        ? StyleSlotResolver.accent(context, node.accent!)
        : _avatarHashColor(initial);
    // White-on-saturated reads at ≥4.5:1 on every color in the palette;
    // the muted onSurfaceVariant pair is reserved for the brand/muted
    // accent overrides where the bright-white would clash.
    final fg = node.accent == AccentToken.muted
        ? Theme.of(context).colorScheme.onSurface
        : Colors.white;
    return Container(
      key: key,
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Text(
        glyph,
        style: TextStyle(
          color: fg,
          fontSize: size * 0.42,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// Pick the 1–2 character glyph for an initial-fallback avatar. We
  /// honor whatever the plugin sent (up to two visible characters) so a
  /// CJK author can pass `"张"` and get a single-character avatar; a
  /// Latin name like `"AB"` lands as two letters; longer strings are
  /// truncated to the first two code points.
  static String _avatarGlyph(String raw) {
    if (raw.isEmpty) return '?';
    final runes = raw.runes.toList();
    if (runes.length == 1) return String.fromCharCode(runes[0]).toUpperCase();
    return String.fromCharCodes(runes.take(2)).toUpperCase();
  }

  /// Deterministic color hash over [seed] — same convention as
  /// Linear / Telegram. Eight buckets keep the palette small enough
  /// to stay recognizable without colliding too often.
  static Color _avatarHashColor(String seed) {
    if (seed.isEmpty) return _avatarPalette[0];
    int hash = 0;
    for (final rune in seed.runes) {
      hash = (hash * 31 + rune) & 0x7fffffff;
    }
    return _avatarPalette[hash % _avatarPalette.length];
  }

  Widget _buildMarkdown(BuildContext context, Key key, UiMarkdown node) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return MarkdownBody(
      key: key,
      data: node.markdown,
      // Strict subset: `ExtensionSet.none` disables tables / footnotes
      // / autolinks. Block syntaxes default to the CommonMark set; raw-
      // HTML block + inline syntaxes are excluded via the explicit
      // syntax lists below so unsupported constructs (a `<table>` from
      // the plugin author, say) render as escaped plain text instead
      // of executing as HTML.
      extensionSet: md.ExtensionSet.none,
      inlineSyntaxes: const <md.InlineSyntax>[],
      // Don't render images — the spec is explicit ("no images") and we
      // already give plugins UiImage for that. The stub falls back to
      // alt text (then the bare URI) so a stray `![logo](x)` in plugin
      // markdown still surfaces something legible instead of nothing.
      imageBuilder: (uri, title, alt) => Text(alt ?? uri.toString()),
      onTapLink: null, // links render but aren't tappable in v0
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        // Code blocks get the mono font + a subtle background. The
        // dedicated UiCodeBlock widget owns the syntax-highlighted
        // path; here we just style the fenced-code body so a plugin
        // that uses markdown end-to-end still reads cleanly.
        code: AppText.mono(
          fontSize: theme.textTheme.bodyMedium?.fontSize,
          color: scheme.onSurface,
        ),
        codeblockDecoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        a: theme.textTheme.bodyMedium?.copyWith(
          color: scheme.primary,
          decoration: TextDecoration.underline,
        ),
      ),
    );
  }

  Widget _buildCodeBlock(BuildContext context, Key key, UiCodeBlock node) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final language = node.language ?? '';
    final monoStyle = AppText.mono(
      fontSize: theme.textTheme.bodyMedium?.fontSize,
      color: scheme.onSurface,
      height: 1.35,
    );
    // Vertical scroll lives at the panel level (the renderer's parent
    // already provides a scroll viewport for the panel). Long lines
    // need an inner horizontal scroller so we don't wrap code — the
    // spec is explicit ("horizontal scroll for long lines; don't wrap").
    Widget body;
    if (language.isEmpty) {
      // Unknown / absent language → plain monospace, no highlight stack.
      body = SelectionArea(
        child: Text(node.code, style: monoStyle),
      );
    } else {
      body = SelectionArea(
        child: HighlightView(
          node.code,
          language: language,
          theme: highlightThemeForBrightness(theme.brightness),
          padding: EdgeInsets.zero,
          textStyle: monoStyle,
        ),
      );
    }
    // The inner SingleChildScrollView reports an unbounded intrinsic
    // width along the main axis, so dropping a CodeBlock into a Row
    // without a width constraint would blow up layout. LayoutBuilder
    // pins the outer width to whatever the parent provides; when the
    // parent supplies infinity (e.g. a `Row { mainAxisSize: min }`),
    // we fall back to a sensible default so the panel still renders
    // instead of asserting.
    return LayoutBuilder(
      key: key,
      builder: (context, constraints) {
        final maxW =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 320.0;
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxW),
          child: Container(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(color: scheme.outline, width: 1),
            ),
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: body,
            ),
          ),
        );
      },
    );
  }

  Widget _buildProgress(BuildContext context, Key key, UiProgress node) {
    final theme = Theme.of(context);
    final color = node.accent != null
        ? StyleSlotResolver.accent(context, node.accent!)
        : theme.colorScheme.primary;
    final variant = node.variant ?? UiProgressVariant.linear;
    final label = node.label;
    switch (variant) {
      case UiProgressVariant.linear:
        // Label below per spec.
        return Column(
          key: key,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LinearProgressIndicator(
              value: node.value,
              color: color,
              backgroundColor: theme.colorScheme.surfaceContainerHigh,
              minHeight: 4,
            ),
            if (label != null && label.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        );
      case UiProgressVariant.circular:
        // Label to the right per spec; size matches the circular
        // indicator's default so the row reads as one composed unit.
        final indicator = SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            value: node.value,
            color: color,
            strokeWidth: 2.5,
          ),
        );
        if (label == null || label.isEmpty) return KeyedSubtree(key: key, child: indicator);
        return Row(
          key: key,
          mainAxisSize: MainAxisSize.min,
          children: [
            indicator,
            const SizedBox(width: AppSpacing.sm),
            Flexible(
              child: Text(
                label,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        );
    }
  }

  // ---- Batch 5 widgets (§4.3) — long tail ----

  Widget _buildGrid(BuildContext context, Key key, UiGrid node) {
    final gap = node.gap == null
        ? AppSpacing.sm
        : StyleSlotResolver.spacingSlot(
            numeric: node.gap!.numeric,
            token: node.gap!.token,
          );
    return LayoutBuilder(
      key: key,
      builder: (context, constraints) {
        int columns;
        if (node.columns.fixed != null) {
          columns = node.columns.fixed!;
        } else {
          // Adaptive: target ~120dp per cell. Clamp to >=1 so very-narrow
          // viewports still render at least one column.
          const target = 120.0;
          final w = constraints.maxWidth.isFinite ? constraints.maxWidth : 360.0;
          columns = (w / target).floor().clamp(1, 1 << 8);
        }
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: gap,
            crossAxisSpacing: gap,
            // Square cells read as dashboard tiles; not a token
            // (renderer-local choice).
            childAspectRatio: 1,
          ),
          itemCount: node.children.length,
          itemBuilder: (context, i) => _render(context, node.children[i]),
        );
      },
    );
  }

  Widget _buildStack(BuildContext context, Key key, UiStack node) {
    final alignment = _stackAlignmentToFlutter(node.alignment);
    return Stack(
      key: key,
      alignment: alignment,
      children: node.children.map((c) => _render(context, c)).toList(),
    );
  }

  static Alignment _stackAlignmentToFlutter(UiStackAlignment? a) {
    switch (a ?? UiStackAlignment.center) {
      case UiStackAlignment.topStart:
        return Alignment.topLeft;
      case UiStackAlignment.topCenter:
        return Alignment.topCenter;
      case UiStackAlignment.topEnd:
        return Alignment.topRight;
      case UiStackAlignment.centerStart:
        return Alignment.centerLeft;
      case UiStackAlignment.center:
        return Alignment.center;
      case UiStackAlignment.centerEnd:
        return Alignment.centerRight;
      case UiStackAlignment.bottomStart:
        return Alignment.bottomLeft;
      case UiStackAlignment.bottomCenter:
        return Alignment.bottomCenter;
      case UiStackAlignment.bottomEnd:
        return Alignment.bottomRight;
    }
  }

  Widget _buildTabBar(BuildContext context, Key key, UiTabBar node) {
    // iOS-style segmented control. Active tab gets a raised pill;
    // inactive tabs are bare label rows. Tap → fire onChangeEvent with
    // payload { tabId }. Switching content is the plugin's job.
    final scheme = Theme.of(context).colorScheme;
    // Defense-in-depth: the parser requires `activeId` to be a non-empty
    // string but does not cross-check it against the `tabs` list, so a
    // plugin can emit a stale id and we render the first tab instead of
    // an unselected segmented control.
    final activeId = node.tabs.any((t) => t.id == node.activeId)
        ? node.activeId
        : node.tabs.first.id;
    return Container(
      key: key,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final tab in node.tabs)
            Expanded(
              child: _UiTabBarItem(
                key: ValueKey<String>('tab:${node.id}/${tab.id}'),
                tab: tab,
                selected: tab.id == activeId,
                onTap: () {
                  final evt = node.onChangeEvent;
                  if (evt != null) {
                    onEvent(UiNodeEvent(
                      nodeId: node.id,
                      type: evt,
                      payload: {'tabId': tab.id},
                    ));
                  }
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSpinner(BuildContext context, Key key, UiSpinner node) {
    final theme = Theme.of(context);
    final size = node.size != null
        ? StyleSlotResolver.sizeSlot(
            numeric: node.size!.numeric,
            token: node.size!.token,
          )
        : AppIconSize.md;
    final indicator = SizedBox(
      width: size,
      height: size,
      child: CircularProgressIndicator(
        strokeWidth: 2.5,
        color: theme.colorScheme.primary,
      ),
    );
    final label = node.label;
    if (label == null || label.isEmpty) {
      return KeyedSubtree(key: key, child: indicator);
    }
    return Row(
      key: key,
      mainAxisSize: MainAxisSize.min,
      children: [
        indicator,
        const SizedBox(width: AppSpacing.sm),
        Flexible(child: Text(label, style: theme.textTheme.bodyMedium)),
      ],
    );
  }
}

/// Eight-color avatar palette. Saturation matched so the eight options
/// read as obviously distinct and no single seed lands on the brand
/// green (the brand color is reserved for `accent: 'brand'` overrides).
const List<Color> _avatarPalette = <Color>[
  Color(0xFF3B82F6), // blue
  Color(0xFFA855F7), // violet
  Color(0xFFEF4444), // red
  Color(0xFFF97316), // orange
  Color(0xFFEAB308), // amber
  Color(0xFF14B8A6), // teal
  Color(0xFFEC4899), // pink
  Color(0xFF6366F1), // indigo
];

/// Single tile inside [UiAppGrid]. Geometry per design §4.3: 48–56px
/// icon area + caption beneath; touch target ≥ 48dp by virtue of the
/// surrounding Material+InkWell occupying the full grid cell.
class _AppGridTile extends StatelessWidget {
  final UiAppTile tile;
  final String gridId;
  final VoidCallback onTap;
  /// Screen-local long-press hook (Plugins-tab launcher only). Null for
  /// plugin-authored panels.
  final VoidCallback? onLongPress;
  const _AppGridTile({
    required this.tile,
    required this.gridId,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = tile.accent != null
        ? StyleSlotResolver.accent(context, tile.accent!)
        : scheme.primary;
    return Material(
      key: ValueKey<String>('app-tile:$gridId/${tile.id}'),
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            border: Border.all(color: scheme.outline, width: 1),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Center(
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: Stack(
                      alignment: Alignment.center,
                      clipBehavior: Clip.none,
                      children: [
                        _renderTileIcon(context, accent),
                        if (tile.badge != null)
                          Positioned(
                            top: -4,
                            right: -4,
                            child: _AppTileBadge(badge: tile.badge!),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                tile.name,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _renderTileIcon(BuildContext context, Color accent) {
    final scheme = Theme.of(context).colorScheme;
    final icon = tile.icon;
    if (icon is UiAppTileIconName) {
      final data = resolveIconByName(icon.name) ?? Icons.help_outline;
      return Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: scheme.outline, width: 1),
        ),
        child: Icon(data, size: 28, color: accent),
      );
    }
    // UiAppTileIconUri → reserved for Batch 3 image support; for now we
    // render the placeholder so the contract is observable but degrades
    // visibly.
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: scheme.outline, width: 1),
      ),
      child: Icon(Icons.image_outlined, size: 28, color: accent),
    );
  }
}

/// Stateful inner renderer for `UiTextField`. Holds its own
/// `TextEditingController` so user keystrokes don't get clobbered by
/// re-renders, and so the caret survives a tree replacement that
/// happens to keep this node identity-stable. When the server-pushed
/// `value` actually changes between two pushes (i.e. the plugin chose
/// to overwrite the field), we sync the controller — but only when the
/// new value differs from what the user is currently typing, to avoid
/// gratuitous caret jumps.
class _UiTextFieldRenderer extends StatefulWidget {
  final String nodeId;
  final String? label;
  final String? initialValue;
  final String? placeholder;
  final void Function(String) onChanged;
  const _UiTextFieldRenderer({
    super.key,
    required this.nodeId,
    required this.label,
    required this.initialValue,
    required this.placeholder,
    required this.onChanged,
  });

  @override
  State<_UiTextFieldRenderer> createState() => _UiTextFieldRendererState();
}

class _UiTextFieldRendererState extends State<_UiTextFieldRenderer> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue ?? '');
  }

  @override
  void didUpdateWidget(_UiTextFieldRenderer old) {
    super.didUpdateWidget(old);
    final next = widget.initialValue ?? '';
    if (widget.initialValue != old.initialValue && _controller.text != next) {
      _controller.text = next;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.placeholder,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: widget.onChanged,
    );
  }
}

/// Stateful inner renderer for `UiSwitch`. Tracks the optimistic
/// value locally so the thumb follows the gesture instantly — the
/// plugin's next render is authoritative and we sync the local value
/// when the wire value changes (this also lets a plugin "reject" a
/// toggle by re-rendering with the prior value).
class _UiSwitchRenderer extends StatefulWidget {
  final UiSwitch node;
  final void Function(UiNodeEvent event) onEvent;
  const _UiSwitchRenderer({
    super.key,
    required this.node,
    required this.onEvent,
  });

  @override
  State<_UiSwitchRenderer> createState() => _UiSwitchRendererState();
}

class _UiSwitchRendererState extends State<_UiSwitchRenderer> {
  late bool _value;

  @override
  void initState() {
    super.initState();
    _value = widget.node.value;
  }

  @override
  void didUpdateWidget(_UiSwitchRenderer old) {
    super.didUpdateWidget(old);
    // The plugin's next render is authoritative: if the incoming wire
    // value disagrees with our optimistic local value, the wire wins.
    // This covers both "plugin confirms the flip" (no-op) and "plugin
    // rejects the flip / re-renders with the previous value" (snap
    // back). We compare against `widget.node.value` (not old.node) so
    // a re-render with the same wire value still snaps a divergent
    // local back into sync.
    if (widget.node.value != _value) {
      _value = widget.node.value;
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.node.label;
    final theSwitch = Switch(
      value: _value,
      onChanged: (next) {
        setState(() => _value = next);
        final evt = widget.node.onChangeEvent;
        if (evt != null) {
          widget.onEvent(UiNodeEvent(
            nodeId: widget.node.id,
            type: evt,
            payload: {'value': next},
          ));
        }
      },
    );
    if (label == null || label.isEmpty) return theSwitch;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Expanded(child: Text(label)),
        theSwitch,
      ],
    );
  }
}

/// Stateful inner renderer for `UiSelect`. Renders as a tappable row
/// (label + current option label + chevron) that opens a modal
/// bottom-sheet picker — the doc spec is explicit that mobile never
/// drops a desktop-style dropdown.
class _UiSelectRenderer extends StatefulWidget {
  final UiSelect node;
  final void Function(UiNodeEvent event) onEvent;
  const _UiSelectRenderer({
    super.key,
    required this.node,
    required this.onEvent,
  });

  @override
  State<_UiSelectRenderer> createState() => _UiSelectRendererState();
}

class _UiSelectRendererState extends State<_UiSelectRenderer> {
  String? _value;

  @override
  void initState() {
    super.initState();
    _value = widget.node.value;
  }

  @override
  void didUpdateWidget(_UiSelectRenderer old) {
    super.didUpdateWidget(old);
    // Wire value wins on any re-render where it disagrees with our
    // optimistic local pick — matches the Switch contract above.
    if (widget.node.value != _value) {
      _value = widget.node.value;
    }
  }

  String _displayLabel() {
    final v = _value;
    if (v == null) return 'Select…';
    for (final opt in widget.node.options) {
      if (opt.value == v) return opt.label;
    }
    return v; // value not in options: show the raw value as a soft fallback
  }

  Future<void> _openPicker(BuildContext context) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.node.label != null && widget.node.label!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.sm,
                    AppSpacing.lg,
                    AppSpacing.sm,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      widget.node.label!,
                      style: Theme.of(sheetCtx).textTheme.titleMedium,
                    ),
                  ),
                ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: widget.node.options.length,
                  itemBuilder: (ctx, i) {
                    final opt = widget.node.options[i];
                    final selected = opt.value == _value;
                    return ListTile(
                      key: ValueKey<String>(
                        'select-option:${widget.node.id}/${opt.value}',
                      ),
                      title: Text(opt.label),
                      trailing: selected
                          ? Icon(
                              Icons.check,
                              color: Theme.of(ctx).colorScheme.primary,
                            )
                          : null,
                      onTap: () => Navigator.of(sheetCtx).pop(opt.value),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
    if (picked == null) return;
    setState(() => _value = picked);
    final evt = widget.node.onChangeEvent;
    if (evt != null) {
      widget.onEvent(UiNodeEvent(
        nodeId: widget.node.id,
        type: evt,
        payload: {'value': picked},
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = widget.node.label;
    return InkWell(
      onTap: () => _openPicker(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          children: [
            if (label != null && label.isNotEmpty)
              Expanded(child: Text(label)),
            if (label == null || label.isEmpty) const Spacer(),
            Text(
              _displayLabel(),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(width: AppSpacing.xs),
            Icon(
              Icons.chevron_right,
              color: scheme.onSurfaceVariant,
              size: AppIconSize.sm,
            ),
          ],
        ),
      ),
    );
  }
}

/// Stateful wrapper that owns the expand/collapse state for a
/// [UiSection] when `collapsible: true`. Default state is expanded.
/// Because the wrapper sits behind a ValueKey derived from the section
/// id, re-renders with the same id reuse the same State object — so
/// the user's toggle survives until either the id changes or the
/// renderer rebuilds without `collapsible`.
class _CollapsibleSection extends StatefulWidget {
  final String? title;
  final Widget Function(bool expanded) renderBody;
  final UiSectionVariant variant;
  const _CollapsibleSection({
    super.key,
    required this.title,
    required this.renderBody,
    required this.variant,
  });

  @override
  State<_CollapsibleSection> createState() => _CollapsibleSectionState();
}

class _CollapsibleSectionState extends State<_CollapsibleSection> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasTitle = widget.title != null && widget.title!.isNotEmpty;
    final chevron = AnimatedRotation(
      turns: _expanded ? 0 : -0.25,
      duration: const Duration(milliseconds: 180),
      child: Icon(
        resolveIconByName('chevron-down') ?? Icons.expand_more,
        size: AppIconSize.sm,
        color: scheme.onSurfaceVariant,
      ),
    );
    final header = InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          children: [
            if (hasTitle)
              Expanded(
                child: Text(
                  widget.title!,
                  style: widget.variant == UiSectionVariant.inset
                      ? theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            letterSpacing: 0.6,
                            fontWeight: FontWeight.w600,
                          )
                      : theme.textTheme.titleMedium,
                ),
              )
            else
              const Spacer(),
            chevron,
          ],
        ),
      ),
    );
    final body = widget.renderBody(_expanded);
    // For the `card` variant, keep the body inside a Material Card so
    // the chrome stays consistent. For `inset`, drop the body inside an
    // [InsetSection] surface when expanded so the dividers + rounded
    // edge still render correctly.
    Widget content;
    switch (widget.variant) {
      case UiSectionVariant.plain:
        content = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            if (_expanded) body,
          ],
        );
        break;
      case UiSectionVariant.card:
        content = Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                if (_expanded)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.sm,
                      0,
                      AppSpacing.sm,
                      AppSpacing.sm,
                    ),
                    child: body,
                  ),
              ],
            ),
          ),
        );
        break;
      case UiSectionVariant.inset:
        content = Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              if (_expanded)
                Material(
                  color: scheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  clipBehavior: Clip.antiAlias,
                  child: body,
                ),
            ],
          ),
        );
        break;
    }
    return content;
  }
}

/// Slim corner badge for [UiAppTile]. Renders a small pill with the
/// count (or text); empty badges degrade to a danger-accented dot.
class _AppTileBadge extends StatelessWidget {
  final UiAppTileBadge badge;
  const _AppTileBadge({required this.badge});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = badge.text ?? (badge.count != null ? "${badge.count}" : "");
    if (label.isEmpty) {
      return Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: scheme.error, shape: BoxShape.circle),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.error,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onError,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}


/// Single segmented-control tab inside [UiTabBar]. Active tabs raise
/// to the surface-container-highest with a subtle border; inactive
/// tabs sit flush.
class _UiTabBarItem extends StatelessWidget {
  final UiTabBarTab tab;
  final bool selected;
  final VoidCallback onTap;
  const _UiTabBarItem({
    super.key,
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final iconData = tab.icon == null ? null : resolveIconByName(tab.icon!);
    final pill = Container(
      decoration: BoxDecoration(
        color: selected ? scheme.surfaceContainerHighest : null,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: selected
            ? Border.all(color: scheme.outline, width: 1)
            : null,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (iconData != null)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.xs),
              child: Icon(
                iconData,
                size: AppIconSize.sm,
                color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
              ),
            ),
          Text(
            tab.label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: pill,
    );
  }
}

/// Stateful inner renderer for [UiSearchField]. Holds its own
/// `TextEditingController` so the clear button can wipe the text
/// without round-tripping through the plugin first; the controller's
/// text is the source of local truth between renders.
class _UiSearchFieldRenderer extends StatefulWidget {
  final UiSearchField node;
  final void Function(UiNodeEvent event) onEvent;
  const _UiSearchFieldRenderer({
    super.key,
    required this.node,
    required this.onEvent,
  });

  @override
  State<_UiSearchFieldRenderer> createState() => _UiSearchFieldRendererState();
}

class _UiSearchFieldRendererState extends State<_UiSearchFieldRenderer> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.node.value ?? '');
  }

  @override
  void didUpdateWidget(_UiSearchFieldRenderer old) {
    super.didUpdateWidget(old);
    final next = widget.node.value ?? '';
    if (widget.node.value != old.node.value && _controller.text != next) {
      _controller.text = next;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _emit(String value) {
    final evt = widget.node.onChangeEvent;
    if (evt == null) return;
    widget.onEvent(UiNodeEvent(
      nodeId: widget.node.id,
      type: evt,
      payload: {'value': value},
    ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final hasText = _controller.text.isNotEmpty;
        return TextField(
          controller: _controller,
          decoration: InputDecoration(
            prefixIcon: Icon(
              resolveIconByName('search') ?? Icons.search,
              size: AppIconSize.sm,
              color: scheme.onSurfaceVariant,
            ),
            suffixIcon: hasText
                ? IconButton(
                    icon: Icon(
                      resolveIconByName('x') ?? Icons.close,
                      size: AppIconSize.sm,
                      color: scheme.onSurfaceVariant,
                    ),
                    tooltip: 'Clear',
                    onPressed: () {
                      _controller.clear();
                      _emit('');
                    },
                  )
                : null,
            hintText: widget.node.placeholder,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: _emit,
        );
      },
    );
  }
}

/// Stateful inner renderer for [UiCheckbox]. Same optimistic-local +
/// authoritative-wire contract as [UiSwitch].
class _UiCheckboxRenderer extends StatefulWidget {
  final UiCheckbox node;
  final void Function(UiNodeEvent event) onEvent;
  const _UiCheckboxRenderer({
    super.key,
    required this.node,
    required this.onEvent,
  });

  @override
  State<_UiCheckboxRenderer> createState() => _UiCheckboxRendererState();
}

class _UiCheckboxRendererState extends State<_UiCheckboxRenderer> {
  late bool _value;

  @override
  void initState() {
    super.initState();
    _value = widget.node.value;
  }

  @override
  void didUpdateWidget(_UiCheckboxRenderer old) {
    super.didUpdateWidget(old);
    if (widget.node.value != _value) {
      _value = widget.node.value;
    }
  }

  void _toggle(bool? next) {
    if (next == null) return;
    setState(() => _value = next);
    final evt = widget.node.onChangeEvent;
    if (evt != null) {
      widget.onEvent(UiNodeEvent(
        nodeId: widget.node.id,
        type: evt,
        payload: {'value': next},
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.node.label;
    final box = Checkbox(value: _value, onChanged: _toggle);
    if (label == null || label.isEmpty) return box;
    return InkWell(
      onTap: () => _toggle(!_value),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          box,
          const SizedBox(width: AppSpacing.xs),
          Flexible(child: Text(label)),
        ],
      ),
    );
  }
}

/// Stateful inner renderer for [UiRadioGroup]. Same contract as
/// [UiSwitch].
class _UiRadioGroupRenderer extends StatefulWidget {
  final UiRadioGroup node;
  final void Function(UiNodeEvent event) onEvent;
  const _UiRadioGroupRenderer({
    super.key,
    required this.node,
    required this.onEvent,
  });

  @override
  State<_UiRadioGroupRenderer> createState() => _UiRadioGroupRendererState();
}

class _UiRadioGroupRendererState extends State<_UiRadioGroupRenderer> {
  String? _value;

  @override
  void initState() {
    super.initState();
    _value = widget.node.value;
  }

  @override
  void didUpdateWidget(_UiRadioGroupRenderer old) {
    super.didUpdateWidget(old);
    if (widget.node.value != _value) {
      _value = widget.node.value;
    }
  }

  void _pick(String? next) {
    if (next == null || next == _value) return;
    setState(() => _value = next);
    final evt = widget.node.onChangeEvent;
    if (evt != null) {
      widget.onEvent(UiNodeEvent(
        nodeId: widget.node.id,
        type: evt,
        payload: {'value': next},
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    // Wrap in RadioGroup<String> per the post-3.32 API: Radio widgets
    // bind to the nearest RadioGroup ancestor for group value + change
    // callback, replacing the per-Radio `groupValue` / `onChanged`
    // arguments that were deprecated in 3.32.
    return RadioGroup<String>(
      groupValue: _value,
      onChanged: _pick,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final opt in widget.node.options)
            InkWell(
              key: ValueKey<String>('radio:${widget.node.id}/${opt.value}'),
              onTap: () => _pick(opt.value),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                child: Row(
                  children: [
                    Radio<String>(value: opt.value),
                    const SizedBox(width: AppSpacing.xs),
                    Flexible(child: Text(opt.label)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Stateful inner renderer for [UiSlider]. Continuous when [UiSlider.step]
/// is null; stepped otherwise. Same optimistic-local + authoritative-
/// wire contract as the other inputs.
class _UiSliderRenderer extends StatefulWidget {
  final UiSlider node;
  final void Function(UiNodeEvent event) onEvent;
  const _UiSliderRenderer({
    super.key,
    required this.node,
    required this.onEvent,
  });

  @override
  State<_UiSliderRenderer> createState() => _UiSliderRendererState();
}

class _UiSliderRendererState extends State<_UiSliderRenderer> {
  late double _value;

  @override
  void initState() {
    super.initState();
    _value = _clamped(widget.node.value);
  }

  @override
  void didUpdateWidget(_UiSliderRenderer old) {
    super.didUpdateWidget(old);
    // Wire value is authoritative: compare against our optimistic
    // local (not against the previous wire value). Otherwise a "plugin
    // rejects local drag by re-rendering with the prior wire value"
    // sequence — where `old.node.value == widget.node.value` — would
    // silently leave the UI on the user's optimistic value while the
    // plugin thinks the slider is back at the previous position. This
    // mirrors the Switch / Checkbox / RadioGroup contract.
    if (widget.node.value != _value) {
      _value = _clamped(widget.node.value);
    }
  }

  double _clamped(double v) => v.clamp(widget.node.min, widget.node.max);

  int? _divisions() {
    final step = widget.node.step;
    if (step == null || step <= 0) return null;
    final span = widget.node.max - widget.node.min;
    if (span <= 0) return null;
    final n = (span / step).round();
    return n > 0 ? n : null;
  }

  void _onChanged(double v) {
    setState(() => _value = v);
    final evt = widget.node.onChangeEvent;
    if (evt != null) {
      widget.onEvent(UiNodeEvent(
        nodeId: widget.node.id,
        type: evt,
        payload: {'value': v},
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Slider(
      min: widget.node.min,
      max: widget.node.max,
      divisions: _divisions(),
      value: _value,
      onChanged: _onChanged,
    );
  }
}
