import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/chat_provider.dart';
import 'chat_bubble.dart';

/// Draggable bottom sheet chat panel for contextual AI chat (REQ-009).
///
/// Shows when user selects code and taps "Ask AI". Displays a context badge,
/// message input, streaming responses, and an expand button to open full Chat tab.
class ContextualChat extends StatefulWidget {
  /// Callback to expand to the full Chat tab (tab index 2).
  final VoidCallback? onExpandToFullChat;

  const ContextualChat({super.key, this.onExpandToFullChat});

  @override
  State<ContextualChat> createState() => _ContextualChatState();
}

class _ContextualChatState extends State<ContextualChat> {
  final _controller = TextEditingController();
  ScrollController? _activeScrollController;
  int _lastMessageCount = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _sendMessage(ChatProvider provider) {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    // Start a conversation if none is active, queuing the message
    // so it's sent after the server confirms the session.
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
      final controller = _activeScrollController;
      if (controller != null && controller.hasClients) {
        controller.animateTo(
          controller.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.4,
      minChildSize: 0.15,
      maxChildSize: 0.85,
      builder: (context, sheetScrollController) {
        return Consumer<ChatProvider>(
          builder: (context, provider, _) {
            return Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(16),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.15),
                    blurRadius: 10,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: Column(
                children: [
                  _buildHandle(context),
                  _buildHeader(context, provider),
                  if (provider.codeContext != null)
                    _buildContextBadge(context, provider),
                  Expanded(
                    child: _buildMessageList(provider, sheetScrollController),
                  ),
                  _buildInputBar(context, provider),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildHandle(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      width: 32,
      height: 4,
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, ChatProvider provider) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.auto_awesome, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            'Ask AI',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          if (widget.onExpandToFullChat != null)
            IconButton(
              icon: const Icon(Icons.open_in_full, size: 20),
              tooltip: 'Open full chat',
              onPressed: widget.onExpandToFullChat,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            ),
        ],
      ),
    );
  }

  Widget _buildContextBadge(BuildContext context, ChatProvider provider) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final ctx = provider.codeContext!;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.code, size: 16, color: colorScheme.onSecondaryContainer),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              ctx.label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: colorScheme.onSecondaryContainer,
                fontFamily: 'monospace',
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          InkWell(
            onTap: () => provider.setCodeContext(null),
            child: Icon(
              Icons.close,
              size: 16,
              color: colorScheme.onSecondaryContainer,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList(
    ChatProvider provider,
    ScrollController sheetScrollController,
  ) {
    _activeScrollController = sheetScrollController;
    final messages = provider.allMessages;

    if (messages.isEmpty && !provider.isStreaming) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Ask a question about the selected code',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    // Auto-scroll only when new messages arrive
    if (messages.length != _lastMessageCount) {
      _lastMessageCount = messages.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom();
      });
    }

    return ListView.builder(
      controller: sheetScrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final msg = messages[index];
        final nextMsg = index + 1 < messages.length
            ? messages[index + 1]
            : null;
        return ChatBubble(message: msg, nextMessage: nextMsg);
      },
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
          // Placeholder attach button
          IconButton(
            icon: const Icon(Icons.attach_file, size: 22),
            tooltip: 'Add more context',
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Add context - coming soon'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          ),
          Expanded(
            child: TextField(
              controller: _controller,
              decoration: InputDecoration(
                hintText: 'Ask about this code...',
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
              maxLines: 3,
              minLines: 1,
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: provider.isStreaming
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colorScheme.primary,
                    ),
                  )
                : Icon(Icons.send, color: colorScheme.primary),
            onPressed: provider.isStreaming
                ? null
                : () => _sendMessage(provider),
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          ),
        ],
      ),
    );
  }
}
