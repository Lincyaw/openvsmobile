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

/// Style hint for `UiText`.
enum UiTextStyleKind { body, title, caption, mono }

/// Visual emphasis for `UiButton`. Maps to Material button variants
/// inside the renderer (see ui_renderer.dart).
enum UiButtonStyleKind { primary, secondary, danger }

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
          gap: _asDouble(raw['gap']),
        );
      case 'Row':
        return UiRow(
          id: id,
          children: _children(raw['children']),
          gap: _asDouble(raw['gap']),
        );
      case 'Section':
        return UiSection(
          id: id,
          title: _asString(raw['title']),
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
        return UiSpacer(id: id, size: _asDouble(raw['size']));
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

  static double? _asDouble(Object? raw) {
    if (raw == null) return null;
    if (raw is num) return raw.toDouble();
    throw FormatException('UiNode: expected number, got ${raw.runtimeType}');
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
  final double? gap;
  const UiColumn({required String id, required this.children, this.gap})
      : super(id);
}

class UiRow extends UiNode {
  final List<UiNode> children;
  final double? gap;
  const UiRow({required String id, required this.children, this.gap})
      : super(id);
}

class UiSection extends UiNode {
  final String? title;
  final List<UiNode> children;
  const UiSection({required String id, this.title, required this.children})
      : super(id);
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
  final double? size;
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

/// What the renderer fires when the user interacts with a leaf widget.
/// Translated by the model layer into the wire payload of `ui.event`.
@immutable
class UiNodeEvent {
  final String nodeId;
  final String type;
  final Map<String, Object?>? payload;
  const UiNodeEvent({required this.nodeId, required this.type, this.payload});
}
