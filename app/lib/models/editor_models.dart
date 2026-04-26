import 'editor_context.dart';

/// Zero-based document position used by the diagnostics and selection models.
class DocumentPosition {
  final int line;
  final int character;

  const DocumentPosition({required this.line, required this.character});

  factory DocumentPosition.fromJson(Map<String, dynamic> json) {
    return DocumentPosition(
      line: json['line'] as int? ?? 0,
      character: json['character'] as int? ?? 0,
    );
  }

  factory DocumentPosition.fromCursor(EditorCursor cursor) {
    return DocumentPosition(
      line: cursor.line > 0 ? cursor.line - 1 : 0,
      character: cursor.column > 0 ? cursor.column - 1 : 0,
    );
  }

  Map<String, dynamic> toJson() => {'line': line, 'character': character};

  EditorCursor toCursor() =>
      EditorCursor(line: line + 1, column: character + 1);
}

/// Zero-based half-open document range.
class DocumentRange {
  final DocumentPosition start;
  final DocumentPosition end;

  const DocumentRange({required this.start, required this.end});

  factory DocumentRange.fromJson(Map<String, dynamic> json) {
    return DocumentRange(
      start: DocumentPosition.fromJson(
        Map<String, dynamic>.from(
          json['start'] as Map? ?? const <String, dynamic>{},
        ),
      ),
      end: DocumentPosition.fromJson(
        Map<String, dynamic>.from(
          json['end'] as Map? ?? const <String, dynamic>{},
        ),
      ),
    );
  }

  factory DocumentRange.fromSelection(EditorSelection selection) {
    return DocumentRange(
      start: DocumentPosition.fromCursor(selection.start),
      end: DocumentPosition.fromCursor(selection.end),
    );
  }

  Map<String, dynamic> toJson() => {
    'start': start.toJson(),
    'end': end.toJson(),
  };

  EditorSelection toSelection() =>
      EditorSelection(start: start.toCursor(), end: end.toCursor());

  bool containsLine(int oneBasedLine) {
    final zeroBased = oneBasedLine > 0 ? oneBasedLine - 1 : 0;
    return zeroBased >= start.line && zeroBased <= end.line;
  }

  int get startLineOneBased => start.line + 1;
  int get endLineOneBased => end.line + 1;
}
