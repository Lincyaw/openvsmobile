import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/chat_provider.dart';
import '../providers/file_provider.dart';
import '../providers/git_provider.dart';
import '../providers/editor_provider.dart';
import '../providers/workspace_provider.dart';
import '../providers/search_provider.dart';
import '../widgets/file_tree_view.dart';
import '../widgets/app_bar_menu.dart';
import 'code_screen.dart';

class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key});

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onSearch(String query) {
    final provider = context.read<SearchProvider>();
    final rootPath = context.read<WorkspaceProvider>().currentPath;
    if (provider.searchMode == SearchMode.fileContent) {
      provider.searchContent(query, rootPath);
    } else {
      provider.search(query, rootPath);
    }
  }

  void _onResultTap(String path, String name) {
    final editorProvider = context.read<EditorProvider>();
    editorProvider.openFile(path).then((_) {
      if (mounted) {
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
  }

  void _switchWorkspace(BuildContext context, String path) {
    final ws = context.read<WorkspaceProvider>();
    ws.setWorkspace(path);
    context.read<FileProvider>().setProject(path);
    context.read<ChatProvider>().setWorkspace(path);
    context.read<GitProvider>().setWorkDir(path);
    // Clear search when workspace changes.
    _searchController.clear();
    context.read<SearchProvider>().clearResults();
  }

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
          const AppBarMenu(),
        ],
      ),
      body: Column(
        children: [
          // Search controls
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Consumer<SearchProvider>(
              builder: (context, provider, _) {
                return SegmentedButton<SearchMode>(
                  segments: const [
                    ButtonSegment(
                      value: SearchMode.fileName,
                      label: Text('Files'),
                      icon: Icon(Icons.insert_drive_file),
                    ),
                    ButtonSegment(
                      value: SearchMode.fileContent,
                      label: Text('Content'),
                      icon: Icon(Icons.text_snippet),
                    ),
                  ],
                  selected: {provider.searchMode},
                  onSelectionChanged: (selected) {
                    provider.setSearchMode(selected.first);
                    if (_searchController.text.isNotEmpty) {
                      _onSearch(_searchController.text);
                    }
                  },
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Consumer<SearchProvider>(
              builder: (context, provider, _) {
                return TextField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  decoration: InputDecoration(
                    hintText: provider.searchMode == SearchMode.fileContent
                        ? 'Search in file contents...'
                        : 'Search files...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              context.read<SearchProvider>().clearResults();
                              setState(() {});
                            },
                          )
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    filled: true,
                  ),
                  onChanged: (value) {
                    setState(() {});
                    _debounce?.cancel();
                    _debounce = Timer(const Duration(milliseconds: 300), () {
                      _onSearch(value);
                    });
                  },
                  onSubmitted: _onSearch,
                  textInputAction: TextInputAction.search,
                );
              },
            ),
          ),
          // Content: file tree or search results
          Expanded(
            child: Consumer<SearchProvider>(
              builder: (context, provider, _) {
                if (provider.query.isNotEmpty) {
                  return _buildSearchResults(provider);
                }
                return FileTreeView(
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
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: _RootActionButton(),
    );
  }

  Widget _buildSearchResults(SearchProvider provider) {
    if (provider.isSearching) {
      return const Center(child: CircularProgressIndicator());
    }

    if (provider.error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(
              'Search failed',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              provider.error!,
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    if (provider.searchMode == SearchMode.fileContent) {
      if (provider.contentResults.isEmpty) {
        return _buildEmptyState(provider.query);
      }
      return ListView.builder(
        itemCount: provider.contentResults.length,
        itemBuilder: (context, index) {
          final result = provider.contentResults[index];
          final fileName = result.file.split('/').last;
          return ListTile(
            leading: const Icon(Icons.text_snippet),
            title: Text(
              '$fileName:${result.line}',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  result.file,
                  style: Theme.of(context).textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                _buildHighlightedLine(result.content, provider.query),
              ],
            ),
            isThreeLine: true,
            onTap: () => _onResultTap(result.file, fileName),
          );
        },
      );
    }

    if (provider.results.isEmpty) {
      return _buildEmptyState(provider.query);
    }
    return ListView.builder(
      itemCount: provider.results.length,
      itemBuilder: (context, index) {
        final result = provider.results[index];
        return ListTile(
          leading: Icon(
            result.isDirectory ? Icons.folder : Icons.insert_drive_file,
            color: result.isDirectory
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
          title: Text(result.name),
          subtitle: Text(
            result.path,
            style: Theme.of(context).textTheme.bodySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: result.isDirectory
              ? null
              : () => _onResultTap(result.path, result.name),
        );
      },
    );
  }

  Widget _buildHighlightedLine(String line, String query) {
    final lowerLine = line.toLowerCase();
    final lowerQuery = query.toLowerCase();
    final matchIndex = lowerLine.indexOf(lowerQuery);

    if (matchIndex == -1) {
      return Text(
        line.trim(),
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(fontFamily: 'monospace'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }

    final before = line.substring(0, matchIndex);
    final match = line.substring(matchIndex, matchIndex + query.length);
    final after = line.substring(matchIndex + query.length);

    return RichText(
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(fontFamily: 'monospace'),
        children: [
          TextSpan(text: before.trimLeft()),
          TextSpan(
            text: match,
            style: TextStyle(
              backgroundColor:
                  Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
              fontWeight: FontWeight.bold,
            ),
          ),
          TextSpan(text: after),
        ],
      ),
    );
  }

  Widget _buildEmptyState(String query) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.search_off,
            size: 64,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            'No results for "$query"',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
        ],
      ),
    );
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
                          style:
                              Theme.of(listCtx).textTheme.labelLarge?.copyWith(
                                    color: Theme.of(listCtx)
                                        .colorScheme
                                        .onSurfaceVariant,
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
