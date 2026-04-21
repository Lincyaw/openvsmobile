import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vscode_mobile/models/github_collaboration_models.dart';
import 'package:vscode_mobile/providers/github_collaboration_provider.dart';
import 'package:vscode_mobile/screens/github_collaboration_screen.dart';
import 'package:vscode_mobile/services/github_collaboration_api_client.dart';
import 'package:vscode_mobile/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets(
    'renders repo header and switches between issues and pull requests',
    (tester) async {
      final provider = await _buildProvider(
        repoContext: GitHubCurrentRepoContext.fromJson(<String, dynamic>{
          'status': 'ok',
          'repository': <String, dynamic>{
            'full_name': 'octo-org/mobile-app',
            'remote_url': 'git@github.com:octo-org/mobile-app.git',
            'repo_root': '/workspace/repo',
          },
          'auth': <String, dynamic>{
            'authenticated': true,
            'github_host': 'github.com',
            'account_login': 'octocat',
            'account_id': 9,
            'needs_refresh': false,
            'needs_reauth': false,
          },
        }),
        issues: <GitHubIssue>[
          GitHubIssue.fromJson(<String, dynamic>{
            'number': 7,
            'title': 'Fix reconnect',
            'state': 'open',
            'comments_count': 1,
            'author': <String, dynamic>{'login': 'octocat', 'id': 9},
          }),
        ],
        pulls: <GitHubPullRequest>[
          GitHubPullRequest.fromJson(<String, dynamic>{
            'number': 12,
            'title': 'Add collaboration UI',
            'state': 'open',
            'changed_files': 1,
            'base_ref': <String, dynamic>{'ref': 'main'},
            'head_ref': <String, dynamic>{'ref': 'feature'},
          }),
        ],
      );

      await tester.pumpWidget(_buildApp(provider));
      await tester.pumpAndSettle();

      expect(find.text('octo-org/mobile-app'), findsOneWidget);
      expect(find.text('Issues'), findsOneWidget);
      expect(find.text('Pull Requests'), findsOneWidget);
      expect(find.text('#7 Fix reconnect'), findsOneWidget);

      await tester.tap(find.text('Pull Requests'));
      await tester.pumpAndSettle();

      expect(find.text('#12 Add collaboration UI'), findsOneWidget);
    },
  );

  testWidgets('renders auth-needed state with auth action', (tester) async {
    final provider = await _buildProvider(
      repoContext: GitHubCurrentRepoContext.fromJson(<String, dynamic>{
        'status': 'not_authenticated',
        'repository': <String, dynamic>{
          'full_name': 'octo-org/mobile-app',
          'remote_url': 'git@github.com:octo-org/mobile-app.git',
          'repo_root': '/workspace/repo',
        },
        'message': 'GitHub is not connected on this server yet.',
      }),
      issues: const <GitHubIssue>[],
      pulls: const <GitHubPullRequest>[],
    );

    await tester.pumpWidget(_buildApp(provider));
    await tester.pumpAndSettle();

    expect(find.text('GitHub authentication required'), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, 'Open GitHub auth'),
      findsOneWidget,
    );
  });
}

Widget _buildApp(GitHubCollaborationProvider provider) {
  return ChangeNotifierProvider<GitHubCollaborationProvider>.value(
    value: provider,
    child: const MaterialApp(home: GitHubCollaborationScreen()),
  );
}

Future<GitHubCollaborationProvider> _buildProvider({
  required GitHubCurrentRepoContext repoContext,
  required List<GitHubIssue> issues,
  required List<GitHubPullRequest> pulls,
}) async {
  final settings = SettingsService();
  await settings.save('http://server.test', 'secret-token');
  final apiClient = _FakeGitHubCollaborationApiClient(settings)
    ..repoContext = repoContext
    ..issues = issues
    ..pulls = pulls;
  final provider = GitHubCollaborationProvider(apiClient: apiClient);
  await provider.setWorkspacePath('/workspace/repo');
  return provider;
}

class _FakeGitHubCollaborationApiClient extends GitHubCollaborationApiClient {
  _FakeGitHubCollaborationApiClient(SettingsService settings)
    : super(settings: settings);

  late GitHubCurrentRepoContext repoContext;
  List<GitHubIssue> issues = <GitHubIssue>[];
  List<GitHubPullRequest> pulls = <GitHubPullRequest>[];

  @override
  Future<GitHubCurrentRepoContext> fetchCurrentRepo({
    String workspacePath = '',
  }) async {
    return repoContext;
  }

  @override
  Future<GitHubAccountContext> fetchAccount({String workspacePath = ''}) async {
    return GitHubAccountContext.fromJson(<String, dynamic>{
      'repository': <String, dynamic>{'full_name': 'octo-org/mobile-app'},
      'account': <String, dynamic>{'login': 'octocat', 'id': 9},
    });
  }

  @override
  Future<List<GitHubIssue>> fetchIssues({
    required GitHubCollaborationFilter filter,
    String workspacePath = '',
  }) async {
    return issues;
  }

  @override
  Future<List<GitHubPullRequest>> fetchPullRequests({
    required GitHubCollaborationFilter filter,
    String workspacePath = '',
  }) async {
    return pulls;
  }
}
