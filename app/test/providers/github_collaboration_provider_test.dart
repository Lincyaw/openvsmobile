import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vscode_mobile/models/github_collaboration_models.dart';
import 'package:vscode_mobile/providers/github_collaboration_provider.dart';
import 'package:vscode_mobile/services/github_collaboration_api_client.dart';
import 'package:vscode_mobile/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsService settings;
  late _FakeGitHubCollaborationApiClient apiClient;
  late GitHubCollaborationProvider provider;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    settings = SettingsService();
    await settings.save('http://server.test', 'secret-token');
    apiClient = _FakeGitHubCollaborationApiClient(settings)
      ..repoContext = GitHubCurrentRepoContext.fromJson(<String, dynamic>{
        'status': 'ok',
        'repository': <String, dynamic>{
          'github_host': 'github.com',
          'owner': 'octo-org',
          'name': 'mobile-app',
          'full_name': 'octo-org/mobile-app',
          'remote_name': 'origin',
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
      })
      ..accountContext = GitHubAccountContext.fromJson(<String, dynamic>{
        'repository': <String, dynamic>{'full_name': 'octo-org/mobile-app'},
        'account': <String, dynamic>{'login': 'octocat', 'id': 9},
      })
      ..issues = <GitHubIssue>[
        GitHubIssue.fromJson(<String, dynamic>{
          'number': 7,
          'title': 'Fix reconnect',
          'state': 'open',
          'comments_count': 1,
        }),
      ]
      ..pulls = <GitHubPullRequest>[
        GitHubPullRequest.fromJson(<String, dynamic>{
          'number': 12,
          'title': 'Add collaboration UI',
          'state': 'open',
          'changed_files': 1,
          'base_ref': <String, dynamic>{'ref': 'main'},
          'head_ref': <String, dynamic>{'ref': 'feature'},
        }),
      ]
      ..issueDetail = GitHubIssueDetail.fromJson(<String, dynamic>{
        'issue': <String, dynamic>{
          'number': 7,
          'title': 'Fix reconnect',
          'state': 'open',
          'comments_count': 1,
        },
        'comments': [
          <String, dynamic>{'id': 1, 'body': 'first'},
        ],
      })
      ..pullDetail = GitHubPullRequestDetail.fromJson(<String, dynamic>{
        'pull_request': <String, dynamic>{
          'number': 12,
          'title': 'Add collaboration UI',
          'state': 'open',
          'changed_files': 1,
          'base_ref': <String, dynamic>{'ref': 'main'},
          'head_ref': <String, dynamic>{'ref': 'feature'},
        },
        'files': [
          <String, dynamic>{
            'filename': 'app/lib/main.dart',
            'status': 'modified',
            'additions': 10,
            'deletions': 2,
            'changes': 12,
            'patch': '@@ -10,1 +42,2 @@\n-old\n+new',
          },
        ],
        'comments': [
          <String, dynamic>{'id': 2, 'body': 'nit'},
        ],
        'reviews': [
          <String, dynamic>{'id': 3, 'state': 'COMMENTED'},
        ],
      })
      ..conversation = GitHubPullRequestConversation.fromJson(<String, dynamic>{
        'comments': [
          <String, dynamic>{'id': 2, 'body': 'nit'},
        ],
        'reviews': [
          <String, dynamic>{'id': 3, 'state': 'COMMENTED'},
        ],
      })
      ..resolveResult = GitHubResolveLocalFileResult.fromJson(<String, dynamic>{
        'repo_root': '/workspace/repo',
        'relative_path': 'app/lib/main.dart',
        'local_path': '/workspace/repo/app/lib/main.dart',
        'exists': true,
      });
    provider = GitHubCollaborationProvider(apiClient: apiClient);
  });

  test(
    'initialize loads repo context issues and pulls for the workspace',
    () async {
      await provider.setWorkspacePath('/workspace/repo');
      await provider.initialize();

      expect(provider.repoContext?.repository?.fullName, 'octo-org/mobile-app');
      expect(provider.accountContext?.account.login, 'octocat');
      expect(provider.issues.single.number, 7);
      expect(provider.pulls.single.number, 12);
      expect(apiClient.lastWorkspacePath, '/workspace/repo');
    },
  );

  test(
    'workspace changes trigger a fresh reload and filter updates refetch',
    () async {
      await provider.setWorkspacePath('/workspace/repo');
      await provider.initialize();

      apiClient.issues = <GitHubIssue>[];
      await provider.updateIssueFilter(
        provider.issueFilter.copyWith(mentioned: true),
      );
      expect(provider.issueFilter.mentioned, isTrue);
      expect(apiClient.lastIssueFilter?.mentioned, isTrue);

      apiClient.pulls = <GitHubPullRequest>[];
      await provider.updatePullFilter(
        provider.pullFilter.copyWith(needsReview: true),
      );
      expect(provider.pullFilter.needsReview, isTrue);
      expect(apiClient.lastPullFilter?.needsReview, isTrue);

      await provider.setWorkspacePath('/workspace/other');
      expect(apiClient.lastWorkspacePath, '/workspace/other');
    },
  );

  test(
    'submitIssueComment exposes in-flight state and refreshes detail',
    () async {
      final completer = Completer<GitHubIssueComment>();
      apiClient.issueCommentCompleter = completer;

      await provider.setWorkspacePath('/workspace/repo');
      await provider.initialize();
      await provider.loadIssueDetail(7, forceRefresh: true);

      final future = provider.submitIssueComment(7, 'hello world');
      expect(provider.isSubmittingIssueComment(7), isTrue);

      completer.complete(
        GitHubIssueComment.fromJson(<String, dynamic>{
          'id': 99,
          'body': 'hello world',
        }),
      );
      final success = await future;

      expect(success, isTrue);
      expect(provider.isSubmittingIssueComment(7), isFalse);
      expect(apiClient.issueCommentBodies, ['hello world']);
    },
  );

  test(
    'submitPullRequestReview and loadPullRequestConversation refresh detail state',
    () async {
      final completer = Completer<GitHubPullRequestReview>();
      apiClient.pullReviewCompleter = completer;

      await provider.setWorkspacePath('/workspace/repo');
      await provider.initialize();
      await provider.loadPullRequestDetail(12, forceRefresh: true);

      final future = provider.submitPullRequestReview(
        12,
        const GitHubPullRequestReviewInput(
          event: 'APPROVE',
          body: 'looks good',
        ),
      );
      expect(provider.isSubmittingPullRequestReview(12), isTrue);

      completer.complete(
        GitHubPullRequestReview.fromJson(<String, dynamic>{
          'id': 55,
          'state': 'APPROVED',
        }),
      );
      final success = await future;

      expect(success, isTrue);
      expect(provider.isSubmittingPullRequestReview(12), isFalse);
      expect(apiClient.lastReviewInput?.event, 'APPROVE');
      expect(
        provider.pullRequestDetailFor(12)?.reviews.single.state,
        'COMMENTED',
      );
    },
  );

  test(
    'resolvePullRequestFileAction prefers local file and falls back to patch',
    () async {
      await provider.setWorkspacePath('/workspace/repo');
      await provider.initialize();
      final file = apiClient.pullDetail.files.single;

      final openLocal = await provider.resolvePullRequestFileAction(file);
      expect(openLocal.shouldOpenLocalFile, isTrue);
      expect(openLocal.localPath, '/workspace/repo/app/lib/main.dart');
      expect(openLocal.line, 42);

      apiClient.resolveResult =
          GitHubResolveLocalFileResult.fromJson(<String, dynamic>{
            'repo_root': '/workspace/repo',
            'relative_path': 'missing.dart',
            'local_path': '/workspace/repo/missing.dart',
            'exists': false,
          });
      final showPatch = await provider.resolvePullRequestFileAction(
        GitHubPullRequestFile.fromJson(<String, dynamic>{
          'filename': 'missing.dart',
          'status': 'removed',
          'additions': 0,
          'deletions': 4,
          'changes': 4,
          'patch': '@@ -1,4 +0,0 @@\n-old',
        }),
      );
      expect(showPatch.shouldOpenLocalFile, isFalse);
      expect(showPatch.patchPath, 'missing.dart');
      expect(showPatch.patch, contains('@@ -1,4 +0,0 @@'));
    },
  );
}

class _FakeGitHubCollaborationApiClient extends GitHubCollaborationApiClient {
  _FakeGitHubCollaborationApiClient(SettingsService settings)
    : super(settings: settings);

  late GitHubCurrentRepoContext repoContext;
  late GitHubAccountContext accountContext;
  List<GitHubIssue> issues = <GitHubIssue>[];
  List<GitHubPullRequest> pulls = <GitHubPullRequest>[];
  late GitHubIssueDetail issueDetail;
  late GitHubPullRequestDetail pullDetail;
  late GitHubPullRequestConversation conversation;
  late GitHubResolveLocalFileResult resolveResult;
  String lastWorkspacePath = '';
  GitHubCollaborationFilter? lastIssueFilter;
  GitHubCollaborationFilter? lastPullFilter;
  final List<String> issueCommentBodies = <String>[];
  Completer<GitHubIssueComment>? issueCommentCompleter;
  Completer<GitHubPullRequestReview>? pullReviewCompleter;
  GitHubPullRequestReviewInput? lastReviewInput;

  @override
  Future<GitHubCurrentRepoContext> fetchCurrentRepo({
    String workspacePath = '',
  }) async {
    lastWorkspacePath = workspacePath;
    return repoContext;
  }

  @override
  Future<GitHubAccountContext> fetchAccount({String workspacePath = ''}) async {
    lastWorkspacePath = workspacePath;
    return accountContext;
  }

  @override
  Future<List<GitHubIssue>> fetchIssues({
    required GitHubCollaborationFilter filter,
    String workspacePath = '',
  }) async {
    lastWorkspacePath = workspacePath;
    lastIssueFilter = filter;
    return issues;
  }

  @override
  Future<GitHubIssueDetail> fetchIssueDetail(
    int number, {
    String workspacePath = '',
  }) async {
    lastWorkspacePath = workspacePath;
    return issueDetail;
  }

  @override
  Future<GitHubIssueComment> submitIssueComment(
    int number,
    GitHubIssueCommentInput input, {
    String workspacePath = '',
  }) async {
    lastWorkspacePath = workspacePath;
    issueCommentBodies.add(input.body);
    if (issueCommentCompleter != null) {
      return issueCommentCompleter!.future;
    }
    return GitHubIssueComment.fromJson(<String, dynamic>{
      'id': 99,
      'body': input.body,
    });
  }

  @override
  Future<List<GitHubPullRequest>> fetchPullRequests({
    required GitHubCollaborationFilter filter,
    String workspacePath = '',
  }) async {
    lastWorkspacePath = workspacePath;
    lastPullFilter = filter;
    return pulls;
  }

  @override
  Future<GitHubPullRequestDetail> fetchPullRequestDetail(
    int number, {
    String workspacePath = '',
  }) async {
    lastWorkspacePath = workspacePath;
    return pullDetail;
  }

  @override
  Future<GitHubPullRequestConversation> fetchPullRequestConversation(
    int number, {
    String workspacePath = '',
  }) async {
    lastWorkspacePath = workspacePath;
    return conversation;
  }

  @override
  Future<GitHubPullRequestReview> submitPullRequestReview(
    int number,
    GitHubPullRequestReviewInput input, {
    String workspacePath = '',
  }) async {
    lastWorkspacePath = workspacePath;
    lastReviewInput = input;
    if (pullReviewCompleter != null) {
      return pullReviewCompleter!.future;
    }
    return GitHubPullRequestReview.fromJson(<String, dynamic>{
      'id': 55,
      'state': input.event,
    });
  }

  @override
  Future<GitHubResolveLocalFileResult> resolveLocalFile({
    required String workspacePath,
    required String relativePath,
  }) async {
    lastWorkspacePath = workspacePath;
    return resolveResult;
  }
}
