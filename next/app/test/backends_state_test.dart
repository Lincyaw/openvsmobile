// Tests for the multi-backend persisted state and its migration from the
// legacy single-backend SharedPreferences keys.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobilecode/settings_store.dart';

void main() {
  group('SettingsStore.loadAppState', () {
    test('returns empty state when no keys exist', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final s = await SettingsStore().loadAppState();
      expect(s.backends, isEmpty);
      expect(s.activeBackendId, isNull);
      expect(s.discoverySources, isEmpty);
      expect(s.schemaVersion, 2);
    });

    test('migrates legacy host/port/token into a single active backend',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'server-host': '192.168.1.20',
        'server-port': 7860,
        'bearer-token': 'tok-abc',
      });
      final store = SettingsStore();
      final s = await store.loadAppState();
      expect(s.backends, hasLength(1));
      final b = s.backends.single;
      expect(b.host, '192.168.1.20');
      expect(b.port, 7860);
      expect(b.token, 'tok-abc');
      expect(b.origin, BackendOrigin.manual);
      expect(b.name, 'default');
      expect(s.activeBackendId, b.id);

      // Legacy keys should be removed after a successful migration; v2 blob
      // should now be present.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('server-host'), isNull);
      expect(prefs.getInt('server-port'), isNull);
      expect(prefs.getString('bearer-token'), isNull);
      expect(prefs.getString('backends-state-v2'), isNotNull);

      // Reloading should produce the same logical state.
      final reloaded = await store.loadAppState();
      expect(reloaded.backends, hasLength(1));
      expect(reloaded.activeBackendId, b.id);
    });

    test('returns empty state when legacy host is incomplete', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'server-host': '',
        'server-port': 7860,
        'bearer-token': '',
      });
      final s = await SettingsStore().loadAppState();
      expect(s.backends, isEmpty);
      expect(s.activeBackendId, isNull);
    });

    test('round-trips a multi-backend blob with discovery sources', () async {
      final state = AppPersistedState(
        backends: [
          BackendTarget(
            id: 'b1',
            name: 'home',
            host: 'h.local',
            port: 7860,
            token: 't1',
            origin: BackendOrigin.manual,
            addedAt: 1000,
            lastConnectedAt: 2000,
            lastWorkspaceId: 'ws-1',
          ),
          BackendTarget(
            id: 'b2',
            name: 'work',
            host: 'w.example.com',
            port: 9000,
            token: 't2',
            origin: BackendOrigin.sshInstall,
            originRef: 'me@w.example.com',
            addedAt: 3000,
          ),
        ],
        activeBackendId: 'b2',
        discoverySources: const [
          DiscoverySource(
            id: 'd1',
            name: 'prod-east',
            url: 'https://lb.example.com/backends',
            refreshIntervalSec: 600,
          ),
        ],
      );
      SharedPreferences.setMockInitialValues(<String, Object>{
        'backends-state-v2': jsonEncode(state.toJson()),
      });
      final loaded = await SettingsStore().loadAppState();
      expect(loaded.backends, hasLength(2));
      expect(loaded.activeBackendId, 'b2');
      expect(loaded.backends[0].lastWorkspaceId, 'ws-1');
      expect(loaded.backends[1].origin, BackendOrigin.sshInstall);
      expect(loaded.backends[1].originRef, 'me@w.example.com');
      expect(loaded.discoverySources, hasLength(1));
      expect(loaded.discoverySources.single.url,
          'https://lb.example.com/backends');
    });
  });

  test('BackendTarget.copyWith preserves fields and clears lastWorkspaceId',
      () {
    final t = BackendTarget(
      id: 'x',
      name: 'n',
      host: 'h',
      port: 1,
      token: 't',
      origin: BackendOrigin.manual,
      addedAt: 0,
      lastWorkspaceId: 'ws',
    );
    final cleared = t.copyWith(clearLastWorkspaceId: true);
    expect(cleared.lastWorkspaceId, isNull);
    final renamed = t.copyWith(name: 'nn');
    expect(renamed.name, 'nn');
    expect(renamed.lastWorkspaceId, 'ws');
  });
}
