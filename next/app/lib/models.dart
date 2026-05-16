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

class TerminalSession {
  final String id;
  final String workspaceId;
  final int cols;
  final int rows;
  final String cwd;
  final int createdAt;

  const TerminalSession({
    required this.id,
    required this.workspaceId,
    required this.cols,
    required this.rows,
    required this.cwd,
    required this.createdAt,
  });

  factory TerminalSession.fromJson(Map<String, dynamic> json) =>
      TerminalSession(
        id: json['id'] as String,
        workspaceId: json['workspaceId'] as String,
        cols: (json['cols'] as num).toInt(),
        rows: (json['rows'] as num).toInt(),
        cwd: json['cwd'] as String,
        createdAt: (json['createdAt'] as num).toInt(),
      );
}
