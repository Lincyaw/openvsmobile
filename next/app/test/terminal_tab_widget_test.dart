// Widget tests for the Terminal-tab session list (issue #63).
//
// Coverage:
//   * Empty state renders the "Start terminal" call to action.
//   * A seeded session renders one row with label / cwd basename / a
//     no-output placeholder preview and a relative timestamp.
//   * Injecting bytes through the preview pipeline updates the row's
//     preview text without going over the wire.
//   * ANSI escape sequences (color codes, OSC titles, control chars)
//     are stripped for the preview.
//   * The "+ New" row at the bottom does not respond to long-press.
//
// We don't need a live backend: AppState exposes `debugSeedTerminals` /
// `debugInjectTerminalOutput` as test seams, matching the pattern used by
// `PluginsModel.debugSeed` in plugins_tab_widget_test.dart.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/app_state.dart';
import 'package:mobilecode/backend_client.dart';
import 'package:mobilecode/models.dart';
import 'package:mobilecode/screens/terminal_tab.dart';
import 'package:mobilecode/settings_store.dart';
import 'package:mobilecode/state/terminal_hub.dart';
import 'package:mobilecode/state/terminals_notifier.dart';

const Workspace _ws = Workspace(
  id: 'ws-1',
  root: '/tmp/ws-1',
  label: 'ws-1',
  createdAt: 0,
);

TerminalSession _session(
  String id, {
  String cwd = '/tmp/ws-1/src',
  String? title,
}) {
  return TerminalSession(
    id: id,
    title: title,
    workspaceId: _ws.id,
    cols: 80,
    rows: 24,
    cwd: cwd,
    createdAt: DateTime.now().millisecondsSinceEpoch,
  );
}

Future<AppState> _appStateWith({
  bool workspace = true,
  List<TerminalSession> sessions = const [],
}) async {
  final state = AppState(client: BackendClient());
  if (workspace) {
    state.debugSetActiveWorkspace(_ws);
    if (sessions.isNotEmpty) {
      state.debugSeedTerminals(_ws.id, sessions);
    }
  }
  return state;
}

Widget _wrap(Widget child) => MaterialApp(
  theme: ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
    useMaterial3: true,
  ),
  home: Scaffold(body: child),
);

BackendTarget _backend({
  String id = 'backend-1',
  String name = 'home',
  String host = 'home.local',
}) {
  return BackendTarget(
    id: id,
    name: name,
    host: host,
    port: 7860,
    token: 'token',
    origin: BackendOrigin.manual,
    addedAt: 0,
  );
}

class _FakeTerminalHub extends TerminalHub {
  _FakeTerminalHub(this._groups);

  List<BackendTerminalGroup> _groups;
  final ValueNotifier<int> _previewVersion = ValueNotifier<int>(0);
  String? renamedTitle;

  @override
  List<BackendTerminalGroup> get groups => _groups;

  @override
  ValueNotifier<int> get previewVersion => _previewVersion;

  @override
  Future<void> renameTerminal(
    String backendId,
    String sessionId,
    String? title,
  ) async {
    renamedTitle = title;
    _groups = [
      for (final group in _groups)
        if (group.backend.id != backendId)
          group
        else
          BackendTerminalGroup(
            backend: group.backend,
            connectionState: group.connectionState,
            lastError: group.lastError,
            sessions: [
              for (final session in group.sessions)
                if (session.id == sessionId)
                  session.copyWith(title: title, clearTitle: title == null)
                else
                  session,
            ],
          ),
    ];
    notifyListeners();
  }
}

void main() {
  testWidgets('empty state shows the Start terminal CTA', (tester) async {
    final appState = await _appStateWith(sessions: const []);
    addTearDown(appState.dispose);
    await tester.pumpWidget(_wrap(TerminalTab(appState: appState)));
    await tester.pump();

    expect(find.text('No terminal sessions yet.'), findsOneWidget);
    expect(find.text('Start terminal'), findsOneWidget);
    // The list-mode "+ New" row only renders once at least one session
    // exists; in the empty state the CTA replaces it.
    expect(find.text('New terminal'), findsNothing);
  });

  testWidgets('seeded session renders one row with the no-output placeholder', (
    tester,
  ) async {
    final appState = await _appStateWith(
      sessions: [_session('sid-aaaaaaaaaaaa')],
    );
    addTearDown(appState.dispose);
    await tester.pumpWidget(_wrap(TerminalTab(appState: appState)));
    await tester.pump();

    expect(find.text('sh · 1'), findsOneWidget);
    // cwd basename — "src" comes from /tmp/ws-1/src.
    expect(find.text('src'), findsOneWidget);
    // Placeholder text while the session has no buffered output yet.
    expect(find.text('(no output yet)'), findsOneWidget);
    // The "+ New" trailing row.
    expect(find.text('New terminal'), findsOneWidget);
  });

  testWidgets('preview row updates live when bytes flow through', (
    tester,
  ) async {
    final appState = await _appStateWith(
      sessions: [_session('sid-aaaaaaaaaaaa')],
    );
    addTearDown(appState.dispose);
    await tester.pumpWidget(_wrap(TerminalTab(appState: appState)));
    await tester.pump();

    expect(find.text('(no output yet)'), findsOneWidget);

    // Push a chunk through the preview pipeline — the exact route a live
    // `terminal.data` notification would take, minus the base64 wrap.
    appState.debugInjectTerminalOutput(
      'sid-aaaaaaaaaaaa',
      utf8.encode('hello world\n'),
    );
    await tester.pump();

    expect(find.text('(no output yet)'), findsNothing);
    expect(find.text('hello world'), findsOneWidget);

    // A second chunk replaces the visible preview line — IM-style "last
    // message" semantics, not a cumulative log.
    appState.debugInjectTerminalOutput(
      'sid-aaaaaaaaaaaa',
      utf8.encode('\$ echo done\ndone\n'),
    );
    await tester.pump();

    expect(find.text('hello world'), findsNothing);
    expect(find.text('done'), findsOneWidget);
  });

  testWidgets('custom terminal title overrides the generated row label', (
    tester,
  ) async {
    final appState = await _appStateWith(
      sessions: [_session('sid-aaaaaaaaaaaa', title: 'deploy box')],
    );
    addTearDown(appState.dispose);
    await tester.pumpWidget(_wrap(TerminalTab(appState: appState)));
    await tester.pump();

    expect(find.text('deploy box'), findsOneWidget);
    expect(find.text('sh · 1'), findsNothing);
  });

  testWidgets('ANSI / OSC / control bytes are stripped from the preview', (
    tester,
  ) async {
    final appState = await _appStateWith(
      sessions: [_session('sid-aaaaaaaaaaaa')],
    );
    addTearDown(appState.dispose);
    await tester.pumpWidget(_wrap(TerminalTab(appState: appState)));
    await tester.pump();

    // Colored prompt + OSC title set + bell + visible content.
    appState.debugInjectTerminalOutput(
      'sid-aaaaaaaaaaaa',
      utf8.encode('\x1B]0;bash\x07\x1B[31mERR\x1B[0m: not found\n'),
    );
    await tester.pump();

    expect(find.text('ERR: not found'), findsOneWidget);
  });

  testWidgets('long-press on "+ New" row does NOT trigger the kill dialog', (
    tester,
  ) async {
    final appState = await _appStateWith(
      sessions: [_session('sid-aaaaaaaaaaaa')],
    );
    addTearDown(appState.dispose);
    await tester.pumpWidget(_wrap(TerminalTab(appState: appState)));
    await tester.pump();

    await tester.longPress(find.text('New terminal'));
    await tester.pump();

    // No dialog should have appeared (the kill confirm copy lives on
    // session-row long-press only).
    expect(find.text('Close terminal?'), findsNothing);
  });

  test('extractPreviewLine returns the last non-empty line', () {
    final bytes = Uint8List.fromList(utf8.encode('line1\nline2\n   \n'));
    expect(extractPreviewLine(bytes), 'line2');
  });

  test('extractPreviewLine truncates with an ellipsis past maxLen', () {
    final long = 'a' * 80;
    final bytes = Uint8List.fromList(utf8.encode(long));
    final preview = extractPreviewLine(bytes, maxLen: 10);
    expect(preview, isNotNull);
    expect(preview!.length, 10);
    expect(preview.endsWith('…'), isTrue);
  });

  testWidgets('detached chip renders the "(detached)" hint', (tester) async {
    final detached = TerminalSession(
      id: 'sid-detached-00',
      workspaceId: _ws.id,
      cols: 80,
      rows: 24,
      cwd: '/tmp/ws-1/src',
      createdAt: DateTime.now().millisecondsSinceEpoch,
      detached: true,
    );
    final appState = await _appStateWith(sessions: [detached]);
    addTearDown(appState.dispose);
    await tester.pumpWidget(_wrap(TerminalTab(appState: appState)));
    await tester.pump();

    expect(find.text('(detached)'), findsOneWidget);
    expect(find.text('sh · 1'), findsOneWidget);
  });

  testWidgets('backend header truncates long status on narrow screens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final appState = await _appStateWith(workspace: false);
    addTearDown(appState.dispose);
    final hub = _FakeTerminalHub([
      BackendTerminalGroup(
        backend: _backend(
          name: 'home server with an intentionally long display name',
          host: '100.125.63.101',
        ),
        connectionState: BackendConnectionState.failed,
        lastError:
            'Iroh connection failed because the endpoint ticket expired before '
            'the relay path could be established',
        sessions: const [],
      ),
    ]);
    addTearDown(hub.dispose);

    await tester.pumpWidget(
      _wrap(TerminalTab(appState: appState, terminalHub: hub)),
    );
    await tester.pump();

    expect(find.textContaining('Iroh connection failed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renaming a hub terminal updates after dialog closes safely', (
    tester,
  ) async {
    final appState = await _appStateWith(workspace: false);
    addTearDown(appState.dispose);
    final session = _session('sid-hub-rename');
    final hub = _FakeTerminalHub([
      BackendTerminalGroup(
        backend: _backend(),
        connectionState: BackendConnectionState.connected,
        lastError: null,
        sessions: [session],
      ),
    ]);
    addTearDown(hub.dispose);

    await tester.pumpWidget(
      _wrap(TerminalTab(appState: appState, terminalHub: hub)),
    );
    await tester.pump();

    await tester.longPress(find.text('sh · 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'prod shell');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(hub.renamedTitle, 'prod shell');
    expect(find.text('prod shell'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('extractPreviewLine returns null for empty / whitespace-only input', () {
    expect(extractPreviewLine(Uint8List(0)), isNull);
    expect(
      extractPreviewLine(Uint8List.fromList(utf8.encode('   \n  \n'))),
      isNull,
    );
  });
}
