import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/file_provider.dart';

class FileTreeView extends StatelessWidget {
  final void Function(String path, String name) onFileTap;

  const FileTreeView({super.key, required this.onFileTap});

  @override
  Widget build(BuildContext context) {
    return Consumer<FileProvider>(
      builder: (context, fileProvider, child) {
        if (fileProvider.isLoading && fileProvider.rootNodes.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }

        if (fileProvider.error != null && fileProvider.rootNodes.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 48,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  'Failed to load files',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  fileProvider.error!,
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton.tonal(
                  onPressed: () => fileProvider.refresh(),
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        }

        if (fileProvider.rootNodes.isEmpty) {
          return const Center(child: Text('No files found'));
        }

        return RefreshIndicator(
          onRefresh: () => fileProvider.refresh(),
          child: ListView.builder(
            itemCount: _countVisibleNodes(fileProvider.rootNodes),
            itemBuilder: (context, index) {
              final (node, depth) = _getNodeAtIndex(
                fileProvider.rootNodes,
                index,
                0,
              );
              if (node == null) return const SizedBox.shrink();
              return _FileTreeItem(
                node: node,
                depth: depth,
                onTap: () => _handleTap(context, node),
                onFileTap: onFileTap,
              );
            },
          ),
        );
      },
    );
  }

  void _handleTap(BuildContext context, FileTreeNode node) {
    if (node.entry.isDir) {
      context.read<FileProvider>().toggleExpand(node);
    } else {
      onFileTap(node.path, node.entry.name);
    }
  }

  int _countVisibleNodes(List<FileTreeNode> nodes) {
    int count = 0;
    for (final node in nodes) {
      count++;
      if (node.isExpanded && node.children != null) {
        count += _countVisibleNodes(node.children!);
      }
    }
    return count;
  }

  (FileTreeNode?, int) _getNodeAtIndex(
    List<FileTreeNode> nodes,
    int targetIndex,
    int depth,
  ) {
    int currentIndex = 0;
    for (final node in nodes) {
      if (currentIndex == targetIndex) return (node, depth);
      currentIndex++;
      if (node.isExpanded && node.children != null) {
        final childCount = _countVisibleNodes(node.children!);
        if (targetIndex < currentIndex + childCount) {
          return _getNodeAtIndex(
            node.children!,
            targetIndex - currentIndex,
            depth + 1,
          );
        }
        currentIndex += childCount;
      }
    }
    return (null, depth);
  }
}

class _FileTreeItem extends StatelessWidget {
  final FileTreeNode node;
  final int depth;
  final VoidCallback onTap;
  final void Function(String path, String name) onFileTap;

  const _FileTreeItem({
    required this.node,
    required this.depth,
    required this.onTap,
    required this.onFileTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: EdgeInsets.only(left: 16.0 * depth + 8, right: 8),
          child: Row(
            children: [
              if (node.entry.isDir)
                Icon(
                  node.isExpanded
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_right,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                )
              else
                const SizedBox(width: 20),
              const SizedBox(width: 4),
              _getFileIcon(node.entry.name, node.entry.isDir, theme),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  node.entry.name,
                  style: theme.textTheme.bodyMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (node.isLoading)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _getFileIcon(String name, bool isDir, ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    if (isDir) {
      return Icon(
        Icons.folder,
        size: 20,
        color: isDark ? Colors.amber.shade400 : Colors.amber.shade700,
      );
    }

    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';

    switch (ext) {
      case 'dart':
        return Icon(Icons.code, size: 20, color: isDark ? Colors.blue.shade300 : Colors.blue.shade600);
      case 'go':
        return Icon(Icons.code, size: 20, color: isDark ? Colors.cyan.shade300 : Colors.cyan.shade600);
      case 'ts':
      case 'tsx':
      case 'js':
      case 'jsx':
        return Icon(Icons.javascript, size: 20, color: isDark ? Colors.yellow.shade600 : Colors.yellow.shade800);
      case 'json':
        return Icon(Icons.data_object, size: 20, color: isDark ? Colors.orange.shade300 : Colors.orange.shade600);
      case 'md':
      case 'txt':
        return Icon(
          Icons.description,
          size: 20,
          color: theme.colorScheme.onSurfaceVariant,
        );
      case 'yaml':
      case 'yml':
        return Icon(
          Icons.settings,
          size: 20,
          color: theme.colorScheme.onSurfaceVariant,
        );
      default:
        return Icon(
          Icons.insert_drive_file,
          size: 20,
          color: theme.colorScheme.onSurfaceVariant,
        );
    }
  }
}
