import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Manages the current workspace (project root directory).
/// All file browsing, search, and terminal operations are scoped to this path.
class WorkspaceProvider extends ChangeNotifier {
  static const _keyWorkspacePath = 'workspace_path';
  static const _keyRecentWorkspaces = 'recent_workspaces';
  static const String defaultWorkspace = '/home';

  String _currentPath = defaultWorkspace;
  List<String> _recentWorkspaces = [];

  String get currentPath => _currentPath;
  List<String> get recentWorkspaces => List.unmodifiable(_recentWorkspaces);

  /// Load persisted workspace from SharedPreferences.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _currentPath = prefs.getString(_keyWorkspacePath) ?? defaultWorkspace;
    _recentWorkspaces =
        prefs.getStringList(_keyRecentWorkspaces) ?? [defaultWorkspace];
    notifyListeners();
  }

  /// Switch to a new workspace path and persist the choice.
  Future<void> setWorkspace(String path) async {
    if (path == _currentPath) return;
    _currentPath = path;
    _addToRecent(path);
    notifyListeners();
    await _persist();
  }

  /// Add a workspace to the recent list (max 10, no duplicates).
  void _addToRecent(String path) {
    _recentWorkspaces.remove(path);
    _recentWorkspaces.insert(0, path);
    if (_recentWorkspaces.length > 10) {
      _recentWorkspaces = _recentWorkspaces.sublist(0, 10);
    }
  }

  /// Remove a workspace from the recent list.
  Future<void> removeFromRecent(String path) async {
    _recentWorkspaces.remove(path);
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyWorkspacePath, _currentPath);
    await prefs.setStringList(_keyRecentWorkspaces, _recentWorkspaces);
  }

  /// Extract display name (last path segment) from any path.
  static String nameForPath(String path) {
    if (path == '/') return '/';
    return path.split('/').where((s) => s.isNotEmpty).last;
  }

  /// The display name for the current workspace.
  String get displayName => nameForPath(_currentPath);
}
