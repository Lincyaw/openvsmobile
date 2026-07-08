import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/app_state.dart';
import 'package:mobilecode/backend_client.dart';
import 'package:mobilecode/screens/agent_hooks_screen.dart';

class _FakeBackendClient extends BackendClient {
  final List<String> calls = [];

  _FakeBackendClient() {
    state.value = BackendConnectionState.connected;
  }

  @override
  Future<dynamic> call(String method, [Map<String, dynamic>? params]) async {
    calls.add(method);
    if (method == 'notification.agentHookStatus') {
      return <String, dynamic>{
        'ok': true,
        'exitCode': 0,
        'statuses': [
          {
            'agent': 'claude-code',
            'state': 'current',
            'message': 'Claude Code Stop hook already current',
            'available': true,
            'changed': false,
          },
          {
            'agent': 'codex',
            'state': 'current',
            'message': 'Codex Stop hook plugin already current',
            'available': true,
            'changed': false,
          },
        ],
        'stdout': '',
        'stderr': '[agent-hooks] checked',
      };
    }
    if (method == 'notification.installAgentHooks') {
      return <String, dynamic>{
        'ok': true,
        'exitCode': 0,
        'statuses': [
          {
            'agent': 'claude-code',
            'state': 'installed',
            'message': 'installed Claude Code Stop hook',
            'available': true,
            'changed': true,
          },
          {
            'agent': 'codex',
            'state': 'missing',
            'message': 'Codex config not found; skipping',
            'available': false,
            'changed': false,
          },
        ],
        'stdout': '',
        'stderr': '[agent-hooks] done',
      };
    }
    if (method == 'auth.publishTokens.list') {
      return <String, dynamic>{
        'items': [
          {
            'id': 'tok_agent',
            'label': 'agent hooks',
            'sourcePrefix': 'agent',
            'rateLimitPerMin': 6,
            'rateLimitPerHour': 60,
            'createdAt': 2000,
            'lastUsedAt': null,
            'revokedAt': null,
          },
        ],
      };
    }
    return <String, dynamic>{};
  }
}

class _LegacyHookStatusClient extends BackendClient {
  final List<String> calls = [];

  _LegacyHookStatusClient() {
    state.value = BackendConnectionState.connected;
  }

  @override
  Future<dynamic> call(String method, [Map<String, dynamic>? params]) async {
    calls.add(method);
    if (method == 'notification.agentHookStatus') {
      throw BackendRpcException(-32601, 'unknown method');
    }
    if (method == 'auth.publishTokens.list') {
      return <String, dynamic>{
        'items': [
          {
            'id': 'tok_agent',
            'label': 'agent hooks',
            'sourcePrefix': 'agent',
            'rateLimitPerMin': 6,
            'rateLimitPerHour': 60,
            'createdAt': 2000,
            'lastUsedAt': null,
            'revokedAt': null,
          },
        ],
      };
    }
    return <String, dynamic>{};
  }
}

void main() {
  testWidgets('installs hooks through AppState and renders statuses', (
    tester,
  ) async {
    final client = _FakeBackendClient();
    final appState = AppState(client: client);
    addTearDown(appState.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          useMaterial3: true,
        ),
        home: AgentHooksScreen(appState: appState),
      ),
    );

    await tester.pumpAndSettle();
    expect(client.calls, contains('notification.agentHookStatus'));
    expect(
      find.byKey(const ValueKey<String>('agent-hooks-summary')),
      findsOneWidget,
    );
    expect(find.text('Agent alerts ready'), findsOneWidget);
    expect(find.text('Hooks current'), findsWidgets);
    expect(find.text('1 token'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('agent-hooks-install-tile')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Install hooks'));
    await tester.pumpAndSettle();

    expect(client.calls, contains('notification.installAgentHooks'));
    expect(find.text('Hook scan needs attention'), findsNothing);
    expect(
      find.text('1 agent config updated; Codex not found'),
      findsOneWidget,
    );
    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.text('Installed'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Config not found'), findsOneWidget);
    expect(find.text('Installer log'), findsOneWidget);
  });

  testWidgets('opens publish token management from setup panel', (
    tester,
  ) async {
    final client = _FakeBackendClient();
    final appState = AppState(client: client);
    addTearDown(appState.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          useMaterial3: true,
        ),
        home: AgentHooksScreen(appState: appState),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Webhook tokens'), findsOneWidget);
    expect(find.text('1 webhook token ready'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('agent-hooks-token-tile')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Webhook tokens'), findsOneWidget);
    expect(client.calls, contains('auth.publishTokens.list'));
  });

  testWidgets('falls back gracefully when status RPC is unavailable', (
    tester,
  ) async {
    final client = _LegacyHookStatusClient();
    final appState = AppState(client: client);
    addTearDown(appState.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          useMaterial3: true,
        ),
        home: AgentHooksScreen(appState: appState),
      ),
    );
    await tester.pumpAndSettle();

    expect(client.calls, contains('notification.agentHookStatus'));
    expect(find.text('Agent alerts need backend update'), findsOneWidget);
    expect(find.text('Cannot scan'), findsOneWidget);
    expect(find.text('Update first'), findsNothing);
    expect(find.text('1 token'), findsOneWidget);
    expect(find.text('1 webhook token ready'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Update backend'), findsNothing);
    expect(find.text('Backend update required'), findsOneWidget);
    expect(
      find.text('This backend is too old for agent hook setup'),
      findsOneWidget,
    );
    expect(find.text('Last scan failed'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('agent-hooks-install-tile')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();

    expect(find.text('Install backend via SSH'), findsNothing);
    expect(find.byType(AgentHooksScreen), findsOneWidget);
  });
}
