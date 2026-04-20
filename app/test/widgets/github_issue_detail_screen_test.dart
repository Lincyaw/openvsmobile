import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vscode_mobile/models/github_collaboration_models.dart';
import 'package:vscode_mobile/providers/github_collaboration_provider.dart';
import 'package:vscode_mobile/screens/github_issue_detail_screen.dart';
import 'package:vscode_mobile/services/github_collaboration_api_client.dart';
import 'package:vscode_mobile/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('renders issue detail and posts a new comment', (tester) async {
    final settings = SettingsService();
    await settings.save('http://server.test', 'secret-token');
    final apiClient = _FakeGitHubCollaborationApiClient(settings);
    final provider = GitHubCollaborationProvider(apiClient: apiClient);
    await provider.setWorkspacePath('/workspace/repo');

    await tester.pumpWidget(
      ChangeNotifierProvider<GitHubCollaborationProvider>.value(
        value: provider,
        child: const MaterialApp(home: GitHubIssueDetailScreen(issueNumber: 7)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('#7 Fix reconnect'), findsOneWidget);
    expect(find.text('No comments yet.'), findsNothing);
    expect(find.text('Existing comment'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'New issue comment');
    await tester.tap(find.widgetWithText(FilledButton, 'Post'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(apiClient.submittedComments, ['New issue comment']);
    expect(find.text('Issue comment posted'), findsOneWidget);
  });
}

class _FakeGitHubCollaborationApiClient extends GitHubCollaborationApiClient {
  _FakeGitHubCollaborationApiClient(SettingsService settings)
    : super(settings: settings);

  final List<String> submittedComments = <String>[];

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
        'comments_count': 1,
      },
      'comments': [
        <String, dynamic>{
          'id': 1,
          'body': 'Existing comment',
          'author': <String, dynamic>{'login': 'octocat', 'id': 9},
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
      'id': 2,
      'body': input.body,
    });
  }
}
