import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/chat_message.dart';
import '../models/session.dart';
import 'api_client.dart' show ApiException;

/// API client for chat-specific endpoints.
/// Separate from Group C's ApiClient to avoid conflicts.
class ChatApiClient {
  final String baseUrl;
  final String token;
  final http.Client _client;

  ChatApiClient({
    required this.baseUrl,
    required this.token,
    http.Client? client,
  }) : _client = client ?? http.Client();

  Map<String, String> get _headers => {'Authorization': 'Bearer $token'};

  Uri _buildUri(String path) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$base$path').replace(queryParameters: {'token': token});
  }

  /// Fetch all sessions. Supports optional search query and project filter.
  Future<List<SessionMeta>> getSessions({
    String? query,
    String? project,
  }) async {
    final params = <String, String>{'token': token};
    if (query != null && query.isNotEmpty) params['q'] = query;
    if (project != null && project.isNotEmpty) params['project'] = project;

    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final uri = Uri.parse('$base/api/sessions').replace(
      queryParameters: params,
    );
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException(
        'Failed to fetch sessions: ${response.statusCode}',
        response.statusCode,
      );
    }
    final List<dynamic> jsonList = jsonDecode(response.body) as List<dynamic>;
    return jsonList
        .map((e) => SessionMeta.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Fetch messages for a specific session.
  Future<List<ChatMessage>> getSessionMessages(String sessionId) async {
    final uri = _buildUri('/api/sessions/$sessionId/messages');
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException(
        'Failed to fetch messages: ${response.statusCode}',
        response.statusCode,
      );
    }
    final List<dynamic> jsonList = jsonDecode(response.body) as List<dynamic>;
    return jsonList
        .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Fetch subagent messages.
  Future<List<ChatMessage>> getSubagentMessages(
    String sessionId,
    String agentId,
  ) async {
    final uri = _buildUri('/api/sessions/$sessionId/subagents/$agentId/messages');
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException(
        'Failed to fetch subagent messages: ${response.statusCode}',
        response.statusCode,
      );
    }
    final List<dynamic> jsonList = jsonDecode(response.body) as List<dynamic>;
    return jsonList
        .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Fetch subagent metadata.
  Future<Map<String, dynamic>> getSubagentMeta(
    String sessionId,
    String agentId,
  ) async {
    final uri = _buildUri('/api/sessions/$sessionId/subagents/$agentId/meta');
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException(
        'Failed to fetch subagent meta: ${response.statusCode}',
        response.statusCode,
      );
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Connect to the chat WebSocket.
  WebSocketChannel connectWebSocket() {
    final wsBase = baseUrl
        .replaceFirst('https://', 'wss://')
        .replaceFirst('http://', 'ws://');
    final base = wsBase.endsWith('/')
        ? wsBase.substring(0, wsBase.length - 1)
        : wsBase;
    final uri = Uri.parse('$base/ws/chat?token=$token');
    return WebSocketChannel.connect(uri);
  }

  void dispose() {
    _client.close();
  }
}
