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
