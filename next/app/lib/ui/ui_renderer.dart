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

import 'package:flutter/material.dart';

import 'app_tokens.dart';
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
  ///
  /// TODO(batch 4 SwipeAction): once UiAppGrid grows an
  /// onLongPressEvent in the spec, drive this through the widget
  /// contract and drop this screen-local hook.
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
      case UiSection(:final title, :final variant, :final children):
        // Dispatch on the optional `variant`. Omitted → `plain` so any
        // pre-Batch-2 tree (no variant on the wire) renders identically
        // to the old Section path. `card` reuses the renderer's Card
        // branch so the visual stays one source of truth.
        switch (variant ?? UiSectionVariant.plain) {
          case UiSectionVariant.plain:
            return _buildPlainSection(context, key, title, children);
          case UiSectionVariant.card:
            return _buildCardSection(context, key, title, children);
          case UiSectionVariant.inset:
            return _buildInsetSection(context, key, title, children);
        }
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
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null && title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
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
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null && title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8, left: 4),
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
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
      accent.withAlpha(38), // ~15% alpha
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
          border: Border.all(color: accent.withAlpha(102), width: 1),
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
    // `swipeActions` is plumbed but not rendered in Batch 1 (Batch 4 lights
    // it up). Material ListTile gives us the title/subtitle/leading/trailing
    // contract for free; tapping fires the configured onTapEvent.
    final tile = ListTile(
      key: key,
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
    return tile;
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
}

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
