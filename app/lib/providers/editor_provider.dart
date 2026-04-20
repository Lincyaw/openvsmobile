import 'package:flutter/foundation.dart';
import '../models/diagnostic.dart';
import '../models/editor_context.dart';
import '../services/api_client.dart';

/// Represents an open file with its content and edit state.
class OpenFile {
  final String path;
  final String name;
  String originalContent;
  String currentContent;
  bool isEditing;

  OpenFile({
    required this.path,
    required this.name,
    required this.originalContent,
    String? currentContent,
    this.isEditing = false,
  }) : currentContent = currentContent ?? originalContent;

  bool get hasUnsavedChanges => currentContent != originalContent;
}

class EditorProvider extends ChangeNotifier {
  final ApiClient apiClient;

  final List<OpenFile> _openFiles = [];
  int _currentFileIndex = -1;
  EditorCursor? _cursor;
  EditorSelection? _selection;
  bool _isLoading = false;
  String? _error;

  // Diagnostics for the current file.
  List<Diagnostic> _diagnostics = [];
  List<Diagnostic> get diagnostics => List.unmodifiable(_diagnostics);
  bool _isLoadingDiagnostics = false;
  bool get isLoadingDiagnostics => _isLoadingDiagnostics;

  EditorProvider({required this.apiClient});

  List<OpenFile> get openFiles => List.unmodifiable(_openFiles);
  OpenFile? get currentFile =>
      _currentFileIndex >= 0 && _currentFileIndex < _openFiles.length
      ? _openFiles[_currentFileIndex]
      : null;
  int get currentFileIndex => _currentFileIndex;
  EditorCursor? get cursor => _cursor;
  EditorSelection? get selection => _selection;
  bool get isLoading => _isLoading;
  String? get error => _error;
  EditorChatContext get chatContext => EditorChatContext(
    activeFile: currentFile?.path,
    cursor: _cursor,
    selection: _selection,
  );

  /// Open a file by path. If already open, switch to it.
  Future<void> openFile(String path) async {
    final existingIndex = _openFiles.indexWhere((f) => f.path == path);
    if (existingIndex >= 0) {
      _currentFileIndex = existingIndex;
      _resetContextForCurrentFile();
      notifyListeners();
      return;
    }

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final content = await apiClient.readFile(path);
      final name = path.split('/').last;
      final file = OpenFile(path: path, name: name, originalContent: content);
      _openFiles.add(file);
      _currentFileIndex = _openFiles.length - 1;
      _resetContextForCurrentFile();
      loadDiagnostics();
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void closeFile(int index) {
    if (index < 0 || index >= _openFiles.length) return;
    _openFiles.removeAt(index);
    if (_currentFileIndex >= _openFiles.length) {
      _currentFileIndex = _openFiles.length - 1;
    }
    _resetContextForCurrentFile();
    notifyListeners();
  }

  void switchToFile(int index) {
    if (index >= 0 && index < _openFiles.length) {
      _currentFileIndex = index;
      _resetContextForCurrentFile();
      notifyListeners();
    }
  }

  void toggleEditMode() {
    final file = currentFile;
    if (file == null) return;
    file.isEditing = !file.isEditing;
    notifyListeners();
  }

  void enterEditMode() {
    final file = currentFile;
    if (file == null) return;
    file.isEditing = true;
    notifyListeners();
  }

  void exitEditMode() {
    final file = currentFile;
    if (file == null) return;
    file.isEditing = false;
    notifyListeners();
  }

  void updateContent(String content) {
    final file = currentFile;
    if (file == null) return;
    file.currentContent = content;
    notifyListeners();
  }

  void updateCursor(EditorCursor? cursor) {
    _cursor = cursor;
    if (cursor == null) {
      _selection = null;
    }
    notifyListeners();
  }

  void updateSelection(EditorSelection? selection, {EditorCursor? cursor}) {
    _selection = selection;
    if (cursor != null) {
      _cursor = cursor;
    }
    notifyListeners();
  }

  void clearSelection() {
    _selection = null;
    notifyListeners();
  }

  /// Save the current file to the server.
  Future<bool> saveCurrentFile() async {
    final file = currentFile;
    if (file == null) return false;

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      await apiClient.writeFile(file.path, file.currentContent);
      file.originalContent = file.currentContent;
      _isLoading = false;
      notifyListeners();
      loadDiagnostics(); // Refresh diagnostics after save.
      return true;
    } catch (e) {
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  bool get hasUnsavedChanges => _openFiles.any((f) => f.hasUnsavedChanges);

  /// Load diagnostics for the current file.
  Future<void> loadDiagnostics() async {
    final file = currentFile;
    if (file == null) return;

    _isLoadingDiagnostics = true;
    notifyListeners();

    try {
      final workDir = _extractWorkDir(file.path);
      final allDiags = await apiClient.getDiagnostics(
        filePath: file.path,
        workDir: workDir,
      );
      // Filter to only diagnostics for the current file.
      _diagnostics = allDiags
          .where(
            (d) => file.path.endsWith(d.filePath) || d.filePath == file.path,
          )
          .toList();
    } catch (_) {
      _diagnostics = [];
    } finally {
      _isLoadingDiagnostics = false;
      notifyListeners();
    }
  }

  List<Diagnostic> diagnosticsForLine(int line) {
    return _diagnostics.where((d) => d.line == line).toList();
  }

  String _extractWorkDir(String filePath) {
    final parts = filePath.split('/');
    // Return everything except the last component (the filename).
    if (parts.length > 1) {
      return parts.sublist(0, parts.length - 1).join('/');
    }
    return '/';
  }

  void _resetContextForCurrentFile() {
    if (currentFile == null) {
      _cursor = null;
      _selection = null;
      return;
    }
    _cursor = const EditorCursor(line: 1, column: 1);
    _selection = null;
  }
}
