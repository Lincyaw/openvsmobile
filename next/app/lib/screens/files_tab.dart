// Files tab: lazy-expand tree rooted at the current workspace's root.
// Tapping a file opens a read-only viewer.

import 'package:flutter/material.dart';

import '../app_state.dart';
import 'file_viewer.dart';

class FilesTab extends StatefulWidget {
  final AppState appState;
  const FilesTab({super.key, required this.appState});

  @override
  State<FilesTab> createState() => _FilesTabState();
}

class _Node {
  final String path;
  final String name;
  final bool isDir;
  bool expanded = false;
  bool loading = false;
  String? error;
  List<_Node>? children;

  _Node({
    required this.path,
    required this.name,
    required this.isDir,
  });
}

class _FilesTabState extends State<FilesTab> {
  String? _rootWorkspaceId;
  _Node? _root;

  @override
  void initState() {
    super.initState();
    widget.appState.addListener(_onAppStateChanged);
    _syncRoot();
  }

  @override
  void dispose() {
    widget.appState.removeListener(_onAppStateChanged);
    super.dispose();
  }

  void _onAppStateChanged() {
    final cur = widget.appState.currentWorkspace;
    if (cur?.id != _rootWorkspaceId) {
      _syncRoot();
    }
  }

  void _syncRoot() {
    final w = widget.appState.currentWorkspace;
    setState(() {
      _rootWorkspaceId = w?.id;
      _root = w == null
          ? null
          : _Node(path: w.root, name: w.label, isDir: true);
    });
    if (w != null && _root != null) {
      _toggle(_root!);
    }
  }

  Future<void> _toggle(_Node node) async {
    if (!node.isDir) return;
    if (node.expanded) {
      setState(() => node.expanded = false);
      return;
    }
    if (node.children != null) {
      setState(() => node.expanded = true);
      return;
    }
    if (_rootWorkspaceId == null) return;
    setState(() {
      node.loading = true;
      node.error = null;
    });
    try {
      final entries = await widget.appState.listDir(
        path: node.path,
        workspaceId: _rootWorkspaceId!,
      );
      if (!mounted) return;
      setState(() {
        node.children = entries
            .map((e) => _Node(
                  path: _join(node.path, e.name),
                  name: e.name,
                  isDir: e.isDir,
                ))
            .toList();
        node.expanded = true;
        node.loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        node.error = e.toString();
        node.loading = false;
      });
    }
  }

  String _join(String dir, String name) =>
      dir.endsWith('/') ? '$dir$name' : '$dir/$name';

  Future<void> _openFile(_Node node) async {
    final ws = widget.appState.currentWorkspace;
    if (ws == null) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final content = await widget.appState.readFile(
        workspaceId: ws.id,
        path: node.path,
      );
      if (!mounted) return;
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => FileViewerScreen(path: node.path, content: content),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Cannot open: $e')));
    }
  }

  List<Widget> _flatten(_Node node, int depth) {
    final out = <Widget>[];
    out.add(_buildRow(node, depth));
    if (node.isDir && node.expanded && node.children != null) {
      for (final c in node.children!) {
        out.addAll(_flatten(c, depth + 1));
      }
    }
    return out;
  }

  Widget _buildRow(_Node node, int depth) {
    return InkWell(
      onTap: () => node.isDir ? _toggle(node) : _openFile(node),
      child: Padding(
        padding: EdgeInsets.only(
          left: 8.0 + depth * 16.0,
          right: 8,
          top: 6,
          bottom: 6,
        ),
        child: Row(
          children: [
            Icon(
              node.isDir
                  ? (node.expanded
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_right)
                  : Icons.insert_drive_file_outlined,
              size: 18,
            ),
            const SizedBox(width: 4),
            Icon(
              node.isDir ? Icons.folder_outlined : Icons.description_outlined,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                node.name,
                style: const TextStyle(fontSize: 14),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (node.loading)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            if (node.error != null)
              Tooltip(
                message: node.error!,
                child: const Icon(Icons.error_outline,
                    size: 16, color: Colors.red),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_root == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No workspace open.\n'
            'Tap the title bar to choose one.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final rows = _flatten(_root!, 0);
    return RefreshIndicator(
      onRefresh: () async {
        // Drop all caches and re-expand the root.
        setState(() {
          _root = _Node(
            path: _root!.path,
            name: _root!.name,
            isDir: true,
          );
        });
        await _toggle(_root!);
      },
      child: ListView(children: rows),
    );
  }
}
