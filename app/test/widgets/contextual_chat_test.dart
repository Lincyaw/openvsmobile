import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vscode_mobile/models/editor_context.dart';
import 'package:vscode_mobile/providers/chat_provider.dart';
import 'package:vscode_mobile/providers/workspace_provider.dart';
import 'package:vscode_mobile/screens/chat_screen.dart';
import 'package:vscode_mobile/widgets/contextual_chat.dart';

import '../test_support/chat_test_helpers.dart';

Widget _wrapWithProviders({
  required ChatProvider chatProvider,
  required WorkspaceProvider workspaceProvider,
  required Widget child,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<WorkspaceProvider>.value(value: workspaceProvider),
      ChangeNotifierProvider<ChatProvider>.value(value: chatProvider),
    ],
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Context summaries', () {
    late RecordingWebSocketChannel channel;
    late ChatProvider chatProvider;
    late WorkspaceProvider workspaceProvider;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      channel = RecordingWebSocketChannel();
      chatProvider = ChatProvider(
        apiClient: FakeChatApiClient(channel: channel),
      );
      workspaceProvider = WorkspaceProvider();
    });

    tearDown(() async {
      chatProvider.dispose();
      await channel.dispose();
    });

    testWidgets('contextual chat shows Workspace, File, and No selection', (
      WidgetTester tester,
    ) async {
      await workspaceProvider.setWorkspace('/workspaces/alpha');
      chatProvider.setWorkspace('/workspaces/alpha');
      chatProvider.setEditorContext(
        const EditorChatContext(
          activeFile: '/workspaces/alpha/lib/main.dart',
          cursor: EditorCursor(line: 18, column: 2),
          selection: null,
        ),
      );

      await tester.pumpWidget(
        _wrapWithProviders(
          chatProvider: chatProvider,
          workspaceProvider: workspaceProvider,
          child: const ContextualChat(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Workspace'), findsOneWidget);
      expect(find.textContaining('alpha'), findsWidgets);
      expect(find.textContaining('File'), findsOneWidget);
      expect(find.textContaining('main.dart'), findsWidgets);
      expect(find.textContaining('No selection'), findsOneWidget);
    });

    testWidgets(
      'summary updates when selection is cleared and survives expand to full chat',
      (WidgetTester tester) async {
        await workspaceProvider.setWorkspace('/workspaces/alpha');
        chatProvider.setWorkspace('/workspaces/alpha');
        chatProvider.setEditorContext(
          const EditorChatContext(
            activeFile: '/workspaces/alpha/lib/main.dart',
            cursor: EditorCursor(line: 8, column: 3),
            selection: EditorSelection(
              start: EditorCursor(line: 8, column: 1),
              end: EditorCursor(line: 11, column: 5),
            ),
          ),
        );

        var expanded = false;
        await tester.pumpWidget(
          _wrapWithProviders(
            chatProvider: chatProvider,
            workspaceProvider: workspaceProvider,
            child: ContextualChat(onExpandToFullChat: () => expanded = true),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('Selection'), findsOneWidget);
        expect(find.textContaining('No selection'), findsNothing);

        chatProvider.setEditorContext(
          const EditorChatContext(
            activeFile: '/workspaces/alpha/lib/main.dart',
            cursor: EditorCursor(line: 12, column: 6),
            selection: null,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('No selection'), findsOneWidget);

        await tester.tap(find.byTooltip('Open full chat'));
        await tester.pumpAndSettle();
        expect(expanded, isTrue);

        await tester.pumpWidget(
          _wrapWithProviders(
            chatProvider: chatProvider,
            workspaceProvider: workspaceProvider,
            child: const ChatScreen(),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('Workspace'), findsOneWidget);
        expect(find.textContaining('main.dart'), findsWidgets);
        expect(find.textContaining('No selection'), findsOneWidget);
      },
    );
  });
}
