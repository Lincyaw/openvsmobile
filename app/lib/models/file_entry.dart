class FileEntry {
  final String name;
  final bool isDir;
  final int size;

  const FileEntry({
    required this.name,
    required this.isDir,
    required this.size,
  });

  factory FileEntry.fromJson(Map<String, dynamic> json) {
    return FileEntry(
      name: json['name'] as String? ?? '',
      isDir: json['isDir'] as bool? ?? false,
      size: json['size'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {'name': name, 'isDir': isDir, 'size': size};
  }
}
