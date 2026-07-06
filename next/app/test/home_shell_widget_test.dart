// Widget tests for the 4-tab HomeShell layout (issue #62).
//
// What's testable without a connected backend:
//   * Bottom nav shows exactly the four destinations in the expected order.
//   * Tapping each destination switches the visible body to the right tab.
//   * The Settings tab lists the spec'd entries (Backends / SSH bootstrap /
//     Diagnostics / About) plus the carry-over Notifications entry, with
//     About navigating into the AboutScreen and routing back to Settings
//     (not Files) after a backends-add flow.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/app_state.dart';
import 'package:mobilecode/backend_client.dart';
import 'package:mobilecode/screens/about_screen.dart';
import 'package:mobilecode/screens/home_shell.dart';
import 'package:mobilecode/screens/settings_tab.dart';
import 'package:mobilecode/services/system_tray.dart';
import 'package:mobilecode/settings_store.dart';
import 'package:mobilecode/state/terminal_hub.dart';

Future<void> _pumpHomeShell(
  WidgetTester tester, {
  required AppState appState,
  VoidCallback? onOpenBackends,
}) async {
  final state = const AppPersistedState(
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
  final terminalHub = TerminalHub();
  addTearDown(terminalHub.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: HomeShell(
        appState: appState,
        terminalHub: terminalHub,
        settingsStore: SettingsStore(),
        state: state,
        systemTrayController: SystemTrayController(),
        onOpenBackends: onOpenBackends ?? () {},
        onSwitchBackend: (_) async {},
        onBackendInstalled: (target, {required bool makeActive}) async {},
        onNotificationPrefsChanged: () async {},
        themeMode: ThemeMode.system,
        onThemeModeChanged: (_) async {},
      ),
    ),
  );
  // First pump renders the chrome; let any post-frame callbacks fire.
  await tester.pump();
}

void main() {
  testWidgets('bottom nav shows exactly 4 destinations in the spec order', (
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
    expect(find.text('Backends'), findsOneWidget);
    expect(find.text('SSH bootstrap'), findsOneWidget);
    expect(find.text('Diagnostics'), findsOneWidget);
    expect(find.text('About'), findsOneWidget);

    // Plugins tab — empty plugins list renders the empty state.
    await tester.tap(find.byIcon(Icons.extension_outlined));
    await tester.pumpAndSettle();
    // The Plugins empty state mentions the filesystem install location;
    // Settings tiles ("Backends" etc.) should not be on screen now.
    expect(find.text('SSH bootstrap'), findsNothing);
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
    await tester.tap(find.text('Backends'));
    await tester.pumpAndSettle();
    expect(find.text('Backends-test-screen'), findsOneWidget);

    rootNav.pop();
    await tester.pumpAndSettle();

    expect(find.byType(SettingsTab), findsOneWidget);
    final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(nav.selectedIndex, 3);
  });
}
