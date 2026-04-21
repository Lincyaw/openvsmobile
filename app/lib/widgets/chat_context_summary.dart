import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/chat_context_attachment.dart';
import '../models/editor_context.dart';
import '../providers/editor_provider.dart';
import '../providers/workspace_provider.dart';

class ChatContextSummary extends StatelessWidget {
  final EditorChatContext? editorContext;
  final ChatContextAttachment? attachment;
  final EdgeInsetsGeometry margin;
  final VoidCallback? onClearAttachment;

  const ChatContextSummary({
    super.key,
    required this.editorContext,
    required this.attachment,
    this.margin = const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    this.onClearAttachment,
  });

  @override
  Widget build(BuildContext context) {
    final hasEditorContext = editorContext?.hasContext ?? false;
    final hasPendingGitHubAttachment =
        attachment?.source == ChatContextAttachmentSource.github;

    if (!hasEditorContext && attachment == null) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final workspace = context.read<WorkspaceProvider>();
    final ctx = editorContext;
    final fileName = (ctx?.activeFile ?? '').split('/').last;
    final selectionLabel = ctx?.selection?.lineLabel ?? 'No selection';

    return Container(
      margin: margin,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: DefaultTextStyle(
        style: theme.textTheme.labelMedium!.copyWith(
          color: colorScheme.onSecondaryContainer,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hasEditorContext)
              _SummarySection(
                icon: Icons.code,
                title: 'Editor context',
                trailing: ctx?.selection != null
                    ? InkWell(
                        onTap: () =>
                            context.read<EditorProvider>().clearSelection(),
                        child: Icon(
                          Icons.close,
                          size: 16,
                          color: colorScheme.onSecondaryContainer,
                        ),
                      )
                    : null,
                lines: <String>[
                  'Workspace: ${workspace.displayName}',
                  'File: $fileName',
                  'Selection: $selectionLabel',
                ],
              ),
            if (hasEditorContext && hasPendingGitHubAttachment)
              Divider(
                height: 16,
                color: colorScheme.onSecondaryContainer.withValues(alpha: 0.18),
              ),
            if (attachment != null)
              _SummarySection(
                icon: Icons.smart_toy_outlined,
                title: 'GitHub attachment',
                trailing: onClearAttachment == null
                    ? null
                    : InkWell(
                        onTap: onClearAttachment,
                        child: Icon(
                          Icons.close,
                          size: 16,
                          color: colorScheme.onSecondaryContainer,
                        ),
                      ),
                lines: <String>[
                  attachment!.actionLabel,
                  '${attachment!.kindLabel}: ${attachment!.title}',
                  ...attachment!.previewDetails,
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _SummarySection extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<String> lines;
  final Widget? trailing;

  const _SummarySection({
    required this.icon,
    required this.title,
    required this.lines,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: colorScheme.onSecondaryContainer),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: colorScheme.onSecondaryContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              ...lines.map(
                (line) =>
                    Text(line, overflow: TextOverflow.ellipsis, maxLines: 2),
              ),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    );
  }
}
