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
import '../test_support/editor_test_helpers.dart';

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
    late FakeEditorApiClient editorApi;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      channel = RecordingWebSocketChannel();
      chatProvider = ChatProvider(
        apiClient: FakeChatApiClient(channel: channel),
      );
      editorApi = FakeEditorApiClient();
      workspaceProvider = WorkspaceProvider(editorApiClient: editorApi);
    });

    tearDown(() async {
      chatProvider.dispose();
      await editorApi.disposeFakes();
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

      expect(findTextContaining('Workspace'), findsOneWidget);
      expect(findTextContaining('alpha'), findsWidgets);
      expect(findTextContaining('File'), findsOneWidget);
      expect(findTextContaining('main.dart'), findsWidgets);
      expect(findTextContaining('No selection'), findsOneWidget);
    });

    testWidgets(
      'summary shows the queued GitHub attachment details and survives expand to full chat',
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
        queueIssueCommentAttachmentForNextTurn(
          chatProvider,
          actionLabel: 'Check issue comment',
          repository: 'octo/repo',
          issueNumber: 7,
          title: 'Fix reconnect',
          commentId: 11,
          commentBody: 'Can we narrow the retry window?',
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

        expect(findTextContaining('Workspace'), findsOneWidget);
        expect(findTextContaining('main.dart'), findsWidgets);
        expect(findTextContaining('Selection'), findsOneWidget);
        expect(findTextContaining('Fix reconnect'), findsOneWidget);
        expect(
          findTextContaining('Can we narrow the retry window?'),
          findsOneWidget,
        );
        expect(findTextContaining('octo/repo'), findsWidgets);

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

        expect(findTextContaining('Workspace'), findsOneWidget);
        expect(findTextContaining('main.dart'), findsWidgets);
        expect(findTextContaining('Fix reconnect'), findsOneWidget);
        expect(
          findTextContaining('Can we narrow the retry window?'),
          findsOneWidget,
        );
        expect(findTextContaining('octo/repo'), findsWidgets);
      },
    );
  });
}
