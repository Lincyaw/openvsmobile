// Files tab: lazy-expand tree rooted at the current workspace's root, with
// git decorations (color + status letter) over the entries, a sticky status
// bar at the top showing branch/ahead/behind/count, a Changes-view toggle
// that filters the tree to decorated paths (and their ancestors), and a
// thin search bar that switches the body to a flat results list.
//
// The tree shape (expanded/collapsed flags + cached children) lives in
// AppState's FileTreeNode; the decoration map / branch info / Changes-view
// toggle live in AppState's WorkspacesModel. This widget is the view layer
// — it does not own server-derived state. See docs/conventions.md §2.

import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../backend_client.dart';
import '../models.dart';
import '../state/workspace_model.dart';
import 'diff_viewer.dart';
import 'file_viewer.dart';

/// Signature of the function FilesTab uses to perform a search. Production
/// wires this to `AppState.findFiles`; tests inject a fake.
typedef FindFilesFn = Future<FindFilesResult> Function(
  String workspaceId,
  String query,
);

/// Signature of the function FilesTab uses when a search result row is
/// tapped. Production wires this to opening the read-only file viewer;
/// tests inject a recorder so they can assert navigation occurred without
/// needing a real `fs.readFile` over the wire.
typedef OpenSearchResultFn = Future<void> Function(
  BuildContext context,
  String workspaceId,
  String relPath,
);

class FilesTab extends StatefulWidget {
  final AppState appState;

  /// Test-only override for the search function. Defaults to
  /// `appState.findFiles`. Exposed so widget tests can mount FilesTab
  /// against canned results.
  @visibleForTesting
  final FindFilesFn? searchOverride;

  /// Test-only override for the search-result tap handler.
  @visibleForTesting
  final OpenSearchResultFn? openSearchResultOverride;

  const FilesTab({
    super.key,
    required this.appState,
    this.searchOverride,
    this.openSearchResultOverride,
  });

  @override
  State<FilesTab> createState() => _FilesTabState();
}

/// Debounce interval for search-bar keystrokes. 120 ms is the issue brief's
/// value and matches typical command-palette feel without thrashing the
/// backend on rapid typing.
const Duration _kSearchDebounce = Duration(milliseconds: 120);

/// Limit passed to `workspace.findFiles`. 50 keeps the result list scrollable
/// on a phone screen; the user can refine the query for more precise matches.
const int _kSearchLimit = 50;

class _FilesTabState extends State<FilesTab> {
  String? _lastWorkspaceId;

  // ---- Search state (lives in widget state because it's view-only, not
  // server-derived — survives a workspace switch by clearing) ----
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  Timer? _searchDebounce;
  int _searchSeq = 0;
  String _searchQuery = '';
  bool _searchLoading = false;
  FindFilesResult? _searchResult;
  String? _searchError;

  @override
  void initState() {
    super.initState();
    widget.appState.addListener(_onAppStateChanged);
    _ensureRoot();
  }

  @override
  void dispose() {
    widget.appState.removeListener(_onAppStateChanged);
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onAppStateChanged() {
    final cur = widget.appState.currentWorkspace;
    if (cur?.id != _lastWorkspaceId) {
      _ensureRoot();
      // Workspace switched out from under the search bar. Clear the query
      // so results from the previous workspace don't briefly flash with the
      // new workspace's tree.
      _clearSearchState();
    }
    if (mounted) setState(() {});
  }

  /// Reset the search bar to its empty/collapsed state. Called on workspace
  /// switch and when the user explicitly clears the field.
  void _clearSearchState() {
    _searchDebounce?.cancel();
    _searchSeq++;
    _searchQuery = '';
    _searchLoading = false;
    _searchResult = null;
    _searchError = null;
    if (_searchController.text.isNotEmpty) {
      _searchController.clear();
    }
  }

  void _onSearchChanged(String value) {
    final trimmed = value.trim();
    _searchDebounce?.cancel();
    if (trimmed.isEmpty) {
      // Empty query → collapse results pane, no in-flight RPC.
      setState(() {
        _searchSeq++;
        _searchQuery = '';
        _searchLoading = false;
        _searchResult = null;
        _searchError = null;
      });
      return;
    }
    // Keep the current results visible while debouncing so the list doesn't
    // strobe between every keystroke; only flip into the "no results yet"
    // skeleton if there's nothing to show.
    setState(() {
      _searchQuery = trimmed;
      if (_searchResult == null) {
        _searchLoading = true;
      }
    });
    _searchDebounce = Timer(_kSearchDebounce, () {
      unawaited(_runSearch(trimmed));
    });
  }

  Future<void> _runSearch(String query) async {
    final workspace = widget.appState.currentWorkspace;
    if (workspace == null) return;
    final seq = ++_searchSeq;
    setState(() {
      _searchLoading = true;
      _searchError = null;
    });
    try {
      final searchFn = widget.searchOverride ??
          (String wsId, String q) => widget.appState.findFiles(
                workspaceId: wsId,
                query: q,
                limit: _kSearchLimit,
              );
      final result = await searchFn(workspace.id, query);
      if (!mounted) return;
      if (seq != _searchSeq) {
        // A newer keystroke landed before this RPC came back. Drop the
        // stale result on the floor — the newer RPC owns the UI now.
        return;
      }
      setState(() {
        _searchLoading = false;
        _searchResult = result;
        _searchError = null;
      });
    } catch (e) {
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _searchLoading = false;
        _searchResult = null;
        _searchError = e.toString();
      });
    }
  }

  Future<void> _openSearchResult(String relPath) async {
    final workspace = widget.appState.currentWorkspace;
    if (workspace == null) return;
    final override = widget.openSearchResultOverride;
    if (override != null) {
      await override(context, workspace.id, relPath);
      return;
    }
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final absPath = _resolveAbsPath(workspace.root, relPath);
    try {
      final content = await widget.appState.readFile(
        workspaceId: workspace.id,
        path: absPath,
      );
      if (!mounted) return;
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => FileViewerScreen(path: absPath, content: content),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Cannot open: $e')));
    }
  }

  String _resolveAbsPath(String workspaceRoot, String relPath) {
    if (relPath.isEmpty) return workspaceRoot;
    if (relPath.startsWith('/')) return relPath;
    return workspaceRoot.endsWith('/')
        ? '$workspaceRoot$relPath'
        : '$workspaceRoot/$relPath';
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
    // Per issue #54: "filename text colour ALSO shifts (subtle tint, not the
    // full badge colour) so the row reads at-a-glance from across the
    // screen." The tint only applies to file rows; directories keep the
    // default colour.
    final nameStyle = _filenameStyle(theme, node, decoration.status);
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
                style: nameStyle,
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

  /// Compute the filename TextStyle for a tree row. File rows with a
  /// status get a subtle tint (Color.lerp with the badge color at 35%) so
  /// the row reads from a distance without overpowering the badge itself.
  /// Deleted rows additionally get strikethrough to mirror the badge state
  /// — the file is gone, the name should look gone. Directories always
  /// render with the default text style (issue #54 explicitly defers
  /// folder-level color tint to a future change).
  TextStyle _filenameStyle(ThemeData theme, FileTreeNode node, String? status) {
    const baseStyle = TextStyle(fontSize: 14);
    if (node.isDir || status == null) return baseStyle;
    final base = theme.colorScheme.onSurface;
    final accent = _statusColor(theme, status);
    final tinted = Color.lerp(base, accent, 0.35) ?? base;
    return baseStyle.copyWith(
      color: tinted,
      decoration: status == 'D' ? TextDecoration.lineThrough : null,
      decorationColor: status == 'D' ? accent : null,
      decorationThickness: status == 'D' ? 2 : null,
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
    final isSearching = _searchQuery.isNotEmpty;
    return Column(
      children: [
        _SearchBar(
          controller: _searchController,
          focusNode: _searchFocus,
          onChanged: _onSearchChanged,
          onClear: () {
            setState(_clearSearchState);
          },
        ),
        _StatusBar(
          appState: widget.appState,
          workspaceState: wsState,
          changesActive: changesActive,
          connectionState: connState,
        ),
        Expanded(
          child: isSearching
              ? _SearchResultsView(
                  query: _searchQuery,
                  loading: _searchLoading,
                  result: _searchResult,
                  error: _searchError,
                  onTapResult: _openSearchResult,
                )
              : root == null
                  ? Center(
                      // Wrapped in Semantics so the "Loading workspace…"
                      // label travels with the spinner for screen-reader
                      // users — conventions §2 "no bare spinners".
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

/// Thin search bar above the status bar. Inline magnifier prefix, suffix
/// clear button when the field is non-empty. Empty query: results pane
/// stays collapsed (the parent decides what to show); non-empty query:
/// results replace the tree below.
class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  const _SearchBar({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          onChanged: onChanged,
          textInputAction: TextInputAction.search,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Search files',
            prefixIcon: const Icon(Icons.search, size: 18),
            prefixIconConstraints:
                const BoxConstraints(minWidth: 32, minHeight: 32),
            suffixIcon: AnimatedBuilder(
              animation: controller,
              builder: (context, _) {
                if (controller.text.isEmpty) {
                  return const SizedBox(width: 0, height: 0);
                }
                return IconButton(
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Clear search',
                  icon: const Icon(Icons.close),
                  onPressed: onClear,
                );
              },
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(
                color: theme.colorScheme.outlineVariant,
              ),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 0,
            ),
          ),
        ),
      ),
    );
  }
}

/// Body shown when the search bar has a non-empty query. Replaces (does
/// not overlay) the file tree.
class _SearchResultsView extends StatelessWidget {
  final String query;
  final bool loading;
  final FindFilesResult? result;
  final String? error;
  final Future<void> Function(String relPath) onTapResult;

  const _SearchResultsView({
    required this.query,
    required this.loading,
    required this.result,
    required this.error,
    required this.onTapResult,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Search failed: $error',
            style: TextStyle(color: theme.colorScheme.error),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final r = result;
    if (r == null) {
      // Loading the very first result for this query. Show a centered
      // spinner with a label so screen-readers get something useful.
      return Center(
        child: Semantics(
          label: 'Searching',
          container: true,
          child: const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (r.matches.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No matches for "$query"',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }
    final children = <Widget>[
      for (final match in r.matches)
        _SearchResultRow(
          match: match,
          query: query,
          onTap: () => onTapResult(match.path),
        ),
    ];
    if (r.truncated) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            'Showing top ${r.matches.length} matches — refine the query for more.',
            style: TextStyle(
              fontSize: 11,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    // Tiny inline spinner overlay when a follow-up search is in flight
    // but we still have stale results to show.
    return Stack(
      children: [
        ListView(children: children),
        if (loading)
          Positioned(
            top: 4,
            right: 8,
            child: Semantics(
              label: 'Searching',
              container: true,
              child: const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
      ],
    );
  }
}

/// One row in the search results list. Filename bold, dimmed dir prefix,
/// query chars highlighted.
class _SearchResultRow extends StatelessWidget {
  final FindFilesMatch match;
  final String query;
  final VoidCallback onTap;

  const _SearchResultRow({
    required this.match,
    required this.query,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lastSlash = match.path.lastIndexOf('/');
    final dirPart =
        lastSlash >= 0 ? match.path.substring(0, lastSlash + 1) : '';
    final basePart =
        lastSlash >= 0 ? match.path.substring(lastSlash + 1) : match.path;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.insert_drive_file_outlined, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _highlightedText(
                    text: basePart,
                    query: query,
                    baseStyle: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                    matchColor: theme.colorScheme.primary,
                  ),
                  if (dirPart.isNotEmpty)
                    Text(
                      dirPart,
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Highlight (bold + primary color) every char in [text] that's also in
  /// the case-insensitive query subsequence. This mirrors the backend
  /// scorer's match policy — same chars, same order — so the user sees
  /// exactly which query characters earned the hit.
  Widget _highlightedText({
    required String text,
    required String query,
    required TextStyle baseStyle,
    required Color matchColor,
  }) {
    if (query.isEmpty) return Text(text, style: baseStyle);
    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    final spans = <TextSpan>[];
    int p = 0;
    int q = 0;
    final buffer = StringBuffer();
    while (p < text.length) {
      if (q < lowerQuery.length && lowerText[p] == lowerQuery[q]) {
        if (buffer.isNotEmpty) {
          spans.add(TextSpan(text: buffer.toString(), style: baseStyle));
          buffer.clear();
        }
        spans.add(TextSpan(
          text: text[p],
          style: baseStyle.copyWith(color: matchColor),
        ));
        q++;
      } else {
        buffer.write(text[p]);
      }
      p++;
    }
    if (buffer.isNotEmpty) {
      spans.add(TextSpan(text: buffer.toString(), style: baseStyle));
    }
    return RichText(
      overflow: TextOverflow.ellipsis,
      text: TextSpan(style: baseStyle, children: spans),
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
    // "K changed" excludes untracked entries per issue #54 — directories
    // with only `?` should not contribute to the displayed count.
    final changed = st?.changedCount ?? 0;
    final bodyStyle = TextStyle(
      // Non-git case is "slightly dimmed" per issue #54; we apply that by
      // shifting the text role from onSurface → onSurfaceVariant. Material 3
      // guarantees both meet WCAG AA on surfaceContainerHighest.
      color: isGit
          ? theme.colorScheme.onSurface
          : theme.colorScheme.onSurfaceVariant,
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
      // The bar tap toggles the Changes view (filtered tree). On non-git
      // workspaces the bar is inert per CLAUDE.md "the bar is NOT a control
      // surface" — issue #54 explicitly keeps a no-op tap until the Changes
      // view wires up properly; here we already have the toggle handler from
      // the prior PR, but it's gated to git repos so non-git stays inert.
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
                const SizedBox(width: 8),
                // Always show `· ↑N ↓M` (zero values included) so the bar
                // has a stable shape and matches the issue spec's exact
                // format string `<branch> · ↑N ↓M · K changed`.
                Text(
                  '· ↑${st.ahead} ↓${st.behind}',
                  style: bodyStyle,
                ),
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

/// Status-letter → semantic Material color. Single source of truth for both
/// the badge color and the row's filename tint so they always agree.
///
/// Picks are deliberately chosen from Material 3 ColorScheme roles rather
/// than hard-coded hex values: Material's scheme generation guarantees the
/// pair `<role>/onSurface` meets WCAG AA contrast on both light and dark
/// themes, which lets us inherit that contract instead of re-validating per
/// PR (see PR description for the WCAG audit). The user-facing mapping:
///   * M (modified) → tertiary  — typically a yellow/amber tone.
///   * A (added)    → primary   — typically a brand/green tone.
///   * D (deleted)  → error     — red, plus strikethrough on the letter.
///   * U (unmerged) → error     — red (letter `U` differentiates from `D`).
///   * ? (untracked)→ outline   — neutral gray that fades vs. clean rows.
Color _statusColor(ThemeData theme, String status) {
  switch (status) {
    case 'M':
      return theme.colorScheme.tertiary;
    case 'A':
      return theme.colorScheme.primary;
    case 'D':
    case 'U':
      return theme.colorScheme.error;
    case '?':
      return theme.colorScheme.outline;
    default:
      return theme.colorScheme.onSurfaceVariant;
  }
}

/// Renders the right-side decoration for one tree row.
///
///   * File with status: colored single-letter badge (M / A / D / ? / U).
///     `D` is additionally rendered with strikethrough.
///   * Directory with changedCount > 0: neutral "●K" badge counting M/A/D/U
///     only — `?`-only directories show no badge per issue #54.
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
      final color = _statusColor(theme, status);
      return Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Text(
          status,
          style: TextStyle(
            color: color,
            fontFamily: 'monospace',
            fontSize: 12,
            fontWeight: FontWeight.bold,
            decoration: status == 'D' ? TextDecoration.lineThrough : null,
            decorationColor: status == 'D' ? color : null,
            decorationThickness: status == 'D' ? 2 : null,
          ),
        ),
      );
    }
    final count = decoration.changedCount;
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
