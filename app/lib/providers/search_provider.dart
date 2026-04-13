import 'package:flutter/foundation.dart';
import '../models/search_result.dart';
import '../services/api_client.dart';

/// Search mode: file name or file content.
enum SearchMode { fileName, fileContent }

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
  final ApiClient apiClient;

  List<SearchResult> _results = [];
  List<ContentSearchResult> _contentResults = [];
  bool _isSearching = false;
  String _query = '';
  String? _error;
  SearchMode _searchMode = SearchMode.fileName;

  SearchProvider({required this.apiClient});

  List<SearchResult> get results => _results;
  List<ContentSearchResult> get contentResults => _contentResults;
  bool get isSearching => _isSearching;
  String get query => _query;
  String? get error => _error;
  SearchMode get searchMode => _searchMode;

  void setSearchMode(SearchMode mode) {
    if (_searchMode != mode) {
      _searchMode = mode;
      _results = [];
      _contentResults = [];
      _error = null;
      notifyListeners();
    }
  }

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
      final rawResults = await apiClient.searchFiles(query, rootPath);
      _results = rawResults
          .map((e) => SearchResult(
                path: e['path'] as String,
                name: e['name'] as String,
                isDirectory: e['isDir'] as bool,
              ))
          .toList();
      _error = null;
    } catch (e) {
      _error = e.toString();
    } finally {
      _isSearching = false;
      notifyListeners();
    }
  }

  /// Search file contents for [query] under [rootPath] via the server endpoint.
  Future<void> searchContent(String query, String rootPath) async {
    if (query.isEmpty) {
      _contentResults = [];
      _query = '';
      _error = null;
      notifyListeners();
      return;
    }

    _isSearching = true;
    _query = query;
    _error = null;
    _contentResults = [];
    notifyListeners();

    try {
      _contentResults = await apiClient.searchContent(query, rootPath);
      _error = null;
    } catch (e) {
      _error = e.toString();
    } finally {
      _isSearching = false;
      notifyListeners();
    }
  }

  void clearResults() {
    _results = [];
    _contentResults = [];
    _query = '';
    _error = null;
    notifyListeners();
  }
}
