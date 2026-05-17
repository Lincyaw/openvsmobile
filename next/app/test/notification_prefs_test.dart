// Unit tests for NotificationPrefs persistence and the
// channel-for-level mapping. The foreground-service plumbing itself
// (start/stop, platform channels) is exercised manually — flutter_test
// cannot drive the platform-channel layer that `flutter_foreground_task`
// and `flutter_local_notifications` rely on without an Android runner.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openvsmobile_next/notification.dart';
import 'package:openvsmobile_next/services/notification_foreground_service.dart';
import 'package:openvsmobile_next/settings_store.dart';

void main() {
  group('NotificationPrefs persistence', () {
    test('default load: backgroundEnabled is true, TTL is 7d, no mute', () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final store = SettingsStore();
      final p = await store.loadNotificationPrefs();
      expect(p.backgroundEnabled, isTrue);
      expect(p.mutedSources, isEmpty);
      expect(p.defaultTtlDays, 7);
      expect(p.quietHoursStartMinutes, isNull);
      expect(p.quietHoursEndMinutes, isNull);
    });

    test('toggle off survives a round-trip', () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final store = SettingsStore();
      final initial = await store.loadNotificationPrefs();
      await store.saveNotificationPrefs(
        initial.copyWith(backgroundEnabled: false),
      );
      final reloaded = await store.loadNotificationPrefs();
      expect(reloaded.backgroundEnabled, isFalse);
    });

    test('mute list and quiet hours round-trip', () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final store = SettingsStore();
      final initial = await store.loadNotificationPrefs();
      await store.saveNotificationPrefs(initial.copyWith(
        mutedSources: ['ci', 'demo:test'],
        quietHoursStartMinutes: 22 * 60,
        quietHoursEndMinutes: 7 * 60,
      ));
      final reloaded = await store.loadNotificationPrefs();
      expect(reloaded.mutedSources, ['ci', 'demo:test']);
      expect(reloaded.quietHoursStartMinutes, 22 * 60);
      expect(reloaded.quietHoursEndMinutes, 7 * 60);
    });

    test('clearQuietHours wipes both endpoints', () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final store = SettingsStore();
      final initial = await store.loadNotificationPrefs();
      await store.saveNotificationPrefs(initial.copyWith(
        quietHoursStartMinutes: 60,
        quietHoursEndMinutes: 120,
      ));
      final mid = await store.loadNotificationPrefs();
      await store.saveNotificationPrefs(mid.copyWith(clearQuietHours: true));
      final reloaded = await store.loadNotificationPrefs();
      expect(reloaded.quietHoursStartMinutes, isNull);
      expect(reloaded.quietHoursEndMinutes, isNull);
    });

    test('getBool / setBool work for the OEM-onboarded flag', () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final store = SettingsStore();
      expect(await store.getBool('background-onboarded'), isNull);
      await store.setBool('background-onboarded', true);
      expect(await store.getBool('background-onboarded'), isTrue);
    });
  });

  group('channel routing', () {
    test('info / success → low; warning → default; error → high', () {
      expect(channelForLevel(NotificationLevel.info),
          NotificationChannels.low);
      expect(channelForLevel(NotificationLevel.success),
          NotificationChannels.low);
      expect(channelForLevel(NotificationLevel.warning),
          NotificationChannels.defaultImp);
      expect(channelForLevel(NotificationLevel.error),
          NotificationChannels.high);
    });

    test('trayIdForNotification is deterministic and positive', () {
      final a = trayIdForNotification('abc');
      final b = trayIdForNotification('abc');
      final c = trayIdForNotification('different');
      expect(a, b);
      expect(a, isNot(c));
      expect(a >= 0, isTrue);
      expect(c >= 0, isTrue);
    });
  });
}
