import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vscode_mobile/models/terminal_session.dart';
import 'package:vscode_mobile/providers/terminal_provider.dart';
import 'package:vscode_mobile/screens/terminal_screen.dart';

import '../test_support/terminal_test_helpers.dart';

void main() {
  group('TerminalScreen', () {
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

    Future<void> pumpScreen(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: TerminalScreen(
            baseUrl: 'http://server.test',
            token: 'secret',
            workDir: '/workspace',
            isActive: true,
            provider: provider,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('renders session management affordances on wide layouts', (
      tester,
    ) async {
      await provider.ensureInitialized();
      provider.setSplitViewEnabled(true);
      await provider.activateSession('term-2', openInSecondary: true);

      await pumpScreen(tester, const Size(1200, 900));

      expect(find.text('Terminal Sessions'), findsOneWidget);
      expect(find.byTooltip('Create session'), findsOneWidget);
      expect(find.byTooltip('Refresh sessions'), findsOneWidget);
      expect(find.byTooltip('Split active session'), findsOneWidget);
      expect(find.text('Alpha'), findsWidgets);
      expect(find.text('Beta'), findsWidgets);
      expect(find.text('Primary'), findsOneWidget);
      expect(find.text('Split'), findsOneWidget);
    });

    testWidgets('shows explicit reconnecting and exited states', (
      tester,
    ) async {
      await provider.ensureInitialized();
      final active = provider.sessionFor('term-1')!;
      active.connectionState = TerminalConnectionState.reconnecting;
      final exited = terminalSession(
        id: 'term-2',
        name: 'Beta',
        state: 'exited',
        exitCode: 7,
      );
      apiClient.sessionsById['term-2'] = exited;
      provider.sessionFor('term-2')!.session = exited;
      provider.sessionFor('term-2')!.connectionState =
          TerminalConnectionState.exited;
      provider.notifyListeners();

      await pumpScreen(tester, const Size(1200, 900));

      expect(find.text('Reconnecting'), findsAtLeastNWidgets(1));
      expect(find.textContaining('Trying to re-attach'), findsOneWidget);
      expect(find.text('Exited (7)'), findsWidgets);
    });

    testWidgets(
      'degrades split layouts to a single visible pane on narrow screens',
      (tester) async {
        await provider.ensureInitialized();
        provider.setSplitViewEnabled(true);
        await provider.activateSession('term-2', openInSecondary: true);

        await pumpScreen(tester, const Size(480, 900));

        expect(
          find.textContaining('falls back to one visible terminal pane'),
          findsOneWidget,
        );
        expect(find.byType(TextField), findsOneWidget);
        expect(
          find.byTooltip('Split view unavailable on narrow layouts'),
          findsOneWidget,
        );
      },
    );
  });
}
