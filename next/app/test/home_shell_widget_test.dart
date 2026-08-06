// Widget tests for the HomeShell bottom navigation layout (issue #62).
//
// What's testable without a connected backend:
//   * Bottom nav shows the expected destinations in order.
//   * Tapping each destination switches the visible body to the right tab.
//   * The Settings tab lists the spec'd entries (backend servers / install /
//     Diagnostics / About) plus the carry-over Notifications entry, with
//     About navigating into the AboutScreen and routing back to Settings
//     (not Files) after a backends-add flow.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/app_state.dart';
import 'package:mobilecode/backend_client.dart';
import 'package:mobilecode/models.dart';
import 'package:mobilecode/notification.dart';
import 'package:mobilecode/screens/about_screen.dart';
import 'package:mobilecode/screens/home_shell.dart';
import 'package:mobilecode/screens/settings_tab.dart';
import 'package:mobilecode/services/system_tray.dart';
import 'package:mobilecode/settings_store.dart';
import 'package:mobilecode/state/terminal_hub.dart';

Future<void> _pumpHomeShell(
  WidgetTester tester, {
  required AppState appState,
  AppPersistedState? persistedState,
  TerminalHub? terminalHub,
  VoidCallback? onOpenBackends,
}) async {
  final state =
      persistedState ??
      const AppPersistedState(
        backends: [
          BackendTarget(
            id: 'b1',
            name: 'home',
            host: 'h.local',
            port: 7860,
            token: 't',
            origin: BackendOrigin.manual,
            addedAt: 0,
          ),
        ],
        activeBackendId: 'b1',
      );
  final hub = terminalHub ?? TerminalHub();
  if (terminalHub == null) addTearDown(hub.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: HomeShell(
        appState: appState,
        terminalHub: hub,
        settingsStore: SettingsStore(),
        state: state,
        systemTrayController: SystemTrayController(),
        onOpenBackends: onOpenBackends ?? () {},
        onSwitchBackend: (_) async {},
        onNotificationPrefsChanged: () async {},
        themeMode: ThemeMode.system,
        onThemeModeChanged: (_) async {},
      ),
    ),
  );
  // First pump renders the chrome; let any post-frame callbacks fire.
  await tester.pump();
}

class _FakeTerminalHub extends TerminalHub {
  _FakeTerminalHub({
    required this.backend,
    this.session,
    this.adoptableSession,
    this.additionalSessions = const [],
  });

  final BackendTarget backend;
  TerminalSession? session;
  final TerminalSession? adoptableSession;
  final List<BackendTerminalSession> additionalSessions;
  String? focusedBackendId;
  String? focusedSessionId;
  final List<String> adoptedExternalSessionNames = [];

  Iterable<BackendTerminalSession> get _knownSessions sync* {
    final current = session;
    if (current != null) {
      yield BackendTerminalSession(backend: backend, session: current);
    }
    yield* additionalSessions;
  }

  @override
  List<BackendTerminalGroup> get groups {
    final grouped = <String, (BackendTarget, List<TerminalSession>)>{};
    for (final ref in _knownSessions) {
      final existing = grouped[ref.backendId];
      if (existing == null) {
        grouped[ref.backendId] = (ref.backend, [ref.session]);
      } else {
        existing.$2.add(ref.session);
      }
    }
    return [
      for (final entry in grouped.values)
        BackendTerminalGroup(
          backend: entry.$1,
          connectionState: BackendConnectionState.connected,
          lastError: null,
          sessions: List.unmodifiable(entry.$2),
        ),
    ];
  }

  @override
  BackendTerminalSession? sessionFor(String backendId, String sessionId) {
    for (final ref in _knownSessions) {
      if (ref.backendId == backendId && ref.sessionId == sessionId) {
        return ref;
      }
    }
    return null;
  }

  @override
  BackendTerminalSession? sessionForExternalSessionId(
    String backendId,
    String externalSessionId,
  ) {
    for (final ref in _knownSessions) {
      if (ref.backendId == backendId &&
          ref.session.externalSessionId == externalSessionId) {
        return ref;
      }
    }
    return null;
  }

  @override
  List<BackendTerminalSession> sessionsForBackend(String backendId) {
    return [
      for (final ref in _knownSessions)
        if (ref.backendId == backendId) ref,
    ];
  }

  @override
  void focusTerminal(String backendId, String sessionId) {
    focusedBackendId = backendId;
    focusedSessionId = sessionId;
  }

  @override
  Future<void> refreshAll() async {}

  @override
  Future<TerminalSession?> adoptExternalSession({
    required String backendId,
    String? workspaceId,
    required String sessionName,
    required int cols,
    required int rows,
  }) async {
    adoptedExternalSessionNames.add(sessionName);
    final adoptable = adoptableSession;
    if (backendId != backend.id ||
        adoptable == null ||
        adoptable.externalSessionId != sessionName) {
      return null;
    }
    session = adoptable;
    return adoptable;
  }
}

void main() {
  testWidgets('bottom nav shows destinations in the spec order', (
    tester,
  ) async {
    final appState = AppState(client: BackendClient());
    addTearDown(appState.dispose);
    await _pumpHomeShell(tester, appState: appState);

    final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(nav.destinations.length, 4);

    // Verify labels and order — Files / Terminal / Plugins / Settings.
    final labels = nav.destinations
        .map((d) => (d as NavigationDestination).label)
        .toList();
    expect(labels, ['Files', 'Terminal', 'Plugins', 'Settings']);

    // Verify the unselected icons match the spec (Material outlined family).
    final icons = nav.destinations
        .map((d) => ((d as NavigationDestination).icon as Icon).icon)
        .toList();
    expect(icons, [
      Icons.folder_outlined,
      Icons.terminal_outlined,
      Icons.extension_outlined,
      Icons.settings_outlined,
    ]);

    // Sanity: the legacy More slot is gone.
    expect(find.text('More'), findsNothing);
  });

  testWidgets('tapping each destination routes to the matching tab body', (
    tester,
  ) async {
    final appState = AppState(client: BackendClient());
    addTearDown(appState.dispose);
    await _pumpHomeShell(tester, appState: appState);

    // Settings tab — tap the destination and confirm the SettingsTab body
    // becomes visible (its entry tiles are unique markers).
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsTab), findsOneWidget);
    expect(find.text('Backend servers'), findsOneWidget);
    expect(find.text('Install backend'), findsNothing);
    await tester.scrollUntilVisible(find.text('Diagnostics'), 200);
    await tester.pumpAndSettle();
    expect(find.text('Diagnostics'), findsOneWidget);
    expect(find.text('About'), findsOneWidget);

    // Plugins tab — empty plugins list renders the empty state.
    await tester.tap(find.byIcon(Icons.extension_outlined));
    await tester.pumpAndSettle();
    // The Plugins empty state mentions the filesystem install location;
    // Settings tiles ("Backend servers" etc.) should not be on screen now.
    expect(find.text('Backend servers'), findsNothing);
    expect(find.text('About'), findsNothing);

    // Terminal tab — switch back; the body changes but we don't need to
    // assert PTY-specific copy (xterm initialization requires a live
    // connection). Just confirm we're off the SettingsTab.
    await tester.tap(find.byIcon(Icons.terminal_outlined));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsTab), findsNothing);

    // Files tab — empty-state copy from FilesTab.
    await tester.tap(find.byIcon(Icons.folder_outlined));
    await tester.pumpAndSettle();
    expect(
      find.text('No workspace open.\nTap the title bar to choose one.'),
      findsOneWidget,
    );
  });

  testWidgets('Terminal tab app bar does not show workspace chooser', (
    tester,
  ) async {
    final appState = AppState(client: BackendClient());
    addTearDown(appState.dispose);
    await _pumpHomeShell(tester, appState: appState);

    expect(find.text('(choose workspace)'), findsOneWidget);
    expect(find.byIcon(Icons.folder_off_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.terminal_outlined));
    await tester.pumpAndSettle();

    expect(find.text('(choose workspace)'), findsNothing);
    expect(find.byIcon(Icons.folder_off_outlined), findsNothing);
    expect(find.byIcon(Icons.terminal_outlined), findsWidgets);

    await tester.tap(find.byIcon(Icons.folder_outlined));
    await tester.pumpAndSettle();

    expect(find.text('(choose workspace)'), findsOneWidget);
    expect(find.byIcon(Icons.folder_off_outlined), findsOneWidget);
  });

  testWidgets('Terminal tab suppresses active-backend connection banner', (
    tester,
  ) async {
    final client = BackendClient();
    final appState = AppState(client: client);
    addTearDown(appState.dispose);
    await _pumpHomeShell(tester, appState: appState);

    client.state.value = BackendConnectionState.connecting;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    expect(find.text('Connecting to home…'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.terminal_outlined));
    await tester.pump();

    expect(find.text('Connecting to home…'), findsNothing);
    expect(find.text('Terminal'), findsWidgets);

    await tester.tap(find.byIcon(Icons.extension_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    expect(find.text('Connecting to home…'), findsOneWidget);
  });

  testWidgets('connection banner shows the latest readable reconnect issue', (
    tester,
  ) async {
    final client = BackendClient();
    final appState = AppState(client: client);
    addTearDown(appState.dispose);
    await _pumpHomeShell(tester, appState: appState);

    client.lastError.value =
        'socket error: PlatformException(IROH_CLOSED, frame too large, null, null)';
    client.state.value = BackendConnectionState.reconnecting;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    expect(find.text('Reconnecting to home…'), findsOneWidget);
    expect(find.text('Last issue: Message too large'), findsOneWidget);
  });

  testWidgets('notification bell uses a dot for routine unread items', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final appState = AppState(client: BackendClient(), deviceId: 'me');
      addTearDown(appState.dispose);
      appState.notifications.onShow(
        AppNotification(
          id: 'n1',
          source: 'claude-code',
          level: NotificationLevel.info,
          title: 'Claude finished',
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      );

      await _pumpHomeShell(tester, appState: appState);

      expect(find.byTooltip('Notifications'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Notifications, unread items'),
        findsOneWidget,
      );
      expect(find.text('1'), findsNothing);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('notification bell counts only attention-worthy unread items', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final appState = AppState(client: BackendClient(), deviceId: 'me');
      addTearDown(appState.dispose);
      for (var i = 0; i < 12; i++) {
        appState.notifications.onShow(
          AppNotification(
            id: 'warn-$i',
            source: 'agent',
            level: NotificationLevel.warning,
            title: 'Agent needs attention',
            timestamp: DateTime.now().millisecondsSinceEpoch + i,
          ),
        );
      }

      await _pumpHomeShell(tester, appState: appState);

      expect(find.byTooltip('Notifications'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Notifications, 12 items need attention'),
        findsOneWidget,
      );
      expect(find.text('9+'), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'notification terminal action falls back to external session id',
    (tester) async {
      final appState = AppState(client: BackendClient(), deviceId: 'me');
      addTearDown(appState.dispose);
      const backend = BackendTarget(
        id: 'b1',
        name: 'home',
        host: 'h.local',
        port: 7860,
        token: 't',
        origin: BackendOrigin.manual,
        addedAt: 0,
      );
      final session = TerminalSession(
        id: 'live-session',
        workspaceRoot: '/repo',
        cols: 80,
        rows: 24,
        cwd: '/repo',
        createdAt: 0,
        externalSessionId: 'zellij-live',
      );
      final terminalHub = _FakeTerminalHub(backend: backend, session: session);
      addTearDown(terminalHub.dispose);
      appState.notifications.onShow(
        AppNotification(
          id: 'n-terminal',
          source: 'claude-code',
          level: NotificationLevel.success,
          title: 'Claude finished',
          timestamp: DateTime.now().millisecondsSinceEpoch,
          action: const OpenTerminalAction(
            backendId: 'b1',
            sessionId: 'stale-session',
            externalSessionId: 'zellij-live',
          ),
        ),
      );

      await _pumpHomeShell(
        tester,
        appState: appState,
        terminalHub: terminalHub,
      );

      await tester.tap(find.byTooltip('Notifications'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Open terminal'));
      await tester.pumpAndSettle();

      expect(terminalHub.focusedSessionId, 'live-session');
      expect(
        find.text('Terminal session not found (zellij-live)'),
        findsNothing,
      );
    },
  );

  testWidgets(
    'notification terminal action adopts an external session before opening',
    (tester) async {
      final appState = AppState(client: BackendClient(), deviceId: 'me');
      addTearDown(appState.dispose);
      const backend = BackendTarget(
        id: 'b1',
        name: 'home',
        host: 'h.local',
        port: 7860,
        token: 't',
        origin: BackendOrigin.manual,
        addedAt: 0,
      );
      final session = TerminalSession(
        id: 'adopted-session',
        workspaceRoot: '/repo',
        cols: 80,
        rows: 24,
        cwd: '/repo',
        createdAt: 0,
        externalSessionId: 'zellij-orphan',
      );
      final terminalHub = _FakeTerminalHub(
        backend: backend,
        session: null,
        adoptableSession: session,
      );
      addTearDown(terminalHub.dispose);
      appState.notifications.onShow(
        AppNotification(
          id: 'n-adopt-terminal',
          source: 'codex',
          level: NotificationLevel.success,
          title: 'Codex finished',
          timestamp: DateTime.now().millisecondsSinceEpoch,
          action: const OpenTerminalAction(
            backendId: 'b1',
            sessionId: 'stale-session',
            externalSessionId: 'zellij-orphan',
          ),
        ),
      );

      await _pumpHomeShell(
        tester,
        appState: appState,
        terminalHub: terminalHub,
      );

      await tester.tap(find.byTooltip('Notifications'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Open terminal'));
      await tester.pumpAndSettle();

      expect(terminalHub.adoptedExternalSessionNames, ['zellij-orphan']);
      expect(terminalHub.focusedSessionId, 'adopted-session');
      expect(
        find.text('Terminal session not found (zellij-orphan)'),
        findsNothing,
      );
    },
  );

  testWidgets(
    'notification terminal action can adopt with only external session id',
    (tester) async {
      final appState = AppState(client: BackendClient(), deviceId: 'me');
      addTearDown(appState.dispose);
      const backend = BackendTarget(
        id: 'b1',
        name: 'home',
        host: 'h.local',
        port: 7860,
        token: 't',
        origin: BackendOrigin.manual,
        addedAt: 0,
      );
      final session = TerminalSession(
        id: 'external-only-session',
        workspaceRoot: '/repo',
        cols: 80,
        rows: 24,
        cwd: '/repo',
        createdAt: 0,
        externalSessionId: 'zellij-external-only',
      );
      final terminalHub = _FakeTerminalHub(
        backend: backend,
        session: null,
        adoptableSession: session,
      );
      addTearDown(terminalHub.dispose);
      appState.notifications.onShow(
        AppNotification(
          id: 'n-adopt-external-only-terminal',
          source: 'claude-code',
          level: NotificationLevel.success,
          title: 'Claude finished',
          timestamp: DateTime.now().millisecondsSinceEpoch,
          action: const OpenTerminalAction(
            backendId: 'b1',
            externalSessionId: 'zellij-external-only',
          ),
        ),
      );

      await _pumpHomeShell(
        tester,
        appState: appState,
        terminalHub: terminalHub,
      );

      await tester.tap(find.byTooltip('Notifications'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Open terminal'));
      await tester.pumpAndSettle();

      expect(terminalHub.adoptedExternalSessionNames, ['zellij-external-only']);
      expect(terminalHub.focusedSessionId, 'external-only-session');
      expect(
        find.text('Terminal session not found (zellij-external-only)'),
        findsNothing,
      );
    },
  );

  testWidgets(
    'notification terminal action without backend id searches all known backends',
    (tester) async {
      final appState = AppState(client: BackendClient(), deviceId: 'me');
      addTearDown(appState.dispose);
      const activeBackend = BackendTarget(
        id: 'b1',
        name: 'home',
        host: 'h.local',
        port: 7860,
        token: 't',
        origin: BackendOrigin.manual,
        addedAt: 0,
      );
      const remoteBackend = BackendTarget(
        id: 'b2',
        name: 'lab',
        host: 'lab.local',
        port: 7860,
        token: 't2',
        origin: BackendOrigin.manual,
        addedAt: 1,
      );
      final remoteSession = TerminalSession(
        id: 'remote-session',
        workspaceRoot: '/repo',
        cols: 80,
        rows: 24,
        cwd: '/repo',
        createdAt: 0,
        externalSessionId: 'zellij-remote',
      );
      final terminalHub = _FakeTerminalHub(
        backend: activeBackend,
        session: null,
        additionalSessions: [
          BackendTerminalSession(
            backend: remoteBackend,
            session: remoteSession,
          ),
        ],
      );
      addTearDown(terminalHub.dispose);
      appState.notifications.onShow(
        AppNotification(
          id: 'n-cross-backend-terminal',
          source: 'claude-code',
          level: NotificationLevel.success,
          title: 'Claude finished',
          timestamp: DateTime.now().millisecondsSinceEpoch,
          action: const OpenTerminalAction(externalSessionId: 'zellij-remote'),
        ),
      );

      await _pumpHomeShell(
        tester,
        appState: appState,
        persistedState: const AppPersistedState(
          backends: [activeBackend, remoteBackend],
          activeBackendId: 'b1',
        ),
        terminalHub: terminalHub,
      );

      await tester.tap(find.byTooltip('Notifications'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Open terminal'));
      await tester.pumpAndSettle();

      expect(terminalHub.focusedBackendId, 'b2');
      expect(terminalHub.focusedSessionId, 'remote-session');
      expect(terminalHub.adoptedExternalSessionNames, isEmpty);
      expect(
        find.text('Terminal session not found (zellij-remote)'),
        findsNothing,
      );
    },
  );

  testWidgets(
    'About entry pushes AboutScreen; back returns to Settings (not Files)',
    (tester) async {
      final appState = AppState(client: BackendClient());
      addTearDown(appState.dispose);
      await _pumpHomeShell(tester, appState: appState);

      // Start on Files (default), open Settings, tap About, then pop.
      // After pop, Settings tab must still be selected — the IndexedStack
      // index should not snap back to 0.
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      // Settings tab is now an inset-grouped scrolling list (Batch 2
      // visual rework); the About tile may land below the 800x600 test
      // viewport, so scroll it into view before tapping.
      await tester.scrollUntilVisible(find.text('About'), 200);
      await tester.pumpAndSettle();
      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();
      expect(find.byType(AboutScreen), findsOneWidget);

      final navState = tester.state<NavigatorState>(find.byType(Navigator));
      navState.pop();
      await tester.pumpAndSettle();

      // SettingsTab still visible — we're back on the Settings destination,
      // not on Files. We don't re-check Backends text because the Settings
      // list may be scrolled past it (after scrolling down to About);
      // SettingsTab presence + the negative Files-empty assertion + the
      // bottom-nav index check below cover the actual invariant.
      expect(find.byType(SettingsTab), findsOneWidget);
      expect(
        find.text('No workspace open.\nTap the title bar to choose one.'),
        findsNothing,
      );

      // Bottom nav still highlights Settings (index 3).
      final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(nav.selectedIndex, 3);
    },
  );

  testWidgets('Settings → Backends → back lands on Settings tab, not Files', (
    tester,
  ) async {
    // Stand in for the production onOpenBackends: push a placeholder
    // route on the root navigator. The contract under test is "Settings
    // remains selected when the user pops a child route" — we don't need
    // BackendsScreen's real wiring.
    final appState = AppState(client: BackendClient());
    addTearDown(appState.dispose);
    late NavigatorState rootNav;
    await _pumpHomeShell(
      tester,
      appState: appState,
      onOpenBackends: () {
        rootNav.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(
              body: Center(child: Text('Backends-test-screen')),
            ),
          ),
        );
      },
    );
    rootNav = tester.state<NavigatorState>(find.byType(Navigator));

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Backend servers'));
    await tester.pumpAndSettle();
    expect(find.text('Backends-test-screen'), findsOneWidget);

    rootNav.pop();
    await tester.pumpAndSettle();

    expect(find.byType(SettingsTab), findsOneWidget);
    final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(nav.selectedIndex, 3);
  });
}
