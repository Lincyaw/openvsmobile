import 'package:flutter/services.dart';

abstract class VoiceInteraction {
  const VoiceInteraction();

  Future<bool> isSpeechRecognitionAvailable();

  Future<String?> recognizeOnce({String? prompt});

  Future<bool> speak(String text);

  Future<bool> speakAndWait(String text);

  Future<void> stopSpeaking();
}

class PlatformVoiceInteraction extends VoiceInteraction {
  static const MethodChannel _channel = MethodChannel(
    'dev.lincyaw.mobilecode/accessibility_voice',
  );

  const PlatformVoiceInteraction();

  @override
  Future<bool> isSpeechRecognitionAvailable() async {
    final result = await _channel.invokeMethod<bool>(
      'isSpeechRecognitionAvailable',
    );
    return result == true;
  }

  @override
  Future<String?> recognizeOnce({String? prompt}) async {
    final result = await _channel.invokeMethod<String>('recognizeOnce', {
      if (prompt != null && prompt.isNotEmpty) 'prompt': prompt,
    });
    final trimmed = result?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  @override
  Future<bool> speak(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    final result = await _channel.invokeMethod<bool>('speak', {
      'text': trimmed,
    });
    return result == true;
  }

  @override
  Future<bool> speakAndWait(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    final result = await _channel.invokeMethod<bool>('speakAndWait', {
      'text': trimmed,
    });
    return result == true;
  }

  @override
  Future<void> stopSpeaking() async {
    await _channel.invokeMethod<void>('stopSpeaking');
  }
}
