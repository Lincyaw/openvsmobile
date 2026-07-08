import 'dart:async';

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
  int _index = 0;
  String? _selectedActionKey;
  bool _executing = false;
  String? _lastSpokenStatus;
  String? _pendingSpokenStatus;

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
      _speakLater('No actions available');
      return;
    }
    setState(() {
      _index = (_safeIndex(actions.length) + delta) % actions.length;
      if (_index < 0) _index += actions.length;
      _selectedActionKey = actions[_index].key;
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
    final state = collectEyesFreeState(_tree);
    if (state.actions.isEmpty) {
      _speakLater('No actions available');
      return;
    }
    if (widget.frozen) {
      _speakLater('${widget.info.name} is frozen');
      return;
    }
    _syncSelection(state.actions);
    final action = state.actions[_safeIndex(state.actions.length)];
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
      }
    } finally {
      if (mounted) setState(() => _executing = false);
      _flushPendingStatus();
    }
  }

  Future<void> _executeVoiceInput(EyesFreeAction action) async {
    final voiceSession = VoiceActivity.instance.begin();
    try {
      final available = await _speechRecognitionAvailable();
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
    return widget.appState.uiPanels.dispatchEvent(
      pluginId: widget.info.id,
      panelId: widget.panel.id,
      event: event,
    );
  }

  void _exit() {
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
