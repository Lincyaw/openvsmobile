// Persistent settings: backend host:port, bearer token, plus per-install
// secondary preferences (deviceId, notification toggles, mute list, quiet
// hours, default TTL).
//
// Keys are kebab-case per docs/conventions.md §4. No migration code: the v0
// rename from `backend.host` etc. will drop existing users' saved settings,
// which is accepted per the settled call in §9.

import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

class Settings {
  final String host;
  final int port;
  final String token;
  const Settings({
    required this.host,
    required this.port,
    required this.token,
  });

  bool get isComplete =>
      host.isNotEmpty && port > 0 && port < 65536 && token.isNotEmpty;
}

/// Per-install notification preferences. Mute list and quiet hours are
/// consumed by the foreground service when deciding whether to post a
/// system-tray notification; the in-app notification center always shows
/// every entry.
class NotificationPrefs {
  /// Whether the foreground service should run at all.
  final bool backgroundEnabled;

  /// Sources the user has chosen to silence — system-tray only. The
  /// in-app center still shows them so they are not lost.
  final List<String> mutedSources;

  /// Quiet-hours window in minutes since midnight, `null` when not set.
  /// When `start == end`, quiet hours are off. When `start > end`, the
  /// window wraps midnight (e.g. 22:00 → 07:00).
  final int? quietHoursStartMinutes;
  final int? quietHoursEndMinutes;

  /// Default TTL in days for the GC-policy hint shown in Settings. Backend
  /// independently applies its own 7-day default; this is purely a display
  /// preference for now.
  final int defaultTtlDays;

  const NotificationPrefs({
    this.backgroundEnabled = true,
    this.mutedSources = const [],
    this.quietHoursStartMinutes,
    this.quietHoursEndMinutes,
    this.defaultTtlDays = 7,
  });

  NotificationPrefs copyWith({
    bool? backgroundEnabled,
    List<String>? mutedSources,
    int? quietHoursStartMinutes,
    int? quietHoursEndMinutes,
    bool clearQuietHours = false,
    int? defaultTtlDays,
  }) {
    return NotificationPrefs(
      backgroundEnabled: backgroundEnabled ?? this.backgroundEnabled,
      mutedSources: mutedSources ?? this.mutedSources,
      quietHoursStartMinutes: clearQuietHours
          ? null
          : (quietHoursStartMinutes ?? this.quietHoursStartMinutes),
      quietHoursEndMinutes: clearQuietHours
          ? null
          : (quietHoursEndMinutes ?? this.quietHoursEndMinutes),
      defaultTtlDays: defaultTtlDays ?? this.defaultTtlDays,
    );
  }
}

class SettingsStore {
  static const _kServerHost = 'server-host';
  static const _kServerPort = 'server-port';
  static const _kBearerToken = 'bearer-token';
  static const _kDeviceId = 'device-id';
  static const _kBackgroundNotifications = 'background-notifications';
  static const _kMutedSources = 'notifications-mute-sources';
  static const _kQuietHoursStart = 'quiet-hours-start';
  static const _kQuietHoursEnd = 'quiet-hours-end';
  static const _kDefaultTtlDays = 'notifications-default-ttl-days';

  Future<Settings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return Settings(
      host: prefs.getString(_kServerHost) ?? '',
      port: prefs.getInt(_kServerPort) ?? 7860,
      token: prefs.getString(_kBearerToken) ?? '',
    );
  }

  Future<void> save(Settings s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kServerHost, s.host);
    await prefs.setInt(_kServerPort, s.port);
    await prefs.setString(_kBearerToken, s.token);
  }

  /// Stable per-install identifier. Generated and persisted on first read.
  /// Used for multi-device read-state sync (see design §4.5).
  ///
  /// The id is a v4-style UUID; we don't depend on `package:uuid` to keep
  /// the dep surface tight. Collision probability with `Random.secure` over
  /// 122 random bits is the same as a real v4.
  Future<String> loadOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_kDeviceId);
    if (existing != null && existing.isNotEmpty) return existing;
    final id = _generateUuidV4();
    await prefs.setString(_kDeviceId, id);
    return id;
  }

  Future<NotificationPrefs> loadNotificationPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final muteRaw = prefs.getString(_kMutedSources);
    final mute = <String>[];
    if (muteRaw != null && muteRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(muteRaw);
        if (decoded is List) {
          mute.addAll(decoded.whereType<String>());
        }
      } on FormatException catch (e) {
        // Corrupted entry — drop it rather than crashing the boot path.
        // The next save overwrites with a fresh JSON list.
        // ignore: avoid_print
        print('SettingsStore: dropping malformed muted-sources entry: $e');
      }
    }
    return NotificationPrefs(
      backgroundEnabled: prefs.getBool(_kBackgroundNotifications) ?? true,
      mutedSources: mute,
      quietHoursStartMinutes: prefs.getInt(_kQuietHoursStart),
      quietHoursEndMinutes: prefs.getInt(_kQuietHoursEnd),
      defaultTtlDays: prefs.getInt(_kDefaultTtlDays) ?? 7,
    );
  }

  Future<void> saveNotificationPrefs(NotificationPrefs p) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kBackgroundNotifications, p.backgroundEnabled);
    await prefs.setString(_kMutedSources, jsonEncode(p.mutedSources));
    if (p.quietHoursStartMinutes == null) {
      await prefs.remove(_kQuietHoursStart);
    } else {
      await prefs.setInt(_kQuietHoursStart, p.quietHoursStartMinutes!);
    }
    if (p.quietHoursEndMinutes == null) {
      await prefs.remove(_kQuietHoursEnd);
    } else {
      await prefs.setInt(_kQuietHoursEnd, p.quietHoursEndMinutes!);
    }
    await prefs.setInt(_kDefaultTtlDays, p.defaultTtlDays);
  }
}

/// Generate a v4-style UUID using `Random.secure`. Crypto-strong randomness
/// — 122 random bits, same entropy as `crypto.randomUUID()`. Format is
/// `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx` where `y` ∈ {8,9,a,b}.
String _generateUuidV4() {
  final r = Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  // Set version (4) and variant (10xx) bits per RFC 4122.
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int n) => n.toRadixString(16).padLeft(2, '0');
  final h = bytes.map(hex).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}'
      '-${h.substring(16, 20)}-${h.substring(20, 32)}';
}
