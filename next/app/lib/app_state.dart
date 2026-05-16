// Central reactive state for the app.
//
// One [BackendClient], one mirror of the backend's workspace registry, plus
// per-PTY-session byte buffers so background-workspace terminals keep
// accruing output while we're focused elsewhere.
//
// Session persistence (see docs/design/mobile-code-platform.md §5.1):
// backend PTYs survive client disconnects. On reconnect we fetch each live
// session's scrollback via `terminal.history` and replay it into a freshly-
// built Terminal before resuming live `terminal.data` notifications. Each
// chunk carries a monotonic `seqEnd` so duplicates queued during the
// reconnect window are dropped instead of re-rendered.

import 'dart:async';
import 'dart:convert';

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

  // Live xterm Terminal objects keyed by sessionId. We create one lazily on
  // first focus (or when we replay history on reconnect) and keep feeding it
  // bytes from terminal.data notifications regardless of which workspace is
  // focused — so background terminals stay live.
  final Map<String, Terminal> _xterms = {};

  // Monotonic generation per sessionId. Bumped whenever the Terminal in
  // `_xterms` is replaced (e.g. after a reconnect history replay). The
  // terminal_tab widget composes its ValueKey from sessionId + generation so
  // the TerminalView rebuilds when the underlying Terminal swaps.
  final Map<String, int> _xtermGen = {};

  // Last seqEnd actually written into the xterm for a session. Used to drop
  // duplicate chunks that arrive after `terminal.history` (which captures
  // bytes up to scrollbackOffsetEnd; any live chunk with seqEnd <= that has
  // already been rendered as part of the replay).
  final Map<String, int> _lastWrittenSeq = {};

  // Pending chunks per session that arrived before the Terminal was created.
  // Each entry is (bytes, seqEnd) so we can dedupe against history offsets
  // on flush. Capped to ~256 KB per session by total byte count.
  static const int _backlogCap = 256 * 1024;
  final Map<String, List<_BacklogChunk>> _backlog = {};
  final Map<String, int> _backlogBytes = {};

  AppState({required this.client}) {
    client.state.addListener(_onConnState);
    _notifSub = client.notifications.listen(_onNotification);
  }

  // ---- Getters used by the UI ----

  List<Workspace> get activeWorkspaces => List.unmodifiable(_active);
  List<String> get recentRoots => List.unmodifiable(_recents);
  Workspace? get currentWorkspace => _current;

  /// Backend-reported $HOME (or "/" on older backends). The picker starts
  /// here instead of the phone's $HOME, which has no meaning to the backend.
  String get backendDefaultCwd {
    final c = client.defaultCwd;
    return c.isEmpty ? '/' : c;
  }

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

  /// Generation counter for a session's underlying Terminal. The UI uses
  /// this in its ValueKey so the TerminalView force-rebuilds when we swap
  /// the Terminal (e.g. after a reconnect history replay).
  int terminalGenerationFor(String sessionId) =>
      _xtermGen[sessionId] ?? 0;

  Terminal terminalFor(String sessionId) {
    final existing = _xterms[sessionId];
    if (existing != null) return existing;
    final t = _buildTerminal(sessionId);
    _xterms[sessionId] = t;
    // Flush any backlog that accumulated before the Terminal existed.
    _flushBacklog(sessionId, t);
    return t;
  }

  Terminal _buildTerminal(String sessionId) {
    final t = Terminal(maxLines: 5000);
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
  }

  /// Drain `_backlog[sessionId]` into the supplied Terminal, respecting the
  /// `_lastWrittenSeq` watermark so we don't re-render bytes already covered
  /// by a history replay.
  void _flushBacklog(String sessionId, Terminal term) {
    final pending = _backlog.remove(sessionId);
    _backlogBytes.remove(sessionId);
    if (pending == null || pending.isEmpty) return;
    final lastSeq = _lastWrittenSeq[sessionId] ?? 0;
    int newLast = lastSeq;
    for (final chunk in pending) {
      // Whole chunk already covered by history.
      if (chunk.seqEnd <= lastSeq) continue;
      final chunkSeqStart = chunk.seqEnd - chunk.bytes.length;
      Uint8List bytes = chunk.bytes;
      if (chunkSeqStart < lastSeq) {
        // Partial overlap — keep only the tail past the watermark.
        final skip = lastSeq - chunkSeqStart;
        bytes = chunk.bytes.sublist(skip);
      }
      if (bytes.isNotEmpty) {
        term.write(utf8.decode(bytes, allowMalformed: true));
      }
      newLast = chunk.seqEnd;
    }
    if (newLast > lastSeq) _lastWrittenSeq[sessionId] = newLast;
  }

  // ---- Lifecycle / notifications ----

  void _onConnState() {
    final s = client.state.value;
    if (s == BackendConnectionState.connected) {
      // Re-fetch workspace + terminal state. With persistent backend state
      // the workspaces and sessions are still there; refreshWorkspaces will
      // replay each session's scrollback so the UI shows continuity.
      unawaited(refreshWorkspaces());
      return;
    }
    if (s == BackendConnectionState.connecting) {
      // First connect (no prior session). Nothing to clear yet — the
      // upcoming `connected` transition will populate fresh.
      return;
    }
    // Any non-connected, non-initial state: the client's view of sessionIds
    // is stale until we reconfirm with the backend. The IDs themselves may
    // still be alive on the backend (that's the whole point of persistence),
    // but we tear down the local Terminal objects so the reconnect replay
    // path can rebuild them fresh. _lastWrittenSeq is cleared too because
    // those offsets are tied to the previous in-memory Terminal lifetime.
    _active = const [];
    _current = null;
    _termsByWorkspace.clear();
    _focusedTermBySpace.clear();
    _xterms.clear();
    _xtermGen.clear();
    _lastWrittenSeq.clear();
    _backlog.clear();
    _backlogBytes.clear();
    // Keep recents — they're useful when reconnecting.
    notifyListeners();
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
    final bytes = Uint8List.fromList(base64Decode(dataB64));
    // seqEnd is required by the post-P1.5 backend. Older backends without it
    // will emit null/undefined; we tolerate that by falling back to a running
    // counter derived from chunk length so dedupe still does *something*
    // sane.
    final seqEnd = (p['seqEnd'] as num?)?.toInt() ??
        ((_lastWrittenSeq[sessionId] ?? 0) +
            (_backlogBytes[sessionId] ?? 0) +
            bytes.length);

    final term = _xterms[sessionId];
    if (term != null) {
      final lastSeq = _lastWrittenSeq[sessionId] ?? 0;
      if (seqEnd <= lastSeq) {
        // Already rendered as part of a history replay. Drop.
        return;
      }
      final chunkSeqStart = seqEnd - bytes.length;
      Uint8List toWrite = bytes;
      if (chunkSeqStart < lastSeq) {
        // Partial overlap with history — keep the tail past the watermark.
        final skip = lastSeq - chunkSeqStart;
        toWrite = bytes.sublist(skip);
      }
      if (toWrite.isNotEmpty) {
        term.write(utf8.decode(toWrite, allowMalformed: true));
      }
      _lastWrittenSeq[sessionId] = seqEnd;
      return;
    }
    // No Terminal yet — buffer with the seqEnd attached so we can dedupe on flush.
    final list = _backlog.putIfAbsent(sessionId, () => <_BacklogChunk>[]);
    list.add(_BacklogChunk(bytes: bytes, seqEnd: seqEnd));
    _backlogBytes.update(sessionId, (v) => v + bytes.length,
        ifAbsent: () => bytes.length);
    // Cap total queued bytes per session.
    while ((_backlogBytes[sessionId] ?? 0) > _backlogCap && list.length > 1) {
      final head = list.removeAt(0);
      _backlogBytes[sessionId] =
          (_backlogBytes[sessionId] ?? 0) - head.bytes.length;
    }
    // Edge case: a single chunk exceeds the cap. Trim its head in place.
    if (list.length == 1 && list.first.bytes.length > _backlogCap) {
      final head = list.first;
      final trimmed = head.bytes.sublist(head.bytes.length - _backlogCap);
      list[0] = _BacklogChunk(bytes: trimmed, seqEnd: head.seqEnd);
      _backlogBytes[sessionId] = trimmed.length;
    }
  }

  Future<void> _onTerminalExit(Map<String, dynamic> p) async {
    final sessionId = p['sessionId'] as String;
    final wsId = p['workspaceId'] as String?;
    _xterms.remove(sessionId);
    _xtermGen.remove(sessionId);
    _lastWrittenSeq.remove(sessionId);
    _backlog.remove(sessionId);
    _backlogBytes.remove(sessionId);
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
      // Workspace already closed locally — search all.
      for (final entry in _termsByWorkspace.entries) {
        entry.value.removeWhere((t) => t.id == sessionId);
      }
    }
    notifyListeners();
  }

  void _onWorkspaceClosed(String id) {
    _active = _active.where((w) => w.id != id).toList();
    final sessions = _termsByWorkspace.remove(id) ?? const [];
    _focusedTermBySpace.remove(id);
    // Tear down any per-session local state that was tied to this workspace.
    for (final s in sessions) {
      _xterms.remove(s.id);
      _xtermGen.remove(s.id);
      _lastWrittenSeq.remove(s.id);
      _backlog.remove(s.id);
      _backlogBytes.remove(s.id);
    }
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
      _termsByWorkspace.clear();
      for (final w in _active) {
        final tres = await client.call(
          'terminal.list',
          {'workspaceId': w.id},
        ) as Map<String, dynamic>;
        final sessions = (tres['sessions'] as List)
            .cast<Map<String, dynamic>>()
            .map(TerminalSession.fromJson)
            .toList();
        _termsByWorkspace[w.id] = sessions;
        // Replay each session's scrollback. Order matters: we must finish
        // the replay (and set _lastWrittenSeq) BEFORE any live terminal.data
        // notifications race in. Notifications observed while the call is
        // in flight land in _backlog (because _xterms[sid] is still empty
        // at that point) and get drained when we finally install the
        // Terminal below. That keeps the dedupe protocol watertight.
        for (final s in sessions) {
          await _replayHistory(s.id);
        }
        // Restore focus so the Terminal tab shows a session immediately on
        // reconnect instead of the "Creating terminal…" placeholder. The
        // disconnect path clears _focusedTermBySpace; without this step the
        // user would have to tap a chip after every drop.
        if (sessions.isNotEmpty) {
          _focusedTermBySpace[w.id] ??= sessions.first.id;
        }
      }
      notifyListeners();
    } catch (_) {
      // Connection probably went away mid-call; _onConnState handles cleanup.
    }
  }

  Future<void> _replayHistory(String sessionId) async {
    Map<String, dynamic> hist;
    try {
      hist = await client.call('terminal.history', {
        'sessionId': sessionId,
      }) as Map<String, dynamic>;
    } catch (_) {
      // Older backends won't implement terminal.history. Fall back to live-
      // only rendering — set the watermark to 0 so the dedupe path is a
      // no-op and every incoming chunk just gets written.
      _lastWrittenSeq[sessionId] = 0;
      _xtermGen[sessionId] = (_xtermGen[sessionId] ?? 0) + 1;
      _xterms[sessionId] = _buildTerminal(sessionId);
      return;
    }
    final bytes = base64Decode(hist['scrollbackBase64'] as String);
    final offsetEnd = (hist['scrollbackOffsetEnd'] as num).toInt();

    final term = _buildTerminal(sessionId);
    if (bytes.isNotEmpty) {
      term.write(utf8.decode(bytes, allowMalformed: true));
    }
    // Replace any previous Terminal for this session and bump the generation
    // so the UI rebuilds the TerminalView (it keys on sessionId + gen).
    _xterms[sessionId] = term;
    _xtermGen[sessionId] = (_xtermGen[sessionId] ?? 0) + 1;
    _lastWrittenSeq[sessionId] = offsetEnd;
    // Drain anything that arrived during the in-flight call. Same dedupe
    // logic as live notifications.
    _flushBacklog(sessionId, term);
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
      // Fresh session — no history to fetch.
      _lastWrittenSeq[sid] = 0;
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

class _BacklogChunk {
  final Uint8List bytes;
  final int seqEnd;
  const _BacklogChunk({required this.bytes, required this.seqEnd});
}
