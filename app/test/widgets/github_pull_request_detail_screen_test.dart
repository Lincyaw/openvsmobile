import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vscode_mobile/models/diagnostic.dart';
import 'package:vscode_mobile/models/github_collaboration_models.dart';
import 'package:vscode_mobile/providers/editor_provider.dart';
import 'package:vscode_mobile/providers/github_collaboration_provider.dart';
import 'package:vscode_mobile/screens/code_screen.dart';
import 'package:vscode_mobile/screens/github_pull_request_detail_screen.dart';
import 'package:vscode_mobile/services/api_client.dart';
import 'package:vscode_mobile/services/github_collaboration_api_client.dart';
import 'package:vscode_mobile/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('renders checks and submits a review action', (tester) async {
    final harness = await _buildHarness();

    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Conversation'));
    await tester.pumpAndSettle();
    expect(find.text('Comment'), findsOneWidget);
    expect(find.text('Approve'), findsOneWidget);
    expect(find.text('Request changes'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Ship it');
    final submitReviewButton = find.widgetWithText(
      FilledButton,
      'Submit review',
    );
    await tester.scrollUntilVisible(
      submitReviewButton,
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(submitReviewButton);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(harness.collabApi.reviewInputs.single.event, 'COMMENT');
    expect(find.text('Review COMMENT submitted'), findsOneWidget);

    await tester.tap(find.text('Checks'));
    await tester.pumpAndSettle();
    expect(find.text('State: pending'), findsOneWidget);
    expect(find.text('ci / unit-tests'), findsOneWidget);
  });

  testWidgets('tapping a file opens the editor when the local file exists', (
    tester,
  ) async {
    final harness = await _buildHarness();
    harness.collabApi.resolveResult =
        GitHubResolveLocalFileResult.fromJson(<String, dynamic>{
          'repo_root': '/workspace/repo',
          'relative_path': 'app/lib/main.dart',
          'local_path': '/workspace/repo/app/lib/main.dart',
          'exists': true,
        });

    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Files'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('app/lib/main.dart'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byType(CodeScreen), findsOneWidget);
    expect(harness.editorProvider.currentFile?.path, '/workspace/repo/app/lib/main.dart');
    expect(harness.editorProvider.cursor?.line, 42);
  });

  testWidgets('tapping a file falls back to the patch screen when missing', (
    tester,
  ) async {
    final harness = await _buildHarness();
    harness.collabApi.resolveResult =
        GitHubResolveLocalFileResult.fromJson(<String, dynamic>{
          'repo_root': '/workspace/repo',
          'relative_path': 'app/lib/main.dart',
          'local_path': '/workspace/repo/app/lib/main.dart',
          'exists': false,
        });

    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Files'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('app/lib/main.dart'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('app/lib/main.dart'), findsWidgets);
    expect(find.textContaining('@@ -10,1 +42,2 @@'), findsOneWidget);
  });
}

class _Harness {
  final Widget widget;
  final _FakeGitHubCollaborationApiClient collabApi;
  final EditorProvider editorProvider;

  const _Harness({
    required this.widget,
    required this.collabApi,
    required this.editorProvider,
  });
}

Future<_Harness> _buildHarness() async {
  final settings = SettingsService();
  await settings.save('http://server.test', 'secret-token');
  final collabApi = _FakeGitHubCollaborationApiClient(settings);
  final editorApi = _FakeApiClient(settings);
  final collabProvider = GitHubCollaborationProvider(apiClient: collabApi);
  await collabProvider.setWorkspacePath('/workspace/repo');
  final editorProvider = EditorProvider(apiClient: editorApi);

  return _Harness(
    collabApi: collabApi,
    editorProvider: editorProvider,
    widget: MultiProvider(
      providers: [
        ChangeNotifierProvider<GitHubCollaborationProvider>.value(
          value: collabProvider,
        ),
        ChangeNotifierProvider<EditorProvider>.value(value: editorProvider),
      ],
      child: const MaterialApp(
        home: GitHubPullRequestDetailScreen(pullRequestNumber: 12),
      ),
    ),
  );
}

class _FakeGitHubCollaborationApiClient extends GitHubCollaborationApiClient {
  _FakeGitHubCollaborationApiClient(SettingsService settings)
    : super(settings: settings);

  GitHubResolveLocalFileResult resolveResult =
      GitHubResolveLocalFileResult.fromJson(<String, dynamic>{
        'repo_root': '/workspace/repo',
        'relative_path': 'app/lib/main.dart',
        'local_path': '/workspace/repo/app/lib/main.dart',
        'exists': true,
      });
  final List<GitHubPullRequestReviewInput> reviewInputs =
      <GitHubPullRequestReviewInput>[];

  @override
  Future<GitHubPullRequestDetail> fetchPullRequestDetail(
    int number, {
    String workspacePath = '',
  }) async {
    return GitHubPullRequestDetail.fromJson(<String, dynamic>{
      'pull_request': <String, dynamic>{
        'number': 12,
        'title': 'Add collaboration UI',
        'state': 'open',
        'body': 'Implements the GitHub collaboration flow.',
        'changed_files': 1,
        'base_ref': <String, dynamic>{'ref': 'main'},
        'head_ref': <String, dynamic>{'ref': 'feature'},
        'checks': <String, dynamic>{
          'state': 'pending',
          'total_count': 1,
          'success_count': 0,
          'pending_count': 1,
          'failure_count': 0,
          'checks': [
            <String, dynamic>{'name': 'ci / unit-tests', 'status': 'pending'},
          ],
        },
      },
      'files': [
        <String, dynamic>{
          'filename': 'app/lib/main.dart',
          'status': 'modified',
          'additions': 2,
          'deletions': 1,
          'changes': 3,
          'patch': '@@ -10,1 +42,2 @@\n-old\n+new',
        },
      ],
      'comments': [
        <String, dynamic>{
          'id': 2,
          'body': 'Inline note',
          'path': 'app/lib/main.dart',
        },
      ],
      'reviews': [
        <String, dynamic>{'id': 3, 'state': 'COMMENTED', 'body': 'Looks good'},
      ],
    });
  }

  @override
  Future<GitHubPullRequestReview> submitPullRequestReview(
    int number,
    GitHubPullRequestReviewInput input, {
    String workspacePath = '',
  }) async {
    reviewInputs.add(input);
    return GitHubPullRequestReview.fromJson(<String, dynamic>{
      'id': 99,
      'state': input.event,
      'body': input.body,
    });
  }

  @override
  Future<GitHubResolveLocalFileResult> resolveLocalFile({
    required String workspacePath,
    required String relativePath,
  }) async {
    return resolveResult;
  }
}

class _FakeApiClient extends ApiClient {
  _FakeApiClient(SettingsService settings) : super(settings: settings);

  @override
  Future<String> readFile(String path) async => 'void main() {}';

  @override
  Future<List<Diagnostic>> getDiagnostics({
    String? filePath,
    String workDir = '/',
  }) async {
    return const <Diagnostic>[];
  }
}
