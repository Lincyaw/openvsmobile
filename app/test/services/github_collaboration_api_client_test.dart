import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vscode_mobile/models/github_collaboration_models.dart';
import 'package:vscode_mobile/services/github_collaboration_api_client.dart';
import 'package:vscode_mobile/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsService settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    settings = SettingsService();
    await settings.save('http://server.test', 'secret-token');
  });

  test(
    'fetchCurrentRepo includes workspace query and decodes repo context',
    () async {
      final client = MockClient((http.Request request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/github/repos/current');
        expect(request.url.queryParameters['path'], '/workspace/repo');
        return http.Response(
          jsonEncode(<String, dynamic>{
            'status': 'ok',
            'repository': <String, dynamic>{
              'github_host': 'github.com',
              'owner': 'octo-org',
              'name': 'mobile-app',
              'full_name': 'octo-org/mobile-app',
              'remote_name': 'origin',
              'remote_url': 'git@github.com:octo-org/mobile-app.git',
              'repo_root': '/workspace/repo',
              'private': true,
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
          200,
        );
      });

      final apiClient = GitHubCollaborationApiClient(
        settings: settings,
        client: client,
      );
      final context = await apiClient.fetchCurrentRepo(
        workspacePath: '/workspace/repo',
      );

      expect(context.isOk, isTrue);
      expect(context.repository?.fullName, 'octo-org/mobile-app');
      expect(context.auth?.accountLogin, 'octocat');
    },
  );

  test('fetchIssues and fetchIssueDetail decode issue payloads', () async {
    final client = MockClient((http.Request request) async {
      if (request.url.path == '/api/github/issues') {
        expect(request.url.queryParameters['state'], 'open');
        expect(request.url.queryParameters['assigned_to_me'], 'true');
        return http.Response(
          jsonEncode(<String, dynamic>{
            'issues': [
              <String, dynamic>{
                'number': 7,
                'title': 'Fix reconnect',
                'state': 'open',
                'body': 'Reconnect stalls after sleep.',
                'comments_count': 3,
                'author': <String, dynamic>{'login': 'octocat', 'id': 9},
              },
            ],
          }),
          200,
        );
      }

      expect(request.url.path, '/api/github/issues/7');
      return http.Response(
        jsonEncode(<String, dynamic>{
          'issue': <String, dynamic>{
            'number': 7,
            'title': 'Fix reconnect',
            'state': 'open',
            'body': 'Reconnect stalls after sleep.',
            'comments_count': 3,
          },
          'comments': [
            <String, dynamic>{
              'id': 11,
              'body': 'I can take this.',
              'author': <String, dynamic>{'login': 'octocat', 'id': 9},
            },
          ],
        }),
        200,
      );
    });

    final apiClient = GitHubCollaborationApiClient(
      settings: settings,
      client: client,
    );

    final issues = await apiClient.fetchIssues(
      filter: const GitHubCollaborationFilter(
        state: 'open',
        assignedToMe: true,
      ),
      workspacePath: '/workspace/repo',
    );
    final detail = await apiClient.fetchIssueDetail(
      7,
      workspacePath: '/workspace/repo',
    );

    expect(issues.single.number, 7);
    expect(issues.single.author?.login, 'octocat');
    expect(detail.issue.title, 'Fix reconnect');
    expect(detail.comments.single.body, 'I can take this.');
  });

  test(
    'fetchPullRequestDetail decodes files comments reviews and checks',
    () async {
      final client = MockClient((http.Request request) async {
        expect(request.url.path, '/api/github/pulls/12');
        return http.Response(
          jsonEncode(<String, dynamic>{
            'pull_request': <String, dynamic>{
              'number': 12,
              'title': 'Add collaboration UI',
              'state': 'open',
              'body': 'Implements the GitHub collaboration flow.',
              'changed_files': 2,
              'base_ref': <String, dynamic>{'ref': 'main'},
              'head_ref': <String, dynamic>{'ref': 'feature/github-collab'},
              'checks': <String, dynamic>{
                'state': 'pending',
                'total_count': 2,
                'success_count': 1,
                'pending_count': 1,
                'failure_count': 0,
                'checks': [
                  <String, dynamic>{
                    'name': 'ci / unit-tests',
                    'status': 'completed',
                    'conclusion': 'success',
                  },
                ],
              },
            },
            'files': [
              <String, dynamic>{
                'filename': 'app/lib/main.dart',
                'status': 'modified',
                'additions': 10,
                'deletions': 0,
                'changes': 10,
                'patch': '@@ -1,1 +1,10 @@\n+new',
              },
            ],
            'comments': [
              <String, dynamic>{
                'id': 21,
                'body': 'Looks good',
                'path': 'app/lib/main.dart',
              },
            ],
            'reviews': [
              <String, dynamic>{
                'id': 31,
                'state': 'COMMENTED',
                'body': 'Ship it',
              },
            ],
          }),
          200,
        );
      });

      final apiClient = GitHubCollaborationApiClient(
        settings: settings,
        client: client,
      );
      final detail = await apiClient.fetchPullRequestDetail(
        12,
        workspacePath: '/workspace/repo',
      );

      expect(detail.pullRequest.number, 12);
      expect(detail.files.single.filename, 'app/lib/main.dart');
      expect(detail.comments.single.path, 'app/lib/main.dart');
      expect(detail.reviews.single.state, 'COMMENTED');
      expect(detail.pullRequest.checks?.checks.single.name, 'ci / unit-tests');
    },
  );

  test(
    'resolveLocalFile and submit endpoints send expected request bodies',
    () async {
      final requests = <Map<String, dynamic>>[];
      final client = MockClient((http.Request request) async {
        if (request.method == 'POST') {
          requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        }
        if (request.url.path == '/api/github/resolve-local-file') {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'repo_root': '/workspace/repo',
              'relative_path': 'app/lib/main.dart',
              'local_path': '/workspace/repo/app/lib/main.dart',
              'exists': true,
            }),
            200,
          );
        }
        if (request.url.path == '/api/github/issues/7/comments') {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'comment': <String, dynamic>{'id': 1, 'body': 'hello'},
            }),
            201,
          );
        }
        if (request.url.path == '/api/github/pulls/12/comments') {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'comment': <String, dynamic>{'id': 2, 'body': 'inline'},
            }),
            201,
          );
        }
        return http.Response(
          jsonEncode(<String, dynamic>{
            'review': <String, dynamic>{'id': 3, 'state': 'APPROVED'},
          }),
          201,
        );
      });

      final apiClient = GitHubCollaborationApiClient(
        settings: settings,
        client: client,
      );

      await apiClient.resolveLocalFile(
        workspacePath: '/workspace/repo',
        relativePath: 'app/lib/main.dart',
      );
      await apiClient.submitIssueComment(
        7,
        const GitHubIssueCommentInput(body: 'hello'),
        workspacePath: '/workspace/repo',
      );
      await apiClient.submitPullRequestComment(
        12,
        const GitHubPullRequestCommentInput(
          body: 'inline',
          path: 'app/lib/main.dart',
          commitId: 'deadbeef',
          line: 10,
          side: 'RIGHT',
        ),
        workspacePath: '/workspace/repo',
      );
      await apiClient.submitPullRequestReview(
        12,
        const GitHubPullRequestReviewInput(
          event: 'APPROVE',
          body: 'Looks good',
          comments: <GitHubPullRequestReviewDraftComment>[
            GitHubPullRequestReviewDraftComment(
              body: 'nit',
              path: 'app/lib/main.dart',
              line: 12,
              side: 'RIGHT',
            ),
          ],
        ),
        workspacePath: '/workspace/repo',
      );

      expect(
        requests.any(
          (request) =>
              request['workspace_path'] == '/workspace/repo' &&
              request['path'] == 'app/lib/main.dart' &&
              request.length == 2,
        ),
        isTrue,
      );
      expect(
        requests.any(
          (request) =>
              request['workspace_path'] == '/workspace/repo' &&
              request['body'] == 'hello' &&
              request.length == 2,
        ),
        isTrue,
      );
      expect(
        requests.any(
          (request) =>
              request['workspace_path'] == '/workspace/repo' &&
              request['body'] == 'inline' &&
              request['path'] == 'app/lib/main.dart' &&
              request['commit_id'] == 'deadbeef' &&
              request['side'] == 'RIGHT' &&
              request['line'] == 10,
        ),
        isTrue,
      );
      expect(
        requests.any((request) {
          final comments = request['comments'] as List<dynamic>?;
          if (comments == null || comments.isEmpty) {
            return false;
          }
          final firstComment = comments.first as Map<String, dynamic>;
          return request['workspace_path'] == '/workspace/repo' &&
              request['event'] == 'APPROVE' &&
              request['body'] == 'Looks good' &&
              firstComment['body'] == 'nit' &&
              firstComment['path'] == 'app/lib/main.dart' &&
              firstComment['side'] == 'RIGHT' &&
              firstComment['line'] == 12;
        }),
        isTrue,
      );
    },
  );

  test('maps structured errors to collaboration exceptions', () async {
    final client = MockClient((_) async {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'error_code': 'app_not_installed_for_repo',
          'message': 'install the GitHub app first',
        }),
        403,
      );
    });

    final apiClient = GitHubCollaborationApiClient(
      settings: settings,
      client: client,
    );

    await expectLater(
      () => apiClient.fetchPullRequests(
        filter: const GitHubCollaborationFilter(),
        workspacePath: '/workspace/repo',
      ),
      throwsA(
        isA<GitHubCollaborationException>()
            .having(
              (error) => error.errorCode,
              'errorCode',
              'app_not_installed_for_repo',
            )
            .having(
              (error) => error.toDisplayMessage(),
              'display message',
              contains('GitHub App'),
            ),
      ),
    );
  });
}
