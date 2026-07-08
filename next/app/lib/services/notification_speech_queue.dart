import 'dart:async';

import 'package:flutter/foundation.dart';

import 'voice_activity.dart';
import 'voice_interaction.dart';

class NotificationSpeechQueue {
  final VoiceInteraction voice;
  final VoiceActivity activity;
  final int maxDeferred;

  final List<String> _deferred = <String>[];
  final List<String> _pendingSpeech = <String>[];
  bool _disposed = false;
  Future<void>? _drainFuture;

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
    _pendingSpeech.add(trimmed);
    _drainFuture ??= _drain();
    await _drainFuture;
  }

  void dispose() {
    _disposed = true;
    _deferred.clear();
    _pendingSpeech.clear();
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
    if (_disposed || activity.isActive) return;
    if (_deferred.isNotEmpty) {
      final pending = _deferred.join('\n\n');
      _deferred.clear();
      _pendingSpeech.add(pending);
    }
    if (_pendingSpeech.isNotEmpty) {
      _drainFuture ??= _drain();
    }
  }

  Future<void> _drain() async {
    try {
      while (!_disposed && !activity.isActive && _pendingSpeech.isNotEmpty) {
        final text = _pendingSpeech.removeAt(0);
        await _speakBestEffort(text);
      }
    } finally {
      _drainFuture = null;
      if (!_disposed && !activity.isActive && _pendingSpeech.isNotEmpty) {
        _drainFuture = _drain();
      }
    }
  }

  Future<void> _speakBestEffort(String text) async {
    if (_disposed || activity.isActive) {
      _defer(text);
      return;
    }
    try {
      await voice.speakAndWait(text);
    } catch (e) {
      debugPrint('notification speech failed: $e');
    }
  }
}
