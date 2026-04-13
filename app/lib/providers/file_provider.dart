import 'package:flutter/foundation.dart';
import '../models/file_entry.dart';
import '../services/api_client.dart';

/// Represents a node in the file tree with its expanded state and children.
class FileTreeNode {
  final String path;
  final FileEntry entry;
  bool isExpanded;
  bool isLoading;
  List<FileTreeNode>? children;

  FileTreeNode({
    required this.path,
    required this.entry,
    this.isExpanded = false,
    this.isLoading = false,
    this.children,
  });
}

class FileProvider extends ChangeNotifier {
  final ApiClient apiClient;

  String _currentProject = '/';
  List<FileTreeNode> _rootNodes = [];
  bool _isLoading = false;
  String? _error;

  FileProvider({required this.apiClient});

  String get currentProject => _currentProject;
  List<FileTreeNode> get rootNodes => _rootNodes;
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// Set the current project/workspace root and load its contents.
  Future<void> setProject(String projectPath) async {
    _currentProject = projectPath;
    _rootNodes = [];
    notifyListeners();
    await loadDirectory(projectPath);
  }

  /// Load the root directory.
  Future<void> loadDirectory(String path) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final entries = await apiClient.listDirectory(path);
      _rootNodes = _sortEntries(entries)
          .map((e) => FileTreeNode(path: _joinPath(path, e.name), entry: e))
          .toList();
      _error = null;
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Toggle expansion of a directory node, loading children if needed.
  Future<void> toggleExpand(FileTreeNode node) async {
    if (!node.entry.isDir) return;

    if (node.isExpanded) {
      node.isExpanded = false;
      notifyListeners();
      return;
    }

    node.isExpanded = true;

    if (node.children == null) {
      node.isLoading = true;
      notifyListeners();

      try {
        final entries = await apiClient.listDirectory(node.path);
        node.children = _sortEntries(entries)
            .map(
              (e) => FileTreeNode(path: _joinPath(node.path, e.name), entry: e),
            )
            .toList();
      } catch (e) {
        node.children = [];
        _error = e.toString();
      } finally {
        node.isLoading = false;
        notifyListeners();
      }
    } else {
      notifyListeners();
    }
  }

  /// Refresh a specific directory node.
  Future<void> refreshNode(FileTreeNode node) async {
    if (!node.entry.isDir) return;
    node.children = null;
    node.isExpanded = false;
    notifyListeners();
    await toggleExpand(node);
  }

  /// Create a new empty file under [parentPath] with [name].
  Future<void> createFile(String parentPath, String name) async {
    final filePath = _joinPath(parentPath, name);
    await apiClient.writeFile(filePath, '');
    await _refreshParent(parentPath);
  }

  /// Create a new directory under [parentPath] with [name].
  Future<void> createDirectory(String parentPath, String name) async {
    final dirPath = _joinPath(parentPath, name);
    await apiClient.createDirectory(dirPath);
    await _refreshParent(parentPath);
  }

  /// Delete a file or directory at [path].
  Future<void> deleteEntry(String path) async {
    await apiClient.deleteFile(path);
    final parentPath = path.contains('/')
        ? path.substring(0, path.lastIndexOf('/'))
        : '/';
    final normalizedParent = parentPath.isEmpty ? '/' : parentPath;
    await _refreshParent(normalizedParent);
  }

  /// Refresh the parent directory after a create/delete operation.
  Future<void> _refreshParent(String parentPath) async {
    // If the parent is the root project, refresh root nodes.
    if (parentPath == _currentProject) {
      await loadDirectory(_currentProject);
      return;
    }
    // Find the node matching parentPath and refresh it.
    final node = _findNode(_rootNodes, parentPath);
    if (node != null) {
      await refreshNode(node);
    } else {
      // Fallback: refresh root.
      await loadDirectory(_currentProject);
    }
  }

  /// Find a node by path in the tree.
  FileTreeNode? _findNode(List<FileTreeNode> nodes, String path) {
    for (final node in nodes) {
      if (node.path == path) return node;
      if (node.children != null) {
        final found = _findNode(node.children!, path);
        if (found != null) return found;
      }
    }
    return null;
  }

  /// Refresh the root.
  Future<void> refresh() async {
    await loadDirectory(_currentProject);
  }

  /// Sort entries: directories first, then alphabetically.
  List<FileEntry> _sortEntries(List<FileEntry> entries) {
    final sorted = List<FileEntry>.from(entries);
    sorted.sort((a, b) {
      if (a.isDir && !b.isDir) return -1;
      if (!a.isDir && b.isDir) return 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return sorted;
  }

  String _joinPath(String parent, String child) {
    if (parent.endsWith('/')) return '$parent$child';
    return '$parent/$child';
  }
}
