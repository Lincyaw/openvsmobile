import 'dart:async';

import 'package:flutter/foundation.dart';

import 'voice_activity.dart';
import 'voice_interaction.dart';

class NotificationSpeechQueue {
  final VoiceInteraction voice;
  final VoiceActivity activity;
  final int maxDeferred;

  final List<String> _deferred = <String>[];
  bool _disposed = false;

  NotificationSpeechQueue({
    required this.voice,
    VoiceActivity? activity,
    this.maxDeferred = 3,
  }) : activity = activity ?? VoiceActivity.instance {
    this.activity.addListener(_flushIfIdle);
  }

  Future<void> speak(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _disposed) return;
    if (activity.isActive) {
      _defer(trimmed);
      return;
    }
    await _speakBestEffort(trimmed);
  }

  void dispose() {
    _disposed = true;
    _deferred.clear();
    activity.removeListener(_flushIfIdle);
  }

  void _defer(String text) {
    _deferred.remove(text);
    _deferred.add(text);
    while (_deferred.length > maxDeferred) {
      _deferred.removeAt(0);
    }
  }

  void _flushIfIdle() {
    if (_disposed || activity.isActive || _deferred.isEmpty) return;
    final pending = _deferred.join('\n\n');
    _deferred.clear();
    unawaited(_speakBestEffort(pending));
  }

  Future<void> _speakBestEffort(String text) async {
    if (_disposed || activity.isActive) {
      _defer(text);
      return;
    }
    try {
      await voice.speak(text);
    } catch (e) {
      debugPrint('notification speech failed: $e');
    }
  }
}
