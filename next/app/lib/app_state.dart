// Central reactive state for the app.
//
// One [BackendClient], one mirror of the backend's workspace registry, plus
// per-PTY-session byte buffers so background-workspace terminals keep
// accruing output while we're focused elsewhere.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import 'backend_client.dart';
import 'models.dart';

class AppState extends ChangeNotifier {
  final BackendClient client;
  StreamSubscription<BackendNotification>? _notifSub;

  List<Workspace> _active = const [];
  List<String> _recents = const [];
  Workspace? _current;

  // Per-workspace terminal session lists (mirror of the backend state).
  final Map<String, List<TerminalSession>> _termsByWorkspace = {};

  // Per-session focused terminal session id within a workspace (UI state).
  final Map<String, String?> _focusedTermBySpace = {};

  // Live xterm Terminal objects keyed by sessionId. We create one lazily
  // on first sight of the session (or when the user focuses it) and keep
  // feeding it bytes from terminal.data notifications regardless of which
  // workspace is focused — so background terminals stay live.
  final Map<String, Terminal> _xterms = {};

  // Pending bytes per session that arrived before the Terminal was created.
  // Capped at ~256 KB per session to avoid runaway memory on chatty PTYs in
  // the background. Older bytes get dropped silently.
  static const int _backlogCap = 256 * 1024;
  final Map<String, BytesBuilder> _backlog = {};

  AppState({required this.client}) {
    client.state.addListener(_onConnState);
    _notifSub = client.notifications.listen(_onNotification);
  }

  // ---- Getters used by the UI ----

  List<Workspace> get activeWorkspaces => List.unmodifiable(_active);
  List<String> get recentRoots => List.unmodifiable(_recents);
  Workspace? get currentWorkspace => _current;

  /// Terminal sessions belonging to the currently-focused workspace.
  List<TerminalSession> get currentTerminals {
    final w = _current;
    if (w == null) return const [];
    return List.unmodifiable(_termsByWorkspace[w.id] ?? const []);
  }

  String? get focusedTerminalId {
    final w = _current;
    if (w == null) return null;
    return _focusedTermBySpace[w.id];
  }

  Terminal terminalFor(String sessionId) {
    return _xterms.putIfAbsent(sessionId, () {
      final t = Terminal(maxLines: 5000);
      // Replay any backlog accumulated before the Terminal existed.
      final pending = _backlog.remove(sessionId);
      if (pending != null && pending.length > 0) {
        t.write(utf8.decode(pending.takeBytes(), allowMalformed: true));
      }
      // Wire input back to the backend.
      t.onOutput = (data) {
        client.call('terminal.write', {
          'sessionId': sessionId,
          'dataBase64': base64Encode(utf8.encode(data)),
        });
      };
      t.onResize = (w, h, _, _) {
        client.call('terminal.resize', {
          'sessionId': sessionId,
          'cols': w,
          'rows': h,
        });
      };
      return t;
    });
  }

  // ---- Lifecycle / notifications ----

  void _onConnState() {
    if (client.state.value == BackendConnectionState.connected) {
      // Re-fetch workspace state on (re)connect; the backend doesn't
      // remember our previous focus across connections.
      unawaited(refreshWorkspaces());
    } else if (client.state.value == BackendConnectionState.disconnected ||
        client.state.value == BackendConnectionState.failed) {
      _active = const [];
      _current = null;
      _termsByWorkspace.clear();
      _focusedTermBySpace.clear();
      // Keep recents — they're useful when reconnecting.
      notifyListeners();
    }
  }

  Future<void> _onNotification(BackendNotification n) async {
    switch (n.method) {
      case 'terminal.data':
        _onTerminalData(n.params as Map<String, dynamic>);
        break;
      case 'terminal.exit':
        await _onTerminalExit(n.params as Map<String, dynamic>);
        break;
      case 'workspace.closed':
        final id = (n.params as Map<String, dynamic>)['id'] as String;
        _onWorkspaceClosed(id);
        break;
      default:
        // Ignore unknown notifications (forward-compat).
        break;
    }
  }

  void _onTerminalData(Map<String, dynamic> p) {
    final sessionId = p['sessionId'] as String;
    final dataB64 = p['dataBase64'] as String;
    final bytes = base64Decode(dataB64);
    final term = _xterms[sessionId];
    if (term != null) {
      term.write(utf8.decode(bytes, allowMalformed: true));
      return;
    }
    // Buffer for later. Cap total to _backlogCap.
    final b = _backlog.putIfAbsent(sessionId, BytesBuilder.new);
    b.add(bytes);
    if (b.length > _backlogCap) {
      // Keep only the last _backlogCap bytes.
      final all = b.takeBytes();
      final keep = all.sublist(all.length - _backlogCap);
      b.add(keep);
    }
  }

  Future<void> _onTerminalExit(Map<String, dynamic> p) async {
    final sessionId = p['sessionId'] as String;
    final wsId = p['workspaceId'] as String?;
    // Tear down local mirror.
    _xterms.remove(sessionId);
    _backlog.remove(sessionId);
    if (wsId != null) {
      final list = _termsByWorkspace[wsId];
      if (list != null) {
        list.removeWhere((t) => t.id == sessionId);
      }
      if (_focusedTermBySpace[wsId] == sessionId) {
        _focusedTermBySpace[wsId] = list != null && list.isNotEmpty
            ? list.first.id
            : null;
      }
    } else {
      // Fall back to searching all workspaces — exit may arrive after the
      // workspace got closed locally.
      for (final entry in _termsByWorkspace.entries) {
        entry.value.removeWhere((t) => t.id == sessionId);
      }
    }
    notifyListeners();
  }

  void _onWorkspaceClosed(String id) {
    _active = _active.where((w) => w.id != id).toList();
    _termsByWorkspace.remove(id);
    _focusedTermBySpace.remove(id);
    if (_current?.id == id) {
      _current = _active.isNotEmpty ? _active.first : null;
    }
    notifyListeners();
  }

  // ---- Public actions ----

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
      // Best-effort: refresh terminal lists for active workspaces.
      _termsByWorkspace.clear();
      for (final w in _active) {
        final tres = await client.call(
          'terminal.list',
          {'workspaceId': w.id},
        ) as Map<String, dynamic>;
        _termsByWorkspace[w.id] = (tres['sessions'] as List)
            .cast<Map<String, dynamic>>()
            .map(TerminalSession.fromJson)
            .toList();
      }
      notifyListeners();
    } catch (_) {
      // Connection probably went away mid-call; _onConnState handles cleanup.
    }
  }

  Future<Workspace?> openWorkspace(String root) async {
    try {
      final r = await client.call('workspace.open', {'root': root})
          as Map<String, dynamic>;
      final ws = Workspace.fromJson(r['workspace'] as Map<String, dynamic>);
      if (!_active.any((w) => w.id == ws.id)) {
        _active = [..._active, ws];
      }
      _termsByWorkspace.putIfAbsent(ws.id, () => []);
      _current = ws;
      if (!_recents.contains(root)) {
        _recents = [root, ..._recents];
      } else {
        _recents = [root, ..._recents.where((r) => r != root)];
      }
      notifyListeners();
      return ws;
    } catch (e) {
      return null;
    }
  }

  Future<void> activateWorkspace(String id) async {
    try {
      final r = await client.call('workspace.activate', {'id': id})
          as Map<String, dynamic>;
      _current = Workspace.fromJson(r['workspace'] as Map<String, dynamic>);
      notifyListeners();
    } catch (_) {
      // Stale id; refresh.
      await refreshWorkspaces();
    }
  }

  Future<void> closeWorkspace(String id) async {
    try {
      await client.call('workspace.close', {'id': id});
      // The backend echoes workspace.closed; _onWorkspaceClosed updates state.
    } catch (_) {
      await refreshWorkspaces();
    }
  }

  Future<TerminalSession?> createTerminal({
    required String workspaceId,
    required int cols,
    required int rows,
  }) async {
    try {
      final r = await client.call('terminal.create', {
        'workspaceId': workspaceId,
        'cols': cols,
        'rows': rows,
      }) as Map<String, dynamic>;
      final sid = r['sessionId'] as String;
      final wsId = r['workspaceId'] as String;
      final session = TerminalSession(
        id: sid,
        workspaceId: wsId,
        cols: cols,
        rows: rows,
        cwd: _active.firstWhere((w) => w.id == wsId).root,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      final list = _termsByWorkspace.putIfAbsent(wsId, () => []);
      list.add(session);
      _focusedTermBySpace[wsId] = sid;
      notifyListeners();
      return session;
    } catch (_) {
      return null;
    }
  }

  Future<void> disposeTerminal(String sessionId) async {
    try {
      await client.call('terminal.dispose', {'sessionId': sessionId});
      // terminal.exit notification will arrive and trigger cleanup.
    } catch (_) {
      // Already gone; ignore.
    }
  }

  void focusTerminal(String sessionId) {
    final w = _current;
    if (w == null) return;
    _focusedTermBySpace[w.id] = sessionId;
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
    _notifSub?.cancel();
    super.dispose();
  }
}
