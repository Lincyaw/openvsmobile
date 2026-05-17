// Persistent settings: backend host:port and bearer token.
//
// Keys are kebab-case per docs/conventions.md §4. No migration code: the v0
// rename from `backend.host` etc. will drop existing users' saved settings,
// which is accepted per the settled call in §9.

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

class SettingsStore {
  static const _kServerHost = 'server-host';
  static const _kServerPort = 'server-port';
  static const _kBearerToken = 'bearer-token';

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
}
