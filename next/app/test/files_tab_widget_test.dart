// Widget + state tests for the Files-tab surface.
//
// What's testable without a backend:
//   * The empty-state path when no workspace is current.
//   * AppState's changes-view toggle bookkeeping.
//   * The model-side data the status bar / decoration badges read from
//     (decoration map, dir rollup, branch info).
//
// What's NOT testable here — and is covered by the manual gate in the PR
// plan: the full Files tab render with a "current workspace" set. Setting
// currentWorkspace requires `workspace.open` over the wire; we don't mock
// that. The unit tests in `workspace_model_test.dart` cover the
// rollup/decoration logic the widgets consume, and the empty-state
// widget test exercises the FilesTab build path itself.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openvsmobile_next/app_state.dart';
import 'package:openvsmobile_next/backend_client.dart';
import 'package:openvsmobile_next/screens/files_tab.dart';

Future<void> _pumpFilesTab(WidgetTester tester, AppState appState) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: Scaffold(body: FilesTab(appState: appState)),
    ),
  );
  await tester.pump();
}

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
}
