class GitRemote {
  final String name;
  final String fetchUrl;
  final String pushUrl;
  final bool isReadOnly;
  final List<String> branches;

  const GitRemote({
    required this.name,
    required this.fetchUrl,
    required this.pushUrl,
    required this.isReadOnly,
    required this.branches,
  });

  factory GitRemote.fromJson(Map<String, dynamic> json) {
    return GitRemote(
      name: json['name'] as String? ?? '',
      fetchUrl: json['fetchUrl'] as String? ?? '',
      pushUrl: json['pushUrl'] as String? ?? '',
      isReadOnly: json['isReadOnly'] as bool? ?? false,
      branches: (json['branches'] as List<dynamic>? ?? const [])
          .map((entry) => entry as String)
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'name': name,
      'fetchUrl': fetchUrl,
      'pushUrl': pushUrl,
      'isReadOnly': isReadOnly,
      'branches': branches,
    };
  }
}

class GitBranchInfo {
  final String current;
  final List<String> branches;

  const GitBranchInfo({required this.current, required this.branches});
}

class GitMergeStatus {
  final String kind;
  final String current;
  final String incoming;

  const GitMergeStatus({
    required this.kind,
    required this.current,
    required this.incoming,
  });

  bool get isEmpty => kind.isEmpty && current.isEmpty && incoming.isEmpty;

  factory GitMergeStatus.fromJson(Map<String, dynamic> json) {
    return GitMergeStatus(
      kind: json['kind'] as String? ?? '',
      current: json['current'] as String? ?? '',
      incoming: json['incoming'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'kind': kind,
      'current': current,
      'incoming': incoming,
    };
  }
}

class GitChange {
  final String path;
  final String originalPath;
  final String status;
  final String indexStatus;
  final String workingTreeStatus;
  final GitMergeStatus? mergeStatus;

  const GitChange({
    required this.path,
    required this.originalPath,
    required this.status,
    required this.indexStatus,
    required this.workingTreeStatus,
    required this.mergeStatus,
  });

  String get displayName => path.split('/').last;

  bool get hasOriginalPath => originalPath.isNotEmpty && originalPath != path;
  bool get isRename => hasOriginalPath || status == 'renamed';

  String get statusLabel {
    if (mergeStatus != null && !mergeStatus!.isEmpty) {
      return mergeStatus!.kind.isNotEmpty ? mergeStatus!.kind : 'merge';
    }
    if (status.isNotEmpty && status != 'unknown') {
      return status;
    }
    final code = indexStatus.isNotEmpty ? indexStatus : workingTreeStatus;
    return code.isNotEmpty ? code : 'unknown';
  }

  factory GitChange.fromJson(Map<String, dynamic> json) {
    final mergeJson = json['mergeStatus'];
    final mergeStatus = mergeJson is Map<String, dynamic>
        ? GitMergeStatus.fromJson(mergeJson)
        : mergeJson is Map
        ? GitMergeStatus.fromJson(Map<String, dynamic>.from(mergeJson))
        : null;

    return GitChange(
      path: json['path'] as String? ?? '',
      originalPath: json['originalPath'] as String? ?? '',
      status: json['status'] as String? ?? 'unknown',
      indexStatus: json['indexStatus'] as String? ?? '',
      workingTreeStatus: json['workingTreeStatus'] as String? ?? '',
      mergeStatus: mergeStatus,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'path': path,
      'originalPath': originalPath,
      'status': status,
      'indexStatus': indexStatus,
      'workingTreeStatus': workingTreeStatus,
      if (mergeStatus != null) 'mergeStatus': mergeStatus!.toJson(),
    };
  }
}

typedef GitFileChange = GitChange;

class GitRepositoryState {
  final String path;
  final String branch;
  final String upstream;
  final int ahead;
  final int behind;
  final List<GitRemote> remotes;
  final List<GitChange> staged;
  final List<GitChange> unstaged;
  final List<GitChange> untracked;
  final List<GitChange> conflicts;
  final List<GitChange> mergeChanges;

  const GitRepositoryState({
    required this.path,
    required this.branch,
    required this.upstream,
    required this.ahead,
    required this.behind,
    required this.remotes,
    required this.staged,
    required this.unstaged,
    required this.untracked,
    required this.conflicts,
    required this.mergeChanges,
  });

  factory GitRepositoryState.empty(String path) {
    return GitRepositoryState(
      path: path,
      branch: '',
      upstream: '',
      ahead: 0,
      behind: 0,
      remotes: const [],
      staged: const [],
      unstaged: const [],
      untracked: const [],
      conflicts: const [],
      mergeChanges: const [],
    );
  }

  factory GitRepositoryState.fromJson(Map<String, dynamic> json) {
    return GitRepositoryState(
      path: json['path'] as String? ?? '',
      branch: json['branch'] as String? ?? '',
      upstream: json['upstream'] as String? ?? '',
      ahead: json['ahead'] as int? ?? 0,
      behind: json['behind'] as int? ?? 0,
      remotes: (json['remotes'] as List<dynamic>? ?? const [])
          .map(
            (entry) =>
                GitRemote.fromJson(Map<String, dynamic>.from(entry as Map)),
          )
          .toList(),
      staged: _changesFromJson(json['staged']),
      unstaged: _changesFromJson(json['unstaged']),
      untracked: _changesFromJson(json['untracked']),
      conflicts: _changesFromJson(json['conflicts']),
      mergeChanges: _changesFromJson(json['mergeChanges']),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'path': path,
      'branch': branch,
      'upstream': upstream,
      'ahead': ahead,
      'behind': behind,
      'remotes': remotes.map((remote) => remote.toJson()).toList(),
      'staged': staged.map((change) => change.toJson()).toList(),
      'unstaged': unstaged.map((change) => change.toJson()).toList(),
      'untracked': untracked.map((change) => change.toJson()).toList(),
      'conflicts': conflicts.map((change) => change.toJson()).toList(),
      'mergeChanges': mergeChanges.map((change) => change.toJson()).toList(),
    };
  }

  int get totalChanges =>
      stagedCount + unstagedCount + untrackedCount + conflictCount;

  int get changeCount => totalChanges;
  bool get isClean => totalChanges == 0;
  int get stagedCount => staged.length;
  int get unstagedCount => unstaged.length + mergeChanges.length;
  int get untrackedCount => untracked.length;
  int get conflictCount => conflicts.length;

  List<GitChange> get changes => [...unstaged, ...mergeChanges];

  List<GitChangeGroup> get groups => [
    GitChangeGroup(
      key: 'conflicts',
      title: 'Conflicts',
      description: 'Resolve merge conflicts before committing.',
      changes: conflicts,
      accent: GitGroupAccent.danger,
      primaryAction: GitChangeAction.resolve,
    ),
    GitChangeGroup(
      key: 'staged',
      title: 'Staged Changes',
      description: 'Ready to include in the next commit.',
      changes: staged,
      accent: GitGroupAccent.success,
      primaryAction: GitChangeAction.unstage,
    ),
    GitChangeGroup(
      key: 'unstaged',
      title: 'Changes',
      description: 'Tracked files with local modifications.',
      changes: changes,
      accent: GitGroupAccent.info,
      primaryAction: GitChangeAction.stage,
    ),
    GitChangeGroup(
      key: 'untracked',
      title: 'Untracked',
      description: 'New files not yet tracked by Git.',
      changes: untracked,
      accent: GitGroupAccent.neutral,
      primaryAction: GitChangeAction.stage,
    ),
  ].where((group) => group.changes.isNotEmpty).toList();
}

enum GitChangeAction { stage, unstage, resolve }

enum GitGroupAccent { success, info, warning, danger, neutral }

class GitChangeGroup {
  final String key;
  final String title;
  final String description;
  final List<GitChange> changes;
  final GitGroupAccent accent;
  final GitChangeAction primaryAction;

  const GitChangeGroup({
    required this.key,
    required this.title,
    required this.description,
    required this.changes,
    required this.accent,
    required this.primaryAction,
  });
}

class GitDiffDocument {
  final String path;
  final String diff;
  final bool staged;

  const GitDiffDocument({
    required this.path,
    required this.diff,
    required this.staged,
  });

  bool get isEmpty => diff.trim().isEmpty;

  factory GitDiffDocument.fromJson(Map<String, dynamic> json) {
    return GitDiffDocument(
      path: json['path'] as String? ?? '',
      diff: json['diff'] as String? ?? '',
      staged: json['staged'] as bool? ?? false,
    );
  }
}

List<GitChange> _changesFromJson(dynamic value) {
  if (value is! List<dynamic>) {
    return const [];
  }
  return value
      .map(
        (entry) => GitChange.fromJson(Map<String, dynamic>.from(entry as Map)),
      )
      .toList();
}
