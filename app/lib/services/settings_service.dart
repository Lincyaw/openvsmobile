import 'package:shared_preferences/shared_preferences.dart';

const _defaultServerUrl = 'http://10.0.2.2:8080';
const _defaultAuthToken = 'dev-token';

class SettingsService {
  static const _keyServerUrl = 'server_url';
  static const _keyAuthToken = 'auth_token';

  String _serverUrl = _defaultServerUrl;
  String _authToken = _defaultAuthToken;

  String get serverUrl => _serverUrl;
  String get authToken => _authToken;

  /// Load saved settings from SharedPreferences.
  /// Falls back to compile-time defaults when no saved value exists.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _serverUrl = prefs.getString(_keyServerUrl) ?? _defaultServerUrl;
    _authToken = prefs.getString(_keyAuthToken) ?? _defaultAuthToken;
  }

  /// Persist the given server URL and auth token.
  Future<void> save(String url, String token) async {
    final prefs = await SharedPreferences.getInstance();
    _serverUrl = url;
    _authToken = token;
    await prefs.setString(_keyServerUrl, url);
    await prefs.setString(_keyAuthToken, token);
  }
}
