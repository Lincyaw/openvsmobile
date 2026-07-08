import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/app_state.dart';
import 'package:mobilecode/backend_client.dart';
import 'package:mobilecode/screens/webhook_tokens_screen.dart';

class _FakePublishTokenClient extends BackendClient {
  final List<({String method, Map<String, dynamic>? params})> calls = [];
  final List<Map<String, dynamic>> items = [];

  _FakePublishTokenClient({bool connected = true}) {
    if (connected) state.value = BackendConnectionState.connected;
  }

  @override
  Future<dynamic> call(String method, [Map<String, dynamic>? params]) async {
    calls.add((method: method, params: params));
    switch (method) {
      case 'auth.publishTokens.list':
        return {'items': items};
      case 'auth.publishTokens.create':
        final id = 'abc123abc123';
        final record = {
          'id': id,
          'label': params!['label'],
          'sourcePrefix': params['sourcePrefix'],
          'rateLimitPerMin': params['rateLimitPerMin'],
          'rateLimitPerHour': params['rateLimitPerHour'],
          'createdAt': 2000,
          'lastUsedAt': null,
          'revokedAt': null,
        };
        items.add(record);
        return {'record': record, 'secret': '$id.${'b' * 64}'};
      default:
        throw StateError('unexpected method $method');
    }
  }
}

void _mockClipboard(WidgetTester tester, void Function(String? text) onCopy) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        final args = call.arguments as Map<Object?, Object?>;
        onCopy(args['text'] as String?);
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
}

Future<void> _pump(WidgetTester tester, AppState appState) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: WebhookTokensScreen(appState: appState),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('offline state defers loading and disables token creation', (
    tester,
  ) async {
    final client = _FakePublishTokenClient(connected: false);
    final appState = AppState(client: client);
    addTearDown(appState.dispose);

    await _pump(tester, appState);

    expect(client.calls, isEmpty);
    expect(find.text('Backend offline'), findsOneWidget);
    expect(
      find.text('Connect to a backend to manage webhook tokens.'),
      findsOneWidget,
    );

    await tester.tap(find.text('New token'));
    await tester.pumpAndSettle();

    expect(find.text('New webhook token'), findsNothing);
    expect(client.calls, isEmpty);

    client.state.value = BackendConnectionState.connected;
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      client.calls.map((c) => c.method),
      contains('auth.publishTokens.list'),
    );
    expect(
      client.calls.map((c) => c.method),
      isNot(contains('auth.publishTokens.create')),
    );
    expect(find.text('Create a publish token'), findsOneWidget);
  });

  testWidgets('creates a token through AppState and shows agent CLI snippet', (
    tester,
  ) async {
    final client = _FakePublishTokenClient();
    final appState = AppState(client: client);
    addTearDown(appState.dispose);
    String? copiedText;
    _mockClipboard(tester, (text) => copiedText = text);

    await _pump(tester, appState);

    expect(find.text('Create a publish token'), findsOneWidget);

    await tester.tap(find.text('New token'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), 'claude-code');
    await tester.enterText(find.byType(TextField).at(1), 'claude-code');
    await tester.tap(find.text('Mint token'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('abc123abc123.'), findsAtLeastNWidgets(1));
    expect(find.textContaining('mobile-notify --token'), findsNWidgets(2));
    expect(find.textContaining('--from-agent-hook'), findsOneWidget);

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -900),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byTooltip('Copy agent hook command'), findsOneWidget);
    await tester.tap(find.byTooltip('Copy agent hook command'));
    await tester.pump();

    expect(copiedText, contains('mobile-notify --token abc123abc123.'));
    expect(copiedText, contains('--source claude-code'));
    expect(copiedText, contains('--from-agent-hook'));

    expect(
      client.calls.map((c) => c.method),
      containsAllInOrder([
        'auth.publishTokens.list',
        'auth.publishTokens.create',
      ]),
    );
  });

  testWidgets(
    'unrestricted token shows separate Claude and Codex hook commands',
    (tester) async {
      final client = _FakePublishTokenClient();
      final appState = AppState(client: client);
      addTearDown(appState.dispose);
      String? copiedText;
      _mockClipboard(tester, (text) => copiedText = text);

      await _pump(tester, appState);

      await tester.tap(find.text('New token'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(0), 'terminal agents');
      await tester.tap(find.text('Mint token'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -900),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Claude Code hook CLI:'), findsOneWidget);
      expect(find.text('Codex hook CLI:'), findsOneWidget);
      expect(find.byTooltip('Copy Claude Code hook command'), findsOneWidget);
      expect(find.byTooltip('Copy Codex hook command'), findsOneWidget);
      expect(find.byTooltip('Copy agent hook command'), findsNothing);

      await tester.tap(find.byTooltip('Copy Claude Code hook command'));
      await tester.pump();
      expect(copiedText, contains('--source claude-code'));
      expect(copiedText, contains('--from-agent-hook'));

      await tester.tap(find.byTooltip('Copy Codex hook command'));
      await tester.pump();
      expect(copiedText, contains('--source codex'));
      expect(copiedText, contains('--from-agent-hook'));
    },
  );
}
