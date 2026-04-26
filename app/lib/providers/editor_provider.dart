import 'package:flutter/foundation.dart';

import '../models/editor_context.dart';
import '../services/api_client.dart';

/// Lightweight in-memory record of an open file used by the read-only
/// code viewer. Mobile no longer edits files on-device, but we still
/// track the active file so chat context (path + selection) flows into
/// [ChatProvider] via the shared editor chat context.
class OpenFile {
  final String path;
  final String name;
  String content;
  EditorCursor cursor;
  EditorSelection? selection;
  EditorSelection? revealSelection;
  int revealNonce;

  OpenFile({
    required this.path,
    required this.name,
    required this.content,
    EditorCursor? cursor,
    this.selection,
    this.revealSelection,
    this.revealNonce = 0,
  }) : cursor = cursor ?? const EditorCursor(line: 1, column: 1);
}

/// Provides the active file, cursor, and selection for the read-only code
/// viewer. The selection is exposed as [chatContext] so [ChatProvider] can
/// attach it to the next message sent to Claude.
class EditorProvider extends ChangeNotifier {
  EditorProvider({required this.apiClient});

  final ApiClient apiClient;

  final List<OpenFile> _openFiles = <OpenFile>[];
  int _currentFileIndex = -1;
  bool _isLoading = false;
  String? _error;

  List<OpenFile> get openFiles => List.unmodifiable(_openFiles);
  OpenFile? get currentFile =>
      _currentFileIndex >= 0 && _currentFileIndex < _openFiles.length
      ? _openFiles[_currentFileIndex]
      : null;
  int get currentFileIndex => _currentFileIndex;
  bool get isLoading => _isLoading;
  String? get error => _error;
  EditorCursor? get cursor => currentFile?.cursor;
  EditorSelection? get selection => currentFile?.selection;
  EditorSelection? get revealSelection => currentFile?.revealSelection;
  int get revealNonce => currentFile?.revealNonce ?? 0;

  EditorChatContext get chatContext => EditorChatContext(
    activeFile: currentFile?.path,
    cursor: currentFile?.cursor,
    selection: currentFile?.selection,
  );

  void clearError() {
    if (_error == null) {
      return;
    }
    _error = null;
    notifyListeners();
  }

  Future<void> openFile(String path) => openFileAt(path);

  Future<void> openFileAt(
    String path, {
    EditorSelection? selection,
    EditorCursor? cursor,
    int? line,
    int? offset,
    int? limit,
  }) async {
    final existingIndex = _openFiles.indexWhere((file) => file.path == path);
    if (existingIndex >= 0) {
      _currentFileIndex = existingIndex;
      final file = _openFiles[existingIndex];
      _applyReveal(
        file,
        selection: selection,
        cursor: cursor,
        line: line,
        offset: offset,
        limit: limit,
      );
      notifyListeners();
      return;
    }

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final content = await apiClient.readFile(path);
      final file = OpenFile(
        path: path,
        name: path.split('/').last,
        content: content,
      );
      _openFiles.add(file);
      _currentFileIndex = _openFiles.length - 1;
      _applyReveal(
        file,
        selection: selection,
        cursor: cursor,
        line: line,
        offset: offset,
        limit: limit,
      );
    } catch (error) {
      _error = error.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> closeFile(int index) async {
    if (index < 0 || index >= _openFiles.length) {
      return false;
    }
    _openFiles.removeAt(index);
    if (_currentFileIndex >= _openFiles.length) {
      _currentFileIndex = _openFiles.length - 1;
    } else if (_currentFileIndex > index) {
      _currentFileIndex -= 1;
    }
    notifyListeners();
    return true;
  }

  void updateCursor(EditorCursor? cursor) {
    final file = currentFile;
    if (file == null || cursor == null) {
      return;
    }
    file.cursor = cursor;
    if (file.selection?.isCollapsed ?? false) {
      file.selection = null;
    }
    notifyListeners();
  }

  void updateSelection(EditorSelection? selection, {EditorCursor? cursor}) {
    final file = currentFile;
    if (file == null) {
      return;
    }
    file.selection = selection;
    if (cursor != null) {
      file.cursor = cursor;
    }
    notifyListeners();
  }

  void clearSelection() {
    final file = currentFile;
    if (file == null) {
      return;
    }
    file.selection = null;
    notifyListeners();
  }

  void _applyReveal(
    OpenFile file, {
    EditorSelection? selection,
    EditorCursor? cursor,
    int? line,
    int? offset,
    int? limit,
  }) {
    var effectiveSelection = selection;
    var effectiveCursor = cursor;

    if (effectiveSelection == null && line != null) {
      final collapsed = EditorCursor(line: line, column: 1);
      effectiveSelection = EditorSelection(start: collapsed, end: collapsed);
      effectiveCursor = collapsed;
    }

    if (effectiveSelection == null && offset != null) {
      effectiveSelection = _selectionFromOffset(
        file.content,
        offset,
        limit: limit,
      );
      effectiveCursor = effectiveSelection?.start;
    }

    if (effectiveSelection != null) {
      file.selection = effectiveSelection;
      file.cursor = effectiveCursor ?? effectiveSelection.end;
      file.revealSelection = effectiveSelection;
      file.revealNonce += 1;
      return;
    }

    if (effectiveCursor != null) {
      file.cursor = effectiveCursor;
      file.selection = null;
      file.revealSelection = EditorSelection(
        start: effectiveCursor,
        end: effectiveCursor,
      );
      file.revealNonce += 1;
      return;
    }

    file.cursor = const EditorCursor(line: 1, column: 1);
    file.selection = null;
    file.revealSelection = null;
  }

  EditorSelection? _selectionFromOffset(
    String content,
    int offset, {
    int? limit,
  }) {
    if (content.isEmpty) {
      return null;
    }
    final startOffset = offset.clamp(0, content.length);
    final endOffset = (offset + (limit ?? 0)).clamp(
      startOffset,
      content.length,
    );
    final start = _offsetToCursor(content, startOffset);
    final end = _offsetToCursor(content, endOffset);
    return EditorSelection(start: start, end: end);
  }

  EditorCursor _offsetToCursor(String content, int rawOffset) {
    final clampedOffset = rawOffset.clamp(0, content.length);
    var line = 1;
    var column = 1;
    for (var index = 0; index < clampedOffset; index += 1) {
      if (content.codeUnitAt(index) == 10) {
        line += 1;
        column = 1;
      } else {
        column += 1;
      }
    }
    return EditorCursor(line: line, column: column);
  }
}
