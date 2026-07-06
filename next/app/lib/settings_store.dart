// Persistent settings: backend list + active selection, plus per-install
// secondary preferences (deviceId, notification toggles, mute list, quiet
// hours, default TTL).
//
// Keys are kebab-case per docs/conventions.md §4. The legacy single-backend
// fields (`server-host` / `server-port` / `bearer-token`) are read once at
// startup and migrated into a `BackendTarget` inside the v2 blob, then
// removed — see `loadAppState`.

import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Settings {
  final String host;
  final int port;
  final String token;
  const Settings({required this.host, required this.port, required this.token});

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

const double kTerminalFontSizeDefault = 13;
const double kTerminalFontSizeMin = 10;
const double kTerminalFontSizeMax = 24;

double clampTerminalFontSize(double value) =>
    value.clamp(kTerminalFontSizeMin, kTerminalFontSizeMax);

@immutable
class TerminalPrefs {
  final double fontSize;
  const TerminalPrefs({this.fontSize = kTerminalFontSizeDefault});

  TerminalPrefs copyWith({double? fontSize}) => TerminalPrefs(
    fontSize: fontSize == null
        ? this.fontSize
        : clampTerminalFontSize(fontSize),
  );
}

/// How a [BackendTarget] entered the user's backends list. Persisted as a
/// string tag rather than an int so the on-disk blob stays diffable.
enum BackendOrigin {
  /// Typed in by hand via the manual-entry form.
  manual,

  /// Installed via the SSH bootstrap flow.
  sshInstall,

  /// Discovered via a [DiscoverySource] (k8s-style LB endpoint). Reserved —
  /// the discovery path is not implemented in v0; the enum value exists so
  /// the persisted schema does not need a breaking bump when it lands.
  discovery,
}

/// Transport used to reach a backend. `websocket` is the original host:port
/// path; `iroh` dials an endpoint ticket and then runs the same JSON-RPC
/// frames over an Iroh bidirectional stream.
enum BackendTransport { websocket, iroh }

String _originToString(BackendOrigin o) => switch (o) {
  BackendOrigin.manual => 'manual',
  BackendOrigin.sshInstall => 'sshInstall',
  BackendOrigin.discovery => 'discovery',
};

BackendOrigin _originFromString(String s) => switch (s) {
  'sshInstall' => BackendOrigin.sshInstall,
  'discovery' => BackendOrigin.discovery,
  _ => BackendOrigin.manual,
};

String _transportToString(BackendTransport t) => switch (t) {
  BackendTransport.websocket => 'websocket',
  BackendTransport.iroh => 'iroh',
};

BackendTransport _transportFromString(String s) => switch (s) {
  'iroh' => BackendTransport.iroh,
  _ => BackendTransport.websocket,
};

/// One reachable backend instance — host:port + bearer token, plus a
/// user-editable display name and bookkeeping for the last workspace opened
/// against it (so a switch back can auto-reopen).
class BackendTarget {
  final String id;
  final String name;
  final String host;
  final int port;
  final String token;
  final BackendTransport transport;
  final String? irohTicket;
  final String? irohEndpointId;
  final String? irohAlpn;
  final BackendOrigin origin;

  /// Free-form back-pointer to whatever produced this target: for
  /// `sshInstall` it can be the `<user>@<host>` string; for `discovery` it
  /// is the [DiscoverySource.id]. Manual entries leave it null.
  final String? originRef;

  /// Future k8s grouping ("prod-east", "staging", …). Always null in v0.
  final String? cluster;

  final int addedAt;
  final int? lastConnectedAt;
  final String? lastWorkspaceId;

  const BackendTarget({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.token,
    this.transport = BackendTransport.websocket,
    this.irohTicket,
    this.irohEndpointId,
    this.irohAlpn,
    required this.origin,
    this.originRef,
    this.cluster,
    required this.addedAt,
    this.lastConnectedAt,
    this.lastWorkspaceId,
  });

  bool get isComplete {
    if (token.isEmpty) return false;
    return switch (transport) {
      BackendTransport.websocket => host.isNotEmpty && port > 0 && port < 65536,
      BackendTransport.iroh =>
        irohTicket != null && irohTicket!.trim().isNotEmpty,
    };
  }

  BackendTarget copyWith({
    String? name,
    String? host,
    int? port,
    String? token,
    BackendTransport? transport,
    String? irohTicket,
    String? irohEndpointId,
    String? irohAlpn,
    bool clearIroh = false,
    BackendOrigin? origin,
    String? originRef,
    String? cluster,
    int? lastConnectedAt,
    String? lastWorkspaceId,
    bool clearLastWorkspaceId = false,
  }) {
    return BackendTarget(
      id: id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      token: token ?? this.token,
      transport: transport ?? this.transport,
      irohTicket: clearIroh ? null : (irohTicket ?? this.irohTicket),
      irohEndpointId: clearIroh
          ? null
          : (irohEndpointId ?? this.irohEndpointId),
      irohAlpn: clearIroh ? null : (irohAlpn ?? this.irohAlpn),
      origin: origin ?? this.origin,
      originRef: originRef ?? this.originRef,
      cluster: cluster ?? this.cluster,
      addedAt: addedAt,
      lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
      lastWorkspaceId: clearLastWorkspaceId
          ? null
          : (lastWorkspaceId ?? this.lastWorkspaceId),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'token': token,
    'transport': _transportToString(transport),
    if (irohTicket != null) 'irohTicket': irohTicket,
    if (irohEndpointId != null) 'irohEndpointId': irohEndpointId,
    if (irohAlpn != null) 'irohAlpn': irohAlpn,
    'origin': _originToString(origin),
    if (originRef != null) 'originRef': originRef,
    if (cluster != null) 'cluster': cluster,
    'addedAt': addedAt,
    if (lastConnectedAt != null) 'lastConnectedAt': lastConnectedAt,
    if (lastWorkspaceId != null) 'lastWorkspaceId': lastWorkspaceId,
  };

  factory BackendTarget.fromJson(Map<String, dynamic> j) => BackendTarget(
    id: j['id'] as String,
    name: (j['name'] as String?) ?? '',
    host: (j['host'] as String?) ?? '',
    port: (j['port'] as num?)?.toInt() ?? 0,
    token: (j['token'] as String?) ?? '',
    transport: _transportFromString((j['transport'] as String?) ?? 'websocket'),
    irohTicket: j['irohTicket'] as String?,
    irohEndpointId: j['irohEndpointId'] as String?,
    irohAlpn: j['irohAlpn'] as String?,
    origin: _originFromString((j['origin'] as String?) ?? 'manual'),
    originRef: j['originRef'] as String?,
    cluster: j['cluster'] as String?,
    addedAt: (j['addedAt'] as num?)?.toInt() ?? 0,
    lastConnectedAt: (j['lastConnectedAt'] as num?)?.toInt(),
    lastWorkspaceId: j['lastWorkspaceId'] as String?,
  );
}

/// Source of a list of backends fetched at runtime (k8s LB, custom
/// directory service, …). v0 only persists the schema — no code path
/// actually polls these yet.
class DiscoverySource {
  final String id;
  final String name;
  final String url;
  final String? authHeader;
  final int refreshIntervalSec;
  final int? lastRefreshedAt;

  const DiscoverySource({
    required this.id,
    required this.name,
    required this.url,
    this.authHeader,
    this.refreshIntervalSec = 300,
    this.lastRefreshedAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    if (authHeader != null) 'authHeader': authHeader,
    'refreshIntervalSec': refreshIntervalSec,
    if (lastRefreshedAt != null) 'lastRefreshedAt': lastRefreshedAt,
  };

  factory DiscoverySource.fromJson(Map<String, dynamic> j) => DiscoverySource(
    id: j['id'] as String,
    name: (j['name'] as String?) ?? '',
    url: (j['url'] as String?) ?? '',
    authHeader: j['authHeader'] as String?,
    refreshIntervalSec: (j['refreshIntervalSec'] as num?)?.toInt() ?? 300,
    lastRefreshedAt: (j['lastRefreshedAt'] as num?)?.toInt(),
  );
}

/// Top-level persisted state for the backends/discovery surface.
class AppPersistedState {
  final List<BackendTarget> backends;
  final String? activeBackendId;
  final List<DiscoverySource> discoverySources;
  final int schemaVersion;

  const AppPersistedState({
    this.backends = const [],
    this.activeBackendId,
    this.discoverySources = const [],
    this.schemaVersion = 2,
  });

  BackendTarget? get activeBackend {
    final id = activeBackendId;
    if (id == null) return null;
    for (final b in backends) {
      if (b.id == id) return b;
    }
    return null;
  }

  AppPersistedState copyWith({
    List<BackendTarget>? backends,
    String? activeBackendId,
    bool clearActiveBackendId = false,
    List<DiscoverySource>? discoverySources,
  }) {
    return AppPersistedState(
      backends: backends ?? this.backends,
      activeBackendId: clearActiveBackendId
          ? null
          : (activeBackendId ?? this.activeBackendId),
      discoverySources: discoverySources ?? this.discoverySources,
      schemaVersion: schemaVersion,
    );
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'backends': backends.map((b) => b.toJson()).toList(),
    if (activeBackendId != null) 'activeBackendId': activeBackendId,
    'discoverySources': discoverySources.map((d) => d.toJson()).toList(),
  };

  factory AppPersistedState.fromJson(Map<String, dynamic> j) {
    final backends = ((j['backends'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map(BackendTarget.fromJson)
        .toList(growable: false);
    return AppPersistedState(
      backends: backends,
      activeBackendId: j['activeBackendId'] as String?,
      discoverySources: ((j['discoverySources'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map(DiscoverySource.fromJson)
          .toList(growable: false),
      schemaVersion: (j['schemaVersion'] as num?)?.toInt() ?? 2,
    );
  }
}

class SettingsStore {
  static const _kServerHost = 'server-host';
  static const _kServerPort = 'server-port';
  static const _kBearerToken = 'bearer-token';
  static const _kBackendsStateV2 = 'backends-state-v2';
  static const _kDeviceId = 'device-id';
  static const _kBackgroundNotifications = 'background-notifications';
  static const _kMutedSources = 'notifications-mute-sources';
  static const _kQuietHoursStart = 'quiet-hours-start';
  static const _kQuietHoursEnd = 'quiet-hours-end';
  static const _kDefaultTtlDays = 'notifications-default-ttl-days';
  static const _kThemeMode = 'theme-mode';
  static const _kTerminalFontSize = 'terminal-font-size';

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

  /// Load the multi-backend state. If the v2 blob is absent but legacy
  /// single-backend keys exist and are complete, migrate them into a fresh
  /// blob with one [BackendTarget] (`name: "default"`, `origin: manual`)
  /// marked active. Legacy keys are removed after a successful migration so
  /// the next load reads from v2 directly.
  Future<AppPersistedState> loadAppState() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kBackendsStateV2);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          return AppPersistedState.fromJson(decoded);
        }
      } on FormatException catch (e) {
        // Corrupted blob — fall through to legacy / empty rather than
        // crashing the boot path. The next save overwrites it cleanly.
        // ignore: avoid_print
        print('SettingsStore: dropping malformed backends-state-v2: $e');
      }
    }
    final legacy = await load();
    if (legacy.isComplete) {
      final migrated = AppPersistedState(
        backends: [
          BackendTarget(
            id: generateUuidV4(),
            name: 'default',
            host: legacy.host,
            port: legacy.port,
            token: legacy.token,
            origin: BackendOrigin.manual,
            addedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        ],
        activeBackendId: null,
      );
      final state = migrated.copyWith(
        activeBackendId: migrated.backends.first.id,
      );
      await saveAppState(state);
      await prefs.remove(_kServerHost);
      await prefs.remove(_kServerPort);
      await prefs.remove(_kBearerToken);
      return state;
    }
    return const AppPersistedState();
  }

  Future<void> saveAppState(AppPersistedState s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBackendsStateV2, jsonEncode(s.toJson()));
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
    final id = generateUuidV4();
    await prefs.setString(_kDeviceId, id);
    return id;
  }

  /// Generic kebab-case bool flag. Used for transient onboarding flags
  /// (e.g. `background-onboarded`) where adding a typed field on a
  /// settings struct is overkill.
  Future<bool?> getBool(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(key);
  }

  Future<void> setBool(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
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

  /// Load the persisted [ThemeMode]. Defaults to [ThemeMode.system] when
  /// the key is absent (first launch) or carries an unknown string —
  /// "follow the OS" is the least-surprising default for a brand-new
  /// install.
  Future<ThemeMode> loadThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kThemeMode);
    return _themeModeFromString(raw);
  }

  /// Persist [mode]. Stored as `'system' | 'light' | 'dark'` so the
  /// on-disk blob stays diffable and human-inspectable.
  Future<void> saveThemeMode(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kThemeMode, _themeModeToString(mode));
  }

  Future<TerminalPrefs> loadTerminalPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getDouble(_kTerminalFontSize);
    return TerminalPrefs(
      fontSize: raw == null
          ? kTerminalFontSizeDefault
          : clampTerminalFontSize(raw),
    );
  }

  Future<void> saveTerminalPrefs(TerminalPrefs value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(
      _kTerminalFontSize,
      clampTerminalFontSize(value.fontSize),
    );
  }
}

/// Stringify a [ThemeMode] for `SharedPreferences`. Public so widget tests
/// can seed the underlying preference without going through the
/// `SettingsStore` API.
String _themeModeToString(ThemeMode mode) => switch (mode) {
  ThemeMode.system => 'system',
  ThemeMode.light => 'light',
  ThemeMode.dark => 'dark',
};

ThemeMode _themeModeFromString(String? s) => switch (s) {
  'light' => ThemeMode.light,
  'dark' => ThemeMode.dark,
  _ => ThemeMode.system,
};

/// Generate a v4-style UUID using `Random.secure`. Crypto-strong randomness
/// — 122 random bits, same entropy as `crypto.randomUUID()`. Format is
/// `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx` where `y` ∈ {8,9,a,b}.
String generateUuidV4() {
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
