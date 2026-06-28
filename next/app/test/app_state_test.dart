import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/app_state.dart';
import 'package:mobilecode/backend_client.dart';
import 'package:mobilecode/models.dart';
import 'package:mobilecode/selection_context.dart';

const _workspace = Workspace(
  id: 'ws-1',
  root: '/tmp/ws-1',
  label: 'ws-1',
  createdAt: 0,
);

const _session = TerminalSession(
  id: 'term-1',
  workspaceId: 'ws-1',
  cols: 80,
  rows: 24,
  cwd: '/tmp/ws-1',
  createdAt: 0,
);

void main() {
  test('resetForBackendSession clears server-derived state', () {
    final appState = AppState(client: BackendClient());
    addTearDown(appState.dispose);

    appState.debugSetActiveWorkspace(_workspace);
    appState.debugSeedTerminals(_workspace.id, const [_session]);
    appState.debugSetFileTree(
      _workspace.id,
      FileTreeNode(path: _workspace.root, name: _workspace.label, isDir: true),
    );
    final selection = SelectionContext.fromFileOffsets(
      path: '/tmp/ws-1/lib/a.dart',
      fullText: 'hello world',
      baseOffset: 0,
      extentOffset: 5,
      language: 'dart',
    )!;
    appState.setSelectionContext(selection);
    appState.setChangesView(true);

    expect(appState.currentWorkspace, _workspace);
    expect(appState.currentTerminals, hasLength(1));
    expect(appState.fileTreeFor(_workspace.id), isNotNull);
    expect(appState.changesViewActive, isTrue);

    final before = appState.backendSessionEpoch;
    appState.resetForBackendSession();

    expect(appState.backendSessionEpoch, before + 1);
    expect(appState.currentWorkspace, isNull);
    expect(appState.activeWorkspaces, isEmpty);
    expect(appState.recentRoots, isEmpty);
    expect(appState.currentTerminals, isEmpty);
    expect(appState.terminalSessionFor(_session.id), isNull);
    expect(appState.terminalForIfKnown(_session.id), isNull);
    expect(appState.fileTreeFor(_workspace.id), isNull);
    expect(appState.selectionContext, isNull);
    expect(appState.changesViewActive, isFalse);
  });

  test(
    'selection context can be scoped and serialized for plugin commands',
    () {
      final appState = AppState(client: BackendClient());
      addTearDown(appState.dispose);
      final selection = SelectionContext.fromFileOffsets(
        path: '/tmp/ws-1/lib/a.dart',
        fullText: 'hello\nworld',
        baseOffset: 6,
        extentOffset: 11,
        language: 'dart',
      )!;

      appState.setSelectionContext(selection);
      appState.clearSelectionContext(sourceId: 'file:/other.dart');
      expect(appState.selectionContext, selection);

      expect(selection.toJson(), {
        'source': 'file',
        'sourceId': 'file:/tmp/ws-1/lib/a.dart',
        'path': '/tmp/ws-1/lib/a.dart',
        'text': 'world',
        'language': 'dart',
        'range': {
          'start': {'line': 2, 'column': 1},
          'end': {'line': 2, 'column': 6},
          'endExclusive': true,
        },
      });

      appState.clearSelectionContext(sourceId: selection.sourceId);
      expect(appState.selectionContext, isNull);
    },
  );
}
