import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vscode_mobile/models/chat_context_attachment.dart';
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
    String? workspaceRoot,
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

Map<String, dynamic> extractGitHubAttachmentPayload(
  Map<String, dynamic> payload,
) {
  final candidates = <dynamic>[
    payload['attachment'],
    payload['chatAttachment'],
    payload['contextAttachment'],
    payload['githubAttachment'],
    payload['github'],
  ];

  for (final candidate in candidates) {
    final normalized = _normalizeJsonLike(candidate);
    if (normalized is Map<String, dynamic> && normalized.isNotEmpty) {
      return normalized;
    }
  }
  return <String, dynamic>{};
}

Object? _normalizeJsonLike(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map(
      (key, dynamic nested) =>
          MapEntry(key.toString(), _normalizeJsonLike(nested)),
    );
  }
  if (value is List) {
    return value.map<Object?>((item) => _normalizeJsonLike(item)).toList();
  }

  final dynamic dynamicValue = value;
  try {
    return _normalizeJsonLike(dynamicValue.toTransportJson());
  } catch (_) {
    // ignored
  }
  try {
    return _normalizeJsonLike(dynamicValue.toJson());
  } catch (_) {
    // ignored
  }

  return value;
}

Map<String, dynamic> pendingChatAttachmentJson(ChatProvider provider) {
  final dynamic dynamicProvider = provider;
  for (final getterName in <String>[
    'pendingAttachment',
    'pendingChatAttachment',
    'pendingContextAttachment',
    'pendingGithubAttachment',
    'pendingGitHubAttachment',
    'chatAttachment',
  ]) {
    try {
      final value = switch (getterName) {
        'pendingAttachment' => dynamicProvider.pendingAttachment,
        'pendingChatAttachment' => dynamicProvider.pendingChatAttachment,
        'pendingContextAttachment' => dynamicProvider.pendingContextAttachment,
        'pendingGithubAttachment' => dynamicProvider.pendingGithubAttachment,
        'pendingGitHubAttachment' => dynamicProvider.pendingGitHubAttachment,
        'chatAttachment' => dynamicProvider.chatAttachment,
        _ => null,
      };
      final normalized = _normalizeJsonLike(value);
      if (normalized is Map<String, dynamic>) {
        return normalized;
      }
    } catch (_) {
      // Keep probing known public getter names.
    }
  }
  return const <String, dynamic>{};
}

void queueIssueAttachmentForNextTurn(
  ChatProvider provider, {
  required String actionLabel,
  required String repository,
  required int issueNumber,
  required String title,
  required String body,
  String htmlUrl = 'https://github.com/octo/repo/issues/7',
}) {
  final attachment = GitHubChatAttachment(
    actionLabel: actionLabel,
    kind: GitHubAttachmentKind.issue,
    reference: '$repository#$issueNumber',
    title: title,
    body: body,
    repositoryFullName: repository,
    url: htmlUrl,
  );
  provider.queueGitHubAction(prompt: actionLabel, attachment: attachment);
}

void queueIssueCommentAttachmentForNextTurn(
  ChatProvider provider, {
  required String actionLabel,
  required String repository,
  required int issueNumber,
  required String title,
  required String commentBody,
  required int commentId,
  String authorLogin = 'octocat',
  String htmlUrl = 'https://github.com/octo/repo/issues/7#issuecomment-11',
}) {
  final attachment = GitHubChatAttachment(
    actionLabel: actionLabel,
    kind: GitHubAttachmentKind.issueComment,
    reference: '$repository#$issueNumber / comment $commentId',
    title: title,
    body: commentBody,
    repositoryFullName: repository,
    authorLogin: authorLogin,
    url: htmlUrl,
  );
  provider.queueGitHubAction(prompt: actionLabel, attachment: attachment);
}

void queuePullRequestAttachmentForNextTurn(
  ChatProvider provider, {
  required String actionLabel,
  required String repository,
  required int pullRequestNumber,
  required String title,
  required String body,
  String htmlUrl = 'https://github.com/octo/repo/pull/12',
}) {
  final attachment = GitHubChatAttachment(
    actionLabel: actionLabel,
    kind: GitHubAttachmentKind.pullRequest,
    reference: '$repository#$pullRequestNumber',
    title: title,
    body: body,
    repositoryFullName: repository,
    url: htmlUrl,
  );
  provider.queueGitHubAction(prompt: actionLabel, attachment: attachment);
}

void queuePullRequestCommentAttachmentForNextTurn(
  ChatProvider provider, {
  required String actionLabel,
  required String repository,
  required int pullRequestNumber,
  required String title,
  required int commentId,
  required String commentBody,
  required String path,
  String authorLogin = 'reviewer',
  String htmlUrl = 'https://github.com/octo/repo/pull/12#discussion_r22',
}) {
  final attachment = GitHubChatAttachment(
    actionLabel: actionLabel,
    kind: GitHubAttachmentKind.pullRequestComment,
    reference: '$repository#$pullRequestNumber / comment $commentId',
    title: title,
    body: commentBody,
    repositoryFullName: repository,
    path: path,
    authorLogin: authorLogin,
    url: htmlUrl,
  );
  provider.queueGitHubAction(prompt: actionLabel, attachment: attachment);
}

Finder findTextContaining(String text) {
  return find.byWidgetPredicate(
    (widget) => widget is Text && (widget.data?.contains(text) ?? false),
    description: 'Text containing "$text"',
  );
}

Finder findButtonContaining(String text) {
  return find.byWidgetPredicate((widget) {
    if (widget is FilledButton) {
      return _widgetContainsText(widget.child, text);
    }
    if (widget is TextButton) {
      return _widgetContainsText(widget.child, text);
    }
    if (widget is OutlinedButton) {
      return _widgetContainsText(widget.child, text);
    }
    if (widget is IconButton) {
      return widget.tooltip?.contains(text) ?? false;
    }
    return false;
  }, description: 'Button containing "$text"');
}

bool _widgetContainsText(Widget? widget, String text) {
  if (widget == null) {
    return false;
  }
  if (widget is Text) {
    return widget.data?.contains(text) ?? false;
  }
  if (widget is RichText) {
    return widget.text.toPlainText().contains(text);
  }
  if (widget is SingleChildRenderObjectWidget) {
    return _widgetContainsText(widget.child, text);
  }
  if (widget is MultiChildRenderObjectWidget) {
    return widget.children.any((child) => _widgetContainsText(child, text));
  }
  return false;
}
