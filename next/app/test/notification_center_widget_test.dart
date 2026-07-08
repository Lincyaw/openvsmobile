// Widget tests for the notification center + bell icon.
//
// Same pattern as files_tab_widget_test.dart: feed AppState through its
// push handlers (no WS), pump the widget, assert on the render.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/app_state.dart';
import 'package:mobilecode/backend_client.dart';
import 'package:mobilecode/notification.dart';
import 'package:mobilecode/screens/notification_center.dart';
import 'package:mobilecode/services/voice_interaction.dart';

class _RecordingBackendClient extends BackendClient {
  final List<({String method, Map<String, dynamic>? params})> calls = [];

  @override
  Future<dynamic> call(String method, [Map<String, dynamic>? params]) async {
    calls.add((method: method, params: params));
    return <String, dynamic>{'ok': true};
  }
}

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

AppNotification _n({
  required String id,
  required String title,
  String source = 'demo',
  NotificationLevel level = NotificationLevel.info,
  int? ts,
  String? body,
  List<NotificationField> fields = const [],
  NotificationAction? action,
  NotificationReply? reply,
  String? groupKey,
}) => AppNotification(
  id: id,
  source: source,
  level: level,
  title: title,
  body: body,
  fields: fields,
  action: action,
  reply: reply,
  groupKey: groupKey,
  timestamp: ts ?? DateTime.now().millisecondsSinceEpoch,
);

Future<void> _pumpCenter(
  WidgetTester tester,
  AppState appState, {
  Future<void> Function(OpenTerminalAction action)? onOpenTerminal,
  VoiceInteraction voice = const PlatformVoiceInteraction(),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: NotificationCenterScreen(
        appState: appState,
        onOpenTerminal: onOpenTerminal,
        voice: voice,
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('shows empty state when no notifications', (tester) async {
    final appState = AppState(client: BackendClient(), deviceId: 'me');
    addTearDown(appState.dispose);
    await _pumpCenter(tester, appState);
    expect(find.text('No agent alerts yet'), findsOneWidget);
    expect(find.byIcon(Icons.smart_toy_outlined), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('notifications-empty-agent-hooks')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('notifications-empty-agent-hooks')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Agent hooks'), findsOneWidget);
  });

  testWidgets('renders a card with source pill, title, body', (tester) async {
    final appState = AppState(client: BackendClient(), deviceId: 'me');
    addTearDown(appState.dispose);
    appState.notifications.onShow(
      _n(
        id: 'n1',
        title: 'Build green',
        source: 'ci:nightly',
        body: 'all 42 checks passed',
        level: NotificationLevel.success,
      ),
    );
    await _pumpCenter(tester, appState);
    expect(find.text('Build green'), findsOneWidget);
    // Source string appears both in the pill on the card and in the
    // filter ChoiceChip row at the top — that's two widgets, both
    // intended. Asserting `findsNWidgets(2)` would be brittle if the row
    // layout changes; `findsAtLeastNWidgets(1)` captures the contract.
    expect(find.text('ci:nightly'), findsAtLeastNWidgets(1));
    // Body is collapsed by default.
    expect(find.text('all 42 checks passed'), findsNothing);
    // Tap to expand.
    await tester.tap(find.text('Build green'));
    await tester.pump();
    expect(find.text('all 42 checks passed'), findsOneWidget);
  });

  testWidgets('terminal action card expands details before opening terminal', (
    tester,
  ) async {
    final appState = AppState(client: BackendClient(), deviceId: 'me');
    addTearDown(appState.dispose);
    appState.notifications.onShow(
      _n(
        id: 'agent-done',
        title: 'Claude finished',
        source: 'claude-code',
        body: 'Changed the Settings tab and all tests passed.',
        fields: const [
          NotificationField(key: 'cwd', value: '/srv/app'),
          NotificationField(key: 'zellij', value: 'claude-main'),
        ],
        action: const OpenTerminalAction(
          sessionId: 'session-1',
          externalSessionId: 'claude-main',
        ),
      ),
    );

    final opened = <OpenTerminalAction>[];
    await _pumpCenter(
      tester,
      appState,
      onOpenTerminal: (action) async {
        opened.add(action);
      },
    );

    expect(
      find.text('Changed the Settings tab and all tests passed.'),
      findsNothing,
    );

    await tester.tap(find.text('Claude finished').last);
    await tester.pump();

    expect(opened, isEmpty);
    expect(
      find.text('Changed the Settings tab and all tests passed.'),
      findsOneWidget,
    );
    expect(find.text('/srv/app'), findsOneWidget);
    expect(find.text('claude-main'), findsAtLeastNWidgets(1));
    expect(
      tester
          .getTopLeft(
            find.widgetWithText(OutlinedButton, 'Open terminal').first,
          )
          .dy,
      lessThan(
        tester
            .getTopLeft(
              find.text('Changed the Settings tab and all tests passed.'),
            )
            .dy,
      ),
    );

    await tester.tap(find.widgetWithText(OutlinedButton, 'Open terminal'));
    await tester.pumpAndSettle();

    expect(opened, hasLength(1));
    expect(opened.single.sessionId, 'session-1');
    expect(opened.single.externalSessionId, 'claude-main');
  });

  testWidgets('replyable notification sends notification.reply', (
    tester,
  ) async {
    final client = _RecordingBackendClient();
    final appState = AppState(client: client, deviceId: 'me');
    addTearDown(appState.dispose);
    appState.notifications.onShow(
      _n(
        id: 'agent-waiting',
        title: 'Agent waiting',
        reply: const NotificationReply(
          target: PluginNotificationReplyTarget(pluginId: 'agent'),
          placeholder: 'Reply to agent',
        ),
      ),
    );

    await _pumpCenter(tester, appState);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Reply'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'continue');
    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await tester.pumpAndSettle();

    final calls = client.calls
        .where((c) => c.method == 'notification.reply')
        .toList();
    expect(calls, hasLength(1));
    expect(calls.single.params, {'id': 'agent-waiting', 'text': 'continue'});
  });

  testWidgets('replyable notification can send dictated reply', (tester) async {
    final client = _RecordingBackendClient();
    final appState = AppState(client: client, deviceId: 'me');
    addTearDown(appState.dispose);
    appState.notifications.onShow(
      _n(
        id: 'agent-waiting',
        title: 'Agent waiting',
        reply: const NotificationReply(
          target: PluginNotificationReplyTarget(pluginId: 'agent'),
          placeholder: 'Reply to agent',
        ),
      ),
    );
    final voice = _FakeVoiceInteraction(recognizedText: 'continue by voice');

    await _pumpCenter(tester, appState, voice: voice);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Reply'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Speak and send'));
    await tester.pumpAndSettle();

    final calls = client.calls
        .where((c) => c.method == 'notification.reply')
        .toList();
    expect(calls, hasLength(1));
    expect(calls.single.params, {
      'id': 'agent-waiting',
      'text': 'continue by voice',
    });
    expect(voice.calls, contains('isSpeechRecognitionAvailable'));
    final cueIndex = voice.calls.indexWhere(
      (call) => call.startsWith('speakAndWait:Listening.'),
    );
    final stopIndex = voice.calls.indexOf('stopSpeaking');
    final recognizeIndex = voice.calls.indexWhere(
      (call) => call.startsWith('recognizeOnce:'),
    );
    expect(cueIndex, isNonNegative);
    expect(stopIndex, greaterThan(cueIndex));
    expect(recognizeIndex, greaterThan(stopIndex));
  });

  testWidgets('dictated notification reply retries network failures offline', (
    tester,
  ) async {
    final client = _RecordingBackendClient();
    final appState = AppState(client: client, deviceId: 'me');
    addTearDown(appState.dispose);
    appState.notifications.onShow(
      _n(
        id: 'agent-waiting',
        title: 'Agent waiting',
        reply: const NotificationReply(
          target: PluginNotificationReplyTarget(pluginId: 'agent'),
          placeholder: 'Reply to agent',
        ),
      ),
    );
    final voice = _FakeVoiceInteraction(
      recognitionResponses: <Object?>[
        PlatformException(
          code: 'NETWORK_TIMEOUT',
          message: 'Speech recognition network error',
        ),
        'continue after retry',
      ],
    );

    await _pumpCenter(tester, appState, voice: voice);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Reply'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Speak and send'));
    await tester.pumpAndSettle();

    expect(
      voice.calls.where((call) => call.startsWith('recognizeOnce:')).toList(),
      <String>[
        'recognizeOnce:Reply to agent:offline=false',
        'recognizeOnce:Reply to agent:offline=true',
      ],
    );
    final calls = client.calls
        .where((c) => c.method == 'notification.reply')
        .toList();
    expect(calls, hasLength(1));
    expect(calls.single.params, {
      'id': 'agent-waiting',
      'text': 'continue after retry',
    });
  });

  testWidgets('confirm-required dictated reply fills text before sending', (
    tester,
  ) async {
    final client = _RecordingBackendClient();
    final appState = AppState(client: client, deviceId: 'me');
    addTearDown(appState.dispose);
    appState.notifications.onShow(
      _n(
        id: 'agent-waiting',
        title: 'Agent waiting',
        reply: const NotificationReply(
          target: PluginNotificationReplyTarget(pluginId: 'agent'),
          placeholder: 'Reply to agent',
          confirmRequired: true,
        ),
      ),
    );
    final voice = _FakeVoiceInteraction(recognizedText: 'review first');

    await _pumpCenter(tester, appState, voice: voice);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Reply'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Speak reply'));
    await tester.pumpAndSettle();

    expect(find.text('review first'), findsOneWidget);
    expect(
      client.calls.where((c) => c.method == 'notification.reply'),
      isEmpty,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await tester.pumpAndSettle();

    final calls = client.calls
        .where((c) => c.method == 'notification.reply')
        .toList();
    expect(calls, hasLength(1));
    expect(calls.single.params, {
      'id': 'agent-waiting',
      'text': 'review first',
    });
  });

  testWidgets('dictated notification reply reports unavailable recognition', (
    tester,
  ) async {
    final client = _RecordingBackendClient();
    final appState = AppState(client: client, deviceId: 'me');
    addTearDown(appState.dispose);
    appState.notifications.onShow(
      _n(
        id: 'agent-waiting',
        title: 'Agent waiting',
        reply: const NotificationReply(
          target: PluginNotificationReplyTarget(pluginId: 'agent'),
          placeholder: 'Reply to agent',
        ),
      ),
    );
    final voice = _FakeVoiceInteraction(
      recognizedText: 'ignored',
      speechRecognitionAvailable: false,
    );

    await _pumpCenter(tester, appState, voice: voice);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Reply'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Speak and send'));
    await tester.pumpAndSettle();

    expect(
      find.text('Speech recognition is not available on this device'),
      findsOneWidget,
    );
    expect(
      client.calls.where((c) => c.method == 'notification.reply'),
      isEmpty,
    );
    expect(
      voice.calls.where((call) => call.startsWith('recognizeOnce:')),
      isEmpty,
    );
  });

  testWidgets('filter pill narrows the list', (tester) async {
    final appState = AppState(client: BackendClient(), deviceId: 'me');
    addTearDown(appState.dispose);
    appState.notifications.onShow(_n(id: '1', title: 'CI msg', source: 'ci'));
    appState.notifications.onShow(
      _n(id: '2', title: 'Claude msg', source: 'claude'),
    );
    await _pumpCenter(tester, appState);
    expect(find.text('CI msg'), findsOneWidget);
    expect(find.text('Claude msg'), findsOneWidget);
    // Tap the 'ci' pill.
    await tester.tap(find.widgetWithText(ChoiceChip, 'ci'));
    await tester.pump();
    expect(find.text('CI msg'), findsOneWidget);
    expect(find.text('Claude msg'), findsNothing);
  });

  testWidgets('bell icon shows badge when unread > 0', (tester) async {
    final appState = AppState(client: BackendClient(), deviceId: 'me');
    addTearDown(appState.dispose);
    appState.notifications.onShow(_n(id: '1', title: 'first'));
    appState.notifications.onShow(_n(id: '2', title: 'second'));
    expect(appState.notifications.unreadCount, 2);

    // Render the bare bell + badge harness rather than HomeShell (which
    // would need a fully-wired SettingsStore). The badge widget itself is
    // what the assertion targets.
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          useMaterial3: true,
        ),
        home: Scaffold(
          appBar: AppBar(
            actions: [
              IconButton(
                icon: appState.notifications.unreadCount > 0
                    ? Badge.count(
                        count: appState.notifications.unreadCount,
                        child: const Icon(Icons.notifications_outlined),
                      )
                    : const Icon(Icons.notifications_outlined),
                onPressed: () {},
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.byType(Badge), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('highlighted open-terminal notification runs terminal opener', (
    tester,
  ) async {
    final appState = AppState(client: BackendClient(), deviceId: 'me');
    addTearDown(appState.dispose);
    appState.notifications.onShow(
      _n(
        id: 'term-ready',
        title: 'Terminal finished',
        action: const OpenTerminalAction(
          sessionId: 'session-1',
          externalSessionId: 'aoy',
        ),
      ),
    );

    final opened = <OpenTerminalAction>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          useMaterial3: true,
        ),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => NotificationCenterScreen(
                    appState: appState,
                    highlightId: 'term-ready',
                    onOpenTerminal: (action) async {
                      opened.add(action);
                    },
                  ),
                ),
              );
            },
            child: const Text('Open center'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open center'));
    await tester.pumpAndSettle();

    expect(opened, hasLength(1));
    expect(opened.single.sessionId, 'session-1');
    expect(opened.single.externalSessionId, 'aoy');
  });

  testWidgets('highlighted copy notification waits for explicit tap', (
    tester,
  ) async {
    final appState = AppState(client: BackendClient(), deviceId: 'me');
    addTearDown(appState.dispose);
    appState.notifications.onShow(
      _n(
        id: 'copy-ready',
        title: 'Copy deploy command',
        action: const CopyAction('deploy --confirm'),
      ),
    );
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final args = call.arguments as Map<Object?, Object?>;
          copiedText = args['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          useMaterial3: true,
        ),
        home: NotificationCenterScreen(
          appState: appState,
          highlightId: 'copy-ready',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(copiedText, isNull);
    expect(find.text('Copy deploy command'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Copy'));
    await tester.pump();

    expect(copiedText, 'deploy --confirm');
  });

  testWidgets('grouped notification exposes newest open-terminal action', (
    tester,
  ) async {
    final appState = AppState(client: BackendClient(), deviceId: 'me');
    addTearDown(appState.dispose);
    final now = DateTime.now().millisecondsSinceEpoch;
    appState.notifications.onShow(
      _n(
        id: 'older-finish',
        title: 'Previous agent run finished',
        groupKey: 'agent:session-1',
        ts: now - 1000,
      ),
    );
    appState.notifications.onShow(
      _n(
        id: 'newer-finish',
        title: 'Latest agent run finished',
        groupKey: 'agent:session-1',
        ts: now,
        action: const OpenTerminalAction(
          sessionId: 'session-1',
          externalSessionId: 'claude',
        ),
      ),
    );

    final opened = <OpenTerminalAction>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          useMaterial3: true,
        ),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => NotificationCenterScreen(
                    appState: appState,
                    onOpenTerminal: (action) async {
                      opened.add(action);
                    },
                  ),
                ),
              );
            },
            child: const Text('Open center'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open center'));
    await tester.pumpAndSettle();

    expect(find.text('Latest agent run finished'), findsAtLeastNWidgets(1));
    expect(find.text('x2'), findsOneWidget);
    final actionButton = find.widgetWithText(OutlinedButton, 'Open terminal');
    expect(actionButton, findsOneWidget);

    await tester.tap(actionButton);
    await tester.pumpAndSettle();

    expect(opened, hasLength(1));
    expect(opened.single.sessionId, 'session-1');
    expect(opened.single.externalSessionId, 'claude');
  });

  testWidgets('terminal action grouping collapses separate agent runs', (
    tester,
  ) async {
    final appState = AppState(client: BackendClient(), deviceId: 'me');
    addTearDown(appState.dispose);
    final now = DateTime.now().millisecondsSinceEpoch;
    appState.notifications.onShow(
      _n(
        id: 'run-a',
        title: 'Claude run A finished',
        source: 'claude-code',
        groupKey: 'claude-code:agent-session-a',
        ts: now - 1000,
        action: const OpenTerminalAction(
          backendId: 'backend-a',
          externalSessionId: 'aoy',
        ),
      ),
    );
    appState.notifications.onShow(
      _n(
        id: 'run-b',
        title: 'Claude run B finished',
        source: 'claude-code',
        groupKey: 'claude-code:agent-session-b',
        ts: now,
        action: const OpenTerminalAction(
          backendId: 'backend-a',
          externalSessionId: 'aoy',
        ),
      ),
    );

    final opened = <OpenTerminalAction>[];
    await _pumpCenter(
      tester,
      appState,
      onOpenTerminal: (action) async {
        opened.add(action);
      },
    );

    expect(find.text('Claude run B finished'), findsAtLeastNWidgets(1));
    expect(find.text('Claude run A finished'), findsNothing);
    expect(find.text('x2'), findsOneWidget);
    expect(
      find.widgetWithText(OutlinedButton, 'Open terminal'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(OutlinedButton, 'Open terminal'));
    await tester.pumpAndSettle();

    expect(opened, hasLength(1));
    expect(opened.single.backendId, 'backend-a');
    expect(opened.single.externalSessionId, 'aoy');
  });

  testWidgets(
    'collapsed groups mark only the newest visible notification read',
    (tester) async {
      tester.view.physicalSize = const Size(390, 620);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final client = _RecordingBackendClient();
      final appState = AppState(client: client, deviceId: 'me');
      addTearDown(appState.dispose);
      final now = DateTime.now().millisecondsSinceEpoch;
      appState.notifications.onShow(
        _n(
          id: 'run-a',
          title: 'Claude run A finished',
          source: 'claude-code',
          groupKey: 'claude-code:agent-session-a',
          ts: now - 1000,
          action: const OpenTerminalAction(
            backendId: 'backend-a',
            externalSessionId: 'aoy',
          ),
        ),
      );
      appState.notifications.onShow(
        _n(
          id: 'run-b',
          title: 'Claude run B finished',
          source: 'claude-code',
          groupKey: 'claude-code:agent-session-b',
          ts: now,
          action: const OpenTerminalAction(
            backendId: 'backend-a',
            externalSessionId: 'aoy',
          ),
        ),
      );

      await _pumpCenter(tester, appState);
      await tester.pump(const Duration(milliseconds: 650));

      final markReadCalls = client.calls
          .where((c) => c.method == 'notification.markRead')
          .toList();
      expect(markReadCalls, isNotEmpty);
      final markedIds = <String>{
        for (final c in markReadCalls)
          ...((c.params?['ids'] as List?) ?? const []).whereType<String>(),
      };

      expect(markedIds, contains('run-b'));
      expect(markedIds, isNot(contains('run-a')));
      expect(appState.notifications.isRead('run-b'), isTrue);
      expect(appState.notifications.isRead('run-a'), isFalse);
    },
  );

  testWidgets('expanded groups mark visible historical notifications read', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final client = _RecordingBackendClient();
    final appState = AppState(client: client, deviceId: 'me');
    addTearDown(appState.dispose);
    final now = DateTime.now().millisecondsSinceEpoch;
    appState.notifications.onShow(
      _n(
        id: 'run-a',
        title: 'Claude run A finished',
        source: 'claude-code',
        groupKey: 'claude-code:agent-session-a',
        ts: now - 1000,
        action: const OpenTerminalAction(
          backendId: 'backend-a',
          externalSessionId: 'aoy',
        ),
      ),
    );
    appState.notifications.onShow(
      _n(
        id: 'run-b',
        title: 'Claude run B finished',
        source: 'claude-code',
        groupKey: 'claude-code:agent-session-b',
        ts: now,
        action: const OpenTerminalAction(
          backendId: 'backend-a',
          externalSessionId: 'aoy',
        ),
      ),
    );

    await _pumpCenter(tester, appState);
    await tester.pump(const Duration(milliseconds: 650));

    expect(appState.notifications.isRead('run-b'), isTrue);
    expect(appState.notifications.isRead('run-a'), isFalse);
    client.calls.clear();

    await tester.tap(find.text('x2'));
    await tester.pump();
    expect(find.text('Claude run A finished'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 650));

    final markReadCalls = client.calls
        .where((c) => c.method == 'notification.markRead')
        .toList();
    expect(markReadCalls, isNotEmpty);
    final markedIds = <String>{
      for (final c in markReadCalls)
        ...((c.params?['ids'] as List?) ?? const []).whereType<String>(),
    };

    expect(markedIds, contains('run-a'));
    expect(appState.notifications.isRead('run-a'), isTrue);
  });

  testWidgets('expanded large groups leave offscreen history unread', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final client = _RecordingBackendClient();
    final appState = AppState(client: client, deviceId: 'me');
    addTearDown(appState.dispose);
    final now = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < 14; i++) {
      appState.notifications.onShow(
        _n(
          id: 'run-$i',
          title: 'Claude run $i finished',
          source: 'claude-code',
          groupKey: 'claude-code:agent-session-a',
          ts: now + i,
        ),
      );
    }

    await _pumpCenter(tester, appState);
    await tester.pump(const Duration(milliseconds: 650));

    expect(appState.notifications.isRead('run-13'), isTrue);
    expect(appState.notifications.isRead('run-12'), isFalse);
    expect(appState.notifications.isRead('run-0'), isFalse);
    client.calls.clear();

    await tester.tap(find.text('x14'));
    await tester.pump();
    expect(find.text('Claude run 12 finished'), findsOneWidget);
    expect(find.text('Claude run 0 finished'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 650));

    final markReadCalls = client.calls
        .where((c) => c.method == 'notification.markRead')
        .toList();
    expect(markReadCalls, isNotEmpty);
    final markedIds = <String>{
      for (final c in markReadCalls)
        ...((c.params?['ids'] as List?) ?? const []).whereType<String>(),
    };

    expect(markedIds, contains('run-12'));
    expect(markedIds, isNot(contains('run-0')));
    expect(appState.notifications.isRead('run-12'), isTrue);
    expect(appState.notifications.isRead('run-0'), isFalse);
  });

  testWidgets('agent session strip groups terminal actions and opens latest', (
    tester,
  ) async {
    final appState = AppState(client: BackendClient(), deviceId: 'me');
    addTearDown(appState.dispose);
    final now = DateTime.now().millisecondsSinceEpoch;
    appState.notifications.onShow(
      _n(
        id: 'agent-older',
        title: 'Previous agent run finished',
        source: 'claude',
        ts: now - 1000,
        action: const OpenTerminalAction(
          sessionId: 'session-1',
          backendId: 'backend-a',
          externalSessionId: 'claude-main',
        ),
      ),
    );
    appState.notifications.onShow(
      _n(
        id: 'agent-newer',
        title: 'Latest agent run finished',
        source: 'claude',
        ts: now,
        action: const OpenTerminalAction(
          sessionId: 'session-1',
          backendId: 'backend-a',
          externalSessionId: 'claude-main',
        ),
      ),
    );

    final opened = <OpenTerminalAction>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          useMaterial3: true,
        ),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => NotificationCenterScreen(
                    appState: appState,
                    onOpenTerminal: (action) async {
                      opened.add(action);
                    },
                  ),
                ),
              );
            },
            child: const Text('Open center'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open center'));
    await tester.pumpAndSettle();

    expect(find.text('Agent sessions'), findsOneWidget);
    expect(find.text('claude-main'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);

    await tester.tap(
      find.byKey(
        const ValueKey<String>('agent-session:backend-a|session-1|claude-main'),
      ),
    );
    await tester.pumpAndSettle();

    expect(opened, hasLength(1));
    expect(opened.single.sessionId, 'session-1');
    expect(opened.single.backendId, 'backend-a');
    expect(opened.single.externalSessionId, 'claude-main');
  });

  testWidgets('agent session strip handles external-only terminal actions', (
    tester,
  ) async {
    final appState = AppState(client: BackendClient(), deviceId: 'me');
    addTearDown(appState.dispose);
    appState.notifications.onShow(
      _n(
        id: 'agent-external-only',
        title: 'External agent run finished',
        source: 'codex',
        action: const OpenTerminalAction(
          backendId: 'backend-a',
          externalSessionId: 'zellij-external-only',
        ),
      ),
    );

    final opened = <OpenTerminalAction>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          useMaterial3: true,
        ),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => NotificationCenterScreen(
                    appState: appState,
                    onOpenTerminal: (action) async {
                      opened.add(action);
                    },
                  ),
                ),
              );
            },
            child: const Text('Open center'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open center'));
    await tester.pumpAndSettle();

    expect(find.text('Agent sessions'), findsOneWidget);
    expect(find.text('zellij-external-only'), findsOneWidget);

    await tester.tap(
      find.byKey(
        const ValueKey<String>('agent-session:backend-a||zellij-external-only'),
      ),
    );
    await tester.pumpAndSettle();

    expect(opened, hasLength(1));
    expect(opened.single.sessionId, isNull);
    expect(opened.single.backendId, 'backend-a');
    expect(opened.single.externalSessionId, 'zellij-external-only');
  });

  testWidgets('opening the center only marks rendered visible cards as read', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final client = _RecordingBackendClient();
    final appState = AppState(client: client, deviceId: 'me');
    addTearDown(appState.dispose);

    final now = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < 18; i++) {
      appState.notifications.onShow(
        _n(
          id: 'n$i',
          title: 'Notification $i',
          source: 'ci',
          ts: now - i,
          body: 'body $i',
        ),
      );
    }

    await _pumpCenter(tester, appState);
    await tester.pump(const Duration(milliseconds: 650));

    final markReadCalls = client.calls
        .where((c) => c.method == 'notification.markRead')
        .toList();
    expect(markReadCalls, isNotEmpty);
    final markedIds = <String>{
      for (final c in markReadCalls)
        ...((c.params?['ids'] as List?) ?? const []).whereType<String>(),
    };

    expect(markedIds, contains('n0'));
    expect(markedIds, isNot(contains('n17')));
    expect(appState.notifications.isRead('n0'), isTrue);
    expect(appState.notifications.isRead('n17'), isFalse);
  });
}
