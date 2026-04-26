import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/terminal_session.dart';

typedef TerminalChannelFactory = WebSocketChannel Function(Uri uri);

class TerminalApiClient {
  TerminalApiClient({
    required this.baseUrl,
    required this.token,
    http.Client? client,
    TerminalChannelFactory? channelFactory,
  }) : _client = client ?? http.Client(),
       _channelFactory = channelFactory ?? WebSocketChannel.connect;

  final String baseUrl;
  final String token;
  final http.Client _client;
  final TerminalChannelFactory _channelFactory;

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  };

  Uri _httpUri(String path) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$base$path');
  }

  Uri _wsUri(String path) {
    final wsBase = baseUrl
        .replaceFirst('https://', 'wss://')
        .replaceFirst('http://', 'ws://');
    final base = wsBase.endsWith('/')
        ? wsBase.substring(0, wsBase.length - 1)
        : wsBase;
    return Uri.parse('$base$path?token=$token');
  }

  Future<List<TerminalSession>> listSessions() async {
    final response = await _client.get(
      _httpUri('/api/terminal/sessions'),
      headers: _headers,
    );
    _ensureSuccess(response, 'list terminal sessions');

    final decoded = jsonDecode(response.body);
    final List<dynamic> sessions;
    if (decoded is List<dynamic>) {
      sessions = decoded;
    } else if (decoded is Map<String, dynamic> && decoded['sessions'] is List) {
      sessions = decoded['sessions'] as List<dynamic>;
    } else {
      throw StateError('unexpected terminal sessions payload: $decoded');
    }

    return sessions
        .cast<Map<String, dynamic>>()
        .map(TerminalSession.fromJson)
        .toList();
  }

  Future<TerminalSession> createSession({
    required String workDir,
    String? name,
    String profile = '',
    int? rows,
    int? cols,
  }) async {
    final payload = <String, dynamic>{
      'cwd': workDir,
      'profile': profile,
      if (name != null && name.isNotEmpty) 'name': name,
      'rows': ?rows,
      'cols': ?cols,
    };
    return _postForSession('/api/terminal/create', payload);
  }

  Future<TerminalSession> attachSession(String id) {
    return _postForSession('/api/terminal/attach', {'id': id});
  }

  Future<TerminalSession> resizeSession(String id, int rows, int cols) {
    return _postForSession('/api/terminal/resize', {
      'id': id,
      'rows': rows,
      'cols': cols,
    });
  }

  Future<TerminalSession> closeSession(String id) {
    return _postForSession('/api/terminal/close', {'id': id});
  }

  Future<TerminalSession> renameSession(String id, String name) {
    return _postForSession('/api/terminal/rename', {'id': id, 'name': name});
  }

  Future<TerminalSession> splitSession(String parentId, {String? name}) {
    return _postForSession('/api/terminal/split', {
      'parentId': parentId,
      if (name != null && name.isNotEmpty) 'name': name,
    });
  }

  WebSocketChannel connectTerminalWebSocket(String id) {
    return _channelFactory(_wsUri('/ws/terminal/$id'));
  }

  WebSocketChannel connectEventsWebSocket() {
    return _channelFactory(_wsUri('/bridge/ws/events'));
  }

  Future<TerminalSession> _postForSession(
    String path,
    Map<String, dynamic> payload,
  ) async {
    final response = await _client.post(
      _httpUri(path),
      headers: _headers,
      body: jsonEncode(payload),
    );
    _ensureSuccess(response, 'call $path');

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final sessionJson = decoded['session'];
    if (sessionJson is Map<String, dynamic>) {
      return TerminalSession.fromJson(sessionJson);
    }
    return TerminalSession.fromJson(decoded);
  }

  void _ensureSuccess(http.Response response, String action) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }
    throw StateError(
      'failed to $action: ${response.statusCode} ${response.body}',
    );
  }
}
