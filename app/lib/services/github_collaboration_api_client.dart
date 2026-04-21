import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/github_collaboration_models.dart';
import 'settings_service.dart';

class GitHubCollaborationApiClient {
  final SettingsService _settings;
  final http.Client _client;

  GitHubCollaborationApiClient({
    required SettingsService settings,
    http.Client? client,
  }) : _settings = settings,
       _client = client ?? http.Client();

  String get baseUrl => _settings.serverUrl;
  String get token => _settings.authToken;

  Map<String, String> get _headers => <String, String>{
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

  Future<GitHubCurrentRepoContext> fetchCurrentRepo({
    String workspacePath = '',
  }) async {
    final response = await _client.get(
      _buildUri(
        '/api/github/repos/current',
        queryParams: _workspaceQuery(workspacePath),
      ),
      headers: _headers,
    );
    return _parseResponse(response, GitHubCurrentRepoContext.fromJson);
  }

  Future<GitHubAccountContext> fetchAccount({String workspacePath = ''}) async {
    final response = await _client.get(
      _buildUri(
        '/api/github/account',
        queryParams: _workspaceQuery(workspacePath),
      ),
      headers: _headers,
    );
    return _parseResponse(response, GitHubAccountContext.fromJson);
  }

  Future<List<GitHubIssue>> fetchIssues({
    required GitHubCollaborationFilter filter,
    String workspacePath = '',
  }) async {
    final response = await _client.get(
      _buildUri(
        '/api/github/issues',
        queryParams: {
          ..._workspaceQuery(workspacePath),
          ...filter.toQueryParameters(includeNeedsReview: false),
        },
      ),
      headers: _headers,
    );
    final payload = _parseJsonEnvelope(response);
    return _mapList(payload['issues'], (item) => GitHubIssue.fromJson(item));
  }

  Future<GitHubIssueDetail> fetchIssueDetail(
    int number, {
    String workspacePath = '',
  }) async {
    final response = await _client.get(
      _buildUri(
        '/api/github/issues/$number',
        queryParams: _workspaceQuery(workspacePath),
      ),
      headers: _headers,
    );
    return _parseResponse(response, GitHubIssueDetail.fromJson);
  }

  Future<GitHubIssueComment> submitIssueComment(
    int number,
    GitHubIssueCommentInput input, {
    String workspacePath = '',
  }) async {
    final response = await _client.post(
      _buildUri('/api/github/issues/$number/comments'),
      headers: _headers,
      body: jsonEncode(<String, dynamic>{
        'workspace_path': workspacePath,
        'body': input.body,
      }),
    );
    final payload = _parseJsonEnvelope(response);
    return GitHubIssueComment.fromJson(
      payload['comment'] as Map<String, dynamic>? ?? const <String, dynamic>{},
    );
  }

  Future<List<GitHubPullRequest>> fetchPullRequests({
    required GitHubCollaborationFilter filter,
    String workspacePath = '',
  }) async {
    final response = await _client.get(
      _buildUri(
        '/api/github/pulls',
        queryParams: {
          ..._workspaceQuery(workspacePath),
          ...filter.toQueryParameters(),
        },
      ),
      headers: _headers,
    );
    final payload = _parseJsonEnvelope(response);
    return _mapList(
      payload['pulls'],
      (item) => GitHubPullRequest.fromJson(item),
    );
  }

  Future<GitHubPullRequestDetail> fetchPullRequestDetail(
    int number, {
    String workspacePath = '',
  }) async {
    final response = await _client.get(
      _buildUri(
        '/api/github/pulls/$number',
        queryParams: _workspaceQuery(workspacePath),
      ),
      headers: _headers,
    );
    return _parseResponse(response, GitHubPullRequestDetail.fromJson);
  }

  Future<GitHubPullRequestConversation> fetchPullRequestConversation(
    int number, {
    String workspacePath = '',
  }) async {
    final response = await _client.get(
      _buildUri(
        '/api/github/pulls/$number/comments',
        queryParams: _workspaceQuery(workspacePath),
      ),
      headers: _headers,
    );
    return _parseResponse(response, GitHubPullRequestConversation.fromJson);
  }

  Future<GitHubPullRequestComment> submitPullRequestComment(
    int number,
    GitHubPullRequestCommentInput input, {
    String workspacePath = '',
  }) async {
    final response = await _client.post(
      _buildUri('/api/github/pulls/$number/comments'),
      headers: _headers,
      body: jsonEncode(input.toJson(workspacePath)),
    );
    final payload = _parseJsonEnvelope(response);
    return GitHubPullRequestComment.fromJson(
      payload['comment'] as Map<String, dynamic>? ?? const <String, dynamic>{},
    );
  }

  Future<GitHubPullRequestReview> submitPullRequestReview(
    int number,
    GitHubPullRequestReviewInput input, {
    String workspacePath = '',
  }) async {
    final response = await _client.post(
      _buildUri('/api/github/pulls/$number/reviews'),
      headers: _headers,
      body: jsonEncode(input.toJson(workspacePath)),
    );
    final payload = _parseJsonEnvelope(response);
    return GitHubPullRequestReview.fromJson(
      payload['review'] as Map<String, dynamic>? ?? const <String, dynamic>{},
    );
  }

  Future<GitHubResolveLocalFileResult> resolveLocalFile({
    required String workspacePath,
    required String relativePath,
  }) async {
    final response = await _client.post(
      _buildUri('/api/github/resolve-local-file'),
      headers: _headers,
      body: jsonEncode(<String, dynamic>{
        'workspace_path': workspacePath,
        'path': relativePath,
      }),
    );
    return _parseResponse(response, GitHubResolveLocalFileResult.fromJson);
  }

  Map<String, dynamic> _parseJsonEnvelope(http.Response response) {
    final payload = _decodeBody(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw GitHubCollaborationException(
        statusCode: response.statusCode,
        errorCode:
            (payload['error_code'] as String?)?.trim() ??
            _defaultErrorCodeForStatus(response.statusCode),
        message:
            (payload['message'] as String?)?.trim() ??
            'GitHub collaboration request failed (HTTP ${response.statusCode}).',
      );
    }
    return payload;
  }

  T _parseResponse<T>(
    http.Response response,
    T Function(Map<String, dynamic> json) fromJson,
  ) {
    final payload = _parseJsonEnvelope(response);
    return fromJson(payload);
  }

  Map<String, dynamic> _decodeBody(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      return const <String, dynamic>{};
    }
    final decoded = jsonDecode(trimmed);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    return const <String, dynamic>{};
  }

  Map<String, String> _workspaceQuery(String workspacePath) {
    final trimmed = workspacePath.trim();
    if (trimmed.isEmpty) {
      return const <String, String>{};
    }
    return <String, String>{'path': trimmed};
  }

  String _defaultErrorCodeForStatus(int statusCode) {
    switch (statusCode) {
      case 400:
        return 'invalid_request';
      case 401:
        return 'not_authenticated';
      case 403:
        return 'repo_access_unavailable';
      case 404:
        return 'not_found';
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

List<T> _mapList<T>(
  Object? value,
  T Function(Map<String, dynamic> item) builder,
) {
  if (value is! List) {
    return List<T>.empty(growable: false);
  }
  return value
      .whereType<Map<String, dynamic>>()
      .map(builder)
      .toList(growable: false);
}
