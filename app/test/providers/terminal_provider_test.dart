import 'package:flutter_test/flutter_test.dart';
import 'package:vscode_mobile/models/terminal_session.dart';
import 'package:vscode_mobile/providers/terminal_provider.dart';

import '../test_support/terminal_test_helpers.dart';

void main() {
  group('TerminalProvider', () {
    late FakeTerminalApiClient apiClient;
    late TerminalProvider provider;

    setUp(() {
      apiClient = FakeTerminalApiClient(
        seedSessions: <TerminalSession>[
          terminalSession(id: 'term-1', name: 'Alpha'),
          terminalSession(id: 'term-2', name: 'Beta'),
        ],
      );
      provider = TerminalProvider(apiClient: apiClient);
      provider.configure(
        baseUrl: 'http://server.test',
        token: 'secret',
        workDir: '/workspace',
      );
    });

    tearDown(() async {
      provider.dispose();
      await apiClient.disposeFakes();
    });

    test('bootstraps sessions and connects bridge events', () async {
      await provider.ensureInitialized();

      expect(provider.hasLoaded, isTrue);
      expect(provider.sessions.map((view) => view.session.id), [
        'term-1',
        'term-2',
      ]);
      expect(provider.activeSessionId, 'term-1');
      expect(apiClient.connectEventsCalls, 1);
      expect(apiClient.attachCalls, ['term-1']);
    });

    test('switching sessions preserves buffered output history', () async {
      await provider.ensureInitialized();

      apiClient
          .socketFor('term-1')
          .serverReady(apiClient.sessionsById['term-1']);
      apiClient.socketFor('term-1').serverOutput('alpha output\n');
      await pumpMicrotasks();

      await provider.activateSession('term-2');
      apiClient
          .socketFor('term-2')
          .serverReady(apiClient.sessionsById['term-2']);
      apiClient.socketFor('term-2').serverOutput('beta output\n');
      await pumpMicrotasks();

      await provider.activateSession('term-1');
      await pumpMicrotasks();

      expect(
        provider.sessionFor('term-1')!.outputText,
        contains('alpha output'),
      );
      expect(
        provider.sessionFor('term-2')!.outputText,
        contains('beta output'),
      );
      expect(apiClient.attachCalls, containsAll(<String>['term-1', 'term-2']));
    });

    test(
      'rename split exited persistence and explicit close update provider state',
      () async {
        await provider.ensureInitialized();

        await provider.renameSession('term-1', 'Primary');
        expect(provider.sessionFor('term-1')!.session.name, 'Primary');

        await provider.splitSession('term-1');
        final splitId = provider.secondarySessionId;
        expect(splitId, isNotNull);
        expect(provider.splitViewEnabled, isTrue);

        apiClient.emitEvent(
          'terminal/sessionUpdated',
          sessionToJson(
            terminalSession(
              id: splitId!,
              name: 'Primary split',
              state: 'exited',
              exitCode: 9,
            ),
          ),
        );
        await pumpMicrotasks();

        final exited = provider.sessionFor(splitId)!;
        expect(exited.session.isExited, isTrue);
        expect(exited.session.exitCode, 9);
        expect(exited.statusLabel, 'Exited (9)');

        await provider.closeSession(splitId);
        expect(provider.sessionFor(splitId), isNull);
      },
    );

    test(
      'refresh re-attaches existing sessions instead of creating duplicates',
      () async {
        await provider.ensureInitialized();
        apiClient
            .socketFor('term-1')
            .serverReady(apiClient.sessionsById['term-1']);
        apiClient.socketFor('term-1').serverOutput('persisted\n');
        await pumpMicrotasks();

        await provider.refreshSessions();

        expect(provider.sessions, hasLength(2));
        expect(
          provider.sessionFor('term-1')!.outputText,
          contains('persisted'),
        );
        expect(
          apiClient.attachCalls.where((id) => id == 'term-1').length,
          greaterThanOrEqualTo(1),
        );
      },
    );
  });
}
