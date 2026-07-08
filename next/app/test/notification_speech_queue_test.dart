import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilecode/services/notification_speech_queue.dart';
import 'package:mobilecode/services/voice_activity.dart';
import 'package:mobilecode/services/voice_interaction.dart';

class _FakeVoiceInteraction extends VoiceInteraction {
  final List<String> spoken = <String>[];
  final List<Completer<bool>> speakAndWaitCompletions;

  _FakeVoiceInteraction({
    List<Completer<bool>> speakAndWaitCompletions = const [],
  }) : speakAndWaitCompletions = List<Completer<bool>>.of(
         speakAndWaitCompletions,
       );

  @override
  Future<bool> isSpeechRecognitionAvailable() async => true;

  @override
  Future<String?> recognizeOnce({
    String? prompt,
    bool preferOffline = false,
  }) async => null;

  @override
  Future<bool> speak(String text) async {
    spoken.add(text);
    return true;
  }

  @override
  Future<bool> speakAndWait(String text) async {
    spoken.add(text);
    if (speakAndWaitCompletions.isNotEmpty) {
      return speakAndWaitCompletions.removeAt(0).future;
    }
    return true;
  }

  @override
  Future<void> stopSpeaking() async {}
}

void main() {
  test('defers notification speech while voice activity is active', () async {
    final activity = VoiceActivity();
    final voice = _FakeVoiceInteraction();
    final queue = NotificationSpeechQueue(voice: voice, activity: activity);
    addTearDown(queue.dispose);

    final session = activity.begin();
    await queue.speak('Agent finished');
    expect(voice.spoken, isEmpty);

    session.end();
    await Future<void>.delayed(Duration.zero);

    expect(voice.spoken, ['Agent finished']);
  });

  test('flushes only after all nested voice activities end', () async {
    final activity = VoiceActivity();
    final voice = _FakeVoiceInteraction();
    final queue = NotificationSpeechQueue(voice: voice, activity: activity);
    addTearDown(queue.dispose);

    final outer = activity.begin();
    final inner = activity.begin();
    await queue.speak('Turn complete');

    inner.end();
    await Future<void>.delayed(Duration.zero);
    expect(voice.spoken, isEmpty);

    outer.end();
    await Future<void>.delayed(Duration.zero);
    expect(voice.spoken, ['Turn complete']);
  });

  test('caps deferred notification speech to the most recent items', () async {
    final activity = VoiceActivity();
    final voice = _FakeVoiceInteraction();
    final queue = NotificationSpeechQueue(
      voice: voice,
      activity: activity,
      maxDeferred: 3,
    );
    addTearDown(queue.dispose);

    final session = activity.begin();
    await queue.speak('one');
    await queue.speak('two');
    await queue.speak('three');
    await queue.speak('four');
    await queue.speak('two');

    session.end();
    await Future<void>.delayed(Duration.zero);

    expect(voice.spoken, ['three\n\nfour\n\ntwo']);
  });

  test('serializes notification speech instead of interrupting', () async {
    final activity = VoiceActivity();
    final firstDone = Completer<bool>();
    final secondDone = Completer<bool>();
    final voice = _FakeVoiceInteraction(
      speakAndWaitCompletions: [firstDone, secondDone],
    );
    final queue = NotificationSpeechQueue(voice: voice, activity: activity);
    addTearDown(queue.dispose);

    final first = queue.speak('first');
    await Future<void>.delayed(Duration.zero);
    expect(voice.spoken, ['first']);

    final second = queue.speak('second');
    await Future<void>.delayed(Duration.zero);
    expect(voice.spoken, ['first']);

    firstDone.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(voice.spoken, ['first', 'second']);

    secondDone.complete(true);
    await Future.wait([first, second]);
  });
}
