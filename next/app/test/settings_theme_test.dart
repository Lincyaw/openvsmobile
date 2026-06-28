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
import 'package:mobilecode/screens/settings_tab.dart';
import 'package:mobilecode/services/system_tray.dart';
import 'package:mobilecode/settings_store.dart';
import 'package:mobilecode/ui/inset_section.dart';

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
    }) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final store = SettingsStore();
      final appState = AppState(client: BackendClient());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsTab(
              appState: appState,
              settingsStore: store,
              systemTrayController: SystemTrayController(),
              onOpenBackends: () {},
              onBackendInstalled: (target, {required bool makeActive}) async {},
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
      'Settings tab renders Connection/Appearance/System inset sections',
      (tester) async {
        // Batch 2 visual rework: each grouped section renders through the
        // same InsetSection primitive the plugin UI renderer uses for
        // UiSection { variant: 'inset' }. Locking the widget type prevents
        // a silent regression to a flat ListView of tiles.
        await pumpTab(tester, mode: ThemeMode.system, onChanged: (_) async {});
        // Three InsetSection groups, identified by their surface keys, must
        // be present so the visual primitive doesn't silently regress.
        expect(find.byType(InsetSection), findsNWidgets(3));
        expect(
          find.byKey(const ValueKey<String>('settings-section:connection')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey<String>('settings-section:appearance')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey<String>('settings-section:system')),
          findsOneWidget,
        );
        // Section group titles are rendered uppercase per the iOS-Settings
        // inset convention.
        expect(find.text('CONNECTION'), findsOneWidget);
        expect(find.text('APPEARANCE'), findsOneWidget);
        expect(find.text('SYSTEM'), findsOneWidget);
      },
    );

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
