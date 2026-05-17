// Files tab: lazy-expand tree rooted at the current workspace's root, with
// git decorations (color + status letter) over the entries, a sticky status
// bar at the top showing branch/ahead/behind/count, and a Changes-view
// toggle that filters the tree to decorated paths (and their ancestors).
//
// The tree shape (expanded/collapsed flags + cached children) lives in
// AppState's FileTreeNode; the decoration map / branch info / Changes-view
// toggle live in AppState's WorkspacesModel. This widget is the view layer
// — it does not own server-derived state. See docs/conventions.md §2.

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../backend_client.dart';
import '../models.dart';
import '../state/workspace_model.dart';
import 'diff_viewer.dart';
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

  /// Workspace-relative path. Tree nodes carry absolute paths (rooted at
  /// the workspace root). Returns "" for the root.
  String _relPathFor(String absPath, String workspaceRoot) {
    if (absPath == workspaceRoot) return '';
    var rel = absPath;
    if (rel.startsWith('$workspaceRoot/')) {
      rel = rel.substring(workspaceRoot.length + 1);
    } else if (rel.startsWith(workspaceRoot)) {
      rel = rel.substring(workspaceRoot.length);
      if (rel.startsWith('/')) rel = rel.substring(1);
    }
    return rel;
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

  void _openDiff(FileTreeNode node) {
    final ws = widget.appState.currentWorkspace;
    if (ws == null) return;
    final relPath = _relPathFor(node.path, ws.root);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DiffViewerScreen(
          appState: widget.appState,
          workspaceId: ws.id,
          path: relPath,
        ),
      ),
    );
  }

  /// Walk the tree, emitting one row per visible node. In Changes view, a
  /// node is visible iff it (or any descendant) appears in the decoration
  /// map. Directory expansion state is consulted in both modes — we never
  /// force-expand for Changes view, but the existing expanded set survives
  /// the toggle (it's stored on FileTreeNode, not in this widget).
  List<Widget> _flatten(
    FileTreeNode node,
    int depth,
    Workspace workspace,
    bool changesView,
  ) {
    final out = <Widget>[];
    final rel = _relPathFor(node.path, workspace.root);
    if (changesView && depth > 0) {
      // Hide nodes with no decorated descendants. The workspace-root row is
      // always shown so the user has a place to dock.
      if (!_hasDecorationDescendant(workspace.id, rel)) {
        return out;
      }
    }
    out.add(_buildRow(node, depth, workspace));
    if (node.isDir && node.expanded && node.children != null) {
      for (final c in node.children!) {
        out.addAll(_flatten(c, depth + 1, workspace, changesView));
      }
    }
    return out;
  }

  /// True when [rel] is itself decorated or has any decorated descendants.
  /// Reads only through [AppState.decorationFor] (PR-B review N2 — one way
  /// to do the same thing).
  bool _hasDecorationDescendant(String workspaceId, String rel) {
    final v = widget.appState.decorationFor(workspaceId, rel);
    if (rel.isEmpty) {
      // For the workspace root, "decorated descendants" == total count.
      return widget.appState.workspaces.decoratedCount(workspaceId) > 0;
    }
    return v.status != null || v.rollupCount > 0;
  }

  Widget _buildRow(
    FileTreeNode node,
    int depth,
    Workspace workspace,
  ) {
    final theme = Theme.of(context);
    final wsId = workspace.id;
    final rel = _relPathFor(node.path, workspace.root);
    final decoration = widget.appState.decorationFor(wsId, rel);
    return InkWell(
      onTap: () {
        if (node.isDir) {
          widget.appState.toggleFileTreeNode(wsId, node);
        } else {
          // In Changes view a file tap opens the diff; otherwise the viewer.
          if (widget.appState.changesViewActive) {
            _openDiff(node);
          } else {
            _openFile(node);
          }
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
            _DecorationBadge(node: node, decoration: decoration),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wsId = _lastWorkspaceId;
    final cur = widget.appState.currentWorkspace;
    if (wsId == null || cur == null) {
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
    final wsState = widget.appState.workspaceStateFor(wsId);
    final connState = widget.appState.connectionState;
    final root = widget.appState.fileTreeFor(wsId);
    final changesActive = widget.appState.changesViewActive;
    return Column(
      children: [
        _StatusBar(
          appState: widget.appState,
          workspaceState: wsState,
          changesActive: changesActive,
          connectionState: connState,
        ),
        Expanded(
          child: root == null
              ? Center(
                  // Wrapped in Semantics so the "Loading workspace…" label
                  // travels with the spinner for screen-reader users —
                  // conventions §2 "no bare spinners".
                  child: Semantics(
                    label: 'Loading workspace',
                    container: true,
                    child: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(height: 12),
                        Text('Loading workspace…'),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: () => widget.appState.refreshFileTree(wsId),
                  child: ListView(
                    children: _flatten(root, 0, cur, changesActive),
                  ),
                ),
        ),
      ],
    );
  }
}

/// Sticky status bar: branch, ahead/behind, changed count, filter toggle,
/// offline pill. Lives at the top of the Files tab.
class _StatusBar extends StatelessWidget {
  final AppState appState;
  final WorkspaceState? workspaceState;
  final bool changesActive;
  final BackendConnectionState connectionState;
  const _StatusBar({
    required this.appState,
    required this.workspaceState,
    required this.changesActive,
    required this.connectionState,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isOffline = connectionState != BackendConnectionState.connected;
    final st = workspaceState;
    final isGit = st != null && st.isGitRepo;
    final changed = st?.decorationMap.length ?? 0;
    final bodyStyle = TextStyle(
      color: theme.colorScheme.onSurface,
      fontSize: 12,
    );
    final monoStyle = TextStyle(
      color: theme.colorScheme.onSurface,
      fontSize: 12,
      fontFamily: 'monospace',
      fontWeight: FontWeight.w500,
    );
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: InkWell(
        onTap: isGit ? appState.toggleChangesView : null,
        child: Container(
          width: double.infinity,
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              if (!isGit && st == null)
                Text('Loading…', style: bodyStyle)
              else if (!isGit)
                Text('Not a git repository', style: bodyStyle)
              else ...[
                Icon(
                  changesActive ? Icons.filter_alt : Icons.account_tree_outlined,
                  size: 14,
                  color: theme.colorScheme.onSurface,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    st.branch ?? '',
                    style: monoStyle,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (st.ahead > 0 || st.behind > 0) ...[
                  const SizedBox(width: 8),
                  Text(
                    '· ↑${st.ahead} ↓${st.behind}',
                    style: bodyStyle,
                  ),
                ],
                const SizedBox(width: 8),
                Text(
                  changesActive
                      ? '· Changes · $changed file${changed == 1 ? '' : 's'}'
                      : '· $changed changed',
                  style: bodyStyle,
                ),
              ],
              const Spacer(),
              if (isGit)
                IconButton(
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                  tooltip: changesActive ? 'Show all files' : 'Show changes only',
                  icon: Icon(
                    changesActive ? Icons.filter_alt : Icons.filter_alt_outlined,
                    color: changesActive
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface,
                  ),
                  onPressed: appState.toggleChangesView,
                ),
              if (isOffline) ...[
                const SizedBox(width: 4),
                _OfflinePill(),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _OfflinePill extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'offline',
        style: TextStyle(
          color: theme.colorScheme.onSecondaryContainer,
          fontSize: 10,
        ),
      ),
    );
  }
}

/// Renders the right-side decoration for one tree row.
///
///   * File with status: colored single-letter badge (M / A / D / ? / U).
///   * Directory with rollupCount > 0: neutral "●K" badge.
///   * Otherwise: nothing.
class _DecorationBadge extends StatelessWidget {
  final FileTreeNode node;
  final WorkspaceDecorationView decoration;
  const _DecorationBadge({required this.node, required this.decoration});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!node.isDir) {
      final status = decoration.status;
      if (status == null) return const SizedBox.shrink();
      final Color color;
      switch (status) {
        case 'M':
          color = theme.colorScheme.tertiary;
          break;
        case 'A':
          color = theme.colorScheme.primary;
          break;
        case 'D':
          color = theme.colorScheme.error;
          break;
        case '?':
          color = theme.colorScheme.outline;
          break;
        case 'U':
          // Unmerged — error tone, plus the letter U as differentiator from D.
          color = theme.colorScheme.error;
          break;
        default:
          color = theme.colorScheme.onSurfaceVariant;
      }
      return Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Text(
          status,
          style: TextStyle(
            color: color,
            fontFamily: 'monospace',
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
    }
    final count = decoration.rollupCount;
    if (count <= 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Text(
        '●$count',
        style: TextStyle(
          color: theme.colorScheme.onSurfaceVariant,
          fontFamily: 'monospace',
          fontSize: 11,
        ),
      ),
    );
  }
}
