import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/chat_provider.dart';
import '../providers/file_provider.dart';
import '../providers/git_provider.dart';
import '../providers/editor_provider.dart';
import '../providers/workspace_provider.dart';
import '../widgets/file_tree_view.dart';
import 'code_screen.dart';

class FilesScreen extends StatelessWidget {
  const FilesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Consumer<WorkspaceProvider>(
          builder: (context, ws, _) {
            return GestureDetector(
              onTap: () => _showWorkspacePicker(context),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      ws.displayName,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.arrow_drop_down, size: 20),
                ],
              ),
            );
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () {
              context.read<FileProvider>().refresh();
            },
          ),
        ],
      ),
      body: FileTreeView(
        onFileTap: (path, name) {
          final editorProvider = context.read<EditorProvider>();
          editorProvider.openFile(path).then((_) {
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
        onCreateFile: (parentPath, name) =>
            _handleCreateFile(context, parentPath, name),
        onCreateDirectory: (parentPath, name) =>
            _handleCreateDirectory(context, parentPath, name),
        onDelete: (path) => _handleDelete(context, path),
      ),
      floatingActionButton: _RootActionButton(),
    );
  }

  void _handleCreateFile(
    BuildContext context,
    String parentPath,
    String name,
  ) async {
    try {
      await context.read<FileProvider>().createFile(parentPath, name);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Created file: $name')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to create file: $e')));
      }
    }
  }

  void _handleCreateDirectory(
    BuildContext context,
    String parentPath,
    String name,
  ) async {
    try {
      await context.read<FileProvider>().createDirectory(parentPath, name);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Created folder: $name')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to create folder: $e')));
      }
    }
  }

  void _handleDelete(BuildContext context, String path) async {
    try {
      await context.read<FileProvider>().deleteEntry(path);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Deleted successfully')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to delete: $e')));
      }
    }
  }

  void _showWorkspacePicker(BuildContext context) {
    final ws = context.read<WorkspaceProvider>();
    final controller = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.8,
          expand: false,
          builder: (_, scrollController) {
            return ListenableBuilder(
              listenable: ws,
              builder: (listCtx, _) {
                final recent = ws.recentWorkspaces;
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Switch Workspace',
                        style: Theme.of(listCtx).textTheme.titleMedium,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                        controller: controller,
                        decoration: InputDecoration(
                          hintText: 'Enter directory path...',
                          prefixIcon: const Icon(Icons.folder_open),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.arrow_forward),
                            onPressed: () {
                              final path = controller.text.trim();
                              if (path.isNotEmpty) {
                                _switchWorkspace(context, path);
                                Navigator.pop(sheetContext);
                              }
                            },
                          ),
                        ),
                        onSubmitted: (path) {
                          if (path.trim().isNotEmpty) {
                            _switchWorkspace(context, path.trim());
                            Navigator.pop(sheetContext);
                          }
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Recent',
                          style: Theme.of(listCtx).textTheme.labelLarge
                              ?.copyWith(
                                color:
                                    Theme.of(listCtx).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        controller: scrollController,
                        itemCount: recent.length,
                        itemBuilder: (_, index) {
                          final path = recent[index];
                          final isCurrent = path == ws.currentPath;
                          final name = WorkspaceProvider.nameForPath(path);
                          final colorScheme = Theme.of(listCtx).colorScheme;
                          return ListTile(
                            leading: Icon(
                              Icons.folder,
                              color: isCurrent ? colorScheme.primary : null,
                            ),
                            title: Text(
                              name,
                              style: isCurrent
                                  ? TextStyle(
                                      color: colorScheme.primary,
                                      fontWeight: FontWeight.bold,
                                    )
                                  : null,
                            ),
                            subtitle: Text(
                              path,
                              style: Theme.of(listCtx).textTheme.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: isCurrent
                                ? const Icon(Icons.check, size: 20)
                                : IconButton(
                                    icon: const Icon(Icons.close, size: 18),
                                    onPressed: () => ws.removeFromRecent(path),
                                  ),
                            onTap: () {
                              _switchWorkspace(context, path);
                              Navigator.pop(sheetContext);
                            },
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  void _switchWorkspace(BuildContext context, String path) {
    final ws = context.read<WorkspaceProvider>();
    ws.setWorkspace(path);
    context.read<FileProvider>().setProject(path);
    context.read<ChatProvider>().setWorkspace(path);
    context.read<GitProvider>().setWorkDir(path);
  }
}

class _RootActionButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return FloatingActionButton(
      onPressed: () => _showRootMenu(context),
      child: const Icon(Icons.add),
    );
  }

  void _showRootMenu(BuildContext context) {
    final fileProvider = context.read<FileProvider>();
    final rootPath = fileProvider.currentProject;

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
                  'Create at root',
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
              ),
              ListTile(
                leading: const Icon(Icons.note_add),
                title: const Text('New File'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showNameDialog(context, 'New File', (name) {
                    _createFile(context, rootPath, name);
                  });
                },
              ),
              ListTile(
                leading: const Icon(Icons.create_new_folder),
                title: const Text('New Folder'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showNameDialog(context, 'New Folder', (name) {
                    _createDirectory(context, rootPath, name);
                  });
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

  void _createFile(BuildContext context, String parentPath, String name) async {
    try {
      await context.read<FileProvider>().createFile(parentPath, name);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Created file: $name')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to create file: $e')));
      }
    }
  }

  void _createDirectory(
    BuildContext context,
    String parentPath,
    String name,
  ) async {
    try {
      await context.read<FileProvider>().createDirectory(parentPath, name);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Created folder: $name')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to create folder: $e')));
      }
    }
  }
}
