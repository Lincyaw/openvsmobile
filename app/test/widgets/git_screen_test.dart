import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vscode_mobile/models/git_models.dart';
import 'package:vscode_mobile/providers/git_provider.dart';
import 'package:vscode_mobile/providers/workspace_provider.dart';
import 'package:vscode_mobile/screens/git_screen.dart';
import 'package:vscode_mobile/services/api_client.dart';
import 'package:vscode_mobile/services/git_api_client.dart';
import 'package:vscode_mobile/services/settings_service.dart';

const Map<String, dynamic> _repositoryDocument = <String, dynamic>{
  'path': '/workspace/repo',
  'branch': 'main',
  'upstream': 'origin/main',
  'ahead': 2,
  'behind': 1,
  'remotes': <Map<String, dynamic>>[
    <String, dynamic>{
      'name': 'origin',
      'fetchUrl': 'git@github.com:Lincyaw/openvsmobile.git',
      'pushUrl': 'git@github.com:Lincyaw/openvsmobile.git',
    },
  ],
  'staged': <Map<String, dynamic>>[
    <String, dynamic>{'path': 'lib/staged.dart', 'status': 'modified'},
  ],
  'unstaged': <Map<String, dynamic>>[
    <String, dynamic>{'path': 'lib/feature.dart', 'status': 'modified'},
  ],
  'untracked': <Map<String, dynamic>>[
    <String, dynamic>{'path': 'lib/new.dart', 'status': 'untracked'},
  ],
  'conflicts': <Map<String, dynamic>>[
    <String, dynamic>{
      'path': 'lib/conflicted.dart',
      'status': 'both_modified',
      'indexStatus': 'U',
      'workingTreeStatus': 'U',
    },
  ],
  'mergeChanges': <Map<String, dynamic>>[],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('renders repository counters and requested change-group labels', (
    tester,
  ) async {
    final provider = await _buildProvider(repository: _repositoryDocument);
    await tester.pumpWidget(_buildApp(provider));
    await tester.pumpAndSettle();

    expect(find.text('Ahead 2'), findsOneWidget);
    expect(find.text('Behind 1'), findsOneWidget);
    expect(find.text('Staged 1'), findsOneWidget);
    expect(find.text('Changes 1'), findsNWidgets(2));
    expect(find.text('Untracked 1'), findsOneWidget);
    expect(find.text('Conflicts 1'), findsOneWidget);

    expect(find.text('Conflicts (1)'), findsOneWidget);
    expect(find.text('Staged Changes (1)'), findsOneWidget);
    expect(find.text('Changes (1)'), findsOneWidget);
    expect(find.text('Untracked (1)'), findsOneWidget);
  });

  testWidgets('disables commit when the message is empty', (tester) async {
    final provider = await _buildProvider(repository: _repositoryDocument);
    await tester.pumpWidget(_buildApp(provider));
    await tester.pumpAndSettle();

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Commit'),
    );
    expect(button.onPressed, isNull);
    expect(
      find.text('Enter a commit message before committing'),
      findsOneWidget,
    );
    expect(provider.commitMessages, isEmpty);
  });

  testWidgets('renders conflict rows with distinct affordances', (
    tester,
  ) async {
    final provider = await _buildProvider(repository: _repositoryDocument);
    await tester.pumpWidget(_buildApp(provider));
    await tester.pumpAndSettle();

    expect(
      find.text('Resolve merge conflicts before committing.'),
      findsOneWidget,
    );
    expect(find.widgetWithText(TextButton, 'Resolve'), findsOneWidget);
    expect(
      find.text('Resolve in diff view before staging a final version.'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.warning_amber_rounded), findsWidgets);
  });

  testWidgets('tapping a file opens a diff preview route', (tester) async {
    final provider = await _buildProvider(repository: _repositoryDocument);
    await tester.pumpWidget(_buildApp(provider));
    await tester.pumpAndSettle();

    await tester.tap(find.text('feature.dart'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pumpAndSettle();

    expect(find.text('lib/feature.dart'), findsWidgets);
    expect(
      find.textContaining('diff --git a/lib/feature.dart b/lib/feature.dart'),
      findsOneWidget,
    );
  });

  testWidgets(
    'repository operations show explicit feedback for success and failure',
    (tester) async {
      final provider = await _buildProvider(repository: _repositoryDocument)
        ..pushError = const ApiException('Push rejected by remote', 502);
      await tester.pumpWidget(_buildApp(provider));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Fetch'));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('Fetch completed'), findsOneWidget);

      await tester.tap(find.byTooltip('Push'));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.textContaining('Push rejected by remote'), findsWidgets);
    },
  );
}

Widget _buildApp(_FakeGitApiClient apiClient) {
  final workspaceProvider = WorkspaceProvider();
  final gitProvider = GitProvider(apiClient: apiClient);

  return MultiProvider(
    providers: [
      ChangeNotifierProvider<WorkspaceProvider>.value(value: workspaceProvider),
      ChangeNotifierProvider<GitProvider>.value(value: gitProvider),
    ],
    child: Builder(
      builder: (context) {
        context.read<WorkspaceProvider>().setWorkspace('/workspace/repo');
        return const MaterialApp(home: GitScreen());
      },
    ),
  );
}

Future<_FakeGitApiClient> _buildProvider({
  required Map<String, dynamic> repository,
}) async {
  final settings = SettingsService();
  await settings.save('http://localhost:8080', 'secret');
  return _FakeGitApiClient(settings)
    ..repository = _repo(repository)
    ..diffDocument = const GitDiffDocument(
      path: 'lib/feature.dart',
      diff:
          'diff --git a/lib/feature.dart b/lib/feature.dart\n@@ -1 +1 @@\n-old\n+new',
      staged: false,
    );
}

GitRepositoryState _repo(Map<String, dynamic> json) {
  return GitRepositoryState.fromJson(
    jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
  );
}

class _FakeGitApiClient extends GitApiClient {
  _FakeGitApiClient(SettingsService settings) : super(settings: settings);

  late GitRepositoryState repository;
  GitDiffDocument diffDocument = const GitDiffDocument(
    path: 'lib/feature.dart',
    diff: '',
    staged: false,
  );
  final List<String> commitMessages = <String>[];
  Object? pushError;

  @override
  Future<GitRepositoryState> getRepository(String path) async => repository;

  @override
  Future<GitRepositoryState> stageFile(String repoPath, String file) async =>
      repository;

  @override
  Future<GitRepositoryState> unstageFile(String repoPath, String file) async =>
      repository;

  @override
  Future<GitRepositoryState> discardFile(String repoPath, String file) async =>
      repository;

  @override
  Future<GitRepositoryState> fetch(String repoPath, {String? remote}) async =>
      repository;

  @override
  Future<GitRepositoryState> pull(
    String repoPath, {
    String? remote,
    String? branch,
  }) async => repository;

  @override
  Future<GitRepositoryState> push(
    String repoPath, {
    String? remote,
    String? branch,
    bool setUpstream = false,
  }) async {
    if (pushError != null) {
      throw pushError!;
    }
    return repository;
  }

  @override
  Future<GitRepositoryState> commit(String repoPath, String message) async {
    commitMessages.add(message);
    return repository;
  }

  @override
  Future<GitDiffDocument> getDiff(
    String repoPath,
    String file, {
    bool staged = false,
  }) async {
    return diffDocument;
  }
}
