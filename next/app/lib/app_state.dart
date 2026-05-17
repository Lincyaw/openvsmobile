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
import 'services/ssh_bootstrap.dart';
import 'state/terminals_notifier.dart';

class AppState extends ChangeNotifier {
  final BackendClient client;
  late final TerminalsNotifier _terminals;
  StreamSubscription<BackendNotification>? _notifSub;

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

  AppState({required this.client}) {
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
      default:
        // Ignore unknown notifications (forward-compat).
        break;
    }
  }

  void _onWorkspaceClosed(String id) {
    _active = _active.where((w) => w.id != id).toList();
    _fileTreeByWorkspace.remove(id);
    _terminals.onWorkspaceClosed(id);
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
      final entries = await listDir(path: node.path, workspaceId: workspaceId);
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

  Future<List<DirEntry>> listDir({
    required String path,
    required String workspaceId,
  }) async {
    final r = await client.call('fs.listDir', {
      'workspaceId': workspaceId,
      'path': path,
    }) as Map<String, dynamic>;
    return (r['entries'] as List)
        .cast<Map<String, dynamic>>()
        .map(DirEntry.fromJson)
        .toList();
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

  @override
  void dispose() {
    client.state.removeListener(_onConnState);
    client.lastError.removeListener(_onConnError);
    _terminals.removeListener(notifyListeners);
    _terminals.dispose();
    _notifSub?.cancel();
    super.dispose();
  }
}
