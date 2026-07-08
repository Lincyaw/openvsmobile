// Coverage for the persisted theme-mode preference + the Settings-tab
// Theme tile/dialog. The store half mirrors the NotificationPrefs
// tests' shape: seed empty SharedPreferences, round-trip every enum
// value, assert default-on-absence is `ThemeMode.system`. The widget
// half exercises the tile -> dialog -> Apply flow so the wire between
// `SettingsTab` and `onThemeModeChanged` does not silently break.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobilecode/app_state.dart';
import 'package:mobilecode/backend_client.dart';
import 'package:mobilecode/screens/agent_hooks_screen.dart';
import 'package:mobilecode/screens/settings_tab.dart';
import 'package:mobilecode/services/system_tray.dart';
import 'package:mobilecode/settings_store.dart';
import 'package:mobilecode/ui/inset_section.dart';

class _HookStatusClient extends BackendClient {
  final List<String> calls = [];

  @override
  Future<dynamic> call(String method, [Map<String, dynamic>? params]) async {
    calls.add(method);
    if (method == 'notification.agentHookStatus') {
      return <String, dynamic>{
        'ok': true,
        'exitCode': 0,
        'statuses': [
          {
            'agent': 'claude-code',
            'state': 'current',
            'message': 'Claude Code Stop hook already current',
            'available': true,
            'changed': false,
          },
          {
            'agent': 'codex',
            'state': 'current',
            'message': 'Codex Stop hook plugin already current',
            'available': true,
            'changed': false,
          },
        ],
        'stdout': '',
        'stderr': '',
      };
    }
    if (method == 'auth.publishTokens.list') {
      return <String, dynamic>{'items': []};
    }
    return <String, dynamic>{};
  }
}

class _UnsupportedHookStatusClient extends BackendClient {
  final List<String> calls = [];

  @override
  Future<dynamic> call(String method, [Map<String, dynamic>? params]) async {
    calls.add(method);
    if (method == 'notification.agentHookStatus') {
      throw BackendRpcException(-32601, 'unknown method');
    }
    if (method == 'auth.publishTokens.list') {
      return <String, dynamic>{'items': []};
    }
    return <String, dynamic>{};
  }
}

class _FailedHookStatusClient extends BackendClient {
  final List<String> calls = [];

  @override
  Future<dynamic> call(String method, [Map<String, dynamic>? params]) async {
    calls.add(method);
    if (method == 'notification.agentHookStatus') {
      return <String, dynamic>{
        'ok': false,
        'exitCode': 1,
        'statuses': [],
        'stdout': '',
        'stderr': 'agent hook installer failed',
      };
    }
    if (method == 'auth.publishTokens.list') {
      return <String, dynamic>{'items': []};
    }
    return <String, dynamic>{};
  }
}

void main() {
  group('SettingsStore.themeMode persistence', () {
    test('default load: ThemeMode.system when key absent', () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final store = SettingsStore();
      expect(await store.loadThemeMode(), ThemeMode.system);
    });

    test('round-trip: light', () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final store = SettingsStore();
      await store.saveThemeMode(ThemeMode.light);
      expect(await store.loadThemeMode(), ThemeMode.light);
    });

    test('round-trip: dark', () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final store = SettingsStore();
      await store.saveThemeMode(ThemeMode.dark);
      expect(await store.loadThemeMode(), ThemeMode.dark);
    });

    test('round-trip: system', () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final store = SettingsStore();
      // Seed a non-default first so we know the save is doing real work.
      await store.saveThemeMode(ThemeMode.dark);
      await store.saveThemeMode(ThemeMode.system);
      expect(await store.loadThemeMode(), ThemeMode.system);
    });

    test('unknown persisted value falls back to system', () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{
        'theme-mode': 'auto-by-time-of-day',
      });
      final store = SettingsStore();
      expect(await store.loadThemeMode(), ThemeMode.system);
    });

    test('persisted key is the documented kebab-case form', () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final store = SettingsStore();
      await store.saveThemeMode(ThemeMode.light);
      final prefs = await SharedPreferences.getInstance();
      // External tools / migration paths read the key directly; lock
      // the spelling so a rename has to update this test too.
      expect(prefs.getString('theme-mode'), 'light');
    });
  });

  group('SettingsStore terminal preference persistence', () {
    test('default load uses the terminal font default', () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final store = SettingsStore();
      final prefs = await store.loadTerminalPrefs();
      expect(prefs.fontSize, kTerminalFontSizeDefault);
    });

    test('round-trip clamps and stores terminal font size', () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final store = SettingsStore();
      await store.saveTerminalPrefs(const TerminalPrefs(fontSize: 18));
      expect((await store.loadTerminalPrefs()).fontSize, 18);

      await store.saveTerminalPrefs(const TerminalPrefs(fontSize: 99));
      expect((await store.loadTerminalPrefs()).fontSize, kTerminalFontSizeMax);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('terminal-font-size'), kTerminalFontSizeMax);
    });
  });

  group('SettingsTab Theme tile', () {
    Future<void> pumpTab(
      WidgetTester tester, {
      required ThemeMode mode,
      required Future<void> Function(ThemeMode mode) onChanged,
      AppPersistedState backendState = const AppPersistedState(),
      BackendConnectionState connectionState =
          BackendConnectionState.disconnected,
      VoidCallback? onOpenBackends,
      BackendClient? client,
      bool isActive = true,
    }) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = SettingsStore();
      final backendClient = client ?? BackendClient();
      backendClient.state.value = connectionState;
      final appState = AppState(client: backendClient);
      addTearDown(appState.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsTab(
              appState: appState,
              settingsStore: store,
              backendState: backendState,
              systemTrayController: SystemTrayController(),
              isActive: isActive,
              onOpenBackends: onOpenBackends ?? () {},
              onNotificationPrefsChanged: () async {},
              themeMode: mode,
              onThemeModeChanged: onChanged,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('subtitle reflects the active mode', (tester) async {
      await pumpTab(tester, mode: ThemeMode.dark, onChanged: (_) async {});
      expect(find.text('Theme'), findsOneWidget);
      expect(find.text('Dark'), findsOneWidget);
    });

    testWidgets('Apply propagates the selected mode', (tester) async {
      ThemeMode? captured;
      await pumpTab(
        tester,
        mode: ThemeMode.system,
        onChanged: (m) async => captured = m,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('settings-theme-tile')),
      );
      await tester.pumpAndSettle();
      // Pick "Light" and apply.
      await tester.tap(
        find.byKey(const ValueKey<String>('theme-option:light')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(captured, ThemeMode.light);
    });

    testWidgets(
      'remote summary is status-only; Backend servers opens manager',
      (tester) async {
        var openedBackends = 0;
        const backend = BackendTarget(
          id: 'prod',
          name: 'Prod host',
          host: 'prod.example',
          port: 7860,
          token: 'token',
          origin: BackendOrigin.manual,
          addedAt: 0,
        );

        await pumpTab(
          tester,
          mode: ThemeMode.system,
          onChanged: (_) async {},
          connectionState: BackendConnectionState.connected,
          onOpenBackends: () => openedBackends++,
          backendState: const AppPersistedState(
            backends: [backend],
            activeBackendId: 'prod',
          ),
        );

        expect(
          find.byKey(const ValueKey<String>('settings-remote-summary')),
          findsOneWidget,
        );
        expect(find.text('Prod host'), findsOneWidget);
        expect(find.text('prod.example:7860'), findsOneWidget);
        expect(find.text('Connected'), findsOneWidget);
        expect(find.text('1 backend'), findsOneWidget);
        expect(find.text('Hooks not checked'), findsOneWidget);

        await tester.tap(
          find.byKey(const ValueKey<String>('settings-remote-summary-main')),
          warnIfMissed: false,
        );
        expect(openedBackends, 0);

        await tester.tap(
          find.byKey(const ValueKey<String>('settings-tile-backends')),
        );
        expect(openedBackends, 1);
      },
    );

    testWidgets('remote summary checks hook status when Settings is active', (
      tester,
    ) async {
      final client = _HookStatusClient();
      const backend = BackendTarget(
        id: 'prod',
        name: 'Prod host',
        host: 'prod.example',
        port: 7860,
        token: 'token',
        origin: BackendOrigin.manual,
        addedAt: 0,
      );

      await pumpTab(
        tester,
        mode: ThemeMode.system,
        onChanged: (_) async {},
        connectionState: BackendConnectionState.connected,
        client: client,
        backendState: const AppPersistedState(
          backends: [backend],
          activeBackendId: 'prod',
        ),
      );
      await tester.pumpAndSettle();

      expect(client.calls, contains('notification.agentHookStatus'));
      expect(find.text('Hooks ready'), findsOneWidget);
      expect(find.text('Hooks not checked'), findsNothing);
    });

    testWidgets('remote summary labels unsupported hook RPC as hook-scoped', (
      tester,
    ) async {
      final client = _UnsupportedHookStatusClient();

      await pumpTab(
        tester,
        mode: ThemeMode.system,
        onChanged: (_) async {},
        connectionState: BackendConnectionState.connected,
        client: client,
      );
      await tester.pumpAndSettle();

      expect(client.calls, contains('notification.agentHookStatus'));
      expect(find.text('Hooks unavailable'), findsOneWidget);
      expect(find.text('Update backend'), findsNothing);
    });

    testWidgets('remote summary surfaces failed hook scans', (tester) async {
      final client = _FailedHookStatusClient();

      await pumpTab(
        tester,
        mode: ThemeMode.system,
        onChanged: (_) async {},
        connectionState: BackendConnectionState.connected,
        client: client,
      );
      await tester.pumpAndSettle();

      expect(client.calls, contains('notification.agentHookStatus'));
      expect(find.text('Hook scan failed'), findsOneWidget);
      expect(find.text('No agents found'), findsNothing);
    });

    testWidgets('remote summary hook chip is status-only; tile opens hooks', (
      tester,
    ) async {
      final client = _HookStatusClient();
      var openedBackends = 0;
      const backend = BackendTarget(
        id: 'prod',
        name: 'Prod host',
        host: 'prod.example',
        port: 7860,
        token: 'token',
        origin: BackendOrigin.manual,
        addedAt: 0,
      );

      await pumpTab(
        tester,
        mode: ThemeMode.system,
        onChanged: (_) async {},
        connectionState: BackendConnectionState.connected,
        client: client,
        onOpenBackends: () => openedBackends++,
        backendState: const AppPersistedState(
          backends: [backend],
          activeBackendId: 'prod',
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('settings-summary-hook-chip')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();

      expect(openedBackends, 0);
      expect(find.byType(AgentHooksScreen), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey<String>('settings-tile-agent-hooks')),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AgentHooksScreen), findsOneWidget);
      expect(find.text('Agent alerts ready'), findsOneWidget);
    });

    testWidgets('hidden Settings tab does not auto-check hook status', (
      tester,
    ) async {
      final client = _HookStatusClient();
      await pumpTab(
        tester,
        mode: ThemeMode.system,
        onChanged: (_) async {},
        connectionState: BackendConnectionState.connected,
        client: client,
        isActive: false,
      );
      await tester.pumpAndSettle();

      expect(client.calls, isNot(contains('notification.agentHookStatus')));
      expect(find.text('Hooks not checked'), findsOneWidget);
    });

    testWidgets('Settings tab renders focused inset sections', (tester) async {
      // Batch 2 visual rework: each grouped section renders through the
      // same InsetSection primitive the plugin UI renderer uses for
      // UiSection { variant: 'inset' }. Locking the widget type prevents
      // a silent regression to a flat ListView of tiles.
      await pumpTab(tester, mode: ThemeMode.system, onChanged: (_) async {});
      // Four InsetSection groups, identified by their surface keys, must
      // be present so the visual primitive doesn't silently regress.
      expect(find.byType(InsetSection), findsNWidgets(4));
      expect(
        find.byKey(const ValueKey<String>('settings-section:backend')),
        findsOneWidget,
      );
      expect(find.text('Backend servers'), findsOneWidget);
      expect(find.text('Install backend'), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('settings-section:workflow')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('settings-section:preferences')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('settings-section:maintenance')),
        findsOneWidget,
      );
      // Section group titles are rendered uppercase per the iOS-Settings
      // inset convention.
      expect(find.text('BACKEND'), findsOneWidget);
      expect(find.text('WORKFLOW'), findsOneWidget);
      expect(find.text('Agent hooks'), findsOneWidget);
      expect(find.text('Webhook tokens'), findsNothing);
      expect(find.text('PREFERENCES'), findsOneWidget);
      expect(find.text('MAINTENANCE'), findsOneWidget);
    });

    testWidgets('Cancel does not invoke onChanged', (tester) async {
      var calls = 0;
      await pumpTab(
        tester,
        mode: ThemeMode.system,
        onChanged: (_) async => calls++,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('settings-theme-tile')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('theme-option:dark')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(calls, 0);
    });
  });
}
