import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../models/chat_message.dart';
import 'subagent_card.dart';
import 'thinking_block.dart';
import 'tool_use_card.dart';

/// Message bubble widget with distinct styling for user vs assistant messages.
///
/// For assistant messages, iterates through content blocks and renders:
/// - text -> markdown
/// - thinking -> ThinkingBlock
/// - tool_use -> ToolUseCard (with matched tool_result if available)
class ChatBubble extends StatelessWidget {
  final ChatMessage message;

  /// The next message in the conversation (used to find tool_results
  /// for tool_use blocks in assistant messages).
  final ChatMessage? nextMessage;

  /// Callback when a file path in a tool card is tapped.
  final void Function(String filePath)? onFileTap;

  /// Session ID for loading subagent conversations.
  final String? sessionId;

  const ChatBubble({
    super.key,
    required this.message,
    this.nextMessage,
    this.onFileTap,
    this.sessionId,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    return isUser ? _buildUserBubble(context) : _buildAssistantBubble(context);
  }

  Widget _buildUserBubble(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final text = message.textContent;

    // Hide implicit tool-result carrier messages; they are rendered
    // inline inside the preceding assistant tool-use card.
    final isToolResultOnly = message.content.isNotEmpty &&
        message.content.every((b) => b.type == 'tool_result');
    if (isToolResultOnly) {
      return const SizedBox.shrink();
    }

    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.85,
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
              bottomLeft: Radius.circular(16),
              bottomRight: Radius.circular(4),
            ),
          ),
          child: Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onPrimaryContainer,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAssistantBubble(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // Build a map of tool_use_id -> tool_result from the next message
    final toolResults = <String, ContentBlock>{};
    if (nextMessage != null && nextMessage!.role == 'user') {
      for (final block in nextMessage!.content) {
        if (block.type == 'tool_result' && block.toolUseId != null) {
          toolResults[block.toolUseId!] = block;
        }
      }
    }

    final contentWidgets = _buildContentBlocks(theme, colorScheme, toolResults);
    if (contentWidgets.isEmpty) {
      return const SizedBox.shrink();
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.85,
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
              bottomLeft: Radius.circular(4),
              bottomRight: Radius.circular(16),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: contentWidgets,
          ),
        ),
      ),
    );
  }

  List<Widget> _buildContentBlocks(
    ThemeData theme,
    ColorScheme colorScheme,
    Map<String, ContentBlock> toolResults,
  ) {
    final widgets = <Widget>[];

    for (final block in message.content) {
      switch (block.type) {
        case 'text':
          if (block.text != null && block.text!.isNotEmpty) {
            widgets.add(
              MarkdownBody(
                data: block.text!,
                selectable: true,
                styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                  p: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurface,
                  ),
                  code: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    backgroundColor: colorScheme.surfaceContainerLow,
                  ),
                  codeblockDecoration: BoxDecoration(
                    color: colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            );
          }
          break;

        case 'thinking':
          if (block.thinking != null) {
            widgets.add(ThinkingBlock(thinkingContent: block.thinking!));
          }
          break;

        case 'tool_use':
          final matchedResult = block.id != null ? toolResults[block.id] : null;
          if (block.name == 'Agent') {
            widgets.add(
              SubagentCard(
                toolUse: block,
                toolResult: matchedResult,
                sessionId: sessionId,
                onFileTap: onFileTap,
              ),
            );
          } else {
            widgets.add(
              ToolUseCard(
                toolUse: block,
                toolResult: matchedResult,
                onFileTap: onFileTap,
              ),
            );
          }
          break;
      }
    }

    return widgets;
  }
}
