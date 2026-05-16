// Persistent settings: backend host:port and bearer token.

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
  static const _kHost = 'backend.host';
  static const _kPort = 'backend.port';
  static const _kToken = 'backend.token';

  Future<Settings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return Settings(
      host: prefs.getString(_kHost) ?? '',
      port: prefs.getInt(_kPort) ?? 7860,
      token: prefs.getString(_kToken) ?? '',
    );
  }

  Future<void> save(Settings s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kHost, s.host);
    await prefs.setInt(_kPort, s.port);
    await prefs.setString(_kToken, s.token);
  }
}
