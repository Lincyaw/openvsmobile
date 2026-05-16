// Step-by-step directory picker. No raw path input — the user drills.
// Uses fs.listDir({ path, picker: true }) so it can traverse outside any
// active workspace.

import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';

class WorkspacePickerScreen extends StatefulWidget {
  final AppState appState;
  const WorkspacePickerScreen({super.key, required this.appState});

  @override
  State<WorkspacePickerScreen> createState() => _WorkspacePickerScreenState();
}

class _WorkspacePickerScreenState extends State<WorkspacePickerScreen> {
  late String _path;
  List<DirEntry>? _entries;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    final home = Platform.environment['HOME'];
    _path = (home != null && home.isNotEmpty) ? home : '/';
    _load(_path);
  }

  Future<void> _load(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await widget.appState.pickerListDir(path);
      if (!mounted) return;
      setState(() {
        _path = path;
        _entries = entries;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  String _parent(String path) {
    if (path == '/' || path.isEmpty) return '/';
    final idx = path.lastIndexOf('/');
    if (idx <= 0) return '/';
    return path.substring(0, idx);
  }

  Future<void> _select() async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final ws = await widget.appState.openWorkspace(_path);
    if (!mounted) return;
    if (ws == null) {
      messenger.showSnackBar(
        SnackBar(content: Text('Failed to open $_path')),
      );
      return;
    }
    navigator.pop(ws);
  }

  @override
  Widget build(BuildContext context) {
    final dirs = _entries?.where((e) => e.isDir).toList() ?? const <DirEntry>[];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose a folder'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : () => _load(_path),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_upward),
                  tooltip: 'Parent',
                  onPressed: _path == '/' ? null : () => _load(_parent(_path)),
                ),
                Expanded(
                  child: Text(
                    _path,
                    style: const TextStyle(fontFamily: 'monospace'),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _entries == null
                ? const SizedBox.shrink()
                : ListView.builder(
                    itemCount: _entries!.length,
                    itemBuilder: (ctx, i) {
                      final e = _entries![i];
                      final enabled = e.isDir;
                      return ListTile(
                        leading: Icon(
                          e.isDir
                              ? Icons.folder_outlined
                              : Icons.insert_drive_file_outlined,
                          color: enabled
                              ? null
                              : Theme.of(context).disabledColor,
                        ),
                        title: Text(
                          e.name,
                          style: TextStyle(
                            color: enabled
                                ? null
                                : Theme.of(context).disabledColor,
                          ),
                        ),
                        onTap: enabled
                            ? () => _load(
                                  _path.endsWith('/')
                                      ? '$_path${e.name}'
                                      : '$_path/${e.name}',
                                )
                            : null,
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.check),
                  label: Text('Select this directory (${dirs.length} subdirs)'),
                  onPressed: _loading ? null : _select,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
