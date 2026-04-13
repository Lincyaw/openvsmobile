import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/chat_message.dart';
import '../providers/chat_provider.dart';
import 'chat_bubble.dart';

/// Expandable card showing a subagent invocation with type badge,
/// description, and full sub-conversation when expanded.
class SubagentCard extends StatefulWidget {
  final ContentBlock toolUse;
  final ContentBlock? toolResult;
  final String? sessionId;

  const SubagentCard({
    super.key,
    required this.toolUse,
    this.toolResult,
    this.sessionId,
  });

  @override
  State<SubagentCard> createState() => _SubagentCardState();
}

class _SubagentCardState extends State<SubagentCard> {
  bool _expanded = false;
  List<ChatMessage>? _messages;
  Map<String, dynamic>? _meta;
  bool _loading = false;
  String? _error;

  String get _agentId {
    // Extract agentId from tool_result content.
    final result = widget.toolResult;
    if (result == null) return '';
    final content = result.resultContent;
    if (content is String) {
      final match = RegExp(r'agentId:\s*(\S+)').firstMatch(content);
      return match?.group(1) ?? '';
    }
    if (content is List) {
      for (final item in content) {
        if (item is Map<String, dynamic>) {
          final text = item['text'] as String? ?? '';
          final match = RegExp(r'agentId:\s*(\S+)').firstMatch(text);
          if (match != null) return match.group(1) ?? '';
        }
      }
    }
    return '';
  }

  String get _description {
    final input = widget.toolUse.input;
    if (input == null) return 'Sub-agent task';
    return input['description'] as String? ??
        input['prompt'] as String? ??
        'Sub-agent task';
  }

  String get _agentType {
    return _meta?['agentType'] as String? ?? 'agent';
  }

  Future<void> _loadSubagentData() async {
    final agentId = _agentId;
    final sessionId = widget.sessionId;
    if (agentId.isEmpty || sessionId == null) {
      setState(() => _error = 'No agent ID available');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final provider = context.read<ChatProvider>();
      final results = await Future.wait([
        provider.loadSubagentMessages(sessionId, agentId),
        provider.loadSubagentMeta(sessionId, agentId).catchError((_) => <String, dynamic>{}),
      ]);
      if (mounted) {
        setState(() {
          _messages = results[0] as List<ChatMessage>;
          _meta = results[1] as Map<String, dynamic>;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (_expanded && _messages == null && !_loading) {
      _loadSubagentData();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.teal.withValues(alpha: 0.3)),
        color: colorScheme.surfaceContainerLow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(theme, colorScheme),
          if (_expanded) _buildBody(theme, colorScheme),
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, ColorScheme colorScheme) {
    return InkWell(
      onTap: _toggle,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.teal.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Icon(Icons.smart_toy_outlined,
                  size: 18, color: Colors.teal),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Agent',
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.teal.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _expanded ? _agentType : 'agent',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: Colors.teal,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(
              _expanded ? Icons.expand_less : Icons.expand_more,
              color: colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme, ColorScheme colorScheme) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          _error!,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.error,
          ),
        ),
      );
    }

    final messages = _messages;
    if (messages == null || messages.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          'No messages',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: colorScheme.outlineVariant),
        ),
      ),
      constraints: const BoxConstraints(maxHeight: 400),
      child: ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: messages.length,
        itemBuilder: (context, index) {
          final msg = messages[index];
          final nextMsg =
              index + 1 < messages.length ? messages[index + 1] : null;
          return ChatBubble(message: msg, nextMessage: nextMsg);
        },
      ),
    );
  }
}
