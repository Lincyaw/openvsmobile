import 'package:flutter/material.dart';

import '../models/chat_message.dart';

/// Card widget for displaying tool invocations (Edit, Write, Bash, Read, Agent).
class ToolUseCard extends StatefulWidget {
  final ContentBlock toolUse;
  final ContentBlock? toolResult;

  /// Callback when a file path is tapped (for navigation to code viewer).
  final void Function(String filePath)? onFileTap;

  const ToolUseCard({
    super.key,
    required this.toolUse,
    this.toolResult,
    this.onFileTap,
  });

  @override
  State<ToolUseCard> createState() => _ToolUseCardState();
}

class _ToolUseCardState extends State<ToolUseCard> {
  bool _resultExpanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final toolName = widget.toolUse.name ?? 'Unknown';
    final annotation = widget.toolUse.fileAnnotation;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colorScheme.outlineVariant),
        color: colorScheme.surfaceContainerLow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(theme, colorScheme, toolName, annotation),
          if (widget.toolResult != null) _buildResult(theme, colorScheme),
        ],
      ),
    );
  }

  Widget _buildHeader(
    ThemeData theme,
    ColorScheme colorScheme,
    String toolName,
    FileAnnotation? annotation,
  ) {
    final IconData icon;
    final String subtitle;
    final Color iconColor;
    final filePath = widget.toolUse.effectiveFilePath;
    final command = widget.toolUse.effectiveCommand;

    switch (toolName) {
      case 'Edit':
        icon = Icons.edit_outlined;
        iconColor = Colors.orange;
        subtitle = filePath ?? 'Edit file';
        break;
      case 'Write':
        icon = Icons.create_new_folder_outlined;
        iconColor = Colors.green;
        subtitle = filePath != null ? 'Created: $filePath' : 'Write file';
        break;
      case 'Bash':
        icon = Icons.terminal;
        iconColor = Colors.blue;
        subtitle = command ?? 'Run command';
        break;
      case 'Read':
        icon = Icons.description_outlined;
        iconColor = Colors.purple;
        subtitle = filePath != null ? 'Read: $filePath' : 'Read file';
        break;
      case 'Grep':
      case 'Glob':
        icon = Icons.search;
        iconColor = Colors.indigo;
        subtitle = filePath ?? widget.toolUse.input?['pattern'] as String? ?? 'Search';
        break;
      case 'Agent':
        icon = Icons.smart_toy_outlined;
        iconColor = Colors.teal;
        subtitle = _getAgentDescription();
        break;
      default:
        icon = Icons.build_outlined;
        iconColor = colorScheme.primary;
        subtitle = toolName;
    }

    return InkWell(
      onTap: () {
        if (filePath != null && widget.onFileTap != null) {
          widget.onFileTap!(filePath);
        }
      },
      borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(icon, size: 18, color: iconColor),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    toolName,
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontFamily: toolName == 'Bash' ? 'monospace' : null,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (filePath != null && widget.onFileTap != null)
              Icon(
                Icons.chevron_right,
                size: 18,
                color: colorScheme.onSurfaceVariant,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildResult(ThemeData theme, ColorScheme colorScheme) {
    final result = widget.toolResult!;
    final isError = result.isError ?? false;
    final resultText = _extractResultText(result);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(height: 1, color: colorScheme.outlineVariant),
        InkWell(
          onTap: () => setState(() => _resultExpanded = !_resultExpanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(
                  isError ? Icons.error_outline : Icons.check_circle_outline,
                  size: 16,
                  color: isError ? colorScheme.error : Colors.green,
                ),
                const SizedBox(width: 6),
                Text(
                  isError ? 'Error' : 'Success',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: isError ? colorScheme.error : Colors.green,
                  ),
                ),
                const Spacer(),
                if (resultText.isNotEmpty)
                  Icon(
                    _resultExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: colorScheme.onSurfaceVariant,
                  ),
              ],
            ),
          ),
        ),
        if (_resultExpanded && resultText.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Text(
              resultText,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                fontSize: 11,
                color: colorScheme.onSurfaceVariant,
              ),
              maxLines: 50,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }

  String _getAgentDescription() {
    final input = widget.toolUse.input;
    if (input == null) return 'Sub-agent';
    final prompt = input['prompt'] as String?;
    if (prompt != null && prompt.length > 80) {
      return prompt.substring(0, 80);
    }
    return prompt ?? 'Sub-agent task';
  }

  String _extractResultText(ContentBlock result) {
    final content = result.resultContent;
    if (content is String) return content;
    if (content is List) {
      return content
          .map((item) {
            if (item is Map<String, dynamic>) {
              return item['text'] as String? ?? '';
            }
            return item.toString();
          })
          .join('\n');
    }
    return '';
  }
}
