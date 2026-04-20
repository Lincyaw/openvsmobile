import 'dart:async';
import 'dart:convert';

import 'package:vscode_mobile/models/chat_message.dart';
import 'package:vscode_mobile/models/session.dart';
import 'package:vscode_mobile/providers/chat_provider.dart';
import 'package:vscode_mobile/services/chat_api_client.dart';
import 'package:vscode_mobile/services/settings_service.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class RecordingWebSocketSink implements WebSocketSink {
  final List<dynamic> sentMessages = <dynamic>[];
  bool isClosed = false;

  @override
  void add(dynamic event) {
    sentMessages.add(event);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) async {
    await for (final event in stream) {
      add(event);
    }
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    isClosed = true;
  }

  @override
  Future<void> get done async {}
}

class RecordingWebSocketChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  RecordingWebSocketChannel()
    : _controller = StreamController<dynamic>.broadcast(),
      _sink = RecordingWebSocketSink();

  final StreamController<dynamic> _controller;
  final RecordingWebSocketSink _sink;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready async {}

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  RecordingWebSocketSink get sink => _sink;

  void serverSend(Map<String, dynamic> payload) {
    _controller.add(jsonEncode(payload));
  }

  Future<void> dispose() async {
    await _controller.close();
  }
}

class FakeChatApiClient extends ChatApiClient {
  FakeChatApiClient({RecordingWebSocketChannel? channel})
    : channel = channel ?? RecordingWebSocketChannel(),
      super(settings: SettingsService());

  final RecordingWebSocketChannel channel;
  List<SessionMeta> sessions = const <SessionMeta>[];

  @override
  WebSocketChannel connectWebSocket() => channel;

  @override
  Future<List<SessionMeta>> getSessions({
    String? query,
    String? project,
  }) async {
    return sessions;
  }

  @override
  Future<List<ChatMessage>> getSessionMessages(String sessionId) async {
    return const <ChatMessage>[];
  }

  @override
  Future<List<ChatMessage>> getSubagentMessages(
    String sessionId,
    String agentId,
  ) async {
    return const <ChatMessage>[];
  }

  @override
  Future<Map<String, dynamic>> getSubagentMeta(
    String sessionId,
    String agentId,
  ) async {
    return const <String, dynamic>{};
  }
}

Map<String, dynamic> decodeSentJson(
  RecordingWebSocketChannel channel,
  int index,
) {
  final raw = channel.sink.sentMessages[index] as String;
  return jsonDecode(raw) as Map<String, dynamic>;
}

List<String> sortedKeys(Map<String, dynamic> payload) {
  final keys = payload.keys.toList()..sort();
  return keys;
}
