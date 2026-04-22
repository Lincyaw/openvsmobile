import 'editor_models.dart';

/// A content search result from the server grep endpoint.
class ContentSearchResult {
  final String file;
  final int line;
  final String content;
  final String linesBefore;
  final String linesAfter;

  const ContentSearchResult({
    required this.file,
    required this.line,
    required this.content,
    this.linesBefore = '',
    this.linesAfter = '',
  });

  factory ContentSearchResult.fromJson(Map<String, dynamic> json) {
    return ContentSearchResult(
      file: json['file'] as String,
      line: json['line'] as int,
      content: json['content'] as String,
      linesBefore: json['linesBefore'] as String? ?? '',
      linesAfter: json['linesAfter'] as String? ?? '',
    );
  }
}

class WorkspaceSymbolResult {
  final String name;
  final String containerName;
  final int kind;
  final String path;
  final String uri;
  final DocumentRange range;

  const WorkspaceSymbolResult({
    required this.name,
    required this.containerName,
    required this.kind,
    required this.path,
    required this.uri,
    required this.range,
  });

  factory WorkspaceSymbolResult.fromJson(Map<String, dynamic> json) {
    final uri = json['uri'] as String? ?? '';
    return WorkspaceSymbolResult(
      name: json['name'] as String? ?? '',
      containerName: json['containerName'] as String? ?? '',
      kind: json['kind'] as int? ?? 0,
      path: json['path'] as String? ?? _pathFromUri(uri),
      uri: uri,
      range: DocumentRange.fromJson(
        Map<String, dynamic>.from(
          json['range'] as Map? ?? const <String, dynamic>{},
        ),
      ),
    );
  }

  String get subtitle => containerName.isEmpty
      ? '$path:${range.startLineOneBased}'
      : '$containerName - $path:${range.startLineOneBased}';
}

String _pathFromUri(String uri) {
  if (uri.isEmpty) {
    return '';
  }
  try {
    return Uri.parse(uri).path;
  } catch (_) {
    return uri;
  }
}
