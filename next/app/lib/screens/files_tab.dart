// Files tab: lazy-expand tree rooted at the current workspace's root.
// Tapping a file opens a read-only viewer.
//
// The tree shape (expanded/collapsed flags + cached children) lives in
// AppState, not widget state — see docs/conventions.md §2. This widget is
// a near-stateless view that reacts to AppState changes and calls back
// into AppState for expand / refresh.

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import 'file_viewer.dart';

class FilesTab extends StatefulWidget {
  final AppState appState;
  const FilesTab({super.key, required this.appState});

  @override
  State<FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<FilesTab> {
  String? _lastWorkspaceId;

  @override
  void initState() {
    super.initState();
    widget.appState.addListener(_onAppStateChanged);
    _ensureRoot();
  }

  @override
  void dispose() {
    widget.appState.removeListener(_onAppStateChanged);
    super.dispose();
  }

  void _onAppStateChanged() {
    final cur = widget.appState.currentWorkspace;
    if (cur?.id != _lastWorkspaceId) {
      _ensureRoot();
    }
    if (mounted) setState(() {});
  }

  void _ensureRoot() {
    final w = widget.appState.currentWorkspace;
    _lastWorkspaceId = w?.id;
    if (w == null) return;
    if (widget.appState.fileTreeFor(w.id) == null) {
      widget.appState.refreshFileTree(w.id);
    }
  }

  Future<void> _openFile(FileTreeNode node) async {
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

  List<Widget> _flatten(FileTreeNode node, int depth) {
    final out = <Widget>[_buildRow(node, depth)];
    if (node.isDir && node.expanded && node.children != null) {
      for (final c in node.children!) {
        out.addAll(_flatten(c, depth + 1));
      }
    }
    return out;
  }

  Widget _buildRow(FileTreeNode node, int depth) {
    final theme = Theme.of(context);
    final wsId = _lastWorkspaceId;
    return InkWell(
      onTap: () {
        if (node.isDir) {
          if (wsId != null) {
            widget.appState.toggleFileTreeNode(wsId, node);
          }
        } else {
          _openFile(node);
        }
      },
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
                child: Icon(Icons.error_outline,
                    size: 16, color: theme.colorScheme.error),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wsId = _lastWorkspaceId;
    if (wsId == null) {
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
    final root = widget.appState.fileTreeFor(wsId);
    if (root == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('Loading workspace…'),
          ],
        ),
      );
    }
    final rows = _flatten(root, 0);
    return RefreshIndicator(
      onRefresh: () => widget.appState.refreshFileTree(wsId),
      child: ListView(children: rows),
    );
  }
}
