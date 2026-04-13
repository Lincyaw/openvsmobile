import 'package:flutter/foundation.dart';
import '../models/file_entry.dart';
import '../services/api_client.dart';

/// A search result entry.
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
  final ApiClient apiClient;

  List<SearchResult> _results = [];
  bool _isSearching = false;
  String _query = '';
  String? _error;

  SearchProvider({required this.apiClient});

  List<SearchResult> get results => _results;
  bool get isSearching => _isSearching;
  String get query => _query;
  String? get error => _error;

  /// Search for files matching [query] under [rootPath] by traversing the
  /// file tree. Matching is case-insensitive on file/directory names.
  Future<void> search(String query, String rootPath) async {
    if (query.isEmpty) {
      _results = [];
      _query = '';
      _error = null;
      notifyListeners();
      return;
    }

    _isSearching = true;
    _query = query;
    _error = null;
    _results = [];
    notifyListeners();

    try {
      final results = <SearchResult>[];
      await _searchRecursive(
        rootPath,
        query.toLowerCase(),
        results,
        maxDepth: 5,
      );
      _results = results;
      _error = null;
    } catch (e) {
      _error = e.toString();
    } finally {
      _isSearching = false;
      notifyListeners();
    }
  }

  Future<void> _searchRecursive(
    String dirPath,
    String lowerQuery,
    List<SearchResult> results, {
    int maxDepth = 5,
    int currentDepth = 0,
  }) async {
    if (currentDepth >= maxDepth || results.length >= 100) return;

    List<FileEntry> entries;
    try {
      entries = await apiClient.listDirectory(dirPath);
    } catch (_) {
      return;
    }

    for (final entry in entries) {
      final fullPath = dirPath.endsWith('/')
          ? '$dirPath${entry.name}'
          : '$dirPath/${entry.name}';

      if (entry.name.toLowerCase().contains(lowerQuery)) {
        results.add(
          SearchResult(
            path: fullPath,
            name: entry.name,
            isDirectory: entry.isDir,
          ),
        );
        if (results.length >= 100) return;
      }

      if (entry.isDir) {
        await _searchRecursive(
          fullPath,
          lowerQuery,
          results,
          maxDepth: maxDepth,
          currentDepth: currentDepth + 1,
        );
        if (results.length >= 100) return;
      }
    }
  }

  void clearResults() {
    _results = [];
    _query = '';
    _error = null;
    notifyListeners();
  }
}
