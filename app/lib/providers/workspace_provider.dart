import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/editor_models.dart';
import '../services/editor_api_client.dart';

/// Manages the current workspace (project root directory).
/// All file browsing, search, and terminal operations are scoped to this path.
class WorkspaceProvider extends ChangeNotifier {
  WorkspaceProvider({required this.editorApiClient});

  static const _keyWorkspacePath = 'workspace_path';
  static const _keyRecentWorkspaces = 'recent_workspaces';
  static const String defaultWorkspace = '/home';

  final EditorApiClient editorApiClient;

  WebSocketChannel? _eventsChannel;
  StreamSubscription<dynamic>? _eventsSubscription;
  String _currentPath = defaultWorkspace;
  List<String> _recentWorkspaces = [];
  List<String> _runtimeFolders = [];
  bool _isDisposed = false;

  String get currentPath => _currentPath;
  List<String> get recentWorkspaces => List.unmodifiable(_recentWorkspaces);
  List<String> get runtimeFolders => List.unmodifiable(_runtimeFolders);
  bool get hasRuntimeFolders => _runtimeFolders.isNotEmpty;
  int get runtimeFolderCount => _runtimeFolders.length;

  /// Load persisted workspace from SharedPreferences.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _currentPath = prefs.getString(_keyWorkspacePath) ?? defaultWorkspace;
    _recentWorkspaces =
        prefs.getStringList(_keyRecentWorkspaces) ?? [defaultWorkspace];
    await refreshRuntimeFolders();
    _connectEvents();
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

  Future<void> refreshRuntimeFolders() async {
    try {
      final folders = await editorApiClient.workspaceFolders();
      _applyRuntimeFolders(folders);
    } catch (_) {
      _applyRuntimeFolders(const <String>[]);
    }
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

  String get runtimeDisplayName {
    if (_runtimeFolders.isEmpty) {
      return displayName;
    }
    if (_runtimeFolders.length == 1) {
      return nameForPath(_runtimeFolders.first);
    }
    return '${nameForPath(_runtimeFolders.first)} +${_runtimeFolders.length - 1}';
  }

  String get statusLabel {
    if (_runtimeFolders.isEmpty) {
      return displayName;
    }
    if (_runtimeFolders.length == 1 && _runtimeFolders.first == _currentPath) {
      return displayName;
    }
    if (_runtimeFolders.length == 1) {
      return '$displayName · runtime ${nameForPath(_runtimeFolders.first)}';
    }
    return '$displayName · ${_runtimeFolders.length} folders';
  }

  @override
  void dispose() {
    _isDisposed = true;
    unawaited(_disconnectEvents());
    super.dispose();
  }

  void _applyRuntimeFolders(List<String> folders) {
    _runtimeFolders = folders;
    for (final folder in folders) {
      _addToRecent(folder);
    }
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  void _connectEvents() {
    unawaited(_reconnectEvents());
  }

  Future<void> _reconnectEvents() async {
    await _disconnectEvents();
    if (_isDisposed) {
      return;
    }
    try {
      final channel = editorApiClient.connectEventsWebSocket();
      if (_isDisposed) {
        await channel.sink.close();
        return;
      }
      _eventsChannel = channel;
      _eventsSubscription = channel.stream.listen(
        _onBridgeEvent,
        onError: (_) {},
        onDone: () {},
      );
    } catch (_) {
      _eventsChannel = null;
      _eventsSubscription = null;
    }
  }

  Future<void> _disconnectEvents() async {
    final subscription = _eventsSubscription;
    final channel = _eventsChannel;
    _eventsSubscription = null;
    _eventsChannel = null;
    await subscription?.cancel();
    await channel?.sink.close();
  }

  void _onBridgeEvent(dynamic raw) {
    if (_isDisposed || raw is! String) {
      return;
    }
    unawaited(_handleBridgeEvent(raw));
  }

  Future<void> _handleBridgeEvent(String raw) async {
    if (_isDisposed) {
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return;
      }
      final event = BridgeEventEnvelope.fromJson(decoded);
      switch (event.type) {
        case 'bridge/ready':
        case 'bridge/restarted':
          await refreshRuntimeFolders();
          return;
        case 'workspace/foldersChanged':
          final payload = event.payload;
          if (payload is! Map) {
            return;
          }
          final folders = payload['folders'];
          if (folders is! List) {
            return;
          }
          _applyRuntimeFolders(
            folders
                .whereType<Map>()
                .map((entry) => Map<String, dynamic>.from(entry))
                .map((entry) => entry['path'] as String? ?? '')
                .where((path) => path.isNotEmpty)
                .toList(),
          );
          return;
      }
    } catch (_) {
      // Ignore malformed bridge events.
    }
  }
}
