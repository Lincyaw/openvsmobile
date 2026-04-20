class EditorCursor {
  final int line;
  final int column;

  const EditorCursor({required this.line, required this.column});

  Map<String, dynamic> toJson() => {'line': line, 'column': column};

  @override
  bool operator ==(Object other) {
    return other is EditorCursor &&
        other.line == line &&
        other.column == column;
  }

  @override
  int get hashCode => Object.hash(line, column);
}

class EditorSelection {
  final EditorCursor start;
  final EditorCursor end;

  const EditorSelection({required this.start, required this.end});

  bool get isCollapsed =>
      start.line == end.line && start.column == end.column;

  Map<String, dynamic> toJson() => {
    'start': start.toJson(),
    'end': end.toJson(),
  };

  String get lineLabel {
    if (start.line == end.line) {
      return 'L${start.line}';
    }
    return 'L${start.line}-${end.line}';
  }

  @override
  bool operator ==(Object other) {
    return other is EditorSelection &&
        other.start == start &&
        other.end == end;
  }

  @override
  int get hashCode => Object.hash(start, end);
}

class EditorChatContext {
  final String? activeFile;
  final EditorCursor? cursor;
  final EditorSelection? selection;

  const EditorChatContext({
    required this.activeFile,
    required this.cursor,
    required this.selection,
  });

  bool get hasContext => activeFile != null && activeFile!.isNotEmpty;

  String get label {
    final filePath = activeFile;
    if (filePath == null || filePath.isEmpty) {
      return 'No active file';
    }
    final fileName = filePath.split('/').last;
    if (selection != null) {
      return '$fileName ${selection!.lineLabel}';
    }
    if (cursor != null) {
      return '$fileName L${cursor!.line}:C${cursor!.column}';
    }
    return fileName;
  }

  Map<String, dynamic> toTransportJson(String workspaceRoot) => {
    'workspaceRoot': workspaceRoot,
    'activeFile': activeFile,
    'cursor': cursor?.toJson(),
    'selection': selection?.toJson(),
  };

  @override
  bool operator ==(Object other) {
    return other is EditorChatContext &&
        other.activeFile == activeFile &&
        other.cursor == cursor &&
        other.selection == selection;
  }

  @override
  int get hashCode => Object.hash(activeFile, cursor, selection);
}
