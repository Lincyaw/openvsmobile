class TerminalSession {
  const TerminalSession({
    required this.id,
    required this.name,
    required this.cwd,
    required this.profile,
    required this.state,
    this.rows,
    this.cols,
    this.exitCode,
  });

  final String id;
  final String name;
  final String cwd;
  final String profile;
  final String state;
  final int? rows;
  final int? cols;
  final int? exitCode;

  bool get isRunning => state == 'running';
  bool get isExited => state == 'exited';
  String get displayName => name.isEmpty ? id : name;

  factory TerminalSession.fromJson(Map<String, dynamic> json) {
    final dynamic exitCode = json['exitCode'] ?? json['exitStatus'];
    return TerminalSession(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      cwd: json['cwd'] as String? ?? '',
      profile: json['profile'] as String? ?? '',
      state: json['state'] as String? ?? 'unknown',
      rows: _parseInt(json['rows']),
      cols: _parseInt(json['cols']),
      exitCode: exitCode is int ? exitCode : int.tryParse('$exitCode'),
    );
  }

  TerminalSession copyWith({
    String? id,
    String? name,
    String? cwd,
    String? profile,
    String? state,
    int? rows,
    int? cols,
    int? exitCode,
    bool clearExitCode = false,
  }) {
    return TerminalSession(
      id: id ?? this.id,
      name: name ?? this.name,
      cwd: cwd ?? this.cwd,
      profile: profile ?? this.profile,
      state: state ?? this.state,
      rows: rows ?? this.rows,
      cols: cols ?? this.cols,
      exitCode: clearExitCode ? null : exitCode ?? this.exitCode,
    );
  }
}

int? _parseInt(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value == null) {
    return null;
  }
  return int.tryParse('$value');
}
