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
  static const _confirmTapWindow = Duration(milliseconds: 700);
  static const double _confirmTapSlop = 96;

  int _index = 0;
  String? _selectedActionKey;
  bool _executing = false;
  Offset? _pointerDownPosition;
  bool _pointerMoved = false;
  DateTime? _lastTapAt;
  Offset? _lastTapPosition;
  String? _lastSpokenStatus;
  String? _pendingSpokenStatus;

  void _debugLog(String message) {
    if (!kDebugMode) return;
    // ignore: avoid_print
    print('[plugin-eyes-free:${widget.info.id}/${widget.panel.id}] $message');
  }

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
    unawaited(_stopSpeaking());
    super.dispose();
  }

  UiNode? get _tree => widget.appState.uiPanels
      .snapshotFor(widget.info.id, widget.panel.id)
      ?.tree;

  void _onPanelsChanged() {
    if (!mounted) return;
    final state = collectEyesFreeState(_tree);
    final nextStatus = state.statusText;
    setState(() => _syncSelection(state.actions));
    if (nextStatus != null && nextStatus != _lastSpokenStatus) {
      if (_executing) {
        _pendingSpokenStatus = nextStatus;
      } else {
        _lastSpokenStatus = nextStatus;
        _speakLater(nextStatus);
      }
    }
  }

  void _announceEntry() {
    final state = collectEyesFreeState(_tree);
    _syncSelection(state.actions);
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

  String _currentAnnouncement(List<EyesFreeAction> actions) {
    if (actions.isEmpty) return 'No actions available';
    final action = actions[_safeIndex(actions.length)];
    final ordinal = '${_safeIndex(actions.length) + 1} of ${actions.length}';
    return [ordinal, action.spoken].where((s) => s.isNotEmpty).join('. ');
  }

  int _safeIndex(int count) {
    if (count <= 0) return 0;
    return _index.clamp(0, count - 1).toInt();
  }

  void _syncSelection(List<EyesFreeAction> actions) {
    if (actions.isEmpty) {
      _index = 0;
      _selectedActionKey = null;
      return;
    }
    final key = _selectedActionKey;
    if (key != null) {
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
    final actions = collectEyesFreeState(_tree).actions;
    if (actions.isEmpty) {
      _debugLog('move ignored: no actions');
      _speakLater('No actions available');
      return;
    }
    setState(() {
      _index = (_safeIndex(actions.length) + delta) % actions.length;
      if (_index < 0) _index += actions.length;
      _selectedActionKey = actions[_index].key;
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
    final state = collectEyesFreeState(_tree);
    if (state.actions.isEmpty) {
      _debugLog('execute ignored: no actions');
      _speakLater('No actions available');
      return;
    }
    if (widget.frozen) {
      _debugLog('execute ignored: plugin frozen');
      _speakLater('${widget.info.name} is frozen');
      return;
    }
    _syncSelection(state.actions);
    final action = state.actions[_safeIndex(state.actions.length)];
    _debugLog(
      'execute action key=${action.key} kind=${action.kind.name} '
      'node=${action.event.nodeId} event=${action.event.type}',
    );
    setState(() => _executing = true);
    HapticFeedback.mediumImpact();
    try {
      switch (action.kind) {
        case EyesFreeActionKind.event:
          await _dispatch(action.event);
          await _speakAndWait('Confirmed. ${action.label}');
          break;
        case EyesFreeActionKind.voiceInput:
          await _executeVoiceInput(action);
          break;
        case EyesFreeActionKind.voiceOutput:
          await _executeVoiceOutput(action);
          break;
      }
    } finally {
      if (mounted) setState(() => _executing = false);
      _flushPendingStatus();
    }
  }

  Future<void> _executeVoiceOutput(EyesFreeAction action) async {
    final text = action.voiceOutputText?.trim() ?? '';
    if (text.isEmpty) {
      _debugLog('voice output ignored: empty text');
      await _speak('Nothing to read');
      return;
    }
    _debugLog('voice output begin length=${text.length}');
    await _stopSpeaking();
    await _speakAndWait(text);
  }

  Future<void> _executeVoiceInput(EyesFreeAction action) async {
    final voiceSession = VoiceActivity.instance.begin();
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
      await _speakAndWait('Sent');
    } finally {
      voiceSession.end();
    }
  }

  void _flushPendingStatus() {
    if (!mounted || _pendingSpokenStatus == null) return;
    _pendingSpokenStatus = null;
    final currentStatus = collectEyesFreeState(_tree).statusText;
    if (currentStatus == null || currentStatus == _lastSpokenStatus) return;
    _lastSpokenStatus = currentStatus;
    _speakLater(currentStatus);
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

  Future<void> _dispatch(UiNodeEvent event) {
    _debugLog('dispatch node=${event.nodeId} type=${event.type}');
    return widget.appState.uiPanels.dispatchEvent(
      pluginId: widget.info.id,
      panelId: widget.panel.id,
      event: event,
    );
  }

  void _exit() {
    _debugLog('exit');
    HapticFeedback.heavyImpact();
    unawaited(_stopSpeaking());
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final state = collectEyesFreeState(_tree);
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
      body: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        child: GestureDetector(
          key: const ValueKey<String>('eyes-free-gesture-surface'),
          behavior: HitTestBehavior.opaque,
          onHorizontalDragEnd: _onHorizontalDragEnd,
          onLongPress: _exit,
          child: Semantics(
            label:
                selected?.spoken ?? state.statusText ?? 'No actions available',
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
                    ],
                    const Spacer(),
                    if (_executing) const LinearProgressIndicator(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
