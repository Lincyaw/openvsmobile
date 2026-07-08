import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobilecode/screens/system_tray_debug_screen.dart';
import 'package:mobilecode/services/system_tray.dart';
import 'package:mobilecode/services/voice_activity.dart';
import 'package:mobilecode/services/voice_interaction.dart';
import 'package:mobilecode/settings_store.dart';

class _FakeVoiceInteraction extends VoiceInteraction {
  final String? recognizedText;
  final List<Object?> recognitionResponses;
  final bool speechRecognitionAvailable;
  final List<String> calls = <String>[];

  _FakeVoiceInteraction({
    this.recognizedText,
    List<Object?> recognitionResponses = const [],
    this.speechRecognitionAvailable = true,
  }) : recognitionResponses = List<Object?>.from(recognitionResponses);

  @override
  Future<bool> isSpeechRecognitionAvailable() async {
    calls.add('isSpeechRecognitionAvailable');
    return speechRecognitionAvailable;
  }

  @override
  Future<String?> recognizeOnce({
    String? prompt,
    bool preferOffline = false,
  }) async {
    calls.add('recognizeOnce:${prompt ?? ""}:offline=$preferOffline');
    if (recognitionResponses.isNotEmpty) {
      final response = recognitionResponses.removeAt(0);
      if (response is PlatformException) throw response;
      if (response is Exception) throw response;
      return response as String?;
    }
    return recognizedText;
  }

  @override
  Future<bool> speak(String text) async {
    calls.add('speak:$text');
    return true;
  }

  @override
  Future<bool> speakAndWait(String text) async {
    calls.add('speakAndWait:$text');
    return true;
  }

  @override
  Future<void> stopSpeaking() async {
    calls.add('stopSpeaking');
  }
}

Future<void> _pumpDiagnostics(
  WidgetTester tester, {
  required _FakeVoiceInteraction voice,
}) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    MaterialApp(
      home: SystemTrayDebugScreen(
        controller: SystemTrayController(),
        settingsStore: SettingsStore(),
        voice: voice,
      ),
    ),
  );
  await tester.pump();
}

Future<void> _tapDiagnosticTile(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey<String>(key));
  await tester.scrollUntilVisible(finder, 200);
  await tester.pumpAndSettle();
  await tester.tap(finder);
}

void main() {
  testWidgets('voice output diagnostic speaks a phrase', (tester) async {
    final voice = _FakeVoiceInteraction();
    await _pumpDiagnostics(tester, voice: voice);

    await _tapDiagnosticTile(tester, 'diagnostics-voice-output');
    await tester.pumpAndSettle();

    expect(find.text('Voice output finished'), findsOneWidget);
    expect(
      voice.calls,
      contains('speakAndWait:MobileCode voice output is working'),
    );
  });

  testWidgets('voice input diagnostic recognizes and repeats text', (
    tester,
  ) async {
    final voice = _FakeVoiceInteraction(recognizedText: 'hello mobile');
    await _pumpDiagnostics(tester, voice: voice);

    await _tapDiagnosticTile(tester, 'diagnostics-voice-input');
    await tester.pumpAndSettle();

    expect(find.text('Heard: hello mobile'), findsOneWidget);
    expect(VoiceActivity.instance.isActive, isFalse);
    final cueIndex = voice.calls.indexWhere(
      (call) => call.startsWith('speakAndWait:Listening.'),
    );
    final stopIndex = voice.calls.indexOf('stopSpeaking');
    final recognizeIndex = voice.calls.indexWhere(
      (call) => call.startsWith('recognizeOnce:'),
    );
    final repeatIndex = voice.calls.indexOf('speakAndWait:Heard: hello mobile');
    expect(cueIndex, isNonNegative);
    expect(stopIndex, greaterThan(cueIndex));
    expect(recognizeIndex, greaterThan(stopIndex));
    expect(repeatIndex, greaterThan(recognizeIndex));
  });

  testWidgets('voice input diagnostic retries network failures offline', (
    tester,
  ) async {
    final voice = _FakeVoiceInteraction(
      recognitionResponses: <Object?>[
        PlatformException(
          code: 'NETWORK_TIMEOUT',
          message: 'Speech recognition network error',
        ),
        'hello after retry',
      ],
    );
    await _pumpDiagnostics(tester, voice: voice);

    await _tapDiagnosticTile(tester, 'diagnostics-voice-input');
    await tester.pumpAndSettle();

    expect(find.text('Heard: hello after retry'), findsOneWidget);
    expect(
      voice.calls.where((call) => call.startsWith('recognizeOnce:')).toList(),
      <String>[
        'recognizeOnce:Say a short test phrase:offline=false',
        'recognizeOnce:Say a short test phrase:offline=true',
      ],
    );
    expect(
      voice.calls,
      contains(
        'speakAndWait:Speech recognition had a network problem. Listening again.',
      ),
    );
    expect(VoiceActivity.instance.isActive, isFalse);
  });

  testWidgets('speech recognition diagnostic reports unavailable service', (
    tester,
  ) async {
    final voice = _FakeVoiceInteraction(speechRecognitionAvailable: false);
    await _pumpDiagnostics(tester, voice: voice);

    await _tapDiagnosticTile(tester, 'diagnostics-voice-availability');
    await tester.pumpAndSettle();
    expect(find.text('Speech recognition is not available'), findsOneWidget);

    await _tapDiagnosticTile(tester, 'diagnostics-voice-input');
    await tester.pumpAndSettle();

    expect(
      find.text('Speech recognition is not available on this device'),
      findsOneWidget,
    );
    expect(
      voice.calls.where((call) => call.startsWith('recognizeOnce:')),
      isEmpty,
    );
    expect(VoiceActivity.instance.isActive, isFalse);
  });
}
