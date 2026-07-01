import 'dart:async';
import 'dart:convert';

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

  test(
    'openWorkspace restores terminals from the returned workspace',
    () async {
      final client = _FakeBackendClient({
        'workspace.open': (params) {
          expect(params?['root'], _workspace.root);
          expect(params?['reuseExisting'], isTrue);
          return {'workspace': _workspace.toJson()};
        },
        'workspace.subscribe': (_) => {'mode': 'current', 'baseVersion': 1},
        'terminal.list': (params) {
          expect(params?['workspaceId'], _workspace.id);
          return {
            'sessions': [_session.toJson()],
          };
        },
        'terminal.history': (params) {
          expect(params?['sessionId'], _session.id);
          return {
            'scrollbackBase64': base64Encode(const <int>[]),
            'scrollbackOffsetEnd': 0,
          };
        },
        'terminal.subscribe': (_) => {'ok': true},
      })..state.value = BackendConnectionState.connected;
      addTearDown(client.disposeFake);
      final appState = AppState(client: client);
      addTearDown(appState.dispose);

      final ws = await appState.openWorkspace(_workspace.root);
      await Future<void>.delayed(Duration.zero);

      expect(ws, _workspace);
      expect(appState.currentWorkspace, _workspace);
      expect(appState.currentTerminals, hasLength(1));
      expect(appState.currentTerminals.first.id, _session.id);
      expect(
        client.calls.map((c) => c.method),
        containsAllInOrder([
          'workspace.open',
          'terminal.list',
          'terminal.history',
        ]),
      );
    },
  );
}

typedef _FakeHandler = FutureOr<dynamic> Function(Map<String, dynamic>? params);

class _FakeCall {
  final String method;
  final Map<String, dynamic>? params;

  const _FakeCall(this.method, this.params);
}

class _FakeBackendClient extends BackendClient {
  _FakeBackendClient(this.handlers);

  final Map<String, _FakeHandler> handlers;
  final List<_FakeCall> calls = [];
  final StreamController<BackendNotification> _notifs =
      StreamController<BackendNotification>.broadcast();

  @override
  Stream<BackendNotification> get notifications => _notifs.stream;

  @override
  Future<dynamic> call(String method, [Map<String, dynamic>? params]) async {
    calls.add(
      _FakeCall(
        method,
        params == null ? null : Map<String, dynamic>.from(params),
      ),
    );
    final handler = handlers[method];
    if (handler == null) return <String, dynamic>{};
    return handler(params);
  }

  void disposeFake() {
    unawaited(_notifs.close());
  }
}

extension on Workspace {
  Map<String, dynamic> toJson() => {
    'id': id,
    'root': root,
    'label': label,
    'createdAt': createdAt,
  };
}

extension on TerminalSession {
  Map<String, dynamic> toJson() => {
    'id': id,
    'workspaceId': workspaceId,
    'cols': cols,
    'rows': rows,
    'cwd': cwd,
    'createdAt': createdAt,
    if (externalSessionId != null) 'externalSessionId': externalSessionId,
  };
}
