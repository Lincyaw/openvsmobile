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
import 'package:mobilecode/screens/terminal_detail.dart';
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
  String? externalSessionId,
  String? workspaceRoot,
}) {
  return TerminalSession(
    id: id,
    title: title,
    workspaceId: _ws.id,
    workspaceRoot: workspaceRoot,
    cols: 80,
    rows: 24,
    cwd: cwd,
    createdAt: DateTime.now().millisecondsSinceEpoch,
    externalSessionId: externalSessionId,
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
  int port = 7860,
  BackendTransport transport = BackendTransport.websocket,
  String? irohEndpointId,
  String? irohTicket,
}) {
  return BackendTarget(
    id: id,
    name: name,
    host: host,
    port: port,
    token: 'token',
    transport: transport,
    irohEndpointId: irohEndpointId,
    irohTicket: irohTicket,
    origin: BackendOrigin.manual,
    addedAt: 0,
  );
}

class _FakeTerminalHub extends TerminalHub {
  _FakeTerminalHub(this._groups);

  List<BackendTerminalGroup> _groups;
  final ValueNotifier<int> _previewVersion = ValueNotifier<int>(0);
  final Map<String, TerminalPreview> _previews = {};
  String? renamedTitle;

  @override
  List<BackendTerminalGroup> get groups => _groups;

  @override
  ValueNotifier<int> get previewVersion => _previewVersion;

  @override
  TerminalPreview previewFor(String backendId, String sessionId) =>
      _previews['$backendId/$sessionId'] ??
      const TerminalPreview(text: null, lastDataAt: null);

  void setPreview(
    String backendId,
    String sessionId, {
    required String text,
    String? recentText,
  }) {
    _previews['$backendId/$sessionId'] = TerminalPreview(
      text: text,
      lastDataAt: DateTime.now().millisecondsSinceEpoch,
      recentText: recentText ?? text,
    );
    _previewVersion.value += 1;
  }

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

  testWidgets('agent sessions render compact Claude and Codex tags', (
    tester,
  ) async {
    final appState = await _appStateWith(
      sessions: [
        _session('sid-claude'),
        _session('sid-codex', externalSessionId: 'codex-prod-review'),
      ],
    );
    addTearDown(appState.dispose);
    await tester.pumpWidget(_wrap(TerminalTab(appState: appState)));
    await tester.pump();

    appState.debugInjectTerminalOutput(
      'sid-claude',
      utf8.encode('Welcome to Claude Code\n'),
    );
    await tester.pump();

    expect(find.text('Claude'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
  });

  testWidgets('plain .codex preview does not render an agent tag', (
    tester,
  ) async {
    final appState = await _appStateWith(
      sessions: [_session('sid-plain-shell')],
    );
    addTearDown(appState.dispose);
    await tester.pumpWidget(_wrap(TerminalTab(appState: appState)));
    await tester.pump();

    appState.debugInjectTerminalOutput(
      'sid-plain-shell',
      utf8.encode('.codex\n'),
    );
    await tester.pump();

    expect(find.text('.codex'), findsOneWidget);
    expect(find.text('Codex'), findsNothing);
  });

  testWidgets('shell command invocation can identify a Claude agent session', (
    tester,
  ) async {
    final appState = await _appStateWith(
      sessions: [_session('sid-claude-cmd')],
    );
    addTearDown(appState.dispose);
    await tester.pumpWidget(_wrap(TerminalTab(appState: appState)));
    await tester.pump();

    appState.debugInjectTerminalOutput(
      'sid-claude-cmd',
      utf8.encode('\$ claude --resume\n'),
    );
    await tester.pump();

    expect(find.text('Claude'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('terminal-agent-activity-strip')),
      findsOneWidget,
    );
    expect(find.text('Claude agent'), findsOneWidget);
  });

  testWidgets('Codex product text identifies a Codex agent session', (
    tester,
  ) async {
    final appState = await _appStateWith(sessions: [_session('sid-codex-ui')]);
    addTearDown(appState.dispose);
    await tester.pumpWidget(_wrap(TerminalTab(appState: appState)));
    await tester.pump();

    appState.debugInjectTerminalOutput(
      'sid-codex-ui',
      utf8.encode('GPT-5 Codex\nAsk for a coding task\n'),
    );
    await tester.pump();

    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Codex agent'), findsOneWidget);
  });

  testWidgets('Claude status text renders an agent tag', (tester) async {
    final appState = await _appStateWith(
      sessions: [_session('sid-claude-status')],
    );
    addTearDown(appState.dispose);
    await tester.pumpWidget(_wrap(TerminalTab(appState: appState)));
    await tester.pump();

    appState.debugInjectTerminalOutput(
      'sid-claude-status',
      utf8.encode('bypass permissions on (shift+tab to cycle)\n'),
    );
    await tester.pump();

    expect(
      find.text('bypass permissions on (shift+tab to cycle)'),
      findsOneWidget,
    );
    expect(find.text('Claude'), findsOneWidget);
    expect(find.text('Needs input'), findsNothing);
  });

  testWidgets('agent approval prompt renders a needs-input tag', (
    tester,
  ) async {
    final appState = await _appStateWith(
      sessions: [_session('sid-claude-approval')],
    );
    addTearDown(appState.dispose);
    await tester.pumpWidget(_wrap(TerminalTab(appState: appState)));
    await tester.pump();

    appState.debugInjectTerminalOutput(
      'sid-claude-approval',
      utf8.encode(
        'Welcome to Claude Code\n'
        'Do you want to proceed?\n'
        '1. Yes\n',
      ),
    );
    await tester.pump();

    expect(find.text('1. Yes'), findsOneWidget);
    expect(find.text('Claude'), findsOneWidget);
    expect(find.text('Needs input'), findsOneWidget);
  });

  testWidgets('agent activity strip summarizes and opens waiting agents', (
    tester,
  ) async {
    final appState = await _appStateWith(
      sessions: [
        _session('sid-codex-active', externalSessionId: 'codex-prod-review'),
        _session('sid-claude-waiting', title: 'claude review'),
        _session('sid-shell'),
      ],
    );
    addTearDown(appState.dispose);
    await tester.pumpWidget(_wrap(TerminalTab(appState: appState)));
    await tester.pump();

    appState.debugInjectTerminalOutput(
      'sid-claude-waiting',
      utf8.encode(
        'Welcome to Claude Code\n'
        'Do you want to proceed?\n'
        '1. Yes\n',
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('terminal-agent-activity-strip')),
      findsOneWidget,
    );
    expect(find.text('Agent activity'), findsOneWidget);
    expect(find.text('1 waiting · 2 active'), findsOneWidget);
    expect(find.text('Needs input: Do you want to proceed?'), findsOneWidget);
    expect(find.text('Claude agent'), findsOneWidget);
    expect(find.text('Codex agent'), findsOneWidget);
    expect(find.text('sid-shell'), findsNothing);

    await tester.tap(
      find.byKey(
        const ValueKey<String>('terminal-agent-activity:sid-claude-waiting'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TerminalDetailScreen), findsOneWidget);
    expect(find.text('claude review'), findsOneWidget);
  });

  testWidgets('plain shell prompt does not render a needs-input tag', (
    tester,
  ) async {
    final appState = await _appStateWith(
      sessions: [_session('sid-shell-prompt')],
    );
    addTearDown(appState.dispose);
    await tester.pumpWidget(_wrap(TerminalTab(appState: appState)));
    await tester.pump();

    appState.debugInjectTerminalOutput(
      'sid-shell-prompt',
      utf8.encode('Do you want to proceed?\n'),
    );
    await tester.pump();

    expect(find.text('Do you want to proceed?'), findsOneWidget);
    expect(find.text('Needs input'), findsNothing);
  });

  testWidgets('Codex command approval prompt renders as waiting input', (
    tester,
  ) async {
    final appState = await _appStateWith(sessions: [_session('sid-codex-run')]);
    addTearDown(appState.dispose);
    await tester.pumpWidget(_wrap(TerminalTab(appState: appState)));
    await tester.pump();

    appState.debugInjectTerminalOutput(
      'sid-codex-run',
      utf8.encode(
        'GPT-5 Codex\n'
        'Allow command?\n'
        '1. Yes\n',
      ),
    );
    await tester.pump();

    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Needs input'), findsOneWidget);
    expect(find.text('Needs input: Allow command?'), findsOneWidget);
  });

  testWidgets('session action sheet can open linked files', (tester) async {
    final session = _session('sid-linked-files', workspaceRoot: '/tmp/ws-1');
    final appState = await _appStateWith(sessions: [session]);
    addTearDown(appState.dispose);
    final opened = <TerminalSession>[];

    await tester.pumpWidget(
      _wrap(
        TerminalTab(
          appState: appState,
          onOpenFilesForSession: (session) async {
            opened.add(session);
          },
        ),
      ),
    );
    await tester.pump();

    await tester.longPress(find.text('sh · 1'));
    await tester.pumpAndSettle();

    expect(find.text('Open files'), findsOneWidget);
    expect(find.text('/tmp/ws-1'), findsOneWidget);

    await tester.tap(find.text('Open files'));
    await tester.pumpAndSettle();

    expect(opened, hasLength(1));
    expect(opened.single.id, 'sid-linked-files');
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

    expect(find.text('Iroh ticket expired'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('backend header summarizes reconnect errors readably', (
    tester,
  ) async {
    final appState = await _appStateWith(workspace: false);
    addTearDown(appState.dispose);
    final hub = _FakeTerminalHub([
      BackendTerminalGroup(
        backend: _backend(name: 'phone relay'),
        connectionState: BackendConnectionState.reconnecting,
        lastError:
            'socket error: PlatformException(IROH_CLOSED, frame too large, null, null)',
        sessions: const [],
      ),
    ]);
    addTearDown(hub.dispose);

    await tester.pumpWidget(
      _wrap(TerminalTab(appState: appState, terminalHub: hub)),
    );
    await tester.pump();

    expect(find.text('reconnecting: Message too large'), findsOneWidget);
    expect(find.textContaining('PlatformException'), findsNothing);
  });

  testWidgets(
    'Iroh backend header shows readable endpoint and terminal count',
    (tester) async {
      final appState = await _appStateWith(workspace: false);
      addTearDown(appState.dispose);
      final hub = _FakeTerminalHub([
        BackendTerminalGroup(
          backend: _backend(
            name: 'iroh backend',
            host: '',
            port: 0,
            transport: BackendTransport.iroh,
            irohEndpointId: 'endpoint-abcdef0123456789',
          ),
          connectionState: BackendConnectionState.connected,
          lastError: null,
          sessions: [_session('sid-aaaaaaaaaaaa', cwd: '/tmp/AgentM')],
        ),
      ]);
      addTearDown(hub.dispose);

      await tester.pumpWidget(
        _wrap(TerminalTab(appState: appState, terminalHub: hub)),
      );
      await tester.pump();

      expect(find.textContaining('Iroh endpoint-abc'), findsOneWidget);
      expect(find.byTooltip('1 terminal'), findsOneWidget);
      expect(find.textContaining('iroh:'), findsNothing);
      expect(find.textContaining(':0'), findsNothing);
    },
  );

  testWidgets('duplicate backend names get short identity suffixes', (
    tester,
  ) async {
    final appState = await _appStateWith(workspace: false);
    addTearDown(appState.dispose);
    final hub = _FakeTerminalHub([
      BackendTerminalGroup(
        backend: _backend(
          id: 'backend-a',
          name: 'iroh backend',
          transport: BackendTransport.iroh,
          irohEndpointId: 'endpoint-abcdef0123456789',
        ),
        connectionState: BackendConnectionState.connected,
        lastError: null,
        sessions: const [],
      ),
      BackendTerminalGroup(
        backend: _backend(
          id: 'backend-b',
          name: 'iroh backend',
          transport: BackendTransport.iroh,
          irohEndpointId: 'endpoint-fedcba9876543210',
        ),
        connectionState: BackendConnectionState.connected,
        lastError: null,
        sessions: const [],
      ),
    ]);
    addTearDown(hub.dispose);

    await tester.pumpWidget(
      _wrap(TerminalTab(appState: appState, terminalHub: hub)),
    );
    await tester.pump();

    expect(find.text('iroh backend'), findsNWidgets(2));
    expect(find.text('#456789'), findsOneWidget);
    expect(find.text('#543210'), findsOneWidget);
    expect(find.byTooltip('Backend identity #456789'), findsOneWidget);
    expect(find.byTooltip('Backend identity #543210'), findsOneWidget);
    expect(find.byTooltip('No terminals'), findsNWidgets(2));
    expect(find.text('connected'), findsNothing);
  });

  testWidgets('backend header marks the active backend', (tester) async {
    final appState = await _appStateWith(workspace: false);
    addTearDown(appState.dispose);
    final hub = _FakeTerminalHub([
      BackendTerminalGroup(
        backend: _backend(id: 'backend-a', name: 'workstation'),
        connectionState: BackendConnectionState.connected,
        lastError: null,
        sessions: const [],
      ),
      BackendTerminalGroup(
        backend: _backend(id: 'backend-b', name: 'phone relay'),
        connectionState: BackendConnectionState.connected,
        lastError: null,
        sessions: const [],
      ),
    ]);
    addTearDown(hub.dispose);

    await tester.pumpWidget(
      _wrap(
        TerminalTab(
          appState: appState,
          terminalHub: hub,
          activeBackendId: 'backend-b',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Active'), findsOneWidget);
    expect(find.byTooltip('Active backend'), findsOneWidget);
  });

  testWidgets('backend header summarizes agent sessions', (tester) async {
    final appState = await _appStateWith(workspace: false);
    addTearDown(appState.dispose);
    final hub = _FakeTerminalHub([
      BackendTerminalGroup(
        backend: _backend(name: 'prod'),
        connectionState: BackendConnectionState.connected,
        lastError: null,
        sessions: [
          _session('sid-codex-agent', externalSessionId: 'codex-prod-review'),
          _session('sid-shell'),
        ],
      ),
    ]);
    addTearDown(hub.dispose);

    await tester.pumpWidget(
      _wrap(TerminalTab(appState: appState, terminalHub: hub)),
    );
    await tester.pump();

    expect(find.text('1 agent'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
    expect(find.byTooltip('2 terminals'), findsOneWidget);
  });

  testWidgets('collapsed backend header keeps agent attention visible', (
    tester,
  ) async {
    final appState = await _appStateWith(workspace: false);
    addTearDown(appState.dispose);
    final hub = _FakeTerminalHub([
      BackendTerminalGroup(
        backend: _backend(name: 'prod'),
        connectionState: BackendConnectionState.connected,
        lastError: null,
        sessions: [_session('sid-claude-agent', title: 'claude review')],
      ),
    ]);
    hub.setPreview(
      'backend-1',
      'sid-claude-agent',
      text: '1. Yes',
      recentText: 'Do you want to proceed?\n1. Yes',
    );
    addTearDown(hub.dispose);

    await tester.pumpWidget(
      _wrap(TerminalTab(appState: appState, terminalHub: hub)),
    );
    await tester.pump();

    await tester.tap(find.text('prod'));
    await tester.pumpAndSettle();

    expect(find.text('claude review'), findsNothing);
    expect(find.text('Needs input'), findsOneWidget);
  });

  testWidgets('hub session action sheet can open linked files', (tester) async {
    final appState = await _appStateWith(workspace: false);
    addTearDown(appState.dispose);
    final backend = _backend(name: 'prod');
    final session = _session('sid-hub-linked-files', workspaceRoot: '/srv/app');
    final hub = _FakeTerminalHub([
      BackendTerminalGroup(
        backend: backend,
        connectionState: BackendConnectionState.connected,
        lastError: null,
        sessions: [session],
      ),
    ]);
    addTearDown(hub.dispose);
    final opened = <BackendTerminalSession>[];

    await tester.pumpWidget(
      _wrap(
        TerminalTab(
          appState: appState,
          terminalHub: hub,
          onOpenFilesForBackendSession: (session) async {
            opened.add(session);
          },
        ),
      ),
    );
    await tester.pump();

    await tester.longPress(find.text('sh · 1'));
    await tester.pumpAndSettle();

    expect(find.text('Open files'), findsOneWidget);
    expect(find.text('prod · /srv/app'), findsOneWidget);

    await tester.tap(find.text('Open files'));
    await tester.pumpAndSettle();

    expect(opened, hasLength(1));
    expect(opened.single.backend.id, backend.id);
    expect(opened.single.session.id, 'sid-hub-linked-files');
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
