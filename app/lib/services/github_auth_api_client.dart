import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/github_auth_models.dart';
import 'settings_service.dart';

class GitHubAuthApiClient {
  final SettingsService _settings;
  final http.Client _client;

  GitHubAuthApiClient({required SettingsService settings, http.Client? client})
    : _settings = settings,
      _client = client ?? http.Client();

  String get baseUrl => _settings.serverUrl;
  String get token => _settings.authToken;

  Map<String, String> get _jsonHeaders => {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  };

  Uri _buildUri(String path, {Map<String, String>? queryParams}) {
    final normalizedBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final uri = Uri.parse('$normalizedBase$path');
    if (queryParams == null || queryParams.isEmpty) {
      return uri;
    }
    return uri.replace(queryParameters: queryParams);
  }

  Future<GitHubDeviceCode> startDeviceFlow({
    String githubHost = 'github.com',
  }) async {
    final host = _normalizeHost(githubHost);
    final response = await _client.post(
      _buildUri('/api/github/auth/device/start'),
      headers: _jsonHeaders,
      body: jsonEncode({'github_host': host}),
    );
    return _parseResponse(response, (json) => GitHubDeviceCode.fromJson(json));
  }

  Future<GitHubPollResponse> pollDeviceFlow({
    required String githubHost,
    required String deviceCode,
  }) async {
    final host = _normalizeHost(githubHost);
    final response = await _client.post(
      _buildUri('/api/github/auth/device/poll'),
      headers: _jsonHeaders,
      body: jsonEncode({'github_host': host, 'device_code': deviceCode}),
    );
    final parsed = _parseResponse(
      response,
      (json) => GitHubPollResponse.fromJson(json),
    );
    if (parsed.isError) {
      throw GitHubAuthApiException(
        statusCode: response.statusCode,
        errorCode: parsed.errorCode ?? 'github_auth_error',
        message: parsed.message ?? 'GitHub authorization failed.',
      );
    }
    return parsed;
  }

  Future<GitHubAuthStatus> getStatus({String githubHost = 'github.com'}) async {
    final host = _normalizeHost(githubHost);
    final response = await _client.get(
      _buildUri('/api/github/auth/status', queryParams: {'github_host': host}),
      headers: {'Authorization': 'Bearer $token'},
    );
    return _parseResponse(response, GitHubAuthStatus.fromJson);
  }

  Future<GitHubDisconnectResponse> disconnect({
    String githubHost = 'github.com',
  }) async {
    final host = _normalizeHost(githubHost);
    final response = await _client.post(
      _buildUri('/api/github/auth/disconnect'),
      headers: _jsonHeaders,
      body: jsonEncode({'github_host': host}),
    );
    return _parseResponse(response, GitHubDisconnectResponse.fromJson);
  }

  T _parseResponse<T>(
    http.Response response,
    T Function(Map<String, dynamic> json) fromJson,
  ) {
    Map<String, dynamic> payload = const {};
    final body = response.body.trim();
    if (body.isNotEmpty) {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        payload = decoded;
      }
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw GitHubAuthApiException(
        statusCode: response.statusCode,
        errorCode:
            (payload['error_code'] as String?)?.trim() ??
            _defaultErrorCodeForStatus(response.statusCode),
        message:
            (payload['message'] as String?)?.trim() ??
            'GitHub auth request failed (HTTP ${response.statusCode}).',
      );
    }

    return fromJson(payload);
  }

  String _normalizeHost(String? githubHost) {
    final trimmed = githubHost?.trim();
    return (trimmed == null || trimmed.isEmpty) ? 'github.com' : trimmed;
  }

  String _defaultErrorCodeForStatus(int statusCode) {
    switch (statusCode) {
      case 401:
        return 'not_authenticated';
      case 503:
        return 'github_auth_disabled';
      default:
        return 'github_auth_error';
    }
  }

  void dispose() {
    _client.close();
  }
}

class GitHubAuthApiException implements Exception {
  final int statusCode;
  final String errorCode;
  final String message;

  const GitHubAuthApiException({
    required this.statusCode,
    required this.errorCode,
    required this.message,
  });

  bool get needsReconnect => const {
    'reauth_required',
    'needs_reauth',
    'expired_token',
    'bad_refresh_token',
    'refresh_not_supported',
  }.contains(errorCode);

  String toDisplayMessage() {
    switch (errorCode) {
      case 'github_auth_disabled':
        return 'GitHub sign-in is not enabled on this server.';
      case 'not_authenticated':
        return 'GitHub is not connected on this server yet.';
      case 'access_denied':
        return 'GitHub authorization was denied. Start again and approve the request.';
      case 'expired_token':
        return 'The GitHub device code expired. Start again for a fresh code.';
      case 'reauth_required':
      case 'needs_reauth':
      case 'bad_refresh_token':
      case 'refresh_not_supported':
        return 'Your GitHub session expired. Disconnect and reconnect to continue.';
      default:
        return message;
    }
  }

  @override
  String toString() =>
      'GitHubAuthApiException($statusCode, $errorCode): $message';
}
