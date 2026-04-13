import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/file_provider.dart';

class FileTreeView extends StatelessWidget {
  final void Function(String path, String name) onFileTap;
  final void Function(String parentPath, String name)? onCreateFile;
  final void Function(String parentPath, String name)? onCreateDirectory;
  final void Function(String path)? onDelete;

  const FileTreeView({
    super.key,
    required this.onFileTap,
    this.onCreateFile,
    this.onCreateDirectory,
    this.onDelete,
  });

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
                onLongPress: () => _showContextMenu(context, node),
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

  void _showContextMenu(BuildContext context, FileTreeNode node) {
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  node.entry.name,
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (node.entry.isDir) ...[
                ListTile(
                  leading: const Icon(Icons.note_add),
                  title: const Text('New File'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showNameDialog(context, 'New File', (name) {
                      onCreateFile?.call(node.path, name);
                    });
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.create_new_folder),
                  title: const Text('New Folder'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showNameDialog(context, 'New Folder', (name) {
                      onCreateDirectory?.call(node.path, name);
                    });
                  },
                ),
              ],
              ListTile(
                leading: const Icon(Icons.content_copy),
                title: const Text('Copy Path'),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: node.path));
                  Navigator.pop(sheetContext);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Path copied to clipboard')),
                  );
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.delete,
                  color: Theme.of(sheetContext).colorScheme.error,
                ),
                title: Text(
                  'Delete',
                  style: TextStyle(
                    color: Theme.of(sheetContext).colorScheme.error,
                  ),
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showDeleteConfirmation(context, node);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showNameDialog(
    BuildContext context,
    String title,
    void Function(String name) onConfirm,
  ) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'Enter name',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (value) {
              if (value.trim().isNotEmpty) {
                Navigator.pop(dialogContext);
                onConfirm(value.trim());
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final name = controller.text.trim();
                if (name.isNotEmpty) {
                  Navigator.pop(dialogContext);
                  onConfirm(name);
                }
              },
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
  }

  void _showDeleteConfirmation(BuildContext context, FileTreeNode node) {
    final typeLabel = node.entry.isDir ? 'folder' : 'file';
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Confirm Delete'),
          content: Text(
            'Are you sure you want to delete the $typeLabel "${node.entry.name}"?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(dialogContext).colorScheme.error,
              ),
              onPressed: () {
                Navigator.pop(dialogContext);
                onDelete?.call(node.path);
              },
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
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
  final VoidCallback onLongPress;
  final void Function(String path, String name) onFileTap;

  const _FileTreeItem({
    required this.node,
    required this.depth,
    required this.onTap,
    required this.onLongPress,
    required this.onFileTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
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
        return Icon(
          Icons.code,
          size: 20,
          color: isDark ? Colors.blue.shade300 : Colors.blue.shade600,
        );
      case 'go':
        return Icon(
          Icons.code,
          size: 20,
          color: isDark ? Colors.cyan.shade300 : Colors.cyan.shade600,
        );
      case 'ts':
      case 'tsx':
      case 'js':
      case 'jsx':
        return Icon(
          Icons.javascript,
          size: 20,
          color: isDark ? Colors.yellow.shade600 : Colors.yellow.shade800,
        );
      case 'json':
        return Icon(
          Icons.data_object,
          size: 20,
          color: isDark ? Colors.orange.shade300 : Colors.orange.shade600,
        );
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
