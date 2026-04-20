import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/git_models.dart';
import 'api_client.dart' show ApiException;
import 'settings_service.dart';

class GitApiClient {
  final SettingsService _settings;
  final http.Client _client;

  GitApiClient({required SettingsService settings, http.Client? client})
      : _settings = settings,
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

  Future<GitRepositoryState> getRepository(String path) async {
    final response = await _client.get(
      _buildUri('/bridge/git/repository', queryParams: {'path': path}),
      headers: _headers,
    );
    return _decodeRepository(response, 'Failed to fetch repository');
  }

  Future<GitDiffDocument> getDiff(
    String repoPath,
    String file, {
    bool staged = false,
  }) async {
    final response = await _client.get(
      _buildUri(
        '/bridge/git/diff',
        queryParams: {
          'path': repoPath,
          'file': file,
          'staged': staged.toString(),
        },
      ),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'Failed to fetch diff: ${_extractErrorMessage(response.body)}',
        response.statusCode,
      );
    }
    return GitDiffDocument.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<GitRepositoryState> stageFile(String repoPath, String file) {
    return _postRepository('/bridge/git/stage', {
      'path': repoPath,
      'file': file,
    }, errorPrefix: 'Failed to stage file');
  }

  Future<GitRepositoryState> unstageFile(String repoPath, String file) {
    return _postRepository('/bridge/git/unstage', {
      'path': repoPath,
      'file': file,
    }, errorPrefix: 'Failed to unstage file');
  }

  Future<GitRepositoryState> discardFile(String repoPath, String file) {
    return _postRepository('/bridge/git/discard', {
      'path': repoPath,
      'file': file,
    }, errorPrefix: 'Failed to discard file');
  }

  Future<GitRepositoryState> commit(String repoPath, String message) {
    return _postRepository('/bridge/git/commit', {
      'path': repoPath,
      'message': message,
    }, errorPrefix: 'Failed to commit');
  }

  Future<GitRepositoryState> checkout(
    String repoPath,
    String ref, {
    bool create = false,
  }) {
    return _postRepository('/bridge/git/checkout', {
      'path': repoPath,
      'ref': ref,
      'create': create,
    }, errorPrefix: 'Failed to checkout');
  }

  Future<GitRepositoryState> fetch(String repoPath, {String? remote}) {
    return _postRepository('/bridge/git/fetch', {
      'path': repoPath,
      if (remote != null && remote.isNotEmpty) 'remote': remote,
    }, errorPrefix: 'Failed to fetch');
  }

  Future<GitRepositoryState> pull(
    String repoPath, {
    String? remote,
    String? branch,
  }) {
    return _postRepository('/bridge/git/pull', {
      'path': repoPath,
      if (remote != null && remote.isNotEmpty) 'remote': remote,
      if (branch != null && branch.isNotEmpty) 'branch': branch,
    }, errorPrefix: 'Failed to pull');
  }

  Future<GitRepositoryState> push(
    String repoPath, {
    String? remote,
    String? branch,
    bool setUpstream = false,
  }) {
    return _postRepository('/bridge/git/push', {
      'path': repoPath,
      if (remote != null && remote.isNotEmpty) 'remote': remote,
      if (branch != null && branch.isNotEmpty) 'branch': branch,
      'setUpstream': setUpstream,
    }, errorPrefix: 'Failed to push');
  }

  Future<GitRepositoryState> stash(
    String repoPath, {
    String? message,
    bool includeUntracked = false,
  }) {
    return _postRepository('/bridge/git/stash', {
      'path': repoPath,
      if (message != null && message.isNotEmpty) 'message': message,
      'includeUntracked': includeUntracked,
    }, errorPrefix: 'Failed to stash changes');
  }

  Future<GitRepositoryState> applyStash(
    String repoPath, {
    String? stash,
    bool pop = false,
  }) {
    return _postRepository('/bridge/git/stash/apply', {
      'path': repoPath,
      if (stash != null && stash.isNotEmpty) 'stash': stash,
      'pop': pop,
    }, errorPrefix: 'Failed to apply stash');
  }

  WebSocketChannel connectEventsWebSocket() {
    final wsBase = baseUrl
        .replaceFirst('https://', 'wss://')
        .replaceFirst('http://', 'ws://');
    final base = wsBase.endsWith('/')
        ? wsBase.substring(0, wsBase.length - 1)
        : wsBase;
    final uri = Uri.parse('$base/bridge/ws/events?token=$token');
    return WebSocketChannel.connect(uri);
  }

  Future<GitRepositoryState> _postRepository(
    String path,
    Map<String, dynamic> body, {
    required String errorPrefix,
  }) async {
    final response = await _client.post(
      _buildUri(path),
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    return _decodeRepository(response, errorPrefix);
  }

  GitRepositoryState _decodeRepository(http.Response response, String errorPrefix) {
    if (response.statusCode != 200) {
      throw ApiException(
        '$errorPrefix: ${_extractErrorMessage(response.body)}',
        response.statusCode,
      );
    }
    return GitRepositoryState.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  String _extractErrorMessage(String body) {
    if (body.isEmpty) {
      return 'unexpected empty response';
    }
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final code = decoded['code'] as String?;
        final message = decoded['message'] as String?;
        if (code != null && code.isNotEmpty && message != null && message.isNotEmpty) {
          return '$code: $message';
        }
        if (message != null && message.isNotEmpty) {
          return message;
        }
        if (code != null && code.isNotEmpty) {
          return code;
        }
      }
    } catch (_) {
      // Fall through to the raw body text.
    }
    return body;
  }

  void dispose() {
    _client.close();
  }
}
