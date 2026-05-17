// Per-workspace resident client model: branch / HEAD / decoration map / tree
// state mirror. Composed under AppState (see docs/conventions.md §2 "If
// AppState outgrows one file, split it into composed sub-notifiers"). Mirrors
// the backend resident model defined in next/backend/src/workspaceModel.ts —
// kept structurally similar so the wire-format semantics carry through
// without translation.
//
// Semantics (CLAUDE.md first principles #1, #2, #4):
//   * Backend is the source of truth. The client subscribes once per
//     workspace, then renders pushes. No polling.
//   * Every push carries a `version`. We track `lastSeenVersion` per
//     workspace; a missed version triggers immediate `workspace.subscribe`
//     with the last good `sinceVersion`.
//   * On reconnect the same subscribe-with-since-version dance recovers the
//     stream. The model is *not* cleared on disconnect — last-known state
//     stays visible behind the offline banner until resync.
//   * The decoration map only carries non-clean files. Cleared entries
//     (status null in a delta) drop out of the map. The dir-rollup is a
//     pure computation off the decoration map; recomputed on every change
//     rather than maintained incrementally — it's cheap for any realistic
//     change set and incremental bookkeeping is bug-prone.
//
// Why a separate ChangeNotifier rather than living inside AppState:
//   * AppState was already ~500 lines; another concern with this many
//     fields would have pushed it over the §2 size guidance.
//   * Reviewers asked for the terminal-side split as the template; this
//     is the same pattern.
//   * Tests can target the model directly without spinning up a full
//     AppState.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../backend_client.dart';
import '../models.dart';

/// One cached `fs.listDir` response. Stale-tracked by a generation counter
/// rather than a boolean so a delta arriving mid-fetch can invalidate the
/// outstanding read without races (see [WorkspaceModel.listDir]).
class _ListDirCacheEntry {
  final List<DirEntry> entries;
  final int generation;
  const _ListDirCacheEntry(this.entries, this.generation);
}

/// Returned to the UI by [WorkspaceModel.statusFor]. Bundles the decoration
/// letter (or null for clean) and the rollup count for directories so the
/// view layer can render both cases off one lookup.
class WorkspaceDecorationView {
  final String? status;
  final int rollupCount;
  const WorkspaceDecorationView({this.status, this.rollupCount = 0});
}

/// Server-derived state for one workspace. One instance per open workspace,
/// owned by [WorkspacesModel].
class WorkspaceState {
  /// Branch name; null while non-git or pre-snapshot.
  String? branch;

  /// HEAD sha; null when no commits yet or non-git.
  String? headSha;

  /// Commits ahead of upstream. Zero when no upstream is configured.
  int ahead = 0;

  /// Commits behind upstream. Zero when no upstream is configured.
  int behind = 0;

  /// True once we've received any head info (i.e. confirmed git status).
  /// Distinguishes "non-git workspace" (set false after a snapshot with no
  /// head info) from "still subscribing".
  bool gitInfoReceived = false;

  /// True if backend reports this workspace is a git repo. Inferred:
  /// non-null branch ⇒ git.
  bool get isGitRepo => branch != null;

  /// path → "M"|"A"|"D"|"?"|"U". Only non-clean files live here.
  final Map<String, String> decorationMap = {};

  /// Directory path → count of decorated descendants. Recomputed from
  /// [decorationMap] on every change.
  final Map<String, int> dirRollup = {};

  /// Monotonic version of the last event we successfully integrated. The
  /// next event MUST have version == lastSeenVersion + 1; if not we
  /// re-subscribe with [lastSeenVersion] as `sinceVersion`.
  int lastSeenVersion = 0;

  /// Cached `fs.listDir` responses keyed by directory path. Cleared
  /// wholesale on snapshot mode; per-parent on tree.delta. Implementation
  /// detail — read via [WorkspacesModel.listDir], not by widgets.
  final Map<String, _ListDirCacheEntry> _listDirCache = {};

  /// Number of paths currently held in the listDir cache. Test hook;
  /// production widgets have no reason to read this.
  @visibleForTesting
  int get cachedListDirCount => _listDirCache.length;

  /// Whether [path] currently has a cached listDir response. Test hook.
  @visibleForTesting
  bool hasCachedListDir(String path) => _listDirCache.containsKey(path);

  /// Monotonic gen counter bumped on every cache invalidation. Used so an
  /// in-flight `listDir` that resolves after invalidation does not poison
  /// the cache with stale data.
  int _cacheGeneration = 0;
}

/// All open workspaces' resident state, plus the subscribe lifecycle.
/// AppState composes one of these and forwards `notifyListeners`.
class WorkspacesModel extends ChangeNotifier {
  final BackendClient _client;
  final Map<String, WorkspaceState> _states = {};

  /// Workspace currently being driven by [subscribe] but waiting for the
  /// initial decoration.snapshot to arrive. Tracked so a snapshot for an
  /// unknown id is treated as a forward-compat ignore rather than an error.
  WorkspacesModel({required BackendClient client}) : _client = client;

  // ---- Public read API ----

  WorkspaceState? stateFor(String workspaceId) => _states[workspaceId];

  /// Decoration view for an arbitrary path inside [workspaceId]. Resolves
  /// both files (status letter) and directories (rollup count). [relPath]
  /// is the workspace-relative path; the empty string returns the workspace
  /// root's rollup.
  WorkspaceDecorationView decorationFor(String workspaceId, String relPath) {
    final st = _states[workspaceId];
    if (st == null) return const WorkspaceDecorationView();
    final status = st.decorationMap[relPath];
    final rollup = st.dirRollup[relPath] ?? 0;
    return WorkspaceDecorationView(status: status, rollupCount: rollup);
  }

  /// All decorated paths for [workspaceId]. Order is insertion order — fine
  /// for the Changes view, which sorts by tree position.
  Iterable<String> decoratedPaths(String workspaceId) =>
      _states[workspaceId]?.decorationMap.keys ?? const [];

  int decoratedCount(String workspaceId) =>
      _states[workspaceId]?.decorationMap.length ?? 0;

  // ---- Subscribe / unsubscribe lifecycle ----

  /// Subscribe to [workspaceId]. Reuses the existing per-workspace state if
  /// any; calls the backend with `sinceVersion = lastSeenVersion` so a
  /// reconnect resync collapses to a `current` or `replay` rather than a
  /// fresh snapshot. Returns the subscribe result mode for callers that
  /// want it (mainly tests).
  ///
  /// Safe to call repeatedly: a second subscribe from the same socket
  /// supersedes the prior subscriber on the backend, so we don't double-up.
  Future<String?> subscribe(String workspaceId) async {
    final st = _states.putIfAbsent(workspaceId, WorkspaceState.new);
    final params = <String, dynamic>{'workspaceId': workspaceId};
    if (st.lastSeenVersion > 0) {
      params['sinceVersion'] = st.lastSeenVersion;
    }
    try {
      final r =
          await _client.call('workspace.subscribe', params) as Map<String, dynamic>;
      final mode = r['mode'] as String?;
      final baseVersion = (r['baseVersion'] as num?)?.toInt() ?? 0;
      if (mode == 'snapshot') {
        // Snapshot reset: invalidate everything cached. Decoration map gets
        // replaced when the workspace.decoration.snapshot notification
        // arrives shortly after.
        st._listDirCache.clear();
        st._cacheGeneration++;
        st.lastSeenVersion = baseVersion;
        // Don't clear decorationMap yet — the snapshot push will replace it.
        // Until then we keep the old view so the UI doesn't flicker to empty.
      }
      // For 'current' / 'replay' nothing to do here: events do the work.
      notifyListeners();
      return mode;
    } catch (e) {
      // A subscribe failure during reconnect is non-fatal — the next reconnect
      // tick will retry. Leave the state in place. Surfaced via debugPrint
      // (not as a user-facing error) because the connection banner already
      // tells the user the link is unhealthy.
      debugPrint('WorkspacesModel.subscribe($workspaceId) failed: $e');
      return null;
    }
  }

  /// Unsubscribe from [workspaceId] (e.g. on workspace.close). Drops the
  /// state entry — the workspace is gone, the last-known view would be
  /// misleading.
  Future<void> unsubscribe(String workspaceId) async {
    if (!_states.containsKey(workspaceId)) return;
    _states.remove(workspaceId);
    try {
      await _client.call(
        'workspace.unsubscribe',
        {'workspaceId': workspaceId},
      );
    } catch (_) {
      // If the workspace was already closed by the backend, unsubscribe is a
      // no-op there too. Nothing to surface.
    }
    notifyListeners();
  }

  /// Drop every cached state — used when the socket leaves `connected`.
  /// We do NOT call workspace.unsubscribe (the socket is dead); the backend
  /// auto-detaches subscribers on socket close. Per CLAUDE.md FP #4 we keep
  /// the previously-rendered decorations in widget memory only briefly —
  /// the upcoming reconnect will re-subscribe and either replay or snapshot.
  ///
  /// Conventions §2: "Disconnect never clears the UI." So we DON'T wipe;
  /// we just mark the state as needing resync. The reconnect path drives
  /// the actual subscribe call.
  void markAllForResync() {
    // No-op for now — the model is intact; reconnect will subscribe with
    // the existing lastSeenVersion. This method exists as a marker so
    // future invariants (e.g. "stale > N seconds → grey out") have a hook.
  }

  // ---- Notification handlers (called from AppState._onNotification) ----

  /// `workspace.tree.delta { workspaceId, added, removed, renamed, version }`
  void onTreeDelta(Map<String, dynamic> params) {
    final wsId = params['workspaceId'] as String?;
    if (wsId == null) return;
    // Seed the state on first push if subscribe hasn't completed yet. The
    // backend only emits events to subscribed sockets, so seeing a push
    // implies the subscription is live even if our local async subscribe()
    // hasn't resolved.
    final st = _states.putIfAbsent(wsId, WorkspaceState.new);
    final version = (params['version'] as num?)?.toInt() ?? 0;
    if (!_checkVersionGap(wsId, st, version)) return;

    final affectedDirs = <String>{};
    void noteParents(String path) {
      affectedDirs.add(_parentDir(path));
    }

    for (final p in (params['added'] as List? ?? const [])) {
      if (p is String) noteParents(p);
    }
    for (final p in (params['removed'] as List? ?? const [])) {
      if (p is String) noteParents(p);
    }
    for (final r in (params['renamed'] as List? ?? const [])) {
      if (r is Map<String, dynamic>) {
        final from = r['from'];
        final to = r['to'];
        if (from is String) noteParents(from);
        if (to is String) noteParents(to);
      }
    }
    for (final dir in affectedDirs) {
      st._listDirCache.remove(dir);
    }
    if (affectedDirs.isNotEmpty) st._cacheGeneration++;
    st.lastSeenVersion = version;
    notifyListeners();
  }

  /// `workspace.decoration.delta { workspaceId, entries, version }`
  void onDecorationDelta(Map<String, dynamic> params) {
    final wsId = params['workspaceId'] as String?;
    if (wsId == null) return;
    final st = _states.putIfAbsent(wsId, WorkspaceState.new);
    final version = (params['version'] as num?)?.toInt() ?? 0;
    if (!_checkVersionGap(wsId, st, version)) return;

    final entries = params['entries'];
    if (entries is List) {
      for (final e in entries) {
        if (e is! Map<String, dynamic>) continue;
        final path = e['path'];
        if (path is! String) continue;
        final status = e['status'];
        if (status == null) {
          st.decorationMap.remove(path);
        } else if (status is String) {
          st.decorationMap[path] = status;
        }
      }
    }
    _recomputeRollup(st);
    st.lastSeenVersion = version;
    notifyListeners();
  }

  /// `workspace.decoration.snapshot { workspaceId, entries, version }` —
  /// fully replaces the decoration map. Sent right after a snapshot-mode
  /// subscribe.
  void onDecorationSnapshot(Map<String, dynamic> params) {
    final wsId = params['workspaceId'] as String?;
    if (wsId == null) return;
    final st = _states.putIfAbsent(wsId, WorkspaceState.new);
    final version = (params['version'] as num?)?.toInt() ?? 0;
    st.decorationMap.clear();
    final entries = params['entries'];
    if (entries is List) {
      for (final e in entries) {
        if (e is! Map<String, dynamic>) continue;
        final path = e['path'];
        if (path is! String) continue;
        final status = e['status'];
        if (status is String) {
          st.decorationMap[path] = status;
        }
      }
    }
    _recomputeRollup(st);
    st.lastSeenVersion = version;
    notifyListeners();
  }

  /// `workspace.head.changed { workspaceId, branch, headSha, ahead, behind, version }`
  void onHeadChanged(Map<String, dynamic> params) {
    final wsId = params['workspaceId'] as String?;
    if (wsId == null) return;
    final st = _states.putIfAbsent(wsId, WorkspaceState.new);
    final version = (params['version'] as num?)?.toInt() ?? 0;
    if (!_checkVersionGap(wsId, st, version)) return;
    st.branch = params['branch'] as String?;
    st.headSha = params['headSha'] as String?;
    st.ahead = (params['ahead'] as num?)?.toInt() ?? 0;
    st.behind = (params['behind'] as num?)?.toInt() ?? 0;
    st.gitInfoReceived = true;
    st.lastSeenVersion = version;
    notifyListeners();
  }

  /// `workspace.commit.added { workspaceId, branch, sha, subject, version }`.
  /// We don't keep a commit log client-side in v0; what we DO update is
  /// ahead/behind — a new commit on our branch advances `ahead` by one (the
  /// backend will also push a head.changed shortly after, but the
  /// commit.added arrives first and lets the status bar update immediately).
  void onCommitAdded(Map<String, dynamic> params) {
    final wsId = params['workspaceId'] as String?;
    if (wsId == null) return;
    final st = _states.putIfAbsent(wsId, WorkspaceState.new);
    final version = (params['version'] as num?)?.toInt() ?? 0;
    if (!_checkVersionGap(wsId, st, version)) return;
    // Optimistic local bump. The follow-up head.changed will overwrite with
    // the authoritative ahead/behind.
    final branch = params['branch'] as String?;
    if (branch != null && branch == st.branch) {
      st.ahead = st.ahead + 1;
    }
    st.lastSeenVersion = version;
    notifyListeners();
  }

  // ---- fs.listDir with caching ----

  /// Workspace-scoped listDir with the per-workspace cache layer described
  /// in §7 of the implementation plan. Returns cached entries when fresh,
  /// otherwise calls the RPC and caches.
  ///
  /// We pass the underlying RPC function as a callback rather than calling
  /// the client directly so AppState can keep its single RPC choke point
  /// (this layer doesn't try to second-guess error reporting / typing).
  Future<List<DirEntry>> listDir({
    required String workspaceId,
    required String path,
    required Future<List<DirEntry>> Function() fetch,
  }) async {
    final st = _states.putIfAbsent(workspaceId, WorkspaceState.new);
    final cached = st._listDirCache[path];
    if (cached != null) {
      return cached.entries;
    }
    final genAtRequest = st._cacheGeneration;
    final entries = await fetch();
    // If the cache generation moved while we were fetching, a tree.delta or
    // snapshot invalidation happened — don't poison the cache with stale
    // data, but still return what we read (it's the freshest the caller
    // can have right now, and the UI will be re-driven by the upcoming
    // notification).
    if (genAtRequest == st._cacheGeneration) {
      st._listDirCache[path] = _ListDirCacheEntry(entries, genAtRequest);
    }
    return entries;
  }

  /// Drop cached entries for [path] without bumping generation. Currently
  /// unused (delta-driven invalidation goes through [onTreeDelta]); exposed
  /// for tests that want to drive a stale-cache scenario.
  @visibleForTesting
  void evictListDirEntry(String workspaceId, String path) {
    final st = _states[workspaceId];
    if (st == null) return;
    st._listDirCache.remove(path);
    st._cacheGeneration++;
  }

  // ---- Internals ----

  /// Returns true if the event with [version] is the expected next one
  /// (lastSeenVersion + 1) or if we're still on the baseline post-snapshot
  /// (version == baseVersion). Triggers a subscribe-replay on gap.
  bool _checkVersionGap(String workspaceId, WorkspaceState st, int version) {
    if (st.lastSeenVersion == 0) {
      // First event on this workspace — accept whatever the server sent.
      return true;
    }
    if (version == st.lastSeenVersion + 1) return true;
    if (version <= st.lastSeenVersion) {
      // Replay overlap (e.g. our subscribe-replay slice + a live emit landed
      // in the same tick on the server side). The backend's
      // lastDeliveredVersion gate makes the duplicate impossible on a
      // single-subscriber wire; this branch is defensive.
      return false;
    }
    // Gap. Fire a subscribe to recover. We do NOT integrate the current
    // event — the upcoming replay or snapshot will deliver it (and any
    // intermediates) in order.
    debugPrint(
      'WorkspacesModel: version gap on $workspaceId '
      '(saw $version, expected ${st.lastSeenVersion + 1}); re-subscribing',
    );
    unawaited(subscribe(workspaceId));
    return false;
  }

  void _recomputeRollup(WorkspaceState st) {
    st.dirRollup.clear();
    for (final path in st.decorationMap.keys) {
      // Walk up ancestor chain. Workspace root (empty path) gets the total.
      var cursor = _parentDir(path);
      while (true) {
        st.dirRollup.update(cursor, (v) => v + 1, ifAbsent: () => 1);
        if (cursor.isEmpty) break;
        cursor = _parentDir(cursor);
      }
    }
  }

  /// Parent directory of [path], using forward slashes (paths are
  /// workspace-relative POSIX from porcelain v2). Root parent is "".
  static String _parentDir(String path) {
    final idx = path.lastIndexOf('/');
    if (idx < 0) return '';
    return path.substring(0, idx);
  }
}

