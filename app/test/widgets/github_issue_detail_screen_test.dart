import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vscode_mobile/models/editor_context.dart';
import 'package:vscode_mobile/models/github_collaboration_models.dart';
import 'package:vscode_mobile/providers/chat_provider.dart';
import 'package:vscode_mobile/providers/github_collaboration_provider.dart';
import 'package:vscode_mobile/providers/workspace_provider.dart';
import 'package:vscode_mobile/screens/chat_screen.dart';
import 'package:vscode_mobile/screens/github_issue_detail_screen.dart';
import 'package:vscode_mobile/services/github_collaboration_api_client.dart';
import 'package:vscode_mobile/services/settings_service.dart';

import '../test_support/chat_test_helpers.dart';
import '../test_support/editor_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets(
    'renders issue AI action, opens chat, and attaches only issue context',
    (tester) async {
      final harness = await _buildHarness();

      await tester.pumpWidget(harness.widget);
      await tester.pumpAndSettle();

      expect(find.text('#7 Fix reconnect'), findsOneWidget);
      expect(find.text('Summarize issue'), findsOneWidget);

      await tester.tap(find.text('Summarize issue'));
      await tester.pumpAndSettle();

      expect(find.byType(ChatScreen), findsOneWidget);
      expect(findTextContaining('Fix reconnect'), findsWidgets);
      expect(
        findTextContaining('Reconnect stalls after sleep.'),
        findsOneWidget,
      );

      final attachment = pendingChatAttachmentJson(harness.chatProvider);
      final encoded = jsonEncode(attachment);
      expect(encoded.toLowerCase(), contains('issue'));
      expect(encoded, contains('Fix reconnect'));
      expect(encoded, contains('Reconnect stalls after sleep.'));
      expect(encoded, isNot(contains('Existing comment')));
      expect(encoded, isNot(contains('Second issue comment')));
    },
  );

  testWidgets(
    'comment AI action attaches only the selected comment and keeps post intact',
    (tester) async {
      final harness = await _buildHarness();

      await tester.pumpWidget(harness.widget);
      await tester.pumpAndSettle();

      expect(find.text('Existing comment'), findsOneWidget);
      expect(find.text('Second issue comment'), findsOneWidget);
      expect(find.text('Check comment'), findsWidgets);

      await tester.tap(find.text('Check comment').first);
      await tester.pumpAndSettle();

      expect(find.byType(ChatScreen), findsOneWidget);

      final attachment = pendingChatAttachmentJson(harness.chatProvider);
      final encoded = jsonEncode(attachment);
      expect(encoded.toLowerCase(), contains('issue'));
      expect(encoded, contains('Fix reconnect'));
      expect(encoded, contains('Existing comment'));
      expect(encoded, isNot(contains('Second issue comment')));

      final postingHarness = await _buildHarness();
      final submitted = await postingHarness.provider.submitIssueComment(
        7,
        'New issue comment',
      );

      expect(submitted, isTrue);
      expect(postingHarness.apiClient.submittedComments, ['New issue comment']);
    },
  );
}

class _Harness {
  final Widget widget;
  final _FakeGitHubCollaborationApiClient apiClient;
  final ChatProvider chatProvider;
  final GitHubCollaborationProvider provider;

  const _Harness({
    required this.widget,
    required this.apiClient,
    required this.chatProvider,
    required this.provider,
  });
}

Future<_Harness> _buildHarness() async {
  final settings = SettingsService();
  await settings.save('http://server.test', 'secret-token');
  final apiClient = _FakeGitHubCollaborationApiClient(settings);
  final provider = GitHubCollaborationProvider(apiClient: apiClient);
  await provider.setWorkspacePath('/workspace/repo');
  await provider.loadCurrentRepo();
  final chatProvider = ChatProvider(
    apiClient: FakeChatApiClient(channel: RecordingWebSocketChannel()),
  );
  chatProvider.setWorkspace('/workspace/repo');
  chatProvider.setEditorContext(
    const EditorChatContext(
      activeFile: '/workspace/repo/lib/main.dart',
      cursor: EditorCursor(line: 14, column: 2),
      selection: null,
    ),
  );
  final workspaceProvider = WorkspaceProvider(
    editorApiClient: FakeEditorApiClient(settings: settings),
  );
  await workspaceProvider.setWorkspace('/workspace/repo');

  return _Harness(
    apiClient: apiClient,
    chatProvider: chatProvider,
    provider: provider,
    widget: MultiProvider(
      providers: [
        ChangeNotifierProvider<GitHubCollaborationProvider>.value(
          value: provider,
        ),
        ChangeNotifierProvider<ChatProvider>.value(value: chatProvider),
        ChangeNotifierProvider<WorkspaceProvider>.value(
          value: workspaceProvider,
        ),
      ],
      child: const MaterialApp(home: GitHubIssueDetailScreen(issueNumber: 7)),
    ),
  );
}

class _FakeGitHubCollaborationApiClient extends GitHubCollaborationApiClient {
  _FakeGitHubCollaborationApiClient(SettingsService settings)
    : super(settings: settings);

  final List<String> submittedComments = <String>[];

  @override
  Future<GitHubCurrentRepoContext> fetchCurrentRepo({
    String workspacePath = '',
  }) async {
    return GitHubCurrentRepoContext.fromJson(<String, dynamic>{
      'status': 'ok',
      'repository': <String, dynamic>{
        'id': 1,
        'github_host': 'github.com',
        'owner': 'octo',
        'name': 'repo',
        'full_name': 'octo/repo',
        'remote_name': 'origin',
        'remote_url': 'git@github.com:octo/repo.git',
        'repo_root': '/workspace/repo',
        'private': false,
      },
    });
  }

  @override
  Future<GitHubAccountContext> fetchAccount({String workspacePath = ''}) async {
    return GitHubAccountContext.fromJson(<String, dynamic>{
      'repository': <String, dynamic>{
        'id': 1,
        'github_host': 'github.com',
        'owner': 'octo',
        'name': 'repo',
        'full_name': 'octo/repo',
        'remote_name': 'origin',
        'remote_url': 'git@github.com:octo/repo.git',
        'repo_root': '/workspace/repo',
        'private': false,
      },
      'account': <String, dynamic>{
        'login': 'octocat',
        'id': 9,
        'name': 'Octo Cat',
        'avatar_url': '',
        'html_url': 'https://github.com/octocat',
      },
    });
  }

  @override
  Future<GitHubIssueDetail> fetchIssueDetail(
    int number, {
    String workspacePath = '',
  }) async {
    return GitHubIssueDetail.fromJson(<String, dynamic>{
      'issue': <String, dynamic>{
        'number': 7,
        'title': 'Fix reconnect',
        'state': 'open',
        'body': 'Reconnect stalls after sleep.',
        'comments_count': 2,
      },
      'comments': [
        <String, dynamic>{
          'id': 1,
          'body': 'Existing comment',
          'author': <String, dynamic>{'login': 'octocat', 'id': 9},
        },
        <String, dynamic>{
          'id': 2,
          'body': 'Second issue comment',
          'author': <String, dynamic>{'login': 'hubot', 'id': 10},
        },
      ],
    });
  }

  @override
  Future<GitHubIssueComment> submitIssueComment(
    int number,
    GitHubIssueCommentInput input, {
    String workspacePath = '',
  }) async {
    submittedComments.add(input.body);
    return GitHubIssueComment.fromJson(<String, dynamic>{
      'id': 3,
      'body': input.body,
    });
  }
}
