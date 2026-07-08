import 'package:flutter/foundation.dart';

import '../ui/ui_node.dart';

enum EyesFreeActionKind { event, voiceInput }

@immutable
class EyesFreeAction {
  final String key;
  final String label;
  final String spoken;
  final String? hint;
  final String? prompt;
  final EyesFreeActionKind kind;
  final UiNodeEvent event;

  const EyesFreeAction({
    required this.key,
    required this.label,
    required this.spoken,
    required this.kind,
    required this.event,
    this.hint,
    this.prompt,
  });
}

@immutable
class EyesFreePanelState {
  final List<EyesFreeAction> actions;
  final String? statusText;

  const EyesFreePanelState({required this.actions, required this.statusText});
}

EyesFreePanelState collectEyesFreeState(UiNode? tree) {
  if (tree == null) {
    return const EyesFreePanelState(actions: [], statusText: null);
  }
  final collector = _EyesFreeCollector();
  collector.visit(tree);
  collector.actions.sort((a, b) {
    final byOrder = a.order.compareTo(b.order);
    return byOrder != 0 ? byOrder : a.sequence.compareTo(b.sequence);
  });
  return EyesFreePanelState(
    actions: [for (final a in collector.actions) a.action],
    statusText: collector.statusText,
  );
}

class _OrderedEyesFreeAction {
  final int order;
  final int sequence;
  final EyesFreeAction action;

  const _OrderedEyesFreeAction({
    required this.order,
    required this.sequence,
    required this.action,
  });
}

class _EyesFreeCollector {
  final List<_OrderedEyesFreeAction> actions = [];
  final List<String> _statuses = [];
  int _sequence = 0;

  String? get statusText {
    if (_statuses.isEmpty) return null;
    return _statuses.take(2).join('. ');
  }

  void visit(UiNode node) {
    final meta = node.accessibility;
    if (meta.focusRole == UiFocusRole.status) {
      final status = _spokenFor(node);
      if (status != null && !_statuses.contains(status)) {
        _statuses.add(status);
      }
    }

    final voiceInputEvent = meta.voiceInputEvent;
    if (node is UiTextField && voiceInputEvent != null) {
      _add(
        node,
        EyesFreeAction(
          key: '${node.id}:voice:$voiceInputEvent',
          label: _labelFor(node) ?? 'Dictate',
          spoken: _composeSpoken(node, fallback: _labelFor(node) ?? 'Dictate'),
          hint: meta.accessibilityHint,
          prompt: node.placeholder ?? node.label ?? meta.accessibilityLabel,
          kind: EyesFreeActionKind.voiceInput,
          event: UiNodeEvent(nodeId: node.id, type: voiceInputEvent),
        ),
      );
    } else if (node is UiButton) {
      _add(
        node,
        EyesFreeAction(
          key: '${node.id}:tap',
          label: _labelFor(node) ?? node.label,
          spoken: _composeSpoken(node, fallback: node.label),
          hint: meta.accessibilityHint,
          kind: EyesFreeActionKind.event,
          event: UiNodeEvent(nodeId: node.id, type: 'tap'),
        ),
      );
    } else if (node is UiListTile && node.onTapEvent != null) {
      _add(
        node,
        EyesFreeAction(
          key: '${node.id}:${node.onTapEvent}',
          label: _labelFor(node) ?? node.title,
          spoken: _composeSpoken(node, fallback: node.title),
          hint: meta.accessibilityHint ?? node.subtitle,
          kind: EyesFreeActionKind.event,
          event: UiNodeEvent(nodeId: node.id, type: node.onTapEvent!),
        ),
      );
    } else if (node is UiInlineBanner && node.action != null) {
      _add(
        node,
        EyesFreeAction(
          key: '${node.id}:${node.action!.eventId}',
          label: node.action!.label,
          spoken: _composeSpoken(node, fallback: node.action!.label),
          hint: meta.accessibilityHint,
          kind: EyesFreeActionKind.event,
          event: UiNodeEvent(nodeId: node.id, type: node.action!.eventId),
        ),
      );
    } else if (node is UiSwitch && node.onChangeEvent != null) {
      _addToggle(node, label: node.label ?? 'Toggle', value: node.value);
    } else if (node is UiCheckbox && node.onChangeEvent != null) {
      _addToggle(node, label: node.label ?? 'Toggle', value: node.value);
    } else if (node is UiRadioGroup && node.onChangeEvent != null) {
      for (final option in node.options) {
        _add(
          node,
          EyesFreeAction(
            key: '${node.id}:${node.onChangeEvent}:${option.value}',
            label: option.label,
            spoken: option.label,
            kind: EyesFreeActionKind.event,
            event: UiNodeEvent(
              nodeId: node.id,
              type: node.onChangeEvent!,
              payload: {'value': option.value},
            ),
          ),
        );
      }
    } else if (node is UiTabBar && node.onChangeEvent != null) {
      for (final tab in node.tabs) {
        _add(
          node,
          EyesFreeAction(
            key: '${node.id}:${node.onChangeEvent}:${tab.id}',
            label: tab.label,
            spoken: tab.label,
            kind: EyesFreeActionKind.event,
            event: UiNodeEvent(
              nodeId: node.id,
              type: node.onChangeEvent!,
              payload: {'tabId': tab.id},
            ),
          ),
        );
      }
    }

    _visitChildren(node);
  }

  void _addToggle(UiNode node, {required String label, required bool value}) {
    final eventType = switch (node) {
      UiSwitch(:final onChangeEvent) => onChangeEvent!,
      UiCheckbox(:final onChangeEvent) => onChangeEvent!,
      _ => 'change',
    };
    _add(
      node,
      EyesFreeAction(
        key: '${node.id}:$eventType',
        label: value ? 'Turn off $label' : 'Turn on $label',
        spoken: value ? 'Turn off $label' : 'Turn on $label',
        kind: EyesFreeActionKind.event,
        event: UiNodeEvent(
          nodeId: node.id,
          type: eventType,
          payload: {'value': !value},
        ),
      ),
    );
  }

  void _add(UiNode node, EyesFreeAction action) {
    final meta = node.accessibility;
    final role = meta.focusRole;
    if (role == UiFocusRole.status) return;
    actions.add(
      _OrderedEyesFreeAction(
        order: meta.focusOrder ?? (1000 + _sequence),
        sequence: _sequence++,
        action: action,
      ),
    );
  }

  void _visitChildren(UiNode node) {
    if (node is UiColumn) {
      for (final child in node.children) {
        visit(child);
      }
    } else if (node is UiRow) {
      for (final child in node.children) {
        visit(child);
      }
    } else if (node is UiSection) {
      for (final child in node.children) {
        visit(child);
      }
    } else if (node is UiCard) {
      for (final child in node.children) {
        visit(child);
      }
    } else if (node is UiList) {
      for (final child in node.items) {
        visit(child);
      }
    } else if (node is UiListTile) {
      final leading = node.leading;
      final trailing = node.trailing;
      if (leading != null) visit(leading);
      if (trailing != null) visit(trailing);
    } else if (node is UiGrid) {
      for (final child in node.children) {
        visit(child);
      }
    } else if (node is UiStack) {
      for (final child in node.children) {
        visit(child);
      }
    } else if (node is UiAspect) {
      visit(node.child);
    } else if (node is UiFlex) {
      visit(node.child);
    } else if (node is UiScroll) {
      visit(node.child);
    }
  }

  String? _labelFor(UiNode node) {
    final meta = node.accessibility;
    if (meta.accessibilityLabel != null) return meta.accessibilityLabel;
    return switch (node) {
      UiButton(:final label) => label,
      UiTextField(:final label) => label,
      UiListTile(:final title) => title,
      UiSwitch(:final label) => label,
      UiCheckbox(:final label) => label,
      UiInlineBanner(:final title) => title,
      _ => null,
    };
  }

  String? _spokenFor(UiNode node) {
    final meta = node.accessibility;
    if (meta.spokenValue != null) return meta.spokenValue;
    if (meta.accessibilityLabel != null) return meta.accessibilityLabel;
    return switch (node) {
      UiText(:final text) => text,
      UiMarkdown(:final markdown) => markdown,
      UiInlineBanner(:final title, :final body) =>
        body == null ? title : '$title. $body',
      UiListTile(:final title, :final subtitle) =>
        subtitle == null ? title : '$title. $subtitle',
      _ => null,
    };
  }

  String _composeSpoken(UiNode node, {required String fallback}) {
    final meta = node.accessibility;
    final parts = <String>[
      meta.spokenValue ?? meta.accessibilityLabel ?? fallback,
      if (meta.accessibilityHint != null) meta.accessibilityHint!,
    ];
    return parts.where((s) => s.trim().isNotEmpty).join('. ');
  }
}
