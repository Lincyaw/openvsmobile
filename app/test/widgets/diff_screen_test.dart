import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vscode_mobile/models/git_models.dart';
import 'package:vscode_mobile/providers/git_provider.dart';
import 'package:vscode_mobile/screens/diff_screen.dart';
import 'package:vscode_mobile/services/git_api_client.dart';
import 'package:vscode_mobile/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('renders a loading state while diff content is being fetched', (
    tester,
  ) async {
    final apiClient = await _buildApiClient();
    apiClient.diffFuture = Completer<GitDiffDocument>().future;

    await tester.pumpWidget(_buildApp(apiClient));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('renders an empty state when no diff content exists', (
    tester,
  ) async {
    final apiClient = await _buildApiClient();
    apiClient.diffFuture = Future<GitDiffDocument>.value(
      const GitDiffDocument(path: 'lib/feature.dart', diff: '', staged: false),
    );

    await tester.pumpWidget(_buildApp(apiClient));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('No diff available for this file'), findsOneWidget);
  });

  testWidgets('renders diff content when a unified diff is available', (
    tester,
  ) async {
    final apiClient = await _buildApiClient();
    apiClient.diffFuture = Future<GitDiffDocument>.value(
      const GitDiffDocument(
        path: 'lib/feature.dart',
        diff:
            'diff --git a/lib/feature.dart b/lib/feature.dart\n@@ -1 +1 @@\n-old\n+new',
        staged: false,
      ),
    );

    await tester.pumpWidget(_buildApp(apiClient));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      find.textContaining('diff --git a/lib/feature.dart b/lib/feature.dart'),
      findsOneWidget,
    );
    expect(find.text('+new'), findsOneWidget);
    expect(find.text('-old'), findsOneWidget);
  });

  testWidgets(
    'renders an explicit error state when diff loading fails and exposes retry',
    (tester) async {
      final apiClient = await _buildApiClient();
      final firstAttempt = Completer<GitDiffDocument>();
      final retryAttempt = Completer<GitDiffDocument>();
      apiClient.diffResponses = <Future<GitDiffDocument>>[
        firstAttempt.future,
        retryAttempt.future,
      ];

      await tester.pumpWidget(_buildApp(apiClient));
      await tester.pump();

      firstAttempt.completeError(Exception('failed to load diff'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('Failed to load diff'), findsOneWidget);
      expect(find.textContaining('failed to load diff'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Try again'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.widgetWithText(FilledButton, 'Try again'));
      await tester.pump();

      expect(apiClient.diffRequests, 2);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      retryAttempt.complete(
        const GitDiffDocument(
          path: 'lib/feature.dart',
          diff: '',
          staged: false,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No diff available for this file'), findsOneWidget);
    },
  );
}

Future<_FakeDiffApiClient> _buildApiClient() async {
  final settings = SettingsService();
  await settings.save('http://localhost:8080', 'secret');
  return _FakeDiffApiClient(settings);
}

Widget _buildApp(_FakeDiffApiClient apiClient) {
  return ChangeNotifierProvider<GitProvider>(
    create: (_) => GitProvider(apiClient: apiClient),
    child: const MaterialApp(
      home: DiffScreen(filePath: 'lib/feature.dart', staged: false),
    ),
  );
}

class _FakeDiffApiClient extends GitApiClient {
  _FakeDiffApiClient(SettingsService settings) : super(settings: settings);

  Future<GitDiffDocument> diffFuture = Future<GitDiffDocument>.value(
    const GitDiffDocument(path: 'lib/feature.dart', diff: '', staged: false),
  );
  List<Future<GitDiffDocument>> diffResponses = <Future<GitDiffDocument>>[];
  int diffRequests = 0;

  @override
  Future<GitDiffDocument> getDiff(
    String repoPath,
    String file, {
    bool staged = false,
  }) {
    diffRequests += 1;
    if (diffResponses.isNotEmpty) {
      return diffResponses.removeAt(0);
    }
    return diffFuture;
  }
}
