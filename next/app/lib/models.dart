// Plain data types mirroring the backend JSON-RPC schema. Kept deliberately
// small — these are wire-format DTOs, not domain models with behavior.

class Workspace {
  final String id;
  final String root;
  final String label;
  final int createdAt;

  const Workspace({
    required this.id,
    required this.root,
    required this.label,
    required this.createdAt,
  });

  factory Workspace.fromJson(Map<String, dynamic> json) => Workspace(
    id: json['id'] as String,
    root: json['root'] as String,
    label: json['label'] as String,
    createdAt: (json['createdAt'] as num).toInt(),
  );

  @override
  bool operator ==(Object other) => other is Workspace && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

class DirEntry {
  final String name;
  final bool isDir;
  final int? size;
  final int? mtime;

  const DirEntry({
    required this.name,
    required this.isDir,
    this.size,
    this.mtime,
  });

  factory DirEntry.fromJson(Map<String, dynamic> json) => DirEntry(
    name: json['name'] as String,
    isDir: (json['type'] as String) == 'dir',
    size: (json['size'] as num?)?.toInt(),
    mtime: (json['mtime'] as num?)?.toInt(),
  );
}

class FileContent {
  /// Raw bytes (decoded from base64).
  final List<int> bytes;
  final bool isBinary;

  const FileContent({required this.bytes, required this.isBinary});
}

/// One row in a `workspace.findFiles` result. `path` is workspace-relative
/// (POSIX separators), `score` is opaque — only the ordering is contractual.
class FindFilesMatch {
  final String path;
  final int score;

  const FindFilesMatch({required this.path, required this.score});

  factory FindFilesMatch.fromJson(Map<String, dynamic> json) => FindFilesMatch(
    path: json['path'] as String,
    score: (json['score'] as num).toInt(),
  );
}

/// Response shape for `workspace.findFiles`.
class FindFilesResult {
  final List<FindFilesMatch> matches;

  /// `true` when the walker hit the candidate ceiling before exhausting
  /// the tree. The UI surfaces a small hint when this is set.
  final bool truncated;

  const FindFilesResult({required this.matches, required this.truncated});

  factory FindFilesResult.fromJson(Map<String, dynamic> json) {
    final raw = (json['matches'] as List).cast<Map<String, dynamic>>();
    return FindFilesResult(
      matches: raw.map(FindFilesMatch.fromJson).toList(growable: false),
      truncated: (json['truncated'] as bool?) ?? false,
    );
  }
}

class PublishTokenRecord {
  final String id;
  final String label;
  final String? sourcePrefix;
  final int rateLimitPerMin;
  final int rateLimitPerHour;
  final int createdAt;
  final int? lastUsedAt;
  final int? revokedAt;

  const PublishTokenRecord({
    required this.id,
    required this.label,
    required this.sourcePrefix,
    required this.rateLimitPerMin,
    required this.rateLimitPerHour,
    required this.createdAt,
    required this.lastUsedAt,
    required this.revokedAt,
  });

  factory PublishTokenRecord.fromJson(Map<String, dynamic> json) =>
      PublishTokenRecord(
        id: json['id'] as String,
        label: json['label'] as String,
        sourcePrefix: json['sourcePrefix'] as String?,
        rateLimitPerMin: (json['rateLimitPerMin'] as num).toInt(),
        rateLimitPerHour: (json['rateLimitPerHour'] as num).toInt(),
        createdAt: (json['createdAt'] as num).toInt(),
        lastUsedAt: (json['lastUsedAt'] as num?)?.toInt(),
        revokedAt: (json['revokedAt'] as num?)?.toInt(),
      );

  PublishTokenRecord copyWith({String? label}) => PublishTokenRecord(
    id: id,
    label: label ?? this.label,
    sourcePrefix: sourcePrefix,
    rateLimitPerMin: rateLimitPerMin,
    rateLimitPerHour: rateLimitPerHour,
    createdAt: createdAt,
    lastUsedAt: lastUsedAt,
    revokedAt: revokedAt,
  );
}

class CreatedPublishToken {
  final PublishTokenRecord record;
  final String secret;

  const CreatedPublishToken({required this.record, required this.secret});
}

class AgentHookStatus {
  final String agent;
  final String state;
  final String message;
  final bool available;
  final bool changed;

  const AgentHookStatus({
    required this.agent,
    required this.state,
    required this.message,
    required this.available,
    required this.changed,
  });

  factory AgentHookStatus.fromJson(Map<String, dynamic> json) =>
      AgentHookStatus(
        agent: json['agent'] as String? ?? 'agent',
        state: json['state'] as String? ?? 'unknown',
        message: json['message'] as String? ?? '',
        available: json['available'] == true,
        changed: json['changed'] == true,
      );
}

class AgentHookInstallResult {
  final bool ok;
  final int? exitCode;
  final List<AgentHookStatus> statuses;
  final String stdout;
  final String stderr;

  const AgentHookInstallResult({
    required this.ok,
    required this.exitCode,
    required this.statuses,
    required this.stdout,
    required this.stderr,
  });

  factory AgentHookInstallResult.fromJson(Map<String, dynamic> json) {
    final rawStatuses = json['statuses'];
    return AgentHookInstallResult(
      ok: json['ok'] == true,
      exitCode: (json['exitCode'] as num?)?.toInt(),
      statuses: rawStatuses is List
          ? rawStatuses
                .whereType<Map<String, dynamic>>()
                .map(AgentHookStatus.fromJson)
                .toList(growable: false)
          : const [],
      stdout: json['stdout'] as String? ?? '',
      stderr: json['stderr'] as String? ?? '',
    );
  }

  AgentHookStatus? statusFor(String agent) {
    for (final status in statuses) {
      if (status.agent == agent) return status;
    }
    return null;
  }
}

/// A node in the per-workspace file tree. Lives in AppState rather than
/// widget state so the tree (expansion + cached children) survives a tab
/// switch or a screen rebuild — see docs/conventions.md §2 "Single source
/// of truth: AppState".
class FileTreeNode {
  final String path;
  final String name;
  final bool isDir;
  bool expanded;
  bool loading;
  String? error;
  List<FileTreeNode>? children;

  FileTreeNode({
    required this.path,
    required this.name,
    required this.isDir,
    this.expanded = false,
    this.loading = false,
    this.error,
    this.children,
  });
}

/// State of the step-by-step workspace picker. Holds the current directory,
/// the entries that path yielded, plus loading/error flags. Cleared when the
/// picker closes; not persisted.
class PickerState {
  final String path;
  final List<DirEntry>? entries;
  final bool loading;
  final String? error;

  const PickerState({
    required this.path,
    this.entries,
    this.loading = false,
    this.error,
  });

  PickerState copyWith({
    String? path,
    Object? entries = _noChange,
    bool? loading,
    Object? error = _noChange,
  }) {
    return PickerState(
      path: path ?? this.path,
      entries: entries == _noChange ? this.entries : entries as List<DirEntry>?,
      loading: loading ?? this.loading,
      error: error == _noChange ? this.error : error as String?,
    );
  }
}

const Object _noChange = Object();

class TerminalSession {
  final String id;
  final String? title;
  final String? workspaceId;
  final String? workspaceRoot;
  final int cols;
  final int rows;
  final String cwd;
  final int createdAt;

  /// Zellij session name when this session is multiplexer-backed; null for
  /// direct-shell sessions. Used to show the user the exact
  /// `zellij attach <name>` invocation after a detach.
  final String? externalSessionId;

  /// True when the backend pushed `terminal.detached` for this session
  /// (zellij client exited but the server session is still alive). The
  /// flag clears on the next `terminal.data` for this id — the lazy-
  /// reattach path repaints, which is the visible cue that the chip is
  /// live again.
  final bool detached;

  const TerminalSession({
    required this.id,
    this.title,
    this.workspaceId,
    this.workspaceRoot,
    required this.cols,
    required this.rows,
    required this.cwd,
    required this.createdAt,
    this.externalSessionId,
    this.detached = false,
  });

  TerminalSession copyWith({
    String? title,
    bool clearTitle = false,
    String? workspaceId,
    bool clearWorkspaceId = false,
    String? workspaceRoot,
    bool clearWorkspaceRoot = false,
    bool? detached,
  }) => TerminalSession(
    id: id,
    title: clearTitle ? null : (title ?? this.title),
    workspaceId: clearWorkspaceId ? null : (workspaceId ?? this.workspaceId),
    workspaceRoot: clearWorkspaceRoot
        ? null
        : (workspaceRoot ?? this.workspaceRoot),
    cols: cols,
    rows: rows,
    cwd: cwd,
    createdAt: createdAt,
    externalSessionId: externalSessionId,
    detached: detached ?? this.detached,
  );

  factory TerminalSession.fromJson(Map<String, dynamic> json) =>
      TerminalSession(
        id: json['id'] as String,
        title: json['title'] as String?,
        workspaceId: json['workspaceId'] as String?,
        workspaceRoot: json['workspaceRoot'] as String?,
        cols: (json['cols'] as num).toInt(),
        rows: (json['rows'] as num).toInt(),
        cwd: json['cwd'] as String,
        createdAt: (json['createdAt'] as num).toInt(),
        externalSessionId: json['externalSessionId'] as String?,
      );
}

/// Wire shape for one row from `terminal.listExternalSessions`. Reflects
/// the backend's `ExternalSession & { adopted }` shape.
class ExternalTerminalSession {
  final String name;

  /// "active" or "exited". Exited sessions can still be revived via
  /// `zellij attach --create <name>` — the same code path adoption uses
  /// — so the UI still allows tapping them.
  final String status;
  final bool adopted;

  const ExternalTerminalSession({
    required this.name,
    required this.status,
    required this.adopted,
  });

  bool get isActive => status == 'active';

  factory ExternalTerminalSession.fromJson(Map<String, dynamic> json) =>
      ExternalTerminalSession(
        name: json['name'] as String,
        status: json['status'] as String,
        adopted: (json['adopted'] as bool?) ?? false,
      );
}
