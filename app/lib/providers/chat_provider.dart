import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/chat_message.dart';
import '../models/session.dart';
import '../providers/workspace_provider.dart';
import '../services/chat_api_client.dart';

/// State management for chat functionality.
/// Manages WebSocket connection, messages, and code context.
/// Each workspace has its own conversation context — switching workspaces
/// clears the active conversation and reloads sessions for the new workspace.
class ChatProvider extends ChangeNotifier {
  final ChatApiClient _apiClient;

  ChatProvider({required ChatApiClient apiClient}) : _apiClient = apiClient;

  // -- Workspace binding --
  String _workspacePath = '/';
  String get workspacePath => _workspacePath;

  // -- Connection state --
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  bool _isConnected = false;
  bool get isConnected => _isConnected;

  // -- Conversation state --
  String? _conversationId;
  String? get conversationId => _conversationId;

  final List<ChatMessage> _messages = [];
  List<ChatMessage> get messages => List.unmodifiable(_messages);

  // Current streaming content blocks being assembled
  final List<ContentBlock> _streamingBlocks = [];
  bool _isStreaming = false;
  bool get isStreaming => _isStreaming;

  // -- Code context (for contextual chat / REQ-009) --
  CodeContext? _codeContext;
  CodeContext? get codeContext => _codeContext;

  // -- Session list --
  List<SessionMeta> _sessions = [];
  List<SessionMeta> get sessions => List.unmodifiable(_sessions);
  bool _isLoadingSessions = false;
  bool get isLoadingSessions => _isLoadingSessions;

  // -- Pending message (queued before conversationId is set) --
  String? _pendingMessage;

  // -- Error state --
  String? _error;
  String? get error => _error;

  /// Switch workspace context. Clears the active conversation and
  /// reloads sessions scoped to the new workspace.
  void setWorkspace(String path) {
    if (path == _workspacePath) return;
    _workspacePath = path;
    // Inline clear without extra notifyListeners — we notify once below.
    _messages.clear();
    _streamingBlocks.clear();
    _conversationId = null;
    _pendingMessage = null;
    _isStreaming = false;
    _codeContext = null;
    _error = null;
    notifyListeners();
    loadSessions();
  }

  /// Set code context for contextual chat.
  void setCodeContext(CodeContext? context) {
    _codeContext = context;
    notifyListeners();
  }

  /// Clear current conversation and start fresh.
  void clearConversation() {
    _messages.clear();
    _streamingBlocks.clear();
    _conversationId = null;
    _pendingMessage = null;
    _isStreaming = false;
    _codeContext = null;
    _error = null;
    notifyListeners();
  }

  /// Connect to the WebSocket if not already connected.
  void _ensureConnected() {
    if (_isConnected && _channel != null) return;

    _channel = _apiClient.connectWebSocket();
    _subscription = _channel!.stream.listen(
      _onMessage,
      onError: _onError,
      onDone: _onDone,
    );
    _isConnected = true;
  }

  /// Start a new conversation in the current workspace.
  void startConversation({String? workDir}) {
    _ensureConnected();
    _messages.clear();
    _streamingBlocks.clear();
    _conversationId = null;
    _error = null;

    final dir = workDir ?? _workspacePath;
    _channel!.sink.add(jsonEncode({'type': 'start', 'workDir': dir}));
    notifyListeners();
  }

  /// Queue a message and start a new conversation in the current workspace.
  void queueAndStart(String text, {String? workDir}) {
    _pendingMessage = text;
    startConversation(workDir: workDir);
  }

  /// Resume an existing conversation.
  void resumeConversation(String sessionId) {
    _ensureConnected();
    _messages.clear();
    _streamingBlocks.clear();
    _error = null;

    _channel!.sink.add(jsonEncode({'type': 'resume', 'sessionId': sessionId}));
    notifyListeners();
  }

  /// Send a message in the current conversation.
  void sendMessage(String text) {
    if (_conversationId == null) return;

    // Build user message text, including code context if present
    String messageText = text;
    if (_codeContext != null) {
      final ctx = _codeContext!;
      messageText =
          'Regarding the code in ${ctx.filePath} '
          '(lines ${ctx.startLine}-${ctx.endLine}):\n'
          '```\n${ctx.selectedText}\n```\n\n$text';
      _codeContext = null; // Clear after sending
    }

    // Add user message locally
    _messages.add(
      ChatMessage(
        role: 'user',
        content: [ContentBlock(type: 'text', text: messageText)],
      ),
    );

    _isStreaming = true;
    _streamingBlocks.clear();
    _error = null;

    _channel!.sink.add(
      jsonEncode({
        'type': 'send',
        'sessionId': _conversationId,
        'message': messageText,
      }),
    );
    notifyListeners();
  }

  /// Handle incoming WebSocket messages.
  void _onMessage(dynamic data) {
    final Map<String, dynamic> msg =
        jsonDecode(data as String) as Map<String, dynamic>;
    final type = msg['type'] as String?;

    switch (type) {
      case 'started':
        _conversationId = msg['conversationId'] as String?;
        if (_pendingMessage != null) {
          final pending = _pendingMessage!;
          _pendingMessage = null;
          sendMessage(pending);
        }
        notifyListeners();
        break;

      case 'resumed':
        _conversationId = msg['conversationId'] as String?;
        notifyListeners();
        break;

      case 'assistant':
        _handleAssistantContent(msg);
        break;

      case 'result':
        _handleResult(msg);
        break;

      case 'error':
        _error = msg['error'] as String?;
        _isStreaming = false;
        notifyListeners();
        break;

      case 'closed':
        _isConnected = false;
        _isStreaming = false;
        notifyListeners();
        break;
    }
  }

  void _handleAssistantContent(Map<String, dynamic> msg) {
    final message = msg['message'] as Map<String, dynamic>?;
    final rawContent = message?['content'] as List<dynamic>?;
    if (rawContent == null) return;

    _streamingBlocks.clear();
    for (final block in rawContent) {
      _streamingBlocks.add(
        ContentBlock.fromJson(block as Map<String, dynamic>),
      );
    }
    notifyListeners();
  }

  void _handleResult(Map<String, dynamic> msg) {
    final resultText = msg['result'] as String?;
    if (resultText == null && _streamingBlocks.isEmpty) return;

    // Prefer streaming blocks (richer content) over the plain-text result fallback.
    List<ContentBlock> blocks;
    if (_streamingBlocks.isNotEmpty) {
      blocks = List.from(_streamingBlocks);
    } else if (resultText != null) {
      blocks = [ContentBlock(type: 'text', text: resultText)];
    } else {
      return;
    }

    _messages.add(ChatMessage(role: 'assistant', content: blocks));
    _streamingBlocks.clear();
    _isStreaming = false;
    notifyListeners();
  }

  void _onError(dynamic error) {
    _error = error.toString();
    _isConnected = false;
    _isStreaming = false;
    notifyListeners();
  }

  void _onDone() {
    _isConnected = false;
    _isStreaming = false;
    notifyListeners();
  }

  /// Get the current streaming assistant message (partial).
  ChatMessage? get streamingMessage {
    if (_streamingBlocks.isEmpty) return null;
    return ChatMessage(role: 'assistant', content: List.from(_streamingBlocks));
  }

  /// All messages including the current streaming one.
  List<ChatMessage> get allMessages {
    final list = List<ChatMessage>.from(_messages);
    final streaming = streamingMessage;
    if (streaming != null) {
      list.add(streaming);
    }
    return list;
  }

  /// Fetch session list from REST API.
  /// Defaults to filtering by the current workspace project name.
  /// Pass [allProjects] = true to show sessions from all workspaces.
  Future<void> loadSessions({
    String? query,
    String? project,
    bool allProjects = false,
  }) async {
    _isLoadingSessions = true;
    _error = null;
    notifyListeners();

    try {
      final effectiveProject =
          allProjects ? null : (project ?? WorkspaceProvider.nameForPath(_workspacePath));
      _sessions = await _apiClient.getSessions(
        query: query,
        project: effectiveProject,
      );
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoadingSessions = false;
      notifyListeners();
    }
  }

  /// Fetch messages for a specific session.
  Future<List<ChatMessage>> loadSessionMessages(String sessionId) async {
    return await _apiClient.getSessionMessages(sessionId);
  }

  /// Fetch subagent messages.
  Future<List<ChatMessage>> loadSubagentMessages(
    String sessionId,
    String agentId,
  ) async {
    return await _apiClient.getSubagentMessages(sessionId, agentId);
  }

  /// Fetch subagent metadata.
  Future<Map<String, dynamic>> loadSubagentMeta(
    String sessionId,
    String agentId,
  ) async {
    return await _apiClient.getSubagentMeta(sessionId, agentId);
  }

  /// Stop the current streaming response.
  void stopStreaming() {
    if (!_isStreaming) return;
    _isStreaming = false;
    // Close the WebSocket to abort the server-side stream, then reconnect
    // on the next user action.
    _subscription?.cancel();
    _channel?.sink.close();
    _channel = null;
    _isConnected = false;
    // Commit whatever partial content we have as a final assistant message.
    if (_streamingBlocks.isNotEmpty) {
      _messages.add(
        ChatMessage(role: 'assistant', content: List.from(_streamingBlocks)),
      );
      _streamingBlocks.clear();
    }
    notifyListeners();
  }

  /// Disconnect and clean up.
  void disconnect() {
    _subscription?.cancel();
    _channel?.sink.close();
    _channel = null;
    _isConnected = false;
    _isStreaming = false;
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
