import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../services/eyes_free_actions.dart';
import '../services/voice_activity.dart';
import '../services/voice_interaction.dart';
import '../state/plugins_model.dart';
import '../ui/app_tokens.dart';
import '../ui/ui_node.dart';

class EyesFreeTab extends StatefulWidget {
  final AppState appState;
  final bool isActive;
  final VoidCallback onExit;
  final VoiceInteraction voice;

  const EyesFreeTab({
    super.key,
    required this.appState,
    required this.isActive,
    required this.onExit,
    this.voice = const PlatformVoiceInteraction(),
  });

  @override
  State<EyesFreeTab> createState() => _EyesFreeTabState();
}

class _EyesFreeTabState extends State<EyesFreeTab> {
  static const _confirmTapWindow = Duration(milliseconds: 700);
  static const double _confirmTapSlop = 96;

  int _index = 0;
  String? _selectedActionKey;
  bool _selectionPinned = false;
  bool _executing = false;
  Offset? _pointerDownPosition;
  bool _pointerMoved = false;
  DateTime? _lastTapAt;
  Offset? _lastTapPosition;
  String? _lastSpokenStatusKey;
  String? _pendingSpokenStatusKey;
  String? _pendingSpokenStatus;

  void _debugLog(String message) {
    if (!kDebugMode) return;
    // ignore: avoid_print
    print('[eyes-free-tab] $message');
  }

  @override
  void initState() {
    super.initState();
    widget.appState.addListener(_onAppStateChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.isActive) _announceEntry();
    });
  }

  @override
  void didUpdateWidget(covariant EyesFreeTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.appState != widget.appState) {
      oldWidget.appState.removeListener(_onAppStateChanged);
      widget.appState.addListener(_onAppStateChanged);
    }
    if (!oldWidget.isActive && widget.isActive) {
      _announceEntry();
    } else if (oldWidget.isActive && !widget.isActive) {
      unawaited(_stopSpeaking());
    }
  }

  @override
  void dispose() {
    widget.appState.removeListener(_onAppStateChanged);
    unawaited(_stopSpeaking());
    super.dispose();
  }

  List<_EyesFreeTargetAction> get _actions {
    final result = <_EyesFreeTargetAction>[];
    for (final plugin in widget.appState.plugins.plugins) {
      if (plugin.state == PluginWireState.disabled) continue;
      for (final panel in plugin.panels) {
        final tree = widget.appState.uiPanels
            .snapshotFor(plugin.id, panel.id)
            ?.tree;
        final panelState = collectEyesFreeState(tree);
        for (final action in panelState.actions) {
          if (!action.voiceShortcut) continue;
          result.add(
            _EyesFreeTargetAction(
              plugin: plugin,
              panel: panel,
              panelState: panelState,
              action: action,
            ),
          );
        }
      }
    }
    return result;
  }

  void _onAppStateChanged() {
    if (!mounted) return;
    final actions = _actions;
    setState(() => _syncSelection(actions));
    if (!widget.isActive) return;
    _speakStatusIfChanged(_selected(actions));
  }

  void _announceEntry() {
    _index = 0;
    _selectedActionKey = null;
    _selectionPinned = false;
    final actions = _actions;
    setState(() => _syncSelection(actions));
    _lastSpokenStatusKey = _selected(actions)?.statusKey;
    final parts = <String>[
      'Voice control',
      _currentAnnouncement(actions),
      'Swipe left or right to choose. Double tap to confirm. Long press to exit.',
    ];
    _speakLater(parts.where((s) => s.isNotEmpty).join('. '));
  }

  _EyesFreeTargetAction? _selected(List<_EyesFreeTargetAction> actions) {
    if (actions.isEmpty) return null;
    return actions[_safeIndex(actions.length)];
  }

  String _currentAnnouncement(List<_EyesFreeTargetAction> actions) {
    final selected = _selected(actions);
    if (selected == null) {
      if (widget.appState.plugins.plugins.isEmpty) {
        return 'No plugins available';
      }
      return 'No eyes-free actions available';
    }
    final ordinal = '${_safeIndex(actions.length) + 1} of ${actions.length}';
    return <String>[
      ordinal,
      selected.plugin.name,
      if (selected.panel.title != selected.plugin.name) selected.panel.title,
      if (selected.panelState.statusText != null)
        selected.panelState.statusText!,
      selected.action.spoken,
    ].where((s) => s.trim().isNotEmpty).join('. ');
  }

  int _safeIndex(int count) {
    if (count <= 0) return 0;
    return _index.clamp(0, count - 1).toInt();
  }

  void _syncSelection(List<_EyesFreeTargetAction> actions) {
    if (actions.isEmpty) {
      _index = 0;
      _selectedActionKey = null;
      return;
    }
    final key = _selectedActionKey;
    if (_selectionPinned && key != null) {
      final existing = actions.indexWhere((action) => action.key == key);
      if (existing >= 0) {
        _index = existing;
        return;
      }
    }
    _index = _safeIndex(actions.length);
    _selectedActionKey = actions[_index].key;
  }

  void _move(int delta) {
    if (_executing) return;
    final actions = _actions;
    if (actions.isEmpty) {
      _debugLog('move ignored: no actions');
      _speakLater('No eyes-free actions available');
      return;
    }
    setState(() {
      _index = (_safeIndex(actions.length) + delta) % actions.length;
      if (_index < 0) _index += actions.length;
      _selectedActionKey = actions[_index].key;
      _selectionPinned = true;
      _lastSpokenStatusKey = actions[_index].statusKey;
    });
    _debugLog(
      'move delta=$delta index=${_safeIndex(actions.length)} '
      'count=${actions.length} action=${actions[_safeIndex(actions.length)].key}',
    );
    HapticFeedback.selectionClick();
    _speakLater(_currentAnnouncement(actions));
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 120) return;
    _move(velocity < 0 ? 1 : -1);
  }

  void _onPointerDown(PointerDownEvent event) {
    _pointerDownPosition = event.position;
    _pointerMoved = false;
    _debugLog(
      'pointer down x=${event.position.dx.toStringAsFixed(1)} '
      'y=${event.position.dy.toStringAsFixed(1)}',
    );
  }

  void _onPointerMove(PointerMoveEvent event) {
    final down = _pointerDownPosition;
    if (down == null) return;
    final distance = (event.position - down).distance;
    if (distance > kTouchSlop && !_pointerMoved) {
      _pointerMoved = true;
      _debugLog(
        'pointer moved beyond tap slop distance=${distance.toStringAsFixed(1)}',
      );
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    final down = _pointerDownPosition;
    final moved =
        _pointerMoved ||
        (down != null && (event.position - down).distance > kTouchSlop);
    _pointerDownPosition = null;
    _pointerMoved = false;
    _debugLog(
      'pointer up moved=$moved x=${event.position.dx.toStringAsFixed(1)} '
      'y=${event.position.dy.toStringAsFixed(1)}',
    );
    if (moved) return;
    _registerConfirmTap(event.position);
  }

  void _registerConfirmTap(Offset position) {
    final now = DateTime.now();
    final previousAt = _lastTapAt;
    final previousPosition = _lastTapPosition;
    _lastTapAt = now;
    _lastTapPosition = position;
    if (previousAt == null || previousPosition == null) {
      _debugLog('tap recorded: waiting for second tap');
      return;
    }
    final gap = now.difference(previousAt);
    if (gap > _confirmTapWindow) {
      _debugLog('tap ignored: gap ${gap.inMilliseconds}ms exceeded window');
      return;
    }
    if ((position - previousPosition).distance > _confirmTapSlop) {
      _debugLog(
        'tap ignored: distance '
        '${(position - previousPosition).distance.toStringAsFixed(1)} exceeded slop',
      );
      return;
    }
    _lastTapAt = null;
    _lastTapPosition = null;
    _debugLog('double tap confirmed gap=${gap.inMilliseconds}ms');
    unawaited(_executeCurrent());
  }

  Future<void> _executeCurrent() async {
    if (_executing) {
      _debugLog('execute ignored: already executing');
      return;
    }
    final actions = _actions;
    if (actions.isEmpty) {
      _debugLog('execute ignored: no actions');
      _speakLater('No eyes-free actions available');
      return;
    }
    _syncSelection(actions);
    final selected = actions[_safeIndex(actions.length)];
    if (selected.frozen) {
      _debugLog('execute ignored: plugin frozen plugin=${selected.plugin.id}');
      _speakLater('${selected.plugin.name} is frozen');
      return;
    }
    _debugLog(
      'execute action plugin=${selected.plugin.id} panel=${selected.panel.id} '
      'key=${selected.action.key} kind=${selected.action.kind.name} '
      'event=${selected.action.event.type}',
    );
    setState(() => _executing = true);
    HapticFeedback.mediumImpact();
    try {
      switch (selected.action.kind) {
        case EyesFreeActionKind.event:
          await _dispatch(selected, selected.action.event);
          await _speakAndWait('Confirmed. ${selected.action.label}');
          break;
        case EyesFreeActionKind.voiceInput:
          await _executeVoiceInput(selected);
          break;
      }
    } finally {
      if (mounted) setState(() => _executing = false);
      _flushPendingStatus();
    }
  }

  Future<void> _executeVoiceInput(_EyesFreeTargetAction selected) async {
    final voiceSession = VoiceActivity.instance.begin();
    final action = selected.action;
    _debugLog(
      'voice input begin node=${action.event.nodeId} event=${action.event.type}',
    );
    try {
      final available = await _speechRecognitionAvailable();
      _debugLog('speech recognition available=$available');
      if (!available) {
        await _speak('Speech recognition is not available on this device');
        return;
      }
      await _speakAndWait('Listening. ${action.label}');
      await _stopSpeaking();
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
        _debugLog('voice input result empty');
        await _speak('No speech recognized');
        return;
      }
      _debugLog('voice input result length=${text.length}');
      await _dispatch(
        selected,
        UiNodeEvent(
          nodeId: action.event.nodeId,
          type: 'changed',
          payload: {'value': text},
        ),
      );
      await _dispatch(
        selected,
        UiNodeEvent(
          nodeId: action.event.nodeId,
          type: action.event.type,
          payload: {'value': text, 'source': 'voice'},
        ),
      );
      await _speakAndWait('Sent');
    } finally {
      voiceSession.end();
    }
  }

  void _speakStatusIfChanged(_EyesFreeTargetAction? selected) {
    final status = selected?.panelState.statusText;
    if (selected == null || status == null) return;
    final key = selected.statusKey;
    if (key == _lastSpokenStatusKey) return;
    if (_executing) {
      _pendingSpokenStatusKey = key;
      _pendingSpokenStatus = status;
      return;
    }
    _lastSpokenStatusKey = key;
    _speakLater(status);
  }

  void _flushPendingStatus() {
    if (!mounted || _pendingSpokenStatus == null) return;
    final key = _pendingSpokenStatusKey;
    final status = _pendingSpokenStatus;
    _pendingSpokenStatusKey = null;
    _pendingSpokenStatus = null;
    if (!widget.isActive || key == null || status == null) return;
    final selected = _selected(_actions);
    if (selected?.statusKey != key || key == _lastSpokenStatusKey) return;
    _lastSpokenStatusKey = key;
    _speakLater(status);
  }

  Future<bool> _speechRecognitionAvailable() async {
    try {
      return await widget.voice.isSpeechRecognitionAvailable();
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _dispatch(_EyesFreeTargetAction selected, UiNodeEvent event) {
    _debugLog(
      'dispatch plugin=${selected.plugin.id} panel=${selected.panel.id} '
      'node=${event.nodeId} type=${event.type}',
    );
    return widget.appState.uiPanels.dispatchEvent(
      pluginId: selected.plugin.id,
      panelId: selected.panel.id,
      event: event,
    );
  }

  Future<void> _speak(String text) async {
    try {
      await widget.voice.speak(text);
    } on PlatformException {
      // Best-effort speech feedback.
    } catch (_) {
      // Best-effort only.
    }
  }

  Future<void> _speakAndWait(String text) async {
    try {
      await widget.voice.speakAndWait(text);
    } on PlatformException {
      // Best-effort cue before opening the microphone.
    } catch (_) {
      // Best-effort only.
    }
  }

  void _speakLater(String text) {
    unawaited(_speak(text));
  }

  Future<void> _stopSpeaking() async {
    try {
      await widget.voice.stopSpeaking();
    } on PlatformException {
      // Best-effort only.
    } catch (_) {
      // Best-effort only.
    }
  }

  void _exit() {
    _debugLog('exit');
    HapticFeedback.heavyImpact();
    unawaited(_stopSpeaking());
    widget.onExit();
  }

  @override
  Widget build(BuildContext context) {
    final actions = _actions;
    final selected = _selected(actions);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final actionStyle = theme.textTheme.displaySmall?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: 0,
    );

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      child: GestureDetector(
        key: const ValueKey<String>('eyes-free-tab-gesture-surface'),
        behavior: HitTestBehavior.opaque,
        onHorizontalDragEnd: _onHorizontalDragEnd,
        onLongPress: _exit,
        child: Semantics(
          key: const ValueKey<String>('eyes-free-tab-semantics'),
          label:
              selected?.action.spoken ??
              selected?.panelState.statusText ??
              'No eyes-free actions available',
          hint: 'Swipe left or right to choose. Double tap to confirm.',
          button: selected != null,
          onTap: selected == null ? null : _executeCurrent,
          onLongPress: _exit,
          onIncrease: selected == null ? null : () => _move(1),
          onDecrease: selected == null ? null : () => _move(-1),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (selected != null) ...[
                    Text(
                      selected.plugin.name,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      selected.panel.title,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (selected.panelState.statusText != null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        selected.panelState.statusText!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                  const Spacer(),
                  if (selected == null)
                    Text(
                      widget.appState.plugins.plugins.isEmpty
                          ? 'No plugins available'
                          : 'No eyes-free actions available',
                      textAlign: TextAlign.center,
                      style: actionStyle,
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
                      selected.action.label,
                      textAlign: TextAlign.center,
                      style: actionStyle,
                    ),
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

class _EyesFreeTargetAction {
  final PluginInfo plugin;
  final PluginPanelStub panel;
  final EyesFreePanelState panelState;
  final EyesFreeAction action;

  const _EyesFreeTargetAction({
    required this.plugin,
    required this.panel,
    required this.panelState,
    required this.action,
  });

  String get key => '${plugin.id}/${panel.id}/${action.key}';

  String get statusKey {
    final status = panelState.statusText ?? '';
    return '${plugin.id}/${panel.id}/$status';
  }

  bool get frozen =>
      plugin.state == PluginWireState.crashed ||
      plugin.state == PluginWireState.unknown;
}
