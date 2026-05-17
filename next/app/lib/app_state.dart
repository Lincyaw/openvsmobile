// Central reactive state for the app.
//
// Every piece of server-derived state lives here: workspaces, the file tree
// per workspace, the workspace picker's current directory + entries, the
// SSH bootstrap result, and a mirror of the BackendClient's connection
// state. PTY-side state (sessions, xterms, backlog) lives in a composed
// `TerminalsNotifier` child; AppState forwards reads to it and re-broadcasts
// its `notifyListeners`. Widgets read from AppState; they do not read
// BackendClient directly. See docs/conventions.md §2 "Single source of
// truth: AppState".

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import 'backend_client.dart';
import 'models.dart';
import 'notification.dart';
import 'services/ssh_bootstrap.dart';
import 'state/notifications_model.dart';
import 'state/plugins_model.dart';
import 'state/terminals_notifier.dart';
import 'state/workspace_model.dart';
import 'ui/ui_panels_model.dart';

class AppState extends ChangeNotifier {
  final BackendClient client;

  /// Stable per-install identifier — see SettingsStore.loadOrCreateDeviceId.
  /// Used by the notification system for multi-device read sync.
  final String deviceId;
  late final TerminalsNotifier _terminals;
  late final WorkspacesModel _workspacesModel;
  late final NotificationsModel _notifications;
  late final PluginsModel _plugins;
  late final UiPanelsModel _uiPanels;
  StreamSubscription<BackendNotification>? _notifSub;

  /// Whether the Files tab should filter to the Changes view (decorated
  /// paths only) instead of the full tree. Lives in AppState rather than
  /// widget state because it must survive a tab switch (conventions §2:
  /// "would the state survive remount? if yes, it's in AppState").
  bool _changesViewActive = false;

  // ---- Workspace + recents ----
  List<Workspace> _active = const [];
  List<String> _recents = const [];
  Workspace? _current;

  // ---- File tree (per workspace) ----
  final Map<String, FileTreeNode> _fileTreeByWorkspace = {};

  // ---- Workspace picker (ephemeral) ----
  PickerState? _pickerState;

  // ---- SSH bootstrap result (survives screen rebuild) ----
  BootstrapSuccess? _lastBootstrapSuccess;
  BootstrapFailure? _lastBootstrapFailure;

  // ---- Connection state mirror ----
  BackendConnectionState _connectionState = BackendConnectionState.disconnected;
  String? _lastConnectionError;

  // ---- Last operation error (surfaced via SnackBar by the calling screen) ----
  String? _lastOperationError;

  AppState({required this.client, this.deviceId = ''}) {
    _connectionState = client.state.value;
    _lastConnectionError = client.lastError.value;
    _terminals = TerminalsNotifier(
      client: client,
      rootOf: (workspaceId) {
        for (final w in _active) {
          if (w.id == workspaceId) return w.root;
        }
        return null;
      },
      currentWorkspaceId: () => _current?.id,
      reportError: _reportOperationError,
    );
    _terminals.addListener(notifyListeners);
    _workspacesModel = WorkspacesModel(client: client);
    _workspacesModel.addListener(notifyListeners);
    _notifications = NotificationsModel(
      client: client,
      deviceId: () => deviceId,
      reportError: _reportOperationError,
    );
    _notifications.addListener(notifyListeners);
    _plugins = PluginsModel(client: client);
    _plugins.addListener(notifyListeners);
    _uiPanels = UiPanelsModel(client: client);
    _uiPanels.addListener(notifyListeners);
    client.state.addListener(_onConnState);
    client.lastError.addListener(_onConnError);
    _notifSub = client.notifications.listen(_onNotification);
  }

  // ---- Getters used by the UI ----

  List<Workspace> get activeWorkspaces => List.unmodifiable(_active);
  List<String> get recentRoots => List.unmodifiable(_recents);
  Workspace? get currentWorkspace => _current;

  /// Backend-reported $HOME (or "/" on older backends). The picker starts
  /// here instead of the phone's $HOME, which has no meaning to the backend.
  String get backendDefaultCwd {
    final cwd = client.defaultCwd;
    return cwd.isEmpty ? '/' : cwd;
  }

  /// Terminal sessions belonging to the currently-focused workspace.
  List<TerminalSession> get currentTerminals => _terminals.currentTerminals;

  String? get focusedTerminalId => _terminals.focusedTerminalId;

  /// Generation counter for a session's underlying Terminal. The UI uses
  /// this in its ValueKey so the TerminalView force-rebuilds when we swap
  /// the Terminal (e.g. after a reconnect history replay).
  int terminalGenerationFor(String sessionId) =>
      _terminals.terminalGenerationFor(sessionId);

  Terminal terminalFor(String sessionId) =>
      _terminals.terminalFor(sessionId);

  /// Listenable that fires whenever any session's preview ring buffer
  /// changes. The Terminal-tab list view listens to this for cheap
  /// per-chunk repaints — using AppState.notifyListeners would rebuild
  /// every other tab/screen on every PTY byte. See
  /// `TerminalsNotifier.previewVersion`.
  Listenable get terminalPreviewChanges => _terminals.previewVersion;

  /// Snapshot of the last-line preview for [sessionId]. Returns an empty
  /// snapshot (text + ts both null) for sessions that haven't produced
  /// output yet.
  TerminalPreview terminalPreviewFor(String sessionId) =>
      _terminals.previewFor(sessionId);

  /// File tree root for [workspaceId], or null if no workspace is open or the
  /// tree hasn't been initialized yet. Screens call [refreshFileTree] to
  /// (re)build it.
  FileTreeNode? fileTreeFor(String workspaceId) =>
      _fileTreeByWorkspace[workspaceId];

  PickerState? get pickerState => _pickerState;

  BootstrapSuccess? get lastBootstrapSuccess => _lastBootstrapSuccess;
  BootstrapFailure? get lastBootstrapFailure => _lastBootstrapFailure;

  BackendConnectionState get connectionState => _connectionState;
  String? get lastConnectionError => _lastConnectionError;

  /// Composed sub-notifier holding per-workspace git/decoration state. Read
  /// from widgets via getters below; mutated only via the subscribe lifecycle
  /// and notification handlers wired here.
  WorkspacesModel get workspaces => _workspacesModel;

  /// Notification surface (design §4.5). Composed under AppState so the bell
  /// icon, badge count, and notification center read from a single source.
  NotificationsModel get notifications => _notifications;

  /// Plugin registry (design §3 / issue C4). Backs the Plugins tab —
  /// AppState forwards notifyListeners so widgets only listen here.
  PluginsModel get plugins => _plugins;

  /// Plugin-owned UI panels (design §4.3 / issue C3). The Plugins-tab
  /// detail view subscribes via `subscribe()` once on connect and
  /// renders snapshots through `UiRenderer`.
  UiPanelsModel get uiPanels => _uiPanels;

  /// Per-workspace state lookup. Returns null if the workspace hasn't been
  /// subscribed yet (e.g. between activate and the first event).
  WorkspaceState? workspaceStateFor(String workspaceId) =>
      _workspacesModel.stateFor(workspaceId);

  /// Decoration view for a workspace-relative path.
  WorkspaceDecorationView decorationFor(String workspaceId, String relPath) =>
      _workspacesModel.decorationFor(workspaceId, relPath);

  bool get changesViewActive => _changesViewActive;

  void toggleChangesView() {
    _changesViewActive = !_changesViewActive;
    notifyListeners();
  }

  void setChangesView(bool active) {
    if (_changesViewActive == active) return;
    _changesViewActive = active;
    notifyListeners();
  }

  /// Last error surfaced from a user-initiated operation (openWorkspace,
  /// createTerminal, etc.). Cleared by [clearLastOperationError] once the UI
  /// has displayed it.
  String? get lastOperationError => _lastOperationError;

  void clearLastOperationError() {
    if (_lastOperationError == null) return;
    _lastOperationError = null;
    notifyListeners();
  }

  void _reportOperationError(String message) {
    _lastOperationError = message;
    notifyListeners();
  }

  // ---- Lifecycle / notifications ----

  void _onConnState() {
    final s = client.state.value;
    _connectionState = s;
    if (s == BackendConnectionState.connected) {
      // Re-fetch workspace + terminal state. With persistent backend state
      // the workspaces and sessions are still there; refreshWorkspaces will
      // replay each session's scrollback so the UI shows continuity.
      unawaited(refreshWorkspaces());
      // (Re)subscribe to notifications and pull the recent backlog so the
      // bell icon's unread badge is accurate immediately. Failures
      // self-log; the connection banner is the user-visible signal for any
      // link issue. Last-known notification state is preserved across the
      // reconnect (first principle #4: disconnect never clears the UI).
      unawaited(_notifications.subscribe());
      unawaited(_notifications.refresh());
      // Plugin surface + UI-descriptor fan-out follow the same shape —
      // subscribe on every successful connect; failures self-log.
      unawaited(_plugins.subscribeAndRefresh());
      unawaited(_uiPanels.subscribe());
      notifyListeners();
      return;
    }
    if (s == BackendConnectionState.connecting) {
      // First connect (no prior session). Nothing to clear yet — the
      // upcoming `connected` transition will populate fresh.
      notifyListeners();
      return;
    }
    // Any non-connected, non-initial state: the client's view of sessionIds
    // is stale until we reconfirm with the backend. The IDs themselves may
    // still be alive on the backend (that's the whole point of persistence),
    // but we tear down the local Terminal objects so the reconnect replay
    // path can rebuild them fresh.
    _active = const [];
    _current = null;
    _fileTreeByWorkspace.clear();
    _terminals.resetAll();
    // Keep recents — they're useful when reconnecting.
    notifyListeners();
  }

  void _onConnError() {
    _lastConnectionError = client.lastError.value;
    notifyListeners();
  }

  Future<void> _onNotification(BackendNotification n) async {
    switch (n.method) {
      case BackendNotifications.terminalData:
        _terminals.onTerminalData(n.params as Map<String, dynamic>);
        break;
      case BackendNotifications.terminalExit:
        _terminals.onTerminalExit(n.params as Map<String, dynamic>);
        break;
      case BackendNotifications.workspaceClosed:
        final id = (n.params as Map<String, dynamic>)['id'] as String;
        _onWorkspaceClosed(id);
        break;
      case BackendNotifications.workspaceTreeDelta:
        _workspacesModel.onTreeDelta(n.params as Map<String, dynamic>);
        break;
      case BackendNotifications.workspaceDecorationDelta:
        _workspacesModel.onDecorationDelta(n.params as Map<String, dynamic>);
        break;
      case BackendNotifications.workspaceDecorationSnapshot:
        _workspacesModel
            .onDecorationSnapshot(n.params as Map<String, dynamic>);
        break;
      case BackendNotifications.workspaceHeadChanged:
        _workspacesModel.onHeadChanged(n.params as Map<String, dynamic>);
        break;
      case BackendNotifications.workspaceCommitAdded:
        _workspacesModel.onCommitAdded(n.params as Map<String, dynamic>);
        break;
      case BackendNotifications.notificationShow:
        final p = n.params as Map<String, dynamic>;
        final raw = p['notification'];
        if (raw is Map<String, dynamic>) {
          _notifications.onShow(AppNotification.fromJson(raw));
        }
        break;
      case BackendNotifications.notificationReadChanged:
        final p = n.params as Map<String, dynamic>;
        final ids = (p['ids'] as List?)?.whereType<String>().toList() ??
            const <String>[];
        final by = p['readByDevice'];
        final ts = (p['ts'] as num?)?.toInt() ?? 0;
        if (by is String) {
          _notifications.onReadChanged(ids, by, ts);
        }
        break;
      case BackendNotifications.notificationDeleted:
        final p = n.params as Map<String, dynamic>;
        final ids = (p['ids'] as List?)?.whereType<String>().toList() ??
            const <String>[];
        _notifications.onDeleted(ids);
        break;
      case BackendNotifications.notificationSuperseded:
        final p = n.params as Map<String, dynamic>;
        final oldId = p['oldId'];
        final newId = p['newId'];
        if (oldId is String && newId is String) {
          _notifications.onSuperseded(oldId, newId);
        }
        break;
      case BackendNotifications.pluginStateChanged:
        _plugins.onStateChanged(n.params as Map<String, dynamic>);
        break;
      default:
        // Ignore unknown notifications (forward-compat).
        break;
    }
  }

  void _onWorkspaceClosed(String id) {
    _active = _active.where((w) => w.id != id).toList();
    _fileTreeByWorkspace.remove(id);
    _terminals.onWorkspaceClosed(id);
    // Server-initiated close: the backend has already disposed the
    // workspace model, so we drop the local state without round-tripping
    // an unsubscribe RPC (which would race against the close anyway).
    // See WorkspacesModel.unsubscribeLocal vs unsubscribeRemote.
    _workspacesModel.unsubscribeLocal(id);
    if (_current?.id == id) {
      _current = _active.isNotEmpty ? _active.first : null;
    }
    notifyListeners();
  }

  // ---- Public actions ----

  /// Re-fetch workspaces + terminals from the backend and replay every
  /// session's scrollback. Called on successful (re)connect.
  ///
  /// Error policy: a mid-call socket drop is benign (the connection banner
  /// already tells the user we're disconnected, and `_onConnState` will
  /// clear everything when the state transition lands). Any other failure
  /// is a real problem — a malformed reply, a server-side throw, an
  /// unexpected exception — and surfaces via `lastOperationError`.
  Future<void> refreshWorkspaces() async {
    try {
      final res = await client.call('workspace.list') as Map<String, dynamic>;
      _active = (res['active'] as List)
          .cast<Map<String, dynamic>>()
          .map(Workspace.fromJson)
          .toList();
      _recents =
          (res['recents'] as List).cast<String>().toList(growable: false);
      final cur =
          await client.call('workspace.current') as Map<String, dynamic>;
      final curRaw = cur['workspace'];
      _current = curRaw == null
          ? null
          : Workspace.fromJson(curRaw as Map<String, dynamic>);
      // (Re)subscribe to each active workspace so we get the push stream
      // back after a reconnect. With a non-zero lastSeenVersion the backend
      // returns mode=current/replay and we keep the existing decoration
      // map; with lastSeenVersion=0 (first connect or post-snapshot) we
      // get a fresh snapshot push. Either way the model converges.
      for (final w in _active) {
        unawaited(_workspacesModel.subscribe(w.id));
      }
      for (final w in _active) {
        final tres = await client.call(
          'terminal.list',
          {'workspaceId': w.id},
        ) as Map<String, dynamic>;
        final sessions = (tres['sessions'] as List)
            .cast<Map<String, dynamic>>()
            .map(TerminalSession.fromJson)
            .toList();
        _terminals.setSessionsForWorkspace(w.id, sessions);
        // Replay each session's scrollback. Order matters: we must finish
        // the replay (and set the seq watermark) BEFORE any live terminal.data
        // notifications race in. Notifications observed while the call is
        // in flight land in the backlog (because no Terminal exists yet for
        // that sid) and get drained when we finally install the Terminal.
        // That keeps the dedupe protocol watertight.
        for (final s in sessions) {
          await _terminals.replayHistory(s.id);
        }
      }
      notifyListeners();
    } catch (e) {
      // Discriminate: mid-call socket drop vs. real RPC failure.
      // `_onConnState` cleans up local mirrors when the state transitions,
      // and the connection banner is the user-visible signal for that
      // case — adding a SnackBar on top would just be noise.
      if (_connectionState != BackendConnectionState.connected) {
        debugPrint(
          'AppState.refreshWorkspaces dropped during reconnect: $e',
        );
        return;
      }
      _reportOperationError('Could not load workspaces: $e');
    }
  }

  /// Open or focus a workspace rooted at [root]. Returns the resulting
  /// workspace on success. On failure, stores the error in
  /// [lastOperationError] and returns null — the caller surfaces it via
  /// SnackBar.
  Future<Workspace?> openWorkspace(String root) async {
    try {
      final r = await client.call('workspace.open', {'root': root})
          as Map<String, dynamic>;
      final ws = Workspace.fromJson(r['workspace'] as Map<String, dynamic>);
      if (!_active.any((w) => w.id == ws.id)) {
        _active = [..._active, ws];
      }
      _current = ws;
      _recents = [root, ..._recents.where((r) => r != root)];
      // Open the resident-model push stream for this workspace. Fire-and-
      // forget: the subscribe handler logs any failure and leaves state
      // for the next reconnect cycle to retry.
      unawaited(_workspacesModel.subscribe(ws.id));
      notifyListeners();
      return ws;
    } catch (e) {
      _reportOperationError('Failed to open $root: $e');
      return null;
    }
  }

  Future<void> activateWorkspace(String id) async {
    try {
      final r = await client.call('workspace.activate', {'id': id})
          as Map<String, dynamic>;
      _current = Workspace.fromJson(r['workspace'] as Map<String, dynamic>);
      notifyListeners();
    } catch (e) {
      // Stale id, most likely — refresh and let the UI catch up. Stash the
      // reason so the user sees *something* instead of a silent no-op.
      _reportOperationError('Could not activate workspace: $e');
      await refreshWorkspaces();
    }
  }

  Future<void> closeWorkspace(String id) async {
    try {
      await client.call('workspace.close', {'id': id});
      // The backend echoes workspace.closed; _onWorkspaceClosed updates state.
    } catch (e) {
      _reportOperationError('Could not close workspace: $e');
      await refreshWorkspaces();
    }
  }

  Future<TerminalSession?> createTerminal({
    required String workspaceId,
    required int cols,
    required int rows,
  }) =>
      _terminals.createTerminal(
        workspaceId: workspaceId,
        cols: cols,
        rows: rows,
      );

  Future<void> disposeTerminal(String sessionId) =>
      _terminals.disposeTerminal(
        sessionId,
        connectionState: _connectionState,
      );

  void focusTerminal(String sessionId) => _terminals.focusTerminal(sessionId);

  // ---- File tree (per workspace) ----

  /// Discard the cached tree for [workspaceId] and re-fetch the root's
  /// children. Returns the future so callers (e.g. RefreshIndicator) can
  /// await it. Errors surface via [lastOperationError]; fire-and-forget
  /// callers (e.g. `_ensureRoot` after a workspace switch) get the same
  /// SnackBar via HomeShell's listener.
  Future<void> refreshFileTree(String workspaceId) async {
    Workspace? ws;
    for (final w in _active) {
      if (w.id == workspaceId) {
        ws = w;
        break;
      }
    }
    if (ws == null) {
      // Workspace was closed between the trigger and this call. Surface
      // rather than throwing into the void.
      _reportOperationError(
        'Could not refresh file tree: workspace gone',
      );
      return;
    }
    final root = FileTreeNode(path: ws.root, name: ws.label, isDir: true);
    _fileTreeByWorkspace[workspaceId] = root;
    notifyListeners();
    await toggleFileTreeNode(workspaceId, root);
  }

  /// Expand or collapse [node] within [workspaceId]'s tree. On first expand
  /// fetches children lazily. Mutates the node in place and notifies.
  Future<void> toggleFileTreeNode(String workspaceId, FileTreeNode node) async {
    if (!node.isDir) return;
    if (node.expanded) {
      node.expanded = false;
      notifyListeners();
      return;
    }
    if (node.children != null) {
      node.expanded = true;
      notifyListeners();
      return;
    }
    node.loading = true;
    node.error = null;
    notifyListeners();
    try {
      // FileTreeNode.path is absolute (rooted at the workspace root); the
      // listDir cache is keyed by workspace-relative paths. Translate here
      // so the cache invalidation path (which sees relative paths from
      // workspace.tree.delta) hits the same keys.
      final ws = _workspaceById(workspaceId);
      if (ws == null) {
        throw StateError('workspace $workspaceId no longer active');
      }
      final relPath = _relPathFromAbs(ws.root, node.path);
      final entries = await listDir(
        workspaceId: workspaceId,
        relPath: relPath,
      );
      node.children = entries
          .map((e) => FileTreeNode(
                path: _joinPath(node.path, e.name),
                name: e.name,
                isDir: e.isDir,
              ))
          .toList();
      node.expanded = true;
    } catch (e) {
      // Keep the per-node tooltip (visible next to the row) AND surface
      // via SnackBar so a failure on a collapsed-then-tapped node doesn't
      // go unnoticed if the user's eyes are elsewhere — unless we're
      // already disconnected, in which case the banner is the signal.
      node.error = e.toString();
      if (_connectionState == BackendConnectionState.connected) {
        _reportOperationError('Could not list ${node.path}: $e');
      }
    } finally {
      node.loading = false;
      notifyListeners();
    }
  }

  String _joinPath(String dir, String name) =>
      dir.endsWith('/') ? '$dir$name' : '$dir/$name';

  /// Inverse of [_resolveWorkspacePath]: strip the workspace root from an
  /// absolute path. Returns `''` when [absPath] is the root itself.
  /// Defensive — if the abs path doesn't start with the root we return it
  /// unchanged rather than guess.
  String _relPathFromAbs(String root, String absPath) {
    if (absPath == root) return '';
    if (absPath.startsWith('$root/')) {
      return absPath.substring(root.length + 1);
    }
    if (root.endsWith('/') && absPath.startsWith(root)) {
      return absPath.substring(root.length);
    }
    return absPath;
  }

  // ---- Workspace picker ----

  /// Initialize the picker at [path] (or the backend's $HOME if null). Idempotent.
  Future<void> openPicker({String? path}) async {
    final start = path ?? backendDefaultCwd;
    _pickerState = PickerState(path: start, loading: true);
    notifyListeners();
    await navigatePicker(start);
  }

  /// Move the picker to [path], fetching entries. Mutates [pickerState].
  Future<void> navigatePicker(String path) async {
    _pickerState = PickerState(path: path, loading: true);
    notifyListeners();
    try {
      final entries = await pickerListDir(path);
      _pickerState = PickerState(path: path, entries: entries);
    } catch (e) {
      _pickerState = PickerState(path: path, error: e.toString());
    }
    notifyListeners();
  }

  /// Discard the picker state. Called when the screen pops.
  void closePicker() {
    if (_pickerState == null) return;
    _pickerState = null;
    notifyListeners();
  }

  // ---- SSH bootstrap result ----

  /// Replace the last bootstrap result. Either success XOR failure is set at
  /// any given moment; passing both null clears the slot.
  void setBootstrapResult({
    BootstrapSuccess? success,
    BootstrapFailure? failure,
  }) {
    _lastBootstrapSuccess = success;
    _lastBootstrapFailure = failure;
    notifyListeners();
  }

  // ---- Filesystem helpers (passthrough wrappers around the RPC) ----

  /// Workspace-scoped directory listing. **[relPath] is workspace-relative**
  /// (`''` for the workspace root, `'src'` for a subdirectory) — same
  /// coordinate system as `workspace.tree.delta` so the cache invalidation
  /// path (`WorkspacesModel.onTreeDelta`) can land on the same keys. The
  /// fetch lambda resolves to the absolute path the backend's `fs.listDir`
  /// RPC wants; that knowledge does not leak into the cache layer. See
  /// PR-B review B1.
  Future<List<DirEntry>> listDir({
    required String workspaceId,
    required String relPath,
  }) async {
    final ws = _workspaceById(workspaceId);
    if (ws == null) {
      // Workspace closed between trigger and call. Surface and bail.
      _reportOperationError(
        'Could not list directory: workspace gone',
      );
      return const [];
    }
    final absPath = _resolveWorkspacePath(ws.root, relPath);
    return _workspacesModel.listDir(
      workspaceId: workspaceId,
      relPath: relPath,
      fetch: () async {
        final r = await client.call('fs.listDir', {
          'workspaceId': workspaceId,
          'path': absPath,
        }) as Map<String, dynamic>;
        return (r['entries'] as List)
            .cast<Map<String, dynamic>>()
            .map(DirEntry.fromJson)
            .toList();
      },
    );
  }

  Workspace? _workspaceById(String workspaceId) {
    for (final w in _active) {
      if (w.id == workspaceId) return w;
    }
    return null;
  }

  /// Translate a workspace-relative path to absolute. Empty / `'.'` /
  /// `'/'` resolve to the root itself. Defensive against accidental
  /// absolute input — if the caller already handed us an absolute path
  /// we pass it through (the backend's scope check will catch a real
  /// escape).
  String _resolveWorkspacePath(String root, String relPath) {
    if (relPath.isEmpty || relPath == '.' || relPath == '/') return root;
    if (relPath.startsWith('/')) return relPath;
    return root.endsWith('/') ? '$root$relPath' : '$root/$relPath';
  }

  /// Fetch a unified diff against HEAD for [path] in [workspaceId]. Returns
  /// the raw JSON response shape: `{kind: "text", hunks: [...]}` for normal
  /// diffs, `{kind: "binary"|"deleted"|"too-large", meta: {...}}` for the
  /// placeholder cases. The diff viewer screen consumes this directly.
  ///
  /// We return the raw map rather than a typed Diff object so the viewer
  /// (the one consumer in v0) can branch on `kind` without an
  /// intermediate model. If a second consumer appears, introduce a typed
  /// shape at that point.
  Future<Map<String, dynamic>> gitDiff({
    required String workspaceId,
    required String path,
  }) async {
    final r = await client.call('git.diff', {
      'workspaceId': workspaceId,
      'path': path,
    }) as Map<String, dynamic>;
    return r;
  }

  Future<List<DirEntry>> pickerListDir(String path) async {
    final r = await client.call('fs.listDir', {
      'path': path,
      'picker': true,
    }) as Map<String, dynamic>;
    return (r['entries'] as List)
        .cast<Map<String, dynamic>>()
        .map(DirEntry.fromJson)
        .toList();
  }

  Future<FileContent> readFile({
    required String workspaceId,
    required String path,
  }) async {
    final r = await client.call('fs.readFile', {
      'workspaceId': workspaceId,
      'path': path,
    }) as Map<String, dynamic>;
    final bytes = base64Decode(r['contentBase64'] as String);
    return FileContent(
      bytes: bytes,
      isBinary: (r['encoding'] as String) == 'binary',
    );
  }

  /// Fuzzy file-name search rooted at [workspaceId]'s workspace. The
  /// returned [FindFilesResult.matches] are sorted by score (high first);
  /// the caller renders them as-is. Out-of-scope or vanished workspaces
  /// resolve to an empty result rather than throwing — the UI's empty-
  /// state copy is the user-visible signal.
  Future<FindFilesResult> findFiles({
    required String workspaceId,
    required String query,
    int limit = 50,
    bool includeIgnored = false,
  }) async {
    final r = await client.call('workspace.findFiles', {
      'workspaceId': workspaceId,
      'query': query,
      'limit': limit,
      'includeIgnored': includeIgnored,
    }) as Map<String, dynamic>;
    return FindFilesResult.fromJson(r);
  }

  /// Test-only seam: directly populate `_active` + `_current` without
  /// going over the wire. Production code paths go through
  /// [refreshWorkspaces] / [openWorkspace]; widget tests need to render
  /// the Files tab with a known workspace, and faking BackendClient is
  /// heavier than this single setter.
  @visibleForTesting
  void debugSetActiveWorkspace(Workspace ws) {
    _active = [ws];
    _current = ws;
    notifyListeners();
  }

  /// Test-only seam: seed the terminal session list for [workspaceId]
  /// without going over the wire. The Terminal-tab widget tests need a
  /// known set of sessions to render rows against.
  @visibleForTesting
  void debugSeedTerminals(String workspaceId, List<TerminalSession> sessions) {
    _terminals.setSessionsForWorkspace(workspaceId, sessions);
  }

  /// Test-only seam: feed bytes through a session's preview pipeline.
  /// Production drives this via `terminal.data` notifications.
  @visibleForTesting
  void debugInjectTerminalOutput(String sessionId, List<int> bytes) {
    _terminals.debugInjectOutput(sessionId, bytes);
  }

  @override
  void dispose() {
    client.state.removeListener(_onConnState);
    client.lastError.removeListener(_onConnError);
    _terminals.removeListener(notifyListeners);
    _terminals.dispose();
    _workspacesModel.removeListener(notifyListeners);
    _workspacesModel.dispose();
    _notifications.removeListener(notifyListeners);
    _notifications.dispose();
    _plugins.removeListener(notifyListeners);
    _plugins.dispose();
    _uiPanels.removeListener(notifyListeners);
    _uiPanels.dispose();
    _notifSub?.cancel();
    super.dispose();
  }
}
