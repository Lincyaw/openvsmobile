/// Git status entry representing a single file's status.
class GitStatusEntry {
  final String path;
  final String status; // "modified", "added", "deleted", "renamed", "untracked"
  final bool staged;
  final String workTree;
  final String index;

  const GitStatusEntry({
    required this.path,
    required this.status,
    required this.staged,
    required this.workTree,
    required this.index,
  });

  factory GitStatusEntry.fromJson(Map<String, dynamic> json) {
    return GitStatusEntry(
      path: json['path'] as String? ?? '',
      status: json['status'] as String? ?? 'unknown',
      staged: json['staged'] as bool? ?? false,
      workTree: json['workTree'] as String? ?? '',
      index: json['index'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'path': path,
      'status': status,
      'staged': staged,
      'workTree': workTree,
      'index': index,
    };
  }
}

/// Git log entry representing a single commit.
class GitLogEntry {
  final String hash;
  final String author;
  final String date;
  final String message;

  const GitLogEntry({
    required this.hash,
    required this.author,
    required this.date,
    required this.message,
  });

  factory GitLogEntry.fromJson(Map<String, dynamic> json) {
    return GitLogEntry(
      hash: json['hash'] as String? ?? '',
      author: json['author'] as String? ?? '',
      date: json['date'] as String? ?? '',
      message: json['message'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {'hash': hash, 'author': author, 'date': date, 'message': message};
  }
}

/// Git branch information.
class GitBranchInfo {
  final String current;
  final List<String> branches;

  const GitBranchInfo({required this.current, required this.branches});

  factory GitBranchInfo.fromJson(Map<String, dynamic> json) {
    return GitBranchInfo(
      current: json['current'] as String? ?? '',
      branches:
          (json['branches'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {'current': current, 'branches': branches};
  }
}
