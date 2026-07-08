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

/// Fit mode for [UiImage] — subset of Flutter's `BoxFit` so the wire
/// contract stays narrow (plugin authors can't reach for `fitWidth` and
/// assume it works everywhere).
enum UiImageFit { cover, contain, fill }

/// Variant of [UiProgress]. Default is [linear].
enum UiProgressVariant { linear, circular }

/// Nine-point alignment for [UiStack]. Matches Flutter's `Alignment`
/// constants minus the LTR/RTL flip — we keep the start/end naming so
/// authors don't accidentally reach for `left`/`right` and break RTL.
enum UiStackAlignment {
  topStart,
  topCenter,
  topEnd,
  centerStart,
  center,
  centerEnd,
  bottomStart,
  bottomCenter,
  bottomEnd,
}

/// Axis for [UiScroll]. Default is [vertical].
enum UiScrollAxis { vertical, horizontal }

/// Eyes-free focus role hint supplied by plugins.
enum UiFocusRole { status, action, input, danger }

@immutable
class UiNodeAccessibility {
  final String? accessibilityLabel;
  final String? accessibilityHint;
  final String? spokenValue;
  final UiFocusRole? focusRole;
  final int? focusOrder;
  final String? voiceInputEvent;
  final String? voiceOutputText;
  final bool voiceShortcut;

  const UiNodeAccessibility({
    this.accessibilityLabel,
    this.accessibilityHint,
    this.spokenValue,
    this.focusRole,
    this.focusOrder,
    this.voiceInputEvent,
    this.voiceOutputText,
    this.voiceShortcut = false,
  });

  bool get isEmpty =>
      accessibilityLabel == null &&
      accessibilityHint == null &&
      spokenValue == null &&
      focusRole == null &&
      focusOrder == null &&
      voiceInputEvent == null &&
      voiceOutputText == null &&
      !voiceShortcut;

  factory UiNodeAccessibility.fromJson(Map<String, dynamic> json) {
    return UiNodeAccessibility(
      accessibilityLabel: _nonEmptyString(json['accessibilityLabel']),
      accessibilityHint: _nonEmptyString(json['accessibilityHint']),
      spokenValue: _nonEmptyString(json['spokenValue']),
      focusRole: _focusRole(json['focusRole']),
      focusOrder: _focusOrder(json['focusOrder']),
      voiceInputEvent: _nonEmptyString(json['voiceInputEvent']),
      voiceOutputText: _nonEmptyString(json['voiceOutputText']),
      voiceShortcut: json['voiceShortcut'] == true,
    );
  }

  static String? _nonEmptyString(Object? raw) {
    if (raw is String && raw.isNotEmpty) return raw;
    return null;
  }

  static int? _focusOrder(Object? raw) {
    if (raw is int && raw >= 0) return raw;
    if (raw is double && raw == raw.truncateToDouble() && raw >= 0) {
      return raw.toInt();
    }
    return null;
  }

  static UiFocusRole? _focusRole(Object? raw) {
    switch (raw) {
      case 'status':
        return UiFocusRole.status;
      case 'action':
        return UiFocusRole.action;
      case 'input':
        return UiFocusRole.input;
      case 'danger':
        return UiFocusRole.danger;
      default:
        return null;
    }
  }
}

final Expando<UiNodeAccessibility> _uiNodeAccessibility =
    Expando<UiNodeAccessibility>('UiNodeAccessibility');

/// Discriminated columns for [UiGrid] — a positive integer or the
/// `'adaptive'` sentinel.
@immutable
class UiGridColumns {
  final int? fixed;
  final bool adaptive;
  const UiGridColumns._({this.fixed, this.adaptive = false});

  factory UiGridColumns.fixedCount(int n) => UiGridColumns._(fixed: n);
  factory UiGridColumns.adaptiveCount() =>
      const UiGridColumns._(adaptive: true);
}

/// Base type for every node in the descriptor tree. Every concrete node
/// carries an `id` which is mandatory and must be unique within the
/// tree — that uniqueness is enforced server-side; the renderer relies
/// on it to construct `ValueKey`s for reconciliation.
@immutable
sealed class UiNode {
  final String id;
  const UiNode(this.id);

  UiNodeAccessibility get accessibility =>
      _uiNodeAccessibility[this] ?? const UiNodeAccessibility();

  /// Parse a raw map (as decoded from the JSON-RPC `ui.tree` payload).
  /// Throws `FormatException` for malformed input.
  static UiNode fromJson(Object? raw) {
    final node = _fromJson(raw);
    if (raw is Map<String, dynamic>) {
      final accessibility = UiNodeAccessibility.fromJson(raw);
      if (!accessibility.isEmpty) {
        _uiNodeAccessibility[node] = accessibility;
      }
    }
    return node;
  }

  static UiNode _fromJson(Object? raw) {
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
          collapsible: _asBool(raw['collapsible']) ?? false,
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
        return UiText(id: id, text: text, style: _textStyle(raw['style']));
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
          throw const FormatException('UiIcon.name must be a non-empty string');
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
      case 'Image':
        final src = raw['src'];
        if (src is! String || src.isEmpty) {
          throw const FormatException('UiImage.src must be a non-empty string');
        }
        return UiImage(
          id: id,
          src: src,
          fit: _imageFit(raw['fit']),
          size: _sizeSlot(raw['size']),
        );
      case 'Avatar':
        final src = _asString(raw['src']);
        final initial = _asString(raw['initial']);
        if (src == null && initial == null) {
          throw const FormatException('UiAvatar requires src or initial');
        }
        return UiAvatar(
          id: id,
          src: src,
          initial: initial,
          size: _sizeSlot(raw['size']),
          accent: accentTokenFromString(_asString(raw['accent'])),
        );
      case 'Markdown':
        final markdown = raw['markdown'];
        if (markdown is! String) {
          throw const FormatException('UiMarkdown.markdown must be a string');
        }
        return UiMarkdown(id: id, markdown: markdown);
      case 'CodeBlock':
        final code = raw['code'];
        if (code is! String) {
          throw const FormatException('UiCodeBlock.code must be a string');
        }
        return UiCodeBlock(
          id: id,
          code: code,
          language: _asString(raw['language']),
        );
      case 'Progress':
        final rawValue = raw['value'];
        double? value;
        if (rawValue == null) {
          value = null;
        } else if (rawValue is num) {
          value = rawValue.toDouble();
          if (!value.isFinite || value < 0 || value > 1) {
            throw const FormatException(
              'UiProgress.value must be in [0, 1] when provided',
            );
          }
        } else {
          throw const FormatException(
            'UiProgress.value must be a number when provided',
          );
        }
        return UiProgress(
          id: id,
          value: value,
          variant: _progressVariant(raw['variant']),
          label: _asString(raw['label']),
          accent: accentTokenFromString(_asString(raw['accent'])),
        );
      case 'Spinner':
        return UiSpinner(
          id: id,
          label: _asString(raw['label']),
          size: _sizeSlot(raw['size']),
        );
      case 'Grid':
        return UiGrid(
          id: id,
          children: _children(raw['children']),
          columns: _gridColumns(raw['columns']),
          gap: _spacingSlot(raw['gap']),
        );
      case 'Stack':
        return UiStack(
          id: id,
          children: _children(raw['children']),
          alignment: _stackAlignment(raw['alignment']),
        );
      case 'Aspect':
        final ratio = raw['ratio'];
        if (ratio is! num || !ratio.isFinite || ratio <= 0) {
          throw const FormatException(
            'UiAspect.ratio must be a positive finite number',
          );
        }
        final childRaw = raw['child'];
        if (childRaw == null) {
          throw const FormatException('UiAspect.child is required');
        }
        return UiAspect(
          id: id,
          ratio: ratio.toDouble(),
          child: UiNode.fromJson(childRaw),
        );
      case 'Flex':
        final flex = raw['flex'];
        if (flex is! num || !flex.isFinite || flex < 0) {
          throw const FormatException(
            'UiFlex.flex must be a non-negative finite number',
          );
        }
        final childRaw = raw['child'];
        if (childRaw == null) {
          throw const FormatException('UiFlex.child is required');
        }
        return UiFlex(
          id: id,
          flex: flex.toDouble(),
          child: UiNode.fromJson(childRaw),
        );
      case 'Scroll':
        final childRaw = raw['child'];
        if (childRaw == null) {
          throw const FormatException('UiScroll.child is required');
        }
        return UiScroll(
          id: id,
          axis: _scrollAxis(raw['axis']),
          child: UiNode.fromJson(childRaw),
        );
      case 'TabBar':
        return UiTabBar(
          id: id,
          tabs: _tabBarTabs(raw['tabs']),
          activeId: _requiredString(raw['activeId'], 'UiTabBar.activeId'),
          onChangeEvent: _asString(raw['onChangeEvent']),
        );
      case 'SearchField':
        return UiSearchField(
          id: id,
          value: _asString(raw['value']),
          placeholder: _asString(raw['placeholder']),
          onChangeEvent: _asString(raw['onChangeEvent']),
        );
      case 'Checkbox':
        final value = raw['value'];
        if (value is! bool) {
          throw const FormatException('UiCheckbox.value must be a bool');
        }
        return UiCheckbox(
          id: id,
          value: value,
          label: _asString(raw['label']),
          onChangeEvent: _asString(raw['onChangeEvent']),
        );
      case 'RadioGroup':
        return UiRadioGroup(
          id: id,
          options: _radioOptions(raw['options']),
          value: _asString(raw['value']),
          onChangeEvent: _asString(raw['onChangeEvent']),
        );
      case 'Slider':
        final minRaw = raw['min'];
        final maxRaw = raw['max'];
        final valueRaw = raw['value'];
        if (minRaw is! num || !minRaw.isFinite) {
          throw const FormatException('UiSlider.min must be a finite number');
        }
        if (maxRaw is! num || !maxRaw.isFinite) {
          throw const FormatException('UiSlider.max must be a finite number');
        }
        if (minRaw >= maxRaw) {
          throw const FormatException('UiSlider: min must be < max');
        }
        if (valueRaw is! num || !valueRaw.isFinite) {
          throw const FormatException('UiSlider.value must be a finite number');
        }
        double? step;
        final stepRaw = raw['step'];
        if (stepRaw != null) {
          if (stepRaw is! num || !stepRaw.isFinite || stepRaw <= 0) {
            throw const FormatException(
              'UiSlider.step must be a positive finite number when provided',
            );
          }
          step = stepRaw.toDouble();
        }
        return UiSlider(
          id: id,
          min: minRaw.toDouble(),
          max: maxRaw.toDouble(),
          step: step,
          value: valueRaw.toDouble(),
          onChangeEvent: _asString(raw['onChangeEvent']),
        );
      default:
        throw FormatException('UiNode: unknown kind "$kind"');
    }
  }

  static bool? _asBool(Object? raw) {
    if (raw == null) return null;
    if (raw is bool) return raw;
    throw FormatException('UiNode: expected bool, got ${raw.runtimeType}');
  }

  static String _requiredString(Object? raw, String field) {
    if (raw is! String || raw.isEmpty) {
      throw FormatException('$field must be a non-empty string');
    }
    return raw;
  }

  static UiGridColumns _gridColumns(Object? raw) {
    if (raw == 'adaptive') return UiGridColumns.adaptiveCount();
    if (raw is int && raw >= 1) return UiGridColumns.fixedCount(raw);
    if (raw is double && raw == raw.truncateToDouble() && raw >= 1) {
      return UiGridColumns.fixedCount(raw.toInt());
    }
    throw const FormatException(
      'UiGrid.columns must be a positive integer or "adaptive"',
    );
  }

  static UiStackAlignment? _stackAlignment(Object? raw) {
    if (raw == null) return null;
    if (raw is! String) {
      throw const FormatException('UiStack.alignment must be a string');
    }
    switch (raw) {
      case 'topStart':
        return UiStackAlignment.topStart;
      case 'topCenter':
        return UiStackAlignment.topCenter;
      case 'topEnd':
        return UiStackAlignment.topEnd;
      case 'centerStart':
        return UiStackAlignment.centerStart;
      case 'center':
        return UiStackAlignment.center;
      case 'centerEnd':
        return UiStackAlignment.centerEnd;
      case 'bottomStart':
        return UiStackAlignment.bottomStart;
      case 'bottomCenter':
        return UiStackAlignment.bottomCenter;
      case 'bottomEnd':
        return UiStackAlignment.bottomEnd;
    }
    throw FormatException('UiStack: unknown alignment "$raw"');
  }

  static UiScrollAxis? _scrollAxis(Object? raw) {
    if (raw == null) return null;
    if (raw is! String) {
      throw const FormatException('UiScroll.axis must be a string');
    }
    switch (raw) {
      case 'vertical':
        return UiScrollAxis.vertical;
      case 'horizontal':
        return UiScrollAxis.horizontal;
    }
    throw FormatException('UiScroll: unknown axis "$raw"');
  }

  static List<UiTabBarTab> _tabBarTabs(Object? raw) {
    if (raw is! List || raw.isEmpty) {
      throw const FormatException('UiTabBar.tabs must be a non-empty array');
    }
    final out = <UiTabBarTab>[];
    final seen = <String>{};
    for (final entry in raw) {
      if (entry is! Map<String, dynamic>) {
        throw const FormatException('UiTabBar.tabs[*] must be a JSON object');
      }
      final id = entry['id'];
      final label = entry['label'];
      if (id is! String || id.isEmpty) {
        throw const FormatException(
          'UiTabBar.tabs[*].id must be a non-empty string',
        );
      }
      if (seen.contains(id)) {
        throw FormatException('UiTabBar: duplicate tab id "$id"');
      }
      seen.add(id);
      if (label is! String || label.isEmpty) {
        throw const FormatException(
          'UiTabBar.tabs[*].label must be a non-empty string',
        );
      }
      out.add(
        UiTabBarTab(id: id, label: label, icon: _asString(entry['icon'])),
      );
    }
    return out;
  }

  static List<UiRadioOption> _radioOptions(Object? raw) {
    if (raw is! List || raw.isEmpty) {
      throw const FormatException(
        'UiRadioGroup.options must be a non-empty array',
      );
    }
    final out = <UiRadioOption>[];
    final seen = <String>{};
    for (final entry in raw) {
      if (entry is! Map<String, dynamic>) {
        throw const FormatException(
          'UiRadioGroup.options[*] must be a JSON object',
        );
      }
      final value = entry['value'];
      final label = entry['label'];
      if (value is! String || value.isEmpty) {
        throw const FormatException(
          'UiRadioGroup.options[*].value must be a non-empty string',
        );
      }
      if (seen.contains(value)) {
        throw FormatException('UiRadioGroup: duplicate option value "$value"');
      }
      seen.add(value);
      if (label is! String || label.isEmpty) {
        throw const FormatException(
          'UiRadioGroup.options[*].label must be a non-empty string',
        );
      }
      out.add(UiRadioOption(value: value, label: label));
    }
    return out;
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

  static UiImageFit? _imageFit(Object? raw) {
    if (raw == null) return null;
    if (raw is! String) {
      throw const FormatException('UiImage.fit must be a string');
    }
    switch (raw) {
      case 'cover':
        return UiImageFit.cover;
      case 'contain':
        return UiImageFit.contain;
      case 'fill':
        return UiImageFit.fill;
    }
    throw FormatException('UiImage: unknown fit "$raw"');
  }

  static UiProgressVariant? _progressVariant(Object? raw) {
    if (raw == null) return null;
    if (raw is! String) {
      throw const FormatException('UiProgress.variant must be a string');
    }
    switch (raw) {
      case 'linear':
        return UiProgressVariant.linear;
      case 'circular':
        return UiProgressVariant.circular;
    }
    throw FormatException('UiProgress: unknown variant "$raw"');
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

  /// When true the renderer adds a tap-to-expand-collapse header
  /// chevron. The renderer persists the expanded/collapsed state per
  /// node id across re-renders.
  final bool collapsible;
  final List<UiNode> children;
  const UiSection({
    required String id,
    this.title,
    this.variant,
    this.collapsible = false,
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
  const UiIcon({required String id, required this.name, this.size, this.accent})
    : super(id);
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
      } else if (rawCount is double &&
          rawCount == rawCount.truncateToDouble()) {
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

/// Network / inline / local-file image (Batch 3 — §4.3). The renderer
/// dispatches on the `src` URL scheme; `file://` URLs reach the client
/// only after the host has cleared them against the plugin's fs cap.
class UiImage extends UiNode {
  final String src;
  final UiImageFit? fit;
  final SizeSlot? size;
  const UiImage({required String id, required this.src, this.fit, this.size})
    : super(id);
}

/// Profile circle (Batch 3 — §4.3). With [src] → renders the image
/// (same URL schemes as [UiImage]). Without [src] → renders the first
/// 1–2 chars of [initial] on a deterministic hashed color. [accent]
/// overrides the hash color. Validator guarantees at least one of
/// [src] / [initial] is present.
class UiAvatar extends UiNode {
  final String? src;
  final String? initial;
  final SizeSlot? size;
  final AccentToken? accent;
  const UiAvatar({
    required String id,
    this.src,
    this.initial,
    this.size,
    this.accent,
  }) : super(id);
}

/// Strict-subset Markdown (Batch 3 — §4.3). Out-of-subset constructs
/// (raw HTML, tables, images) degrade to plain text on render.
class UiMarkdown extends UiNode {
  final String markdown;
  const UiMarkdown({required String id, required this.markdown}) : super(id);
}

/// Pre-formatted source code block (Batch 3 — §4.3). Reuses the app's
/// existing `flutter_highlight` stack and shared highlight theme.
class UiCodeBlock extends UiNode {
  final String code;
  final String? language;
  const UiCodeBlock({required String id, required this.code, this.language})
    : super(id);
}

/// Progress indicator (Batch 3 — §4.3). [value] in [0, 1] → determinate;
/// null → indeterminate. [variant] defaults to [UiProgressVariant.linear].
class UiProgress extends UiNode {
  final double? value;
  final UiProgressVariant? variant;
  final String? label;
  final AccentToken? accent;
  const UiProgress({
    required String id,
    this.value,
    this.variant,
    this.label,
    this.accent,
  }) : super(id);
}

/// Indeterminate spinner (Batch 3 — §4.3).
class UiSpinner extends UiNode {
  final String? label;
  final SizeSlot? size;
  const UiSpinner({required String id, this.label, this.size}) : super(id);
}

// ---- Batch 5 widgets (§4.3) — long tail ----

/// Fixed-column / adaptive grid (Batch 5). Children flow row-major.
class UiGrid extends UiNode {
  final List<UiNode> children;
  final UiGridColumns columns;
  final SpacingSlot? gap;
  const UiGrid({
    required String id,
    required this.children,
    required this.columns,
    this.gap,
  }) : super(id);
}

/// Z-axis stack (Batch 5). Children paint on top of each other,
/// anchored by [alignment] (default center).
class UiStack extends UiNode {
  final List<UiNode> children;
  final UiStackAlignment? alignment;
  const UiStack({required String id, required this.children, this.alignment})
    : super(id);
}

/// Aspect-ratio enforcer (Batch 5). [ratio] is width / height.
class UiAspect extends UiNode {
  final double ratio;
  final UiNode child;
  const UiAspect({required String id, required this.ratio, required this.child})
    : super(id);
}

/// Flex distribution hint for a Row/Column child (Batch 5). Outside a
/// Row/Column the renderer falls back to the bare child without
/// claiming extra space.
class UiFlex extends UiNode {
  final double flex;
  final UiNode child;
  const UiFlex({required String id, required this.flex, required this.child})
    : super(id);
}

/// Explicit scroll region (Batch 5). Default axis is vertical.
class UiScroll extends UiNode {
  final UiScrollAxis? axis;
  final UiNode child;
  const UiScroll({required String id, this.axis, required this.child})
    : super(id);
}

/// Tab entry inside [UiTabBar] (Batch 5).
@immutable
class UiTabBarTab {
  final String id;
  final String label;
  final String? icon;
  const UiTabBarTab({required this.id, required this.label, this.icon});
}

/// Segmented tab control (Batch 5). The host renders the chrome; the
/// plugin owns content-switching behavior on tap.
class UiTabBar extends UiNode {
  final List<UiTabBarTab> tabs;
  final String activeId;
  final String? onChangeEvent;
  const UiTabBar({
    required String id,
    required this.tabs,
    required this.activeId,
    this.onChangeEvent,
  }) : super(id);
}

/// Search variant of [UiTextField] (Batch 5). The renderer adds a
/// magnifier prefix + a clear-button suffix.
class UiSearchField extends UiNode {
  final String? value;
  final String? placeholder;
  final String? onChangeEvent;
  const UiSearchField({
    required String id,
    this.value,
    this.placeholder,
    this.onChangeEvent,
  }) : super(id);
}

/// Standalone checkbox (Batch 5). Same reconciliation contract as
/// [UiSwitch].
class UiCheckbox extends UiNode {
  final String? label;
  final bool value;
  final String? onChangeEvent;
  const UiCheckbox({
    required String id,
    required this.value,
    this.label,
    this.onChangeEvent,
  }) : super(id);
}

@immutable
class UiRadioOption {
  final String value;
  final String label;
  const UiRadioOption({required this.value, required this.label});
}

/// Single-selection radio list (Batch 5). Same reconciliation contract
/// as [UiSwitch] / [UiCheckbox].
class UiRadioGroup extends UiNode {
  final List<UiRadioOption> options;
  final String? value;
  final String? onChangeEvent;
  const UiRadioGroup({
    required String id,
    required this.options,
    this.value,
    this.onChangeEvent,
  }) : super(id);
}

/// Continuous or stepped slider (Batch 5). Renderer clamps [value] to
/// [min, max] and snaps to [step] when set.
class UiSlider extends UiNode {
  final double min;
  final double max;
  final double? step;
  final double value;
  final String? onChangeEvent;
  const UiSlider({
    required String id,
    required this.min,
    required this.max,
    required this.value,
    this.step,
    this.onChangeEvent,
  }) : super(id);
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

// ---- Batch 4 imperative modal types (§4.3) ----
//
// These ride a separate `ui.modal` notification from the backend. They
// are NOT part of the declarative `ui.tree` and have no monotonic
// version — the host pushes one event per modal, the user picks (or
// dismisses), and the picked action's `eventId` flows back through the
// regular `ui.event` channel. Cancellation = host emits no follow-up;
// the modal is gone the instant the user resolves it.

enum UiAlertActionVariant { primary, danger }

@immutable
class UiAlertAction {
  final String label;
  final String eventId;
  final UiAlertActionVariant? variant;
  const UiAlertAction({
    required this.label,
    required this.eventId,
    this.variant,
  });

  factory UiAlertAction.fromJson(Map<String, dynamic> raw) {
    final label = raw['label'];
    if (label is! String || label.isEmpty) {
      throw const FormatException(
        'UiAlertAction.label must be a non-empty string',
      );
    }
    final eventId = raw['eventId'];
    if (eventId is! String || eventId.isEmpty) {
      throw const FormatException(
        'UiAlertAction.eventId must be a non-empty string',
      );
    }
    UiAlertActionVariant? variant;
    final rawVariant = raw['variant'];
    if (rawVariant != null) {
      if (rawVariant is! String) {
        throw const FormatException('UiAlertAction.variant must be a string');
      }
      switch (rawVariant) {
        case 'primary':
          variant = UiAlertActionVariant.primary;
          break;
        case 'danger':
          variant = UiAlertActionVariant.danger;
          break;
        default:
          throw FormatException('UiAlertAction: unknown variant "$rawVariant"');
      }
    }
    return UiAlertAction(label: label, eventId: eventId, variant: variant);
  }
}

@immutable
class UiAlertDialog {
  final String id;
  final String title;
  final String? body;
  final List<UiAlertAction> actions;

  /// Default `true`. `false` blocks tap-outside / back-press; only the
  /// action buttons resolve the dialog.
  final bool dismissible;
  const UiAlertDialog({
    required this.id,
    required this.title,
    required this.actions,
    this.body,
    this.dismissible = true,
  });

  factory UiAlertDialog.fromJson(Map<String, dynamic> raw) {
    final id = raw['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException(
        'UiAlertDialog.id must be a non-empty string',
      );
    }
    final title = raw['title'];
    if (title is! String || title.isEmpty) {
      throw const FormatException(
        'UiAlertDialog.title must be a non-empty string',
      );
    }
    final rawActions = raw['actions'];
    if (rawActions is! List || rawActions.isEmpty) {
      throw const FormatException(
        'UiAlertDialog.actions must be a non-empty array',
      );
    }
    final actions = <UiAlertAction>[];
    for (final a in rawActions) {
      if (a is! Map<String, dynamic>) {
        throw const FormatException(
          'UiAlertDialog.actions[*] must be a JSON object',
        );
      }
      actions.add(UiAlertAction.fromJson(a));
    }
    final body = raw['body'];
    final rawDismissible = raw['dismissible'];
    return UiAlertDialog(
      id: id,
      title: title,
      actions: actions,
      body: body is String ? body : null,
      dismissible: rawDismissible is bool ? rawDismissible : true,
    );
  }
}

@immutable
class UiActionSheetAction {
  final String label;
  final String eventId;
  final String? icon;
  final AccentToken? accent;
  const UiActionSheetAction({
    required this.label,
    required this.eventId,
    this.icon,
    this.accent,
  });

  factory UiActionSheetAction.fromJson(Map<String, dynamic> raw) {
    final label = raw['label'];
    if (label is! String || label.isEmpty) {
      throw const FormatException(
        'UiActionSheetAction.label must be a non-empty string',
      );
    }
    final eventId = raw['eventId'];
    if (eventId is! String || eventId.isEmpty) {
      throw const FormatException(
        'UiActionSheetAction.eventId must be a non-empty string',
      );
    }
    final icon = raw['icon'];
    if (icon != null && icon is! String) {
      throw const FormatException('UiActionSheetAction.icon must be a string');
    }
    final accent = raw['accent'];
    if (accent != null && accent is! String) {
      throw const FormatException(
        'UiActionSheetAction.accent must be a string',
      );
    }
    return UiActionSheetAction(
      label: label,
      eventId: eventId,
      icon: icon is String ? icon : null,
      accent: accentTokenFromString(accent is String ? accent : null),
    );
  }
}

@immutable
class UiActionSheet {
  final String id;
  final String? title;
  final List<UiActionSheetAction> actions;
  final String? dismissEventId;
  const UiActionSheet({
    required this.id,
    required this.actions,
    this.title,
    this.dismissEventId,
  });

  factory UiActionSheet.fromJson(Map<String, dynamic> raw) {
    final id = raw['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException(
        'UiActionSheet.id must be a non-empty string',
      );
    }
    final rawActions = raw['actions'];
    if (rawActions is! List || rawActions.isEmpty) {
      throw const FormatException(
        'UiActionSheet.actions must be a non-empty array',
      );
    }
    final actions = <UiActionSheetAction>[];
    for (final a in rawActions) {
      if (a is! Map<String, dynamic>) {
        throw const FormatException(
          'UiActionSheet.actions[*] must be a JSON object',
        );
      }
      actions.add(UiActionSheetAction.fromJson(a));
    }
    final title = raw['title'];
    final dismissEventId = raw['dismissEventId'];
    return UiActionSheet(
      id: id,
      actions: actions,
      title: title is String ? title : null,
      dismissEventId: dismissEventId is String ? dismissEventId : null,
    );
  }
}

@immutable
class UiBottomSheet {
  final String id;
  final String? title;
  final UiNode child;
  final String? dismissEventId;
  const UiBottomSheet({
    required this.id,
    required this.child,
    this.title,
    this.dismissEventId,
  });

  factory UiBottomSheet.fromJson(Map<String, dynamic> raw) {
    final id = raw['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException(
        'UiBottomSheet.id must be a non-empty string',
      );
    }
    final rawChild = raw['child'];
    if (rawChild == null) {
      throw const FormatException('UiBottomSheet.child is required');
    }
    final child = UiNode.fromJson(rawChild);
    final title = raw['title'];
    final dismissEventId = raw['dismissEventId'];
    return UiBottomSheet(
      id: id,
      child: child,
      title: title is String ? title : null,
      dismissEventId: dismissEventId is String ? dismissEventId : null,
    );
  }
}

/// One inbound `ui.modal` push. Discriminated on `kind` so the renderer
/// can switch on the modal type without unwrapping in the model layer.
@immutable
sealed class UiModalPush {
  final String pluginId;
  final String panelId;
  const UiModalPush({required this.pluginId, required this.panelId});

  /// Parse a raw `ui.modal` notification payload. Returns null for an
  /// unrecognized / malformed push so the model layer can drop it
  /// without crashing the whole receiver.
  static UiModalPush? tryFromJson(Map<String, dynamic> raw) {
    final pluginId = raw['pluginId'];
    final panelId = raw['panelId'];
    final kind = raw['kind'];
    if (pluginId is! String || panelId is! String || kind is! String) {
      return null;
    }
    try {
      switch (kind) {
        case 'alert':
          final alert = raw['alert'];
          if (alert is! Map<String, dynamic>) return null;
          return UiAlertPush(
            pluginId: pluginId,
            panelId: panelId,
            alert: UiAlertDialog.fromJson(alert),
          );
        case 'actionSheet':
          final sheet = raw['sheet'];
          if (sheet is! Map<String, dynamic>) return null;
          return UiActionSheetPush(
            pluginId: pluginId,
            panelId: panelId,
            sheet: UiActionSheet.fromJson(sheet),
          );
        case 'bottomSheet':
          final sheet = raw['sheet'];
          if (sheet is! Map<String, dynamic>) return null;
          return UiBottomSheetPush(
            pluginId: pluginId,
            panelId: panelId,
            sheet: UiBottomSheet.fromJson(sheet),
          );
        default:
          return null;
      }
    } catch (e) {
      debugPrint('UiModalPush.fromJson: malformed push: $e');
      return null;
    }
  }
}

class UiAlertPush extends UiModalPush {
  final UiAlertDialog alert;
  const UiAlertPush({
    required super.pluginId,
    required super.panelId,
    required this.alert,
  });
}

class UiActionSheetPush extends UiModalPush {
  final UiActionSheet sheet;
  const UiActionSheetPush({
    required super.pluginId,
    required super.panelId,
    required this.sheet,
  });
}

class UiBottomSheetPush extends UiModalPush {
  final UiBottomSheet sheet;
  const UiBottomSheetPush({
    required super.pluginId,
    required super.panelId,
    required this.sheet,
  });
}
