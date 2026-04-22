import 'editor_models.dart';

/// Model for diagnostic findings from either the legacy diagnostics endpoint or
/// the newer bridge-backed editor diagnostics report.
class Diagnostic {
  final String filePath;
  final DocumentRange range;
  final String severity;
  final String message;
  final String source;

  const Diagnostic({
    required this.filePath,
    required this.range,
    required this.severity,
    required this.message,
    required this.source,
  });

  factory Diagnostic.fromJson(
    Map<String, dynamic> json, {
    String? defaultPath,
  }) {
    final rawRange = json['range'];
    final filePath =
        json['file'] as String? ??
        json['filePath'] as String? ??
        json['path'] as String? ??
        defaultPath ??
        '';

    if (rawRange is Map) {
      return Diagnostic(
        filePath: filePath,
        range: DocumentRange.fromJson(Map<String, dynamic>.from(rawRange)),
        severity: _severityToString(json['severity']),
        message: json['message'] as String? ?? '',
        source: json['source'] as String? ?? '',
      );
    }

    final line = (json['line'] as int? ?? 1).clamp(1, 1 << 20);
    final column = (json['column'] as int? ?? 1).clamp(1, 1 << 20);
    return Diagnostic(
      filePath: filePath,
      range: DocumentRange(
        start: DocumentPosition(line: line - 1, character: column - 1),
        end: DocumentPosition(line: line - 1, character: column),
      ),
      severity: _severityToString(json['severity']),
      message: json['message'] as String? ?? '',
      source: json['source'] as String? ?? '',
    );
  }

  static List<Diagnostic> listFromReportJson(Map<String, dynamic> json) {
    final path = json['file'] as String? ?? json['path'] as String? ?? '';
    final rawDiagnostics = json['diagnostics'];
    if (rawDiagnostics is! List) {
      return const <Diagnostic>[];
    }
    return rawDiagnostics
        .whereType<Map>()
        .map(
          (entry) => Diagnostic.fromJson(
            Map<String, dynamic>.from(entry),
            defaultPath: path,
          ),
        )
        .toList();
  }

  int get line => range.startLineOneBased;
  int get column => range.start.character + 1;
  int get endLine => range.endLineOneBased;
  int get endColumn => range.end.character + 1;

  bool get isError => severity == 'error';
  bool get isWarning => severity == 'warning';
  bool get isInfo => severity == 'info';
}

String _severityToString(dynamic severity) {
  if (severity is String) {
    return severity.toLowerCase();
  }
  if (severity is num) {
    switch (severity.toInt()) {
      case 1:
        return 'error';
      case 2:
        return 'warning';
      case 3:
        return 'info';
      default:
        return 'hint';
    }
  }
  return 'info';
}
