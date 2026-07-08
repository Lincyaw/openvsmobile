import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../services/voice_interaction.dart';
import '../state/plugins_model.dart';
import '../ui/app_tokens.dart';
import '../ui/ui_node.dart';

class PluginEyesFreeScreen extends StatefulWidget {
  final AppState appState;
  final PluginInfo info;
  final PluginPanelStub panel;
  final bool frozen;
  final VoiceInteraction voice;

  const PluginEyesFreeScreen({
    super.key,
    required this.appState,
    required this.info,
    required this.panel,
    this.frozen = false,
    this.voice = const PlatformVoiceInteraction(),
  });

  @override
  State<PluginEyesFreeScreen> createState() => _PluginEyesFreeScreenState();
}

class _PluginEyesFreeScreenState extends State<PluginEyesFreeScreen> {
  int _index = 0;
  bool _executing = false;
  String? _lastSpokenStatus;

  @override
  void initState() {
    super.initState();
    widget.appState.uiPanels.addListener(_onPanelsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _announceEntry();
    });
  }

  @override
  void dispose() {
    widget.appState.uiPanels.removeListener(_onPanelsChanged);
    unawaited(widget.voice.stopSpeaking());
    super.dispose();
  }

  UiNode? get _tree => widget.appState.uiPanels
      .snapshotFor(widget.info.id, widget.panel.id)
      ?.tree;

  void _onPanelsChanged() {
    if (!mounted) return;
    final nextStatus = _collectEyesFreeState(_tree).statusText;
    setState(() {});
    if (nextStatus != null && nextStatus != _lastSpokenStatus) {
      _lastSpokenStatus = nextStatus;
      _speakLater(nextStatus);
    }
  }

  void _announceEntry() {
    final state = _collectEyesFreeState(_tree);
    _lastSpokenStatus = state.statusText;
    final parts = <String>[
      'Eyes-free mode',
      widget.info.name,
      if (state.statusText != null) state.statusText!,
      _currentAnnouncement(state.actions),
      'Swipe left or right to choose. Double tap to confirm. Long press to exit.',
    ];
    _speakLater(parts.join('. '));
  }

  String _currentAnnouncement(List<_EyesFreeAction> actions) {
    if (actions.isEmpty) return 'No actions available';
    final action = actions[_safeIndex(actions.length)];
    final ordinal = '${_safeIndex(actions.length) + 1} of ${actions.length}';
    return [ordinal, action.spoken].where((s) => s.isNotEmpty).join('. ');
  }

  int _safeIndex(int count) {
    if (count <= 0) return 0;
    return _index.clamp(0, count - 1).toInt();
  }

  void _move(int delta) {
    final actions = _collectEyesFreeState(_tree).actions;
    if (actions.isEmpty) {
      _speakLater('No actions available');
      return;
    }
    setState(() {
      _index = (_safeIndex(actions.length) + delta) % actions.length;
      if (_index < 0) _index += actions.length;
    });
    HapticFeedback.selectionClick();
    _speakLater(_currentAnnouncement(actions));
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 120) return;
    _move(velocity < 0 ? 1 : -1);
  }

  Future<void> _executeCurrent() async {
    if (_executing) return;
    final state = _collectEyesFreeState(_tree);
    if (state.actions.isEmpty) {
      _speakLater('No actions available');
      return;
    }
    if (widget.frozen) {
      _speakLater('${widget.info.name} is frozen');
      return;
    }
    final action = state.actions[_safeIndex(state.actions.length)];
    setState(() => _executing = true);
    HapticFeedback.mediumImpact();
    try {
      switch (action.kind) {
        case _EyesFreeActionKind.event:
          await _dispatch(action.event);
          await _speak('Confirmed. ${action.label}');
          break;
        case _EyesFreeActionKind.voiceInput:
          await _executeVoiceInput(action);
          break;
      }
    } finally {
      if (mounted) setState(() => _executing = false);
    }
  }

  Future<void> _executeVoiceInput(_EyesFreeAction action) async {
    await _speak('Listening. ${action.label}');
    final String? text;
    try {
      text = await widget.voice.recognizeOnce(prompt: action.prompt);
    } on PlatformException catch (e) {
      await _speak(e.message ?? 'Voice input failed');
      return;
    } catch (_) {
      await _speak('Voice input failed');
      return;
    }
    if (text == null || text.isEmpty) {
      await _speak('No speech recognized');
      return;
    }
    await _dispatch(
      UiNodeEvent(
        nodeId: action.event.nodeId,
        type: 'changed',
        payload: {'value': text},
      ),
    );
    await _dispatch(
      UiNodeEvent(
        nodeId: action.event.nodeId,
        type: action.event.type,
        payload: {'value': text, 'source': 'voice'},
      ),
    );
    await _speak('Sent');
  }

  Future<void> _speak(String text) async {
    try {
      await widget.voice.speak(text);
    } on PlatformException {
      // Eyes-free speech is a feedback channel, not a control-flow
      // dependency. Keep gestures working even if the device TTS service is
      // missing, busy, or denied.
    } catch (_) {
      // Best-effort only.
    }
  }

  void _speakLater(String text) {
    unawaited(_speak(text));
  }

  Future<void> _dispatch(UiNodeEvent event) {
    return widget.appState.uiPanels.dispatchEvent(
      pluginId: widget.info.id,
      panelId: widget.panel.id,
      event: event,
    );
  }

  void _exit() {
    HapticFeedback.heavyImpact();
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final state = _collectEyesFreeState(_tree);
    final actions = state.actions;
    final selected = actions.isEmpty
        ? null
        : actions[_safeIndex(actions.length)];
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final titleStyle = theme.textTheme.displaySmall?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: 0,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.info.name),
        leading: IconButton(
          tooltip: 'Exit eyes-free mode',
          icon: const Icon(Icons.close),
          onPressed: _exit,
        ),
      ),
      body: GestureDetector(
        key: const ValueKey<String>('eyes-free-gesture-surface'),
        behavior: HitTestBehavior.opaque,
        onHorizontalDragEnd: _onHorizontalDragEnd,
        onDoubleTap: _executeCurrent,
        onLongPress: _exit,
        child: Semantics(
          label: selected?.spoken ?? state.statusText ?? 'No actions available',
          hint: 'Swipe left or right to choose. Double tap to confirm.',
          button: selected != null,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    widget.panel.title,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (state.statusText != null) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      state.statusText!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (selected == null)
                    Text(
                      _tree == null
                          ? 'Waiting for panel'
                          : 'No actions exposed',
                      textAlign: TextAlign.center,
                      style: titleStyle,
                    )
                  else ...[
                    Text(
                      '${_safeIndex(actions.length) + 1} / ${actions.length}',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: scheme.primary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      selected.label,
                      textAlign: TextAlign.center,
                      style: titleStyle,
                    ),
                    if (selected.hint != null) ...[
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        selected.hint!,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                  const Spacer(),
                  if (_executing) const LinearProgressIndicator(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _EyesFreeActionKind { event, voiceInput }

class _EyesFreeAction {
  final String key;
  final String label;
  final String spoken;
  final String? hint;
  final String? prompt;
  final _EyesFreeActionKind kind;
  final UiNodeEvent event;

  const _EyesFreeAction({
    required this.key,
    required this.label,
    required this.spoken,
    required this.kind,
    required this.event,
    this.hint,
    this.prompt,
  });
}

class _EyesFreePanelState {
  final List<_EyesFreeAction> actions;
  final String? statusText;

  const _EyesFreePanelState({required this.actions, required this.statusText});
}

_EyesFreePanelState _collectEyesFreeState(UiNode? tree) {
  if (tree == null) {
    return const _EyesFreePanelState(actions: [], statusText: null);
  }
  final collector = _EyesFreeCollector();
  collector.visit(tree);
  collector.actions.sort((a, b) {
    final byOrder = a.order.compareTo(b.order);
    return byOrder != 0 ? byOrder : a.sequence.compareTo(b.sequence);
  });
  return _EyesFreePanelState(
    actions: [for (final a in collector.actions) a.action],
    statusText: collector.statusText,
  );
}

class _OrderedEyesFreeAction {
  final int order;
  final int sequence;
  final _EyesFreeAction action;

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
        _EyesFreeAction(
          key: '${node.id}:voice:$voiceInputEvent',
          label: _labelFor(node) ?? 'Dictate',
          spoken: _composeSpoken(node, fallback: _labelFor(node) ?? 'Dictate'),
          hint: meta.accessibilityHint,
          prompt: node.placeholder ?? node.label ?? meta.accessibilityLabel,
          kind: _EyesFreeActionKind.voiceInput,
          event: UiNodeEvent(nodeId: node.id, type: voiceInputEvent),
        ),
      );
    } else if (node is UiButton) {
      _add(
        node,
        _EyesFreeAction(
          key: '${node.id}:tap',
          label: _labelFor(node) ?? node.label,
          spoken: _composeSpoken(node, fallback: node.label),
          hint: meta.accessibilityHint,
          kind: _EyesFreeActionKind.event,
          event: UiNodeEvent(nodeId: node.id, type: 'tap'),
        ),
      );
    } else if (node is UiListTile && node.onTapEvent != null) {
      _add(
        node,
        _EyesFreeAction(
          key: '${node.id}:${node.onTapEvent}',
          label: _labelFor(node) ?? node.title,
          spoken: _composeSpoken(node, fallback: node.title),
          hint: meta.accessibilityHint ?? node.subtitle,
          kind: _EyesFreeActionKind.event,
          event: UiNodeEvent(nodeId: node.id, type: node.onTapEvent!),
        ),
      );
    } else if (node is UiInlineBanner && node.action != null) {
      _add(
        node,
        _EyesFreeAction(
          key: '${node.id}:${node.action!.eventId}',
          label: node.action!.label,
          spoken: _composeSpoken(node, fallback: node.action!.label),
          hint: meta.accessibilityHint,
          kind: _EyesFreeActionKind.event,
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
          _EyesFreeAction(
            key: '${node.id}:${node.onChangeEvent}:${option.value}',
            label: option.label,
            spoken: option.label,
            kind: _EyesFreeActionKind.event,
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
          _EyesFreeAction(
            key: '${node.id}:${node.onChangeEvent}:${tab.id}',
            label: tab.label,
            spoken: tab.label,
            kind: _EyesFreeActionKind.event,
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
      _EyesFreeAction(
        key: '${node.id}:$eventType',
        label: value ? 'Turn off $label' : 'Turn on $label',
        spoken: value ? 'Turn off $label' : 'Turn on $label',
        kind: _EyesFreeActionKind.event,
        event: UiNodeEvent(
          nodeId: node.id,
          type: eventType,
          payload: {'value': !value},
        ),
      ),
    );
  }

  void _add(UiNode node, _EyesFreeAction action) {
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
