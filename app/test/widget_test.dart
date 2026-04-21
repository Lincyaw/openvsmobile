import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vscode_mobile/models/github_collaboration_models.dart';
import 'package:vscode_mobile/providers/github_collaboration_provider.dart';
import 'package:vscode_mobile/providers/github_auth_provider.dart';
import 'package:vscode_mobile/screens/github_collaboration_screen.dart';
import 'package:vscode_mobile/screens/more_screen.dart';
import 'package:vscode_mobile/services/git_api_client.dart';
import 'package:vscode_mobile/services/github_collaboration_api_client.dart';
import 'package:vscode_mobile/services/github_auth_api_client.dart';
import 'package:vscode_mobile/services/settings_service.dart';

Future<Widget> buildTestApp() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});

  final settings = SettingsService();
  await settings.save('http://localhost:8080', 'server-token');
  final collaborationProvider = GitHubCollaborationProvider(
    apiClient: _FakeGitHubCollaborationApiClient(settings),
  );
  await collaborationProvider.setWorkspacePath('/workspaces/openvsmobile');

  return MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: settings),
      ChangeNotifierProvider(
        create: (_) => GitHubAuthProvider(
          apiClient: _FakeGitHubAuthApiClient(settings),
          gitApiClient: _FakeGitApiClient(settings),
        )..setWorkspacePath('/workspaces/openvsmobile'),
      ),
      ChangeNotifierProvider<GitHubCollaborationProvider>.value(
        value: collaborationProvider,
      ),
    ],
    child: const MaterialApp(home: MoreScreen()),
  );
}

void main() {
  testWidgets('More screen routes the GitHub entry to collaboration', (
    tester,
  ) async {
    await tester.pumpWidget(await buildTestApp());
    await tester.pumpAndSettle();

    expect(find.text('GitHub'), findsOneWidget);
    expect(
      find.text('Browse issues, pull requests, and reviews'),
      findsOneWidget,
    );
    expect(find.text('GitHub Connection'), findsOneWidget);

    await tester.tap(find.text('GitHub'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byType(GitHubCollaborationScreen), findsOneWidget);
    expect(find.text('octo-org/mobile-app'), findsOneWidget);
  });
}

class _FakeGitHubAuthApiClient extends GitHubAuthApiClient {
  _FakeGitHubAuthApiClient(SettingsService settings)
    : super(settings: settings);
}

class _FakeGitApiClient extends GitApiClient {
  _FakeGitApiClient(SettingsService settings) : super(settings: settings);
}

class _FakeGitHubCollaborationApiClient extends GitHubCollaborationApiClient {
  _FakeGitHubCollaborationApiClient(SettingsService settings)
    : super(settings: settings);

  @override
  Future<GitHubCurrentRepoContext> fetchCurrentRepo({
    String workspacePath = '',
  }) async {
    return GitHubCurrentRepoContext.fromJson(<String, dynamic>{
      'status': 'ok',
      'repository': <String, dynamic>{
        'full_name': 'octo-org/mobile-app',
        'remote_url': 'git@github.com:octo-org/mobile-app.git',
        'repo_root': workspacePath,
      },
      'auth': <String, dynamic>{
        'authenticated': true,
        'github_host': 'github.com',
        'account_login': 'octocat',
        'account_id': 9,
        'needs_refresh': false,
        'needs_reauth': false,
      },
    });
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
    return <GitHubIssue>[
      GitHubIssue.fromJson(<String, dynamic>{
        'number': 7,
        'title': 'Fix reconnect',
        'state': 'open',
        'comments_count': 1,
      }),
    ];
  }

  @override
  Future<List<GitHubPullRequest>> fetchPullRequests({
    required GitHubCollaborationFilter filter,
    String workspacePath = '',
  }) async {
    return <GitHubPullRequest>[
      GitHubPullRequest.fromJson(<String, dynamic>{
        'number': 12,
        'title': 'Add collaboration UI',
        'state': 'open',
        'changed_files': 1,
        'base_ref': <String, dynamic>{'ref': 'main'},
        'head_ref': <String, dynamic>{'ref': 'feature'},
      }),
    ];
  }
}
