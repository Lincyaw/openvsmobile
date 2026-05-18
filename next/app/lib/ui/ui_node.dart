// UI descriptor types — Dart mirror of the backend's `UiNode` union
// defined in `next/backend/src/plugins/ui.ts`. See design §4.3 and
// issue #59.
//
// The protocol carries a typed widget tree, not opaque HTML. We model
// each kind as a sealed-class case so the renderer's switch is
// exhaustive at compile time — adding a new widget kind requires both
// expanding the backend's validator and adding a Dart case here, which
// is the intended friction (CLAUDE.md "Plugins extend the vocabulary,
// never the runtime").
//
// Validation policy: the backend already rejects malformed trees with
// -32602 before they ever reach the wire. Dart-side parsing is
// defensive but lenient — unknown fields are ignored (forward-compat
// for v1 widget extensions), and a structurally broken push surfaces as
// a `FormatException` from `UiNode.fromJson` which the model layer
// catches and turns into a dropped push + log line.

import 'package:flutter/foundation.dart';

import 'app_tokens.dart';

/// Style hint for `UiText`.
enum UiTextStyleKind { body, title, caption, mono }

/// Visual emphasis for `UiButton`. Maps to Material button variants
/// inside the renderer (see ui_renderer.dart).
enum UiButtonStyleKind { primary, secondary, danger }

/// `gap` / `size` / `padding` accepts either a raw number (legacy) or a
/// named [SpacingToken] (Batch 1). The container carries whichever the
/// plugin sent and the renderer resolves through [StyleSlotResolver].
@immutable
class SpacingSlot {
  final double? numeric;
  final SpacingToken? token;
  const SpacingSlot._({this.numeric, this.token});

  factory SpacingSlot.number(double v) => SpacingSlot._(numeric: v);
  factory SpacingSlot.tokenValue(SpacingToken t) => SpacingSlot._(token: t);

  bool get isEmpty => numeric == null && token == null;
}

/// `size` slot for [UiIcon] — accepts a number or [SizeToken].
@immutable
class SizeSlot {
  final double? numeric;
  final SizeToken? token;
  const SizeSlot._({this.numeric, this.token});

  factory SizeSlot.number(double v) => SizeSlot._(numeric: v);
  factory SizeSlot.tokenValue(SizeToken t) => SizeSlot._(token: t);
}

/// Discriminant for [UiBadge].
enum UiBadgeVariant { dot, pill }

/// Visual variant of [UiSection] (Batch 2 — §4.3).
/// * [plain]  — no surface, just title + children (the pre-Batch-2 default)
/// * [card]   — Material-flavor rounded card with subtle border
/// * [inset]  — iOS Settings inset-grouped style; carries the
///   Settings-app visual identity.
/// Omitted/null on the wire = [plain] so pre-Batch-2 trees keep rendering.
enum UiSectionVariant { plain, card, inset }

/// Accent for [UiInlineBanner] — narrower than [AccentToken] because a
/// "you should notice this" surface only ships in info / success /
/// warning / danger tones.
enum UiInlineBannerAccent { info, success, warning, danger }

/// Orientation for [UiDivider].
enum UiDividerOrientation { horizontal, vertical }

/// Base type for every node in the descriptor tree. Every concrete node
/// carries an `id` which is mandatory and must be unique within the
/// tree — that uniqueness is enforced server-side; the renderer relies
/// on it to construct `ValueKey`s for reconciliation.
@immutable
sealed class UiNode {
  final String id;
  const UiNode(this.id);

  /// Parse a raw map (as decoded from the JSON-RPC `ui.tree` payload).
  /// Throws `FormatException` for malformed input.
  static UiNode fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('UiNode: expected JSON object');
    }
    final id = raw['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('UiNode: id must be a non-empty string');
    }
    final kind = raw['kind'];
    switch (kind) {
      case 'Column':
        return UiColumn(
          id: id,
          children: _children(raw['children']),
          gap: _spacingSlot(raw['gap']),
        );
      case 'Row':
        return UiRow(
          id: id,
          children: _children(raw['children']),
          gap: _spacingSlot(raw['gap']),
        );
      case 'Section':
        return UiSection(
          id: id,
          title: _asString(raw['title']),
          variant: _sectionVariant(raw['variant']),
          children: _children(raw['children']),
        );
      case 'Card':
        return UiCard(id: id, children: _children(raw['children']));
      case 'List':
        return UiList(id: id, items: _children(raw['items']));
      case 'Text':
        final text = raw['text'];
        if (text is! String) {
          throw const FormatException('UiText.text must be a string');
        }
        return UiText(
          id: id,
          text: text,
          style: _textStyle(raw['style']),
        );
      case 'Spacer':
        return UiSpacer(id: id, size: _spacingSlot(raw['size']));
      case 'TextField':
        return UiTextField(
          id: id,
          label: _asString(raw['label']),
          value: _asString(raw['value']),
          placeholder: _asString(raw['placeholder']),
        );
      case 'Button':
        final label = raw['label'];
        if (label is! String || label.isEmpty) {
          throw const FormatException(
            'UiButton.label must be a non-empty string',
          );
        }
        return UiButton(
          id: id,
          label: label,
          style: _buttonStyle(raw['style']),
        );
      case 'Icon':
        final name = raw['name'];
        if (name is! String || name.isEmpty) {
          throw const FormatException(
            'UiIcon.name must be a non-empty string',
          );
        }
        return UiIcon(
          id: id,
          name: name,
          size: _sizeSlot(raw['size']),
          accent: accentTokenFromString(_asString(raw['accent'])),
        );
      case 'Badge':
        final variantRaw = raw['variant'];
        if (variantRaw is! String) {
          throw const FormatException('UiBadge.variant is required');
        }
        return UiBadge(
          id: id,
          variant: _badgeVariant(variantRaw),
          text: _asString(raw['text']),
          count: _asInt(raw['count']),
          accent: accentTokenFromString(_asString(raw['accent'])),
        );
      case 'ListTile':
        final title = raw['title'];
        if (title is! String || title.isEmpty) {
          throw const FormatException(
            'UiListTile.title must be a non-empty string',
          );
        }
        return UiListTile(
          id: id,
          title: title,
          subtitle: _asString(raw['subtitle']),
          leading: raw['leading'] == null
              ? null
              : UiNode.fromJson(raw['leading']),
          trailing: raw['trailing'] == null
              ? null
              : UiNode.fromJson(raw['trailing']),
          onTapEvent: _asString(raw['onTapEvent']),
          swipeActions: _swipeActions(raw['swipeActions']),
        );
      case 'AppGrid':
        return UiAppGrid(
          id: id,
          items: _appTiles(raw['items']),
          columns: _asInt(raw['columns']),
          onLaunchEvent: _asString(raw['onLaunchEvent']),
        );
      case 'Switch':
        final value = raw['value'];
        if (value is! bool) {
          throw const FormatException('UiSwitch.value must be a bool');
        }
        return UiSwitch(
          id: id,
          value: value,
          label: _asString(raw['label']),
          onChangeEvent: _asString(raw['onChangeEvent']),
        );
      case 'Select':
        return UiSelect(
          id: id,
          options: _selectOptions(raw['options']),
          label: _asString(raw['label']),
          value: _asString(raw['value']),
          onChangeEvent: _asString(raw['onChangeEvent']),
        );
      case 'Banner':
        final title = raw['title'];
        if (title is! String || title.isEmpty) {
          throw const FormatException(
            'UiInlineBanner.title must be a non-empty string',
          );
        }
        final accentRaw = raw['accent'];
        final accent = _bannerAccent(accentRaw);
        Object? actionRaw = raw['action'];
        UiInlineBannerAction? action;
        if (actionRaw is Map<String, dynamic>) {
          final aLabel = actionRaw['label'];
          final aEventId = actionRaw['eventId'];
          if (aLabel is! String || aLabel.isEmpty) {
            throw const FormatException(
              'UiInlineBanner.action.label must be a non-empty string',
            );
          }
          if (aEventId is! String || aEventId.isEmpty) {
            throw const FormatException(
              'UiInlineBanner.action.eventId must be a non-empty string',
            );
          }
          action = UiInlineBannerAction(label: aLabel, eventId: aEventId);
        } else if (actionRaw != null) {
          throw const FormatException(
            'UiInlineBanner.action must be a JSON object when provided',
          );
        }
        return UiInlineBanner(
          id: id,
          title: title,
          accent: accent,
          body: _asString(raw['body']),
          action: action,
          dismissEventId: _asString(raw['dismissEventId']),
        );
      case 'Divider':
        return UiDivider(
          id: id,
          orientation: _dividerOrientation(raw['orientation']),
        );
      default:
        throw FormatException('UiNode: unknown kind "$kind"');
    }
  }

  static List<UiNode> _children(Object? raw) {
    if (raw is! List) {
      throw const FormatException(
        'UiNode: children/items must be a JSON array',
      );
    }
    return [for (final c in raw) UiNode.fromJson(c)];
  }

  static String? _asString(Object? raw) {
    if (raw == null) return null;
    if (raw is! String) {
      throw FormatException('UiNode: expected string, got ${raw.runtimeType}');
    }
    return raw;
  }

  static int? _asInt(Object? raw) {
    if (raw == null) return null;
    if (raw is int) return raw;
    if (raw is double && raw == raw.truncateToDouble()) return raw.toInt();
    throw FormatException('UiNode: expected integer, got ${raw.runtimeType}');
  }

  static SpacingSlot? _spacingSlot(Object? raw) {
    if (raw == null) return null;
    if (raw is num) return SpacingSlot.number(raw.toDouble());
    if (raw is String) {
      final tok = spacingTokenFromString(raw);
      if (tok != null) return SpacingSlot.tokenValue(tok);
    }
    throw FormatException(
      'UiNode: spacing must be a number or SpacingToken string, got ${raw.runtimeType}',
    );
  }

  static SizeSlot? _sizeSlot(Object? raw) {
    if (raw == null) return null;
    if (raw is num) return SizeSlot.number(raw.toDouble());
    if (raw is String) {
      final tok = sizeTokenFromString(raw);
      if (tok != null) return SizeSlot.tokenValue(tok);
    }
    throw FormatException(
      'UiNode: size must be a number or SizeToken string, got ${raw.runtimeType}',
    );
  }

  static UiBadgeVariant _badgeVariant(String raw) {
    switch (raw) {
      case 'dot':
        return UiBadgeVariant.dot;
      case 'pill':
        return UiBadgeVariant.pill;
    }
    throw FormatException('UiBadge: unknown variant "$raw"');
  }

  static UiSectionVariant? _sectionVariant(Object? raw) {
    if (raw == null) return null;
    if (raw is! String) {
      throw const FormatException('UiSection.variant must be a string');
    }
    switch (raw) {
      case 'plain':
        return UiSectionVariant.plain;
      case 'card':
        return UiSectionVariant.card;
      case 'inset':
        return UiSectionVariant.inset;
    }
    throw FormatException('UiSection: unknown variant "$raw"');
  }

  static List<UiSelectOption> _selectOptions(Object? raw) {
    if (raw is! List) {
      throw const FormatException('UiSelect.options must be a JSON array');
    }
    final out = <UiSelectOption>[];
    for (final entry in raw) {
      if (entry is! Map<String, dynamic>) {
        throw const FormatException(
          'UiSelect.options[*] must be a JSON object',
        );
      }
      final value = entry['value'];
      final label = entry['label'];
      if (value is! String || value.isEmpty) {
        throw const FormatException(
          'UiSelect.options[*].value must be a non-empty string',
        );
      }
      if (label is! String || label.isEmpty) {
        throw const FormatException(
          'UiSelect.options[*].label must be a non-empty string',
        );
      }
      out.add(UiSelectOption(value: value, label: label));
    }
    return out;
  }

  static UiInlineBannerAccent _bannerAccent(Object? raw) {
    if (raw is! String) {
      throw const FormatException(
        'UiInlineBanner.accent must be one of info|success|warning|danger',
      );
    }
    switch (raw) {
      case 'info':
        return UiInlineBannerAccent.info;
      case 'success':
        return UiInlineBannerAccent.success;
      case 'warning':
        return UiInlineBannerAccent.warning;
      case 'danger':
        return UiInlineBannerAccent.danger;
    }
    throw FormatException('UiInlineBanner: unknown accent "$raw"');
  }

  static UiDividerOrientation? _dividerOrientation(Object? raw) {
    if (raw == null) return null;
    if (raw is! String) {
      throw const FormatException('UiDivider.orientation must be a string');
    }
    switch (raw) {
      case 'horizontal':
        return UiDividerOrientation.horizontal;
      case 'vertical':
        return UiDividerOrientation.vertical;
    }
    throw FormatException('UiDivider: unknown orientation "$raw"');
  }

  static List<UiSwipeAction>? _swipeActions(Object? raw) {
    if (raw == null) return null;
    if (raw is! List) {
      throw const FormatException(
        'UiListTile.swipeActions must be a JSON array',
      );
    }
    return [
      for (final r in raw)
        if (r is Map<String, dynamic>)
          UiSwipeAction(
            label: r['label'] is String ? r['label'] as String : '',
            eventId: r['eventId'] is String ? r['eventId'] as String : '',
            icon: _asString(r['icon']),
            accent: accentTokenFromString(_asString(r['accent'])),
          ),
    ];
  }

  static List<UiAppTile> _appTiles(Object? raw) {
    if (raw is! List) {
      throw const FormatException('UiAppGrid.items must be a JSON array');
    }
    return [
      for (final r in raw)
        if (r is Map<String, dynamic>) UiAppTile.fromJson(r),
    ];
  }

  static UiTextStyleKind? _textStyle(Object? raw) {
    if (raw == null) return null;
    switch (raw) {
      case 'body':
        return UiTextStyleKind.body;
      case 'title':
        return UiTextStyleKind.title;
      case 'caption':
        return UiTextStyleKind.caption;
      case 'mono':
        return UiTextStyleKind.mono;
      default:
        throw FormatException('UiText: unknown style "$raw"');
    }
  }

  static UiButtonStyleKind? _buttonStyle(Object? raw) {
    if (raw == null) return null;
    switch (raw) {
      case 'primary':
        return UiButtonStyleKind.primary;
      case 'secondary':
        return UiButtonStyleKind.secondary;
      case 'danger':
        return UiButtonStyleKind.danger;
      default:
        throw FormatException('UiButton: unknown style "$raw"');
    }
  }
}

class UiColumn extends UiNode {
  final List<UiNode> children;
  final SpacingSlot? gap;
  const UiColumn({required String id, required this.children, this.gap})
      : super(id);
}

class UiRow extends UiNode {
  final List<UiNode> children;
  final SpacingSlot? gap;
  const UiRow({required String id, required this.children, this.gap})
      : super(id);
}

class UiSection extends UiNode {
  final String? title;
  final UiSectionVariant? variant;
  final List<UiNode> children;
  const UiSection({
    required String id,
    this.title,
    this.variant,
    required this.children,
  }) : super(id);
}

class UiCard extends UiNode {
  final List<UiNode> children;
  const UiCard({required String id, required this.children}) : super(id);
}

class UiList extends UiNode {
  final List<UiNode> items;
  const UiList({required String id, required this.items}) : super(id);
}

class UiText extends UiNode {
  final String text;
  final UiTextStyleKind? style;
  const UiText({required String id, required this.text, this.style})
      : super(id);
}

class UiSpacer extends UiNode {
  final SpacingSlot? size;
  const UiSpacer({required String id, this.size}) : super(id);
}

class UiTextField extends UiNode {
  final String? label;
  final String? value;
  final String? placeholder;
  const UiTextField({
    required String id,
    this.label,
    this.value,
    this.placeholder,
  }) : super(id);
}

class UiButton extends UiNode {
  final String label;
  final UiButtonStyleKind? style;
  const UiButton({required String id, required this.label, this.style})
      : super(id);
}

class UiIcon extends UiNode {
  final String name;
  final SizeSlot? size;
  final AccentToken? accent;
  const UiIcon({
    required String id,
    required this.name,
    this.size,
    this.accent,
  }) : super(id);
}

class UiBadge extends UiNode {
  final UiBadgeVariant variant;
  final String? text;
  final int? count;
  final AccentToken? accent;
  const UiBadge({
    required String id,
    required this.variant,
    this.text,
    this.count,
    this.accent,
  }) : super(id);
}

/// Swipe action attached to a [UiListTile] — Batch 1 plumbs the field
/// but does not render it; Batch 4 lights up the swipe gesture. Shape
/// matches the doc spec: required `label` + `eventId`, optional `icon`
/// (Feather catalog name) + `accent`.
@immutable
class UiSwipeAction {
  final String label;
  final String eventId;
  final String? icon;
  final AccentToken? accent;
  const UiSwipeAction({
    required this.label,
    required this.eventId,
    this.icon,
    this.accent,
  });
}

class UiListTile extends UiNode {
  final String title;
  final String? subtitle;
  final UiNode? leading;
  final UiNode? trailing;
  final String? onTapEvent;
  final List<UiSwipeAction>? swipeActions;
  const UiListTile({
    required String id,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTapEvent,
    this.swipeActions,
  }) : super(id);
}

/// Compact tile-corner badge — slim `{ count?, text? }` shape from the
/// doc spec. Plain object (not a [UiBadge] node) because it lives off
/// the main reconciliation tree.
@immutable
class UiAppTileBadge {
  final int? count;
  final String? text;
  const UiAppTileBadge({this.count, this.text});
}

/// Items in [UiAppGrid]. Not a `UiNode` itself — app-tiles live off the
/// main reconciliation path and only the surrounding grid carries an id
/// for ValueKey reconciliation.
@immutable
class UiAppTile {
  final String id;
  final String name;
  /// One of: `String iconName` (Feather catalog lookup) or
  /// `UiAppTileIconUri uri` (opaque ref for future Batch 3 image support).
  final UiAppTileIcon icon;
  final UiAppTileBadge? badge;
  final AccentToken? accent;
  const UiAppTile({
    required this.id,
    required this.name,
    required this.icon,
    this.badge,
    this.accent,
  });

  factory UiAppTile.fromJson(Map<String, dynamic> raw) {
    final id = raw['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('UiAppTile.id must be a non-empty string');
    }
    final name = raw['name'];
    if (name is! String || name.isEmpty) {
      throw const FormatException('UiAppTile.name must be a non-empty string');
    }
    final iconRaw = raw['icon'];
    final UiAppTileIcon icon;
    if (iconRaw is String && iconRaw.isNotEmpty) {
      icon = UiAppTileIconName(iconRaw);
    } else if (iconRaw is Map<String, dynamic>) {
      final uri = iconRaw['uri'];
      if (uri is! String || uri.isEmpty) {
        throw const FormatException('UiAppTile.icon.uri must be a string');
      }
      icon = UiAppTileIconUri(uri);
    } else {
      throw const FormatException('UiAppTile.icon must be a string or { uri }');
    }
    UiAppTileBadge? badge;
    final badgeRaw = raw['badge'];
    if (badgeRaw is Map<String, dynamic>) {
      final rawCount = badgeRaw['count'];
      final rawText = badgeRaw['text'];
      int? count;
      if (rawCount is int) {
        count = rawCount;
      } else if (rawCount is double && rawCount == rawCount.truncateToDouble()) {
        count = rawCount.toInt();
      } else if (rawCount != null) {
        throw const FormatException('UiAppTile.badge.count must be an int');
      }
      String? text;
      if (rawText is String) {
        text = rawText;
      } else if (rawText != null) {
        throw const FormatException('UiAppTile.badge.text must be a string');
      }
      badge = UiAppTileBadge(count: count, text: text);
    }
    final accent = accentTokenFromString(
      raw['accent'] is String ? raw['accent'] as String : null,
    );
    return UiAppTile(
      id: id,
      name: name,
      icon: icon,
      badge: badge,
      accent: accent,
    );
  }
}

@immutable
sealed class UiAppTileIcon {
  const UiAppTileIcon();
}

class UiAppTileIconName extends UiAppTileIcon {
  final String name;
  const UiAppTileIconName(this.name);
}

class UiAppTileIconUri extends UiAppTileIcon {
  final String uri;
  const UiAppTileIconUri(this.uri);
}

class UiAppGrid extends UiNode {
  final List<UiAppTile> items;
  final int? columns;
  final String? onLaunchEvent;
  const UiAppGrid({
    required String id,
    required this.items,
    this.columns,
    this.onLaunchEvent,
  }) : super(id);
}

/// Two-state toggle (Batch 2). The plugin owns canonical state; the
/// renderer fires `onChangeEvent` with `payload: { value: bool }` the
/// moment the user flips it and tracks the gesture optimistically.
class UiSwitch extends UiNode {
  final String? label;
  final bool value;
  final String? onChangeEvent;
  const UiSwitch({
    required String id,
    required this.value,
    this.label,
    this.onChangeEvent,
  }) : super(id);
}

@immutable
class UiSelectOption {
  final String value;
  final String label;
  const UiSelectOption({required this.value, required this.label});
}

/// Single-choice picker (Batch 2). Always renders as a modal
/// bottom-sheet picker on mobile — no dropdown menus. The host fires
/// `onChangeEvent` with `payload: { value: String }` when the user
/// commits a pick.
class UiSelect extends UiNode {
  final String? label;
  final List<UiSelectOption> options;
  final String? value;
  final String? onChangeEvent;
  const UiSelect({
    required String id,
    required this.options,
    this.label,
    this.value,
    this.onChangeEvent,
  }) : super(id);
}

@immutable
class UiInlineBannerAction {
  final String label;
  final String eventId;
  const UiInlineBannerAction({required this.label, required this.eventId});
}

/// Persistent in-flow status surface (Batch 2). Lives in the declarative
/// tree — unlike imperative `ui.showAlert` (Batch 4).
class UiInlineBanner extends UiNode {
  final String title;
  final String? body;
  final UiInlineBannerAccent accent;
  final UiInlineBannerAction? action;
  final String? dismissEventId;
  const UiInlineBanner({
    required String id,
    required this.title,
    required this.accent,
    this.body,
    this.action,
    this.dismissEventId,
  }) : super(id);
}

/// Explicit divider (Batch 2). The inset section variant paints its
/// own row separators internally; this widget is for placement
/// **outside** that context.
class UiDivider extends UiNode {
  final UiDividerOrientation? orientation;
  const UiDivider({required String id, this.orientation}) : super(id);
}

/// What the renderer fires when the user interacts with a leaf widget.
/// Translated by the model layer into the wire payload of `ui.event`.
@immutable
class UiNodeEvent {
  final String nodeId;
  final String type;
  final Map<String, Object?>? payload;
  const UiNodeEvent({required this.nodeId, required this.type, this.payload});
}
