import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/chat_provider.dart';
import '../providers/editor_provider.dart';
import '../providers/workspace_provider.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/app_bar_menu.dart';
import 'code_screen.dart';
import 'session_list_screen.dart';

/// Full-screen AI chat view (tab 2 in bottom navigation).
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  int _lastMessageCount = 0;

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _sendMessage(ChatProvider provider) {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    if (provider.conversationId == null) {
      provider.queueAndStart(text);
    } else {
      provider.sendMessage(text);
    }

    _controller.clear();
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        return Scaffold(
          appBar: AppBar(
            title: Consumer<WorkspaceProvider>(
              builder: (context, ws, _) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('AI Chat'),
                    Text(
                      ws.displayName,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant,
                      ),
                    ),
                  ],
                );
              },
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.history),
                tooltip: 'Past sessions',
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const SessionListScreen(),
                    ),
                  );
                },
              ),
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: 'New conversation',
                onPressed: () {
                  provider.clearConversation();
                },
              ),
              const AppBarMenu(),
            ],
          ),
          body: Column(
            children: [
              if (provider.error != null) _buildErrorBanner(context, provider),
              if (provider.codeContext != null)
                _buildContextBadge(context, provider),
              Expanded(child: _buildMessageList(context, provider)),
              _buildInputBar(context, provider),
            ],
          ),
        );
      },
    );
  }

  Widget _buildErrorBanner(BuildContext context, ChatProvider provider) {
    return MaterialBanner(
      content: Text(provider.error!),
      backgroundColor: Theme.of(context).colorScheme.errorContainer,
      actions: [
        TextButton(
          onPressed: () {
            provider.clearConversation();
          },
          child: const Text('Dismiss'),
        ),
      ],
    );
  }

  Widget _buildContextBadge(BuildContext context, ChatProvider provider) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final ctx = provider.codeContext!;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.code, size: 18, color: colorScheme.onSecondaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Context: ${ctx.label}',
              style: theme.textTheme.labelMedium?.copyWith(
                color: colorScheme.onSecondaryContainer,
                fontFamily: 'monospace',
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          InkWell(
            onTap: () => provider.setCodeContext(null),
            child: Icon(
              Icons.close,
              size: 18,
              color: colorScheme.onSecondaryContainer,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList(BuildContext context, ChatProvider provider) {
    final messages = provider.allMessages;

    if (messages.isEmpty) {
      _lastMessageCount = 0;
      return _buildEmptyState(context);
    }

    if (messages.length != _lastMessageCount) {
      _lastMessageCount = messages.length;
      _scrollToBottom();
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final msg = messages[index];
        final nextMsg = index + 1 < messages.length
            ? messages[index + 1]
            : null;
        return ChatBubble(
          message: msg,
          nextMessage: nextMsg,
          sessionId: provider.conversationId,
          onFileTap: (filePath) {
            final editorProvider = context.read<EditorProvider>();
            editorProvider.openFile(filePath).then((_) {
              if (context.mounted) {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ChangeNotifierProvider.value(
                      value: editorProvider,
                      child: const CodeScreen(),
                    ),
                  ),
                );
              }
            });
          },
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_awesome,
              size: 48,
              color: colorScheme.primary.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              'Start a conversation',
              style: theme.textTheme.titleMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Ask Claude about your code, get help with editing, '
              'debugging, and more.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBar(BuildContext context, ChatProvider provider) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      padding: EdgeInsets.only(
        left: 12,
        right: 8,
        top: 8,
        bottom: MediaQuery.of(context).padding.bottom + 8,
      ),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              decoration: InputDecoration(
                hintText: 'Message Claude...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: colorScheme.surfaceContainerHighest,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                isDense: true,
              ),
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _sendMessage(provider),
              maxLines: 5,
              minLines: 1,
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: provider.isStreaming
                ? Icon(Icons.stop_circle, color: colorScheme.error)
                : Icon(Icons.send, color: colorScheme.primary),
            onPressed: provider.isStreaming
                ? () => provider.stopStreaming()
                : () => _sendMessage(provider),
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          ),
        ],
      ),
    );
  }
}
