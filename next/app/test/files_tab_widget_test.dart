// Widget + state tests for the Files-tab surface.
//
// What's testable without a backend:
//   * The empty-state path when no workspace is current.
//   * AppState's changes-view toggle bookkeeping.
//   * The model-side data the status bar / decoration badges read from
//     (decoration map, dir rollup, branch info).
//   * The search bar: debounce, results render, tap → file viewer (the
//     RPC + viewer-open paths are stubbed via FilesTab's test seams).
//
// The full file-tree render with a "current workspace" set is covered via
// `debugSetActiveWorkspace`; the unit tests in `workspace_model_test.dart`
// cover the rollup/decoration logic the widgets consume.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/app_state.dart';
import 'package:mobilecode/backend_client.dart';
import 'package:mobilecode/models.dart';
import 'package:mobilecode/screens/files_tab.dart';

Future<void> _pumpFilesTab(
  WidgetTester tester,
  AppState appState, {
  FindFilesFn? searchOverride,
  OpenSearchResultFn? openSearchResultOverride,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: Scaffold(
        body: FilesTab(
          appState: appState,
          searchOverride: searchOverride,
          openSearchResultOverride: openSearchResultOverride,
        ),
      ),
    ),
  );
  await tester.pump();
}

Workspace _testWorkspace() => const Workspace(
      id: 'ws-test',
      root: '/tmp/ws-test',
      label: 'ws-test',
      createdAt: 0,
    );

void main() {
  testWidgets('FilesTab shows empty state when no workspace is current',
      (tester) async {
    final appState = AppState(client: BackendClient());
    addTearDown(appState.dispose);
    await _pumpFilesTab(tester, appState);
    expect(
      find.text('No workspace open.\nTap the title bar to choose one.'),
      findsOneWidget,
    );
  });

  test('toggleChangesView flips the AppState flag', () {
    final appState = AppState(client: BackendClient());
    addTearDown(appState.dispose);
    expect(appState.changesViewActive, isFalse);
    appState.toggleChangesView();
    expect(appState.changesViewActive, isTrue);
    appState.toggleChangesView();
    expect(appState.changesViewActive, isFalse);
  });

  test('M file populates decorationMap; rollup propagates up ancestors', () {
    final appState = AppState(client: BackendClient());
    addTearDown(appState.dispose);
    appState.workspaces.onDecorationDelta({
      'workspaceId': 'ws-1',
      'version': 1,
      'entries': [
        {'path': 'lib/a.dart', 'status': 'M'},
      ],
    });
    final st = appState.workspaceStateFor('ws-1')!;
    expect(st.decorationMap['lib/a.dart'], 'M');
    expect(st.dirRollup['lib'], 1);
    expect(st.dirRollup[''], 1);
  });

  test('folder rollup aggregates across decorated descendants', () {
    final appState = AppState(client: BackendClient());
    addTearDown(appState.dispose);
    appState.workspaces.onDecorationSnapshot({
      'workspaceId': 'ws-1',
      'version': 1,
      'entries': [
        {'path': 'src/sub/a.dart', 'status': 'A'},
        {'path': 'src/sub/b.dart', 'status': 'M'},
        {'path': 'src/c.dart', 'status': '?'},
        {'path': 'README.md', 'status': 'M'},
      ],
    });
    final st = appState.workspaceStateFor('ws-1')!;
    expect(st.dirRollup['src'], 3);
    expect(st.dirRollup['src/sub'], 2);
    expect(st.dirRollup[''], 4);
  });

  test('branch / ahead / behind populate from head.changed', () {
    final appState = AppState(client: BackendClient());
    addTearDown(appState.dispose);
    appState.workspaces.onHeadChanged({
      'workspaceId': 'ws-1',
      'version': 1,
      'branch': 'main',
      'headSha': 'abc',
      'ahead': 3,
      'behind': 2,
    });
    final st = appState.workspaceStateFor('ws-1')!;
    expect(st.branch, 'main');
    expect(st.ahead, 3);
    expect(st.behind, 2);
    expect(st.isGitRepo, isTrue);
  });

  testWidgets(
    'search bar runs query through searchOverride, renders results, '
    'tap navigates to file viewer',
    (tester) async {
      final appState = AppState(client: BackendClient());
      addTearDown(appState.dispose);
      appState.debugSetActiveWorkspace(_testWorkspace());

      String? capturedQuery;
      String? tappedPath;
      Future<FindFilesResult> fakeSearch(String wsId, String q) async {
        capturedQuery = q;
        expect(wsId, 'ws-test');
        return const FindFilesResult(
          matches: [
            FindFilesMatch(path: 'foo/bar.md', score: 999),
            FindFilesMatch(path: 'lib/main.dart', score: 500),
          ],
          truncated: false,
        );
      }

      Future<void> fakeOpen(
        BuildContext context,
        String workspaceId,
        String relPath,
      ) async {
        tappedPath = relPath;
      }

      await _pumpFilesTab(
        tester,
        appState,
        searchOverride: fakeSearch,
        openSearchResultOverride: fakeOpen,
      );

      // Empty query: results pane should not render — the file tree path
      // is what's shown. (The tree will be in its "Loading workspace…"
      // placeholder because no fs.listDir is wired here; that's fine.)
      expect(find.text('foo/bar.md'), findsNothing);

      final field = find.byType(TextField);
      expect(field, findsOneWidget);
      await tester.enterText(field, 'fobar');
      // Debounce is 120 ms; pump well past it and let the fake RPC resolve.
      await tester.pump(const Duration(milliseconds: 130));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(capturedQuery, 'fobar');
      // Filename appears bold (RichText with highlighted spans); the dimmed
      // dir prefix appears as a plain Text widget. `findRichText: true` lets
      // the matcher recurse into RichText descendants.
      expect(find.text('bar.md', findRichText: true), findsOneWidget);
      expect(find.text('foo/'), findsOneWidget);
      expect(find.text('main.dart', findRichText: true), findsOneWidget);

      // Tap a result — the override fires, recording the workspace-
      // relative path. (Production wires this to a Navigator.push, but
      // we verify the upstream contract instead of poking at routes.)
      await tester.tap(find.text('bar.md', findRichText: true));
      await tester.pumpAndSettle();
      expect(tappedPath, 'foo/bar.md');
    },
  );

  testWidgets(
    'clear button restores tree view by emptying the query',
    (tester) async {
      final appState = AppState(client: BackendClient());
      addTearDown(appState.dispose);
      appState.debugSetActiveWorkspace(_testWorkspace());

      Future<FindFilesResult> fakeSearch(String wsId, String q) async {
        return const FindFilesResult(
          matches: [FindFilesMatch(path: 'foo/bar.md', score: 1)],
          truncated: false,
        );
      }

      await _pumpFilesTab(
        tester,
        appState,
        searchOverride: fakeSearch,
        openSearchResultOverride: (_, _, _) async {},
      );

      await tester.enterText(find.byType(TextField), 'bar');
      await tester.pump(const Duration(milliseconds: 130));
      await tester.pumpAndSettle();
      expect(find.text('bar.md', findRichText: true), findsOneWidget);

      // Tap the clear (close) icon in the search bar.
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.text('bar.md', findRichText: true), findsNothing);
      // Search-results pane is gone. The text field is still mounted —
      // clearing collapses the results, not the bar itself.
      expect(find.byType(TextField), findsOneWidget);
    },
  );

  testWidgets(
    'stale search results are dropped when a newer keystroke wins',
    (tester) async {
      final appState = AppState(client: BackendClient());
      addTearDown(appState.dispose);
      appState.debugSetActiveWorkspace(_testWorkspace());

      // First search blocks on a completer; second search resolves
      // synchronously. The stale (slow) one must NOT overwrite the fresh
      // results when it finally lands.
      Completer<FindFilesResult>? slowCompleter;
      Future<FindFilesResult> fakeSearch(String wsId, String q) {
        if (q == 'aaa') {
          final completer = Completer<FindFilesResult>();
          slowCompleter = completer;
          return completer.future;
        }
        return Future.value(
          const FindFilesResult(
            matches: [FindFilesMatch(path: 'fast/hit.md', score: 10)],
            truncated: false,
          ),
        );
      }

      await _pumpFilesTab(
        tester,
        appState,
        searchOverride: fakeSearch,
        openSearchResultOverride: (_, _, _) async {},
      );

      // First keystroke: slow search begins.
      await tester.enterText(find.byType(TextField), 'aaa');
      await tester.pump(const Duration(milliseconds: 130));
      // Don't complete the slow future yet — the search is still in flight.
      expect(slowCompleter, isNotNull);

      // Second keystroke: fast search resolves with different results.
      await tester.enterText(find.byType(TextField), 'bbb');
      await tester.pump(const Duration(milliseconds: 130));
      await tester.pumpAndSettle();
      expect(find.text('hit.md', findRichText: true), findsOneWidget);

      // Now complete the slow future. It must not replace the visible
      // results — its seq is stale.
      slowCompleter!.complete(
        const FindFilesResult(
          matches: [FindFilesMatch(path: 'slow/old.md', score: 1)],
          truncated: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('old.md', findRichText: true), findsNothing);
      expect(find.text('hit.md', findRichText: true), findsOneWidget);
    },
  );
}
