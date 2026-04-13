/// Model for diagnostic findings from the server.
class Diagnostic {
  final String filePath;
  final int line;
  final int column;
  final String severity;
  final String message;
  final String source;

  const Diagnostic({
    required this.filePath,
    required this.line,
    required this.column,
    required this.severity,
    required this.message,
    required this.source,
  });

  factory Diagnostic.fromJson(Map<String, dynamic> json) {
    return Diagnostic(
      filePath: json['filePath'] as String? ?? '',
      line: json['line'] as int? ?? 0,
      column: json['column'] as int? ?? 0,
      severity: json['severity'] as String? ?? 'info',
      message: json['message'] as String? ?? '',
      source: json['source'] as String? ?? '',
    );
  }

  bool get isError => severity == 'error';
  bool get isWarning => severity == 'warning';
  bool get isInfo => severity == 'info';
}
