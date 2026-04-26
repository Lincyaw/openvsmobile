import 'dart:convert';

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

    test('bootstraps sessions for the active workspace', () async {
      await provider.ensureInitialized();

      expect(provider.hasLoaded, isTrue);
      expect(provider.sessions.map((view) => view.session.id), [
        'term-1',
        'term-2',
      ]);
      expect(provider.activeSessionId, 'term-1');
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

        // The provider no longer owns the bridge events socket; app.dart now
        // routes terminal.session.* events through refreshSessions(). Simulate
        // the server reporting an exited split by mutating the fake inventory
        // and asking the provider to re-sync.
        apiClient.sessionsById[splitId!] = terminalSession(
          id: splitId,
          name: 'Primary split',
          state: 'exited',
          exitCode: 9,
        );
        await provider.refreshSessions();

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

    test(
      'writes emulator-generated responses back to the terminal websocket',
      () async {
        await provider.ensureInitialized();

        final socket = apiClient.socketFor('term-1');
        socket.serverReady(apiClient.sessionsById['term-1']);
        socket.serverOutput('\u001b[6n');
        await pumpMicrotasks();

        final payloads = socket.sink.sentMessages.cast<String>().toList(
          growable: false,
        );
        final last = jsonDecode(payloads.last) as Map<String, dynamic>;
        expect(last['type'], 'input');
        expect(utf8.decode(base64Decode(last['data'] as String)), '\x1B[1;1R');
      },
    );

    test(
      'replay frames replace local emulator state without emitting responses',
      () async {
        await provider.ensureInitialized();

        final socket = apiClient.socketFor('term-1');
        socket.serverReady(apiClient.sessionsById['term-1']);
        socket.serverOutput('stale-output\r\n');
        await pumpMicrotasks();

        final beforeReplayMessages = socket.sink.sentMessages.length;
        socket.serverSend(<String, dynamic>{
          'type': 'replay',
          'data': base64Encode(utf8.encode('\u001b[6nrestored-state\r\n')),
        });
        await pumpMicrotasks();

        expect(
          provider.sessionFor('term-1')!.outputText,
          contains('restored-state'),
        );
        expect(
          provider.sessionFor('term-1')!.outputText,
          isNot(contains('stale-output')),
        );
        expect(socket.sink.sentMessages.length, beforeReplayMessages);
      },
    );

    test('alternate-screen replay requests a redraw after attach', () async {
      await provider.ensureInitialized();

      final socket = apiClient.socketFor('term-1');
      socket.serverReady(apiClient.sessionsById['term-1']);
      final beforeReplayMessages = socket.sink.sentMessages.length;
      socket.serverSend(<String, dynamic>{
        'type': 'replay',
        'data': base64Encode(
          utf8.encode('\u001b[?1049h\u001b[2J\u001b[Hrestored-tui'),
        ),
      });
      await pumpMicrotasks();

      expect(socket.sink.sentMessages.length, beforeReplayMessages + 1);
      final redrawPayload =
          jsonDecode(socket.sink.sentMessages.last as String)
              as Map<String, dynamic>;
      expect(redrawPayload['type'], 'input');
      expect(
        utf8.decode(base64Decode(redrawPayload['data'] as String)),
        '\x0C',
      );
    });

    test('zellij startup fixture replay restores the welcome screen', () async {
      await provider.ensureInitialized();

      final socket = apiClient.socketFor('term-1');
      socket.serverReady(apiClient.sessionsById['term-1']);
      final beforeReplayMessages = socket.sink.sentMessages.length;
      socket.serverSend(<String, dynamic>{
        'type': 'replay',
        'data': base64Encode(decodeTerminalFixture('zellij_startup.base64')),
      });
      await pumpMicrotasks();

      final session = provider.sessionFor('term-1')!;
      expect(session.snapshot.isAlternateBuffer, isTrue);
      expect(session.outputText, contains('Zellij'));
      expect(socket.sink.sentMessages.length, beforeReplayMessages + 1);
    });

    test(
      'vim fixture replay lands back on the shell backlog without redraw',
      () async {
        await provider.ensureInitialized();

        final socket = apiClient.socketFor('term-1');
        socket.serverReady(apiClient.sessionsById['term-1']);
        final beforeReplayMessages = socket.sink.sentMessages.length;
        socket.serverSend(<String, dynamic>{
          'type': 'replay',
          'data': base64Encode(decodeTerminalFixture('vim_edit_exit.base64')),
        });
        await pumpMicrotasks();

        final session = provider.sessionFor('term-1')!;
        expect(session.snapshot.isAlternateBuffer, isFalse);
        expect(session.outputText, contains('saved notes.txt'));
        expect(socket.sink.sentMessages.length, beforeReplayMessages);
      },
    );

    test('resizing an alternate-screen session requests a redraw', () async {
      await provider.ensureInitialized();

      final socket = apiClient.socketFor('term-1');
      socket.serverReady(apiClient.sessionsById['term-1']);
      socket.serverSend(<String, dynamic>{
        'type': 'replay',
        'data': base64Encode(
          utf8.encode('\u001b[?1049h\u001b[2J\u001b[Halt-screen'),
        ),
      });
      await pumpMicrotasks();

      final beforeResizeMessages = socket.sink.sentMessages.length;
      await provider.resizeSession('term-1', 43, 52);

      expect(provider.sessionFor('term-1')!.session.rows, 43);
      expect(provider.sessionFor('term-1')!.session.cols, 52);
      expect(socket.sink.sentMessages.length, beforeResizeMessages + 1);

      final redrawPayload =
          jsonDecode(socket.sink.sentMessages.last as String)
              as Map<String, dynamic>;
      expect(redrawPayload['type'], 'input');
      expect(
        utf8.decode(base64Decode(redrawPayload['data'] as String)),
        '\x0C',
      );
    });

    test('pinning a session moves it to the front of the list', () async {
      await provider.ensureInitialized();

      expect(provider.sessions.map((view) => view.session.id).toList(), [
        'term-1',
        'term-2',
      ]);

      provider.togglePinned('term-2');

      expect(provider.sessions.map((view) => view.session.id).toList(), [
        'term-2',
        'term-1',
      ]);
      expect(provider.isPinned('term-2'), isTrue);

      provider.togglePinned('term-2');

      expect(provider.isPinned('term-2'), isFalse);
      expect(provider.sessions.map((view) => view.session.id).toList(), [
        'term-1',
        'term-2',
      ]);
    });
  });
}
