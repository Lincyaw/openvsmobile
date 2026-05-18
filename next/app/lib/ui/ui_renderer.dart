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

  const UiRenderer({super.key, required this.tree, required this.onEvent});

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
      case UiSection(:final title, :final children):
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
      case UiCard(:final children):
        return Card(
          key: key,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: children.map((c) => _render(context, c)).toList(),
            ),
          ),
        );
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
    // Pick foreground for readable contrast: bright accents (brand/info)
    // pair with onPrimary; muted accents pair with onSurface.
    final fg = node.accent == AccentToken.muted
        ? scheme.onSurface
        : scheme.onPrimary;
    return Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
            return _AppGridTile(
              tile: tile,
              gridId: node.id,
              onTap: () => onEvent(UiNodeEvent(
                nodeId: node.id,
                type: node.onLaunchEvent ?? 'launch',
                payload: {'tileId': tile.id},
              )),
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
  const _AppGridTile({
    required this.tile,
    required this.gridId,
    required this.onTap,
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
