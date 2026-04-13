import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/diagnostic.dart';
import '../models/file_entry.dart';
import '../models/search_result.dart';
import 'settings_service.dart';

class ApiClient {
  final SettingsService _settings;
  final http.Client _client;

  ApiClient({required SettingsService settings, http.Client? client})
    : _settings = settings,
      _client = client ?? http.Client();

  String get baseUrl => _settings.serverUrl;
  String get token => _settings.authToken;

  Map<String, String> get _headers => {'Authorization': 'Bearer $token'};

  Uri _buildUri(String path, {Map<String, String>? extraParams}) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    if (extraParams != null && extraParams.isNotEmpty) {
      return Uri.parse('$base$path').replace(queryParameters: extraParams);
    }
    return Uri.parse('$base$path');
  }

  /// List directory contents at [path].
  Future<List<FileEntry>> listDirectory(String path) async {
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final uri = _buildUri('/api/files$normalizedPath');
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException(
        'Failed to list directory: ${response.statusCode}',
        response.statusCode,
      );
    }
    final List<dynamic> jsonList = jsonDecode(response.body) as List<dynamic>;
    return jsonList
        .map((e) => FileEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Read file content at [path].
  Future<String> readFile(String path) async {
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final uri = _buildUri('/api/files$normalizedPath');
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException(
        'Failed to read file: ${response.statusCode}',
        response.statusCode,
      );
    }
    return response.body;
  }

  /// Write file content at [path].
  Future<void> writeFile(String path, String content) async {
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final uri = _buildUri('/api/files$normalizedPath');
    final response = await _client.put(
      uri,
      headers: {..._headers, 'Content-Type': 'text/plain'},
      body: content,
    );
    if (response.statusCode != 200 && response.statusCode != 204) {
      throw ApiException(
        'Failed to write file: ${response.statusCode}',
        response.statusCode,
      );
    }
  }

  /// Delete file or directory at [path].
  Future<void> deleteFile(String path) async {
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final uri = _buildUri('/api/files$normalizedPath');
    final response = await _client.delete(uri, headers: _headers);
    if (response.statusCode != 200 && response.statusCode != 204) {
      throw ApiException(
        'Failed to delete file: ${response.statusCode}',
        response.statusCode,
      );
    }
  }

  /// Create a directory at [path].
  Future<void> createDirectory(String path) async {
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final uri = _buildUri(
      '/api/files$normalizedPath',
      extraParams: {'type': 'directory'},
    );
    final response = await _client.post(uri, headers: _headers);
    if (response.statusCode != 201) {
      throw ApiException(
        'Failed to create directory: ${response.statusCode}',
        response.statusCode,
      );
    }
  }

  /// Fetch diagnostics for a file or directory.
  Future<List<Diagnostic>> getDiagnostics({
    String? filePath,
    String workDir = '/',
  }) async {
    final params = <String, String>{'workDir': workDir};
    if (filePath != null) params['path'] = filePath;

    final uri = _buildUri('/api/diagnostics', extraParams: params);
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException(
        'Failed to fetch diagnostics: ${response.statusCode}',
        response.statusCode,
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded == null) return [];
    final List<dynamic> jsonList = decoded as List<dynamic>;
    return jsonList
        .map((e) => Diagnostic.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Search file contents for [query] under [path].
  Future<List<ContentSearchResult>> searchContent(
    String query,
    String path,
  ) async {
    final uri = _buildUri(
      '/api/search',
      extraParams: {'q': query, 'path': path},
    );
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException(
        'Failed to search content: ${response.statusCode}',
        response.statusCode,
      );
    }
    final List<dynamic> jsonList = jsonDecode(response.body) as List<dynamic>;
    return jsonList
        .map((e) => ContentSearchResult.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Search for files by name under [path].
  Future<List<Map<String, dynamic>>> searchFiles(
    String query,
    String path,
  ) async {
    final uri = _buildUri(
      '/api/search/files',
      extraParams: {'q': query, 'path': path},
    );
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException(
        'Failed to search files: ${response.statusCode}',
        response.statusCode,
      );
    }
    return (jsonDecode(response.body) as List<dynamic>)
        .cast<Map<String, dynamic>>();
  }

  void dispose() {
    _client.close();
  }
}

class ApiException implements Exception {
  final String message;
  final int statusCode;

  const ApiException(this.message, this.statusCode);

  @override
  String toString() => 'ApiException($statusCode): $message';
}
