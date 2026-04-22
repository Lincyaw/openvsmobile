import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vscode_mobile/models/terminal_session.dart';
import 'package:vscode_mobile/providers/terminal_provider.dart';
import 'package:vscode_mobile/providers/workspace_provider.dart';
import 'package:vscode_mobile/screens/terminal_workspace_screen.dart';
import 'package:vscode_mobile/services/settings_service.dart';

import '../test_support/editor_test_helpers.dart';
import '../test_support/terminal_test_helpers.dart';

void main() {
  group('TerminalWorkspaceScreen', () {
    late FakeTerminalApiClient apiClient;
    late TerminalProvider terminalProvider;
    late WorkspaceProvider workspaceProvider;
    late SettingsService settingsService;
    late FakeEditorApiClient editorApiClient;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      apiClient = FakeTerminalApiClient(
        seedSessions: <TerminalSession>[
          terminalSession(id: 'term-1', name: 'Alpha'),
          terminalSession(id: 'term-2', name: 'Beta'),
        ],
      );
      terminalProvider = TerminalProvider(apiClient: apiClient);
      editorApiClient = FakeEditorApiClient();
      workspaceProvider = WorkspaceProvider(editorApiClient: editorApiClient);
      settingsService = SettingsService();
      await workspaceProvider.load();
      await workspaceProvider.setWorkspace('/workspace');
      await settingsService.save('http://server.test', 'secret');
    });

    tearDown(() async {
      terminalProvider.dispose();
      workspaceProvider.dispose();
      settingsService.dispose();
      await editorApiClient.disposeFakes();
      await apiClient.disposeFakes();
    });

    Future<void> pumpScreen(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsService>.value(
              value: settingsService,
            ),
            ChangeNotifierProvider<WorkspaceProvider>.value(
              value: workspaceProvider,
            ),
            ChangeNotifierProvider<TerminalProvider>.value(
              value: terminalProvider,
            ),
          ],
          child: const MaterialApp(
            home: TerminalWorkspaceScreen(isActive: true),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets(
      'renders multi-session controls and split markers on wide layouts',
      (tester) async {
        await terminalProvider.ensureInitialized();
        terminalProvider.setSplitViewEnabled(true);
        await terminalProvider.activateSession('term-2', openInSecondary: true);

        await pumpScreen(tester, const Size(1200, 900));

        expect(find.text('New'), findsOneWidget);
        expect(find.text('Named'), findsOneWidget);
        expect(find.text('Refresh'), findsOneWidget);
        expect(find.text('Split current'), findsOneWidget);
        expect(find.text('Alpha'), findsWidgets);
        expect(find.text('Beta'), findsWidgets);
        expect(find.text('Primary'), findsOneWidget);
        expect(find.text('Split'), findsOneWidget);
        expect(find.text('/workspace'), findsWidgets);
      },
    );

    testWidgets('shows reconnecting and exited session states', (tester) async {
      await terminalProvider.ensureInitialized();
      await pumpScreen(tester, const Size(1200, 900));

      final active = terminalProvider.sessionFor('term-1')!;
      active.connectionState = TerminalConnectionState.reconnecting;
      final exited = terminalSession(
        id: 'term-2',
        name: 'Beta',
        state: 'exited',
        exitCode: 7,
      );
      apiClient.sessionsById['term-2'] = exited;
      terminalProvider.sessionFor('term-2')!.session = exited;
      terminalProvider.sessionFor('term-2')!.connectionState =
          TerminalConnectionState.exited;
      terminalProvider.notifyListeners();

      await tester.pump();

      expect(find.text('Reconnecting'), findsAtLeastNWidgets(1));
      expect(find.textContaining('Trying to re-attach'), findsOneWidget);
      expect(find.text('Exited (7)'), findsWidgets);
    });

    testWidgets('keeps sessions visible on compact layouts', (tester) async {
      await terminalProvider.ensureInitialized();
      terminalProvider.setSplitViewEnabled(true);
      await terminalProvider.activateSession('term-2', openInSecondary: true);

      await pumpScreen(tester, const Size(480, 900));

      expect(find.text('Alpha'), findsWidgets);
      expect(find.text('Beta'), findsWidgets);
      expect(find.byType(TextField), findsNWidgets(2));
    });
  });
}
