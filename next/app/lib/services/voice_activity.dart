import 'package:flutter/foundation.dart';

class VoiceActivity extends ChangeNotifier {
  static final VoiceActivity instance = VoiceActivity();

  int _activeCount = 0;

  bool get isActive => _activeCount > 0;

  VoiceActivitySession begin() {
    _activeCount += 1;
    if (_activeCount == 1) notifyListeners();
    return VoiceActivitySession._(this);
  }

  void _end() {
    if (_activeCount == 0) return;
    _activeCount -= 1;
    if (_activeCount == 0) notifyListeners();
  }
}

class VoiceActivitySession {
  final VoiceActivity _activity;
  bool _ended = false;

  VoiceActivitySession._(this._activity);

  void end() {
    if (_ended) return;
    _ended = true;
    _activity._end();
  }
}
