import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// 1-based text position. [end] points to the first character after the
/// selection, so ranges are half-open and can map cleanly to LSP-style APIs.
@immutable
class SelectionPoint {
  final int line;
  final int column;

  const SelectionPoint({required this.line, required this.column});

  Map<String, dynamic> toJson() => <String, dynamic>{
    'line': line,
    'column': column,
  };

  @override
  bool operator ==(Object other) =>
      other is SelectionPoint && other.line == line && other.column == column;

  @override
  int get hashCode => Object.hash(line, column);
}

@immutable
class SelectionRange {
  final SelectionPoint start;
  final SelectionPoint end;

  const SelectionRange({required this.start, required this.end});

  Map<String, dynamic> toJson() => <String, dynamic>{
    'start': start.toJson(),
    'end': end.toJson(),
    'endExclusive': true,
  };

  @override
  bool operator ==(Object other) =>
      other is SelectionRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

@immutable
class SelectionContext {
  final String source;
  final String sourceId;
  final String? workspaceId;
  final String? workspaceRoot;
  final String path;
  final String? relativePath;
  final String text;
  final String? language;
  final SelectionRange? range;
  final SelectionRange? oldRange;
  final SelectionRange? newRange;
  final String? diffLineKind;

  const SelectionContext({
    required this.source,
    required this.sourceId,
    this.workspaceId,
    this.workspaceRoot,
    required this.path,
    this.relativePath,
    required this.text,
    this.language,
    this.range,
    this.oldRange,
    this.newRange,
    this.diffLineKind,
  });

  static SelectionContext? fromFileOffsets({
    required String path,
    required String fullText,
    required int baseOffset,
    required int extentOffset,
    String? language,
    String? workspaceId,
    String? workspaceRoot,
    String? relativePath,
  }) {
    final offsets = _normalizedOffsets(fullText, baseOffset, extentOffset);
    if (offsets == null) return null;
    return SelectionContext(
      source: 'file',
      sourceId: fileSourceId(path),
      workspaceId: workspaceId,
      workspaceRoot: workspaceRoot,
      path: path,
      relativePath: relativePath,
      text: fullText.substring(offsets.start, offsets.end),
      language: language,
      range: SelectionRange(
        start: _pointForOffset(fullText, offsets.start),
        end: _pointForOffset(fullText, offsets.end),
      ),
    );
  }

  static SelectionContext? fromFileSelectedText({
    required String path,
    required String fullText,
    required String selectedText,
    String? language,
    String? workspaceId,
    String? workspaceRoot,
    String? relativePath,
  }) {
    if (selectedText.isEmpty) return null;
    final start = fullText.indexOf(selectedText);
    if (start < 0) return null;
    return fromFileOffsets(
      path: path,
      fullText: fullText,
      baseOffset: start,
      extentOffset: start + selectedText.length,
      language: language,
      workspaceId: workspaceId,
      workspaceRoot: workspaceRoot,
      relativePath: relativePath,
    );
  }

  static SelectionContext? fromDiffLineOffsets({
    required String path,
    required String lineText,
    required String lineKind,
    required int? oldLine,
    required int? newLine,
    required int baseOffset,
    required int extentOffset,
    String? workspaceId,
  }) {
    final offsets = _normalizedOffsets(lineText, baseOffset, extentOffset);
    if (offsets == null) return null;
    final selectedText = lineText.substring(offsets.start, offsets.end);
    final oldRange = oldLine == null
        ? null
        : SelectionRange(
            start: SelectionPoint(line: oldLine, column: offsets.start + 1),
            end: SelectionPoint(line: oldLine, column: offsets.end + 1),
          );
    final newRange = newLine == null
        ? null
        : SelectionRange(
            start: SelectionPoint(line: newLine, column: offsets.start + 1),
            end: SelectionPoint(line: newLine, column: offsets.end + 1),
          );
    return SelectionContext(
      source: 'diff',
      sourceId: diffSourceId(path),
      workspaceId: workspaceId,
      path: path,
      relativePath: path,
      text: selectedText,
      oldRange: oldRange,
      newRange: newRange,
      diffLineKind: lineKind,
    );
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'source': source,
      'sourceId': sourceId,
      'path': path,
      'text': text,
    };
    if (workspaceId != null) json['workspaceId'] = workspaceId;
    if (workspaceRoot != null) json['workspaceRoot'] = workspaceRoot;
    if (relativePath != null) json['relativePath'] = relativePath;
    if (language != null) json['language'] = language;
    if (range != null) json['range'] = range!.toJson();
    if (oldRange != null) json['oldRange'] = oldRange!.toJson();
    if (newRange != null) json['newRange'] = newRange!.toJson();
    if (diffLineKind != null) json['diffLineKind'] = diffLineKind;
    return json;
  }

  static String fileSourceId(String path) => 'file:$path';
  static String diffSourceId(String path) => 'diff:$path';

  @override
  bool operator ==(Object other) =>
      other is SelectionContext &&
      other.source == source &&
      other.sourceId == sourceId &&
      other.workspaceId == workspaceId &&
      other.workspaceRoot == workspaceRoot &&
      other.path == path &&
      other.relativePath == relativePath &&
      other.text == text &&
      other.language == language &&
      other.range == range &&
      other.oldRange == oldRange &&
      other.newRange == newRange &&
      other.diffLineKind == diffLineKind;

  @override
  int get hashCode => Object.hash(
    source,
    sourceId,
    workspaceId,
    workspaceRoot,
    path,
    relativePath,
    text,
    language,
    range,
    oldRange,
    newRange,
    diffLineKind,
  );
}

({int start, int end})? _normalizedOffsets(
  String text,
  int baseOffset,
  int extentOffset,
) {
  final start = math.min(baseOffset, extentOffset).clamp(0, text.length);
  final end = math.max(baseOffset, extentOffset).clamp(0, text.length);
  if (start == end) return null;
  return (start: start, end: end);
}

SelectionPoint _pointForOffset(String text, int offset) {
  var line = 1;
  var column = 1;
  final capped = offset.clamp(0, text.length);
  for (var i = 0; i < capped; i++) {
    if (text.codeUnitAt(i) == 0x0a) {
      line++;
      column = 1;
    } else {
      column++;
    }
  }
  return SelectionPoint(line: line, column: column);
}
