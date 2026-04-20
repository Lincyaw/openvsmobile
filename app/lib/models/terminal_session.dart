class TerminalSession {
  const TerminalSession({
    required this.id,
    required this.name,
    required this.cwd,
    required this.profile,
    required this.state,
    this.exitCode,
  });

  final String id;
  final String name;
  final String cwd;
  final String profile;
  final String state;
  final int? exitCode;

  bool get isRunning => state == 'running';

  factory TerminalSession.fromJson(Map<String, dynamic> json) {
    final dynamic exitCode = json['exitCode'] ?? json['exitStatus'];
    return TerminalSession(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      cwd: json['cwd'] as String? ?? '',
      profile: json['profile'] as String? ?? '',
      state: json['state'] as String? ?? 'unknown',
      exitCode: exitCode is int ? exitCode : int.tryParse('$exitCode'),
    );
  }
}
