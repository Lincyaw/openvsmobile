import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/git_models.dart';
import 'api_client.dart' show ApiException;
import 'settings_service.dart';

/// API client for Git-related endpoints.
class GitApiClient {
  final SettingsService _settings;
  final http.Client _client;

  GitApiClient({
    required SettingsService settings,
    http.Client? client,
  }) : _settings = settings,
       _client = client ?? http.Client();

  String get baseUrl => _settings.serverUrl;
  String get token => _settings.authToken;

  Map<String, String> get _headers => {'Authorization': 'Bearer $token'};

  Uri _buildUri(String path, {Map<String, String>? queryParams}) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    if (queryParams != null && queryParams.isNotEmpty) {
      return Uri.parse('$base$path').replace(queryParameters: queryParams);
    }
    return Uri.parse('$base$path');
  }

  /// Get git status for [path].
  Future<List<GitStatusEntry>> getStatus(String path) async {
    final uri = _buildUri('/api/git/status', queryParams: {'path': path});
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException(
        'Failed to get git status: ${response.statusCode}',
        response.statusCode,
      );
    }
    final List<dynamic> jsonList = (jsonDecode(response.body) as List<dynamic>?) ?? [];
    return jsonList
        .map((e) => GitStatusEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Get diff for [path], optionally for a specific [file] and [staged] state.
  Future<String> getDiff(
    String path, {
    String? file,
    bool staged = false,
  }) async {
    final queryParams = <String, String>{
      'path': path,
      'staged': staged.toString(),
    };
    if (file != null) {
      queryParams['file'] = file;
    }
    final uri = _buildUri('/api/git/diff', queryParams: queryParams);
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException(
        'Failed to get diff: ${response.statusCode}',
        response.statusCode,
      );
    }
    return response.body;
  }

  /// Get git log for [path] with up to [count] entries.
  Future<List<GitLogEntry>> getLog(String path, {int count = 20}) async {
    final uri = _buildUri(
      '/api/git/log',
      queryParams: {'path': path, 'count': count.toString()},
    );
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException(
        'Failed to get git log: ${response.statusCode}',
        response.statusCode,
      );
    }
    final List<dynamic> jsonList = (jsonDecode(response.body) as List<dynamic>?) ?? [];
    return jsonList
        .map((e) => GitLogEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Get branch info for [path].
  Future<GitBranchInfo> getBranches(String path) async {
    final uri = _buildUri('/api/git/branches', queryParams: {'path': path});
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException(
        'Failed to get branches: ${response.statusCode}',
        response.statusCode,
      );
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return GitBranchInfo.fromJson(json);
  }

  /// Stage a file at [path] in the repo at [repoPath].
  Future<void> stageFile(String repoPath, String file) async {
    final uri = _buildUri('/api/git/stage');
    final response = await _client.post(
      uri,
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode({'path': repoPath, 'file': file}),
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'Failed to stage file: ${response.body}',
        response.statusCode,
      );
    }
  }

  /// Unstage a file at [path] in the repo at [repoPath].
  Future<void> unstageFile(String repoPath, String file) async {
    final uri = _buildUri('/api/git/unstage');
    final response = await _client.post(
      uri,
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode({'path': repoPath, 'file': file}),
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'Failed to unstage file: ${response.body}',
        response.statusCode,
      );
    }
  }

  /// Commit staged changes in the repo at [repoPath] with [message].
  Future<void> commit(String repoPath, String message) async {
    final uri = _buildUri('/api/git/commit');
    final response = await _client.post(
      uri,
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode({'path': repoPath, 'message': message}),
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'Failed to commit: ${response.body}',
        response.statusCode,
      );
    }
  }

  /// Get diff/output for a specific commit [hash] in repo at [path].
  Future<String> getShowCommit(String path, String hash) async {
    final uri = _buildUri(
      '/api/git/show',
      queryParams: {'path': path, 'hash': hash},
    );
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException(
        'Failed to get commit diff: ${response.statusCode}',
        response.statusCode,
      );
    }
    return response.body;
  }

  /// Checkout [branch] in repo at [repoPath].
  Future<void> checkoutBranch(String repoPath, String branch) async {
    final uri = _buildUri('/api/git/checkout');
    final response = await _client.post(
      uri,
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode({'path': repoPath, 'branch': branch}),
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'Failed to checkout branch: ${response.body}',
        response.statusCode,
      );
    }
  }

  void dispose() {
    _client.close();
  }
}
