import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/editor_models.dart';
import '../models/search_result.dart';
import '../services/api_client.dart';
import '../services/editor_api_client.dart';

/// Search mode: file name, file content, or workspace symbols.
enum SearchMode { fileName, fileContent, workspaceSymbols }

/// A file-name search result entry.
class SearchResult {
  final String path;
  final String name;
  final bool isDirectory;

  const SearchResult({
    required this.path,
    required this.name,
    required this.isDirectory,
  });
}

class SearchProvider extends ChangeNotifier {
  SearchProvider({required this.apiClient, required this.editorApiClient}) {
    unawaited(_refreshCapabilities());
    _connectEvents();
  }

  final ApiClient apiClient;
  final EditorApiClient editorApiClient;

  WebSocketChannel? _eventsChannel;
  StreamSubscription<dynamic>? _eventsSubscription;
  BridgeCapabilitiesDocument? _capabilities;

  List<SearchResult> _results = [];
  List<ContentSearchResult> _contentResults = [];
  List<WorkspaceSymbolResult> _symbolResults = [];
  bool _isSearching = false;
  String _query = '';
  String _rootPath = '/';
  String? _error;
  SearchMode _searchMode = SearchMode.fileName;
  bool _isDisposed = false;

  List<SearchResult> get results => _results;
  List<ContentSearchResult> get contentResults => _contentResults;
  List<WorkspaceSymbolResult> get symbolResults => _symbolResults;
  bool get isSearching => _isSearching;
  String get query => _query;
  String? get error => _error;
  SearchMode get searchMode => _searchMode;
  bool get workspaceSymbolsAvailable =>
      _capabilities?.isEnabled('workspace.symbols') ?? false;

  void setSearchMode(SearchMode mode) {
    if (_searchMode != mode) {
      _searchMode = mode;
      _results = [];
      _contentResults = [];
      _symbolResults = [];
      _error = null;
      notifyListeners();
    }
  }

  Future<void> search(String query, String rootPath) async {
    await _runSearch(
      query,
      rootPath,
      onEmpty: () => _results = [],
      run: () async {
        final rawResults = await _searchFiles(query, rootPath);
        _results = rawResults
            .map(
              (e) => SearchResult(
                path: e['path'] as String,
                name: e['name'] as String,
                isDirectory: e['isDir'] as bool,
              ),
            )
            .toList();
      },
    );
  }

  Future<void> searchContent(String query, String rootPath) async {
    await _runSearch(
      query,
      rootPath,
      onEmpty: () => _contentResults = [],
      run: () async {
        _contentResults = await _searchContent(query, rootPath);
      },
    );
  }

  Future<void> searchSymbols(String query, String rootPath) async {
    await _runSearch(
      query,
      rootPath,
      onEmpty: () => _symbolResults = [],
      run: () async {
        if (!workspaceSymbolsAvailable) {
          throw const ApiException(
            'Workspace symbols are not available for the current bridge session.',
            404,
          );
        }
        _symbolResults = await editorApiClient.workspaceSymbols(
          query: query,
          workDir: rootPath,
          max: 200,
        );
      },
    );
  }

  void clearResults() {
    _results = [];
    _contentResults = [];
    _symbolResults = [];
    _query = '';
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    unawaited(_disconnectEvents());
    super.dispose();
  }

  Future<void> _runSearch(
    String query,
    String rootPath, {
    required VoidCallback onEmpty,
    required Future<void> Function() run,
  }) async {
    if (query.isEmpty) {
      onEmpty();
      _query = '';
      _rootPath = rootPath;
      _error = null;
      notifyListeners();
      return;
    }

    _isSearching = true;
    _query = query;
    _rootPath = rootPath;
    _error = null;
    _results = [];
    _contentResults = [];
    _symbolResults = [];
    notifyListeners();

    try {
      await run();
      _error = null;
    } catch (e) {
      _error = e.toString();
    } finally {
      _isSearching = false;
      if (!_isDisposed) {
        notifyListeners();
      }
    }
  }

  Future<List<Map<String, dynamic>>> _searchFiles(
    String query,
    String rootPath,
  ) async {
    final useBridge = _capabilities?.isEnabled('workspace.search') ?? false;
    if (useBridge) {
      return editorApiClient.workspaceSearchFiles(
        query: query,
        workDir: rootPath,
        max: 200,
      );
    }
    return apiClient.searchFiles(query, rootPath);
  }

  Future<List<ContentSearchResult>> _searchContent(
    String query,
    String rootPath,
  ) async {
    final useBridge = _capabilities?.isEnabled('workspace.search') ?? false;
    if (useBridge) {
      return editorApiClient.workspaceSearchText(
        query: query,
        workDir: rootPath,
        max: 200,
      );
    }
    return apiClient.searchContent(query, rootPath);
  }

  Future<void> _refreshCapabilities() async {
    try {
      _capabilities = await editorApiClient.getCapabilities();
    } catch (_) {
      _capabilities = null;
    }
    if (!workspaceSymbolsAvailable &&
        _searchMode == SearchMode.workspaceSymbols) {
      _searchMode = SearchMode.fileName;
      _symbolResults = [];
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
      if (event.type == 'bridge/ready' || event.type == 'bridge/restarted') {
        await _refreshCapabilities();
        await _rerunCurrentQuery();
        return;
      }
      if (event.type == 'workspace/foldersChanged') {
        await _rerunCurrentQuery();
      }
    } catch (_) {
      // Ignore malformed bridge events.
    }
  }

  Future<void> _rerunCurrentQuery() async {
    if (_query.isEmpty || _isSearching) {
      return;
    }
    switch (_searchMode) {
      case SearchMode.fileName:
        await search(_query, _rootPath);
        break;
      case SearchMode.fileContent:
        await searchContent(_query, _rootPath);
        break;
      case SearchMode.workspaceSymbols:
        await searchSymbols(_query, _rootPath);
        break;
    }
  }
}
