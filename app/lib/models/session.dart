// Model for session metadata from GET /api/sessions.

class SessionMeta {
  final int pid;
  final String sessionId;
  final String cwd;
  final DateTime startedAt;
  final String kind;
  final String entrypoint;
  final String summary;

  const SessionMeta({
    required this.pid,
    required this.sessionId,
    required this.cwd,
    required this.startedAt,
    required this.kind,
    required this.entrypoint,
    this.summary = '',
  });

  factory SessionMeta.fromJson(Map<String, dynamic> json) {
    return SessionMeta(
      pid: json['pid'] as int? ?? 0,
      sessionId: json['sessionId'] as String,
      cwd: json['cwd'] as String? ?? '',
      startedAt: json['startedAt'] != null
          ? (json['startedAt'] is int
                ? DateTime.fromMillisecondsSinceEpoch(json['startedAt'] as int)
                : DateTime.parse(json['startedAt'] as String))
          : DateTime.now(),
      kind: json['kind'] as String? ?? '',
      entrypoint: json['entrypoint'] as String? ?? '',
      summary: json['summary'] as String? ?? '',
    );
  }

  /// Derive a project name from the working directory.
  String get projectName {
    if (cwd.isEmpty) return 'Unknown';
    final parts = cwd.split('/');
    return parts.last.isNotEmpty
        ? parts.last
        : (parts.length > 1 ? parts[parts.length - 2] : cwd);
  }
}
