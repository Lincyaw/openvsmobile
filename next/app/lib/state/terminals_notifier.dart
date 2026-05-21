// PTY-side state: the per-workspace session lists, the focused session per
// workspace, live xterm.dart Terminal objects, and the seqEnd / backlog
// machinery that keeps history-replay vs. live-stream watertight on
// reconnect. Composed as a child of AppState (see docs/conventions.md §2 —
// "If `AppState` outgrows one file, split it into composed sub-notifiers").
//
// Why it lives apart:
//   * AppState was ~800 lines once file-tree + picker + bootstrap state
//     piled on; reviewers asked for a clean seam.
//   * This class is the natural cleavage: every method touches sessionId-
//     keyed Maps and nothing about workspaces / files / picker / settings.
//   * AppState owns one instance, listens to it, and re-broadcasts its
//     changes via `notifyListeners`. The widget-facing surface stays
//     "subscribe to AppState"; this child is invisible to screens.
//
// Session persistence (docs/design/mobile-code-platform.md §5.1): backend
// PTYs survive client disconnects. On reconnect we fetch each live
// session's scrollback via `terminal.history` and replay it into a fresh
// Terminal before resuming live `terminal.data` notifications. Each chunk
// carries a monotonic `seqEnd` so duplicates queued during the reconnect
// window are dropped instead of re-rendered.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../backend_client.dart';
import '../models.dart';

/// Reports a user-facing operation error upward. AppState surfaces it via
/// SnackBar in the standard way.
typedef ReportOperationError = void Function(String message);

/// Resolve a workspace id to its root path, or null if the workspace has
/// since been closed. Used when a fresh terminal needs a cwd.
typedef WorkspaceRootLookup = String? Function(String workspaceId);

/// Resolve the currently-focused workspace id, or null if none. Used by the
/// view helpers `currentTerminals` / `focusedTerminalId` so the widget tree
/// can ask "what's relevant right now" without threading the workspace id
/// through every getter.
typedef CurrentWorkspaceIdLookup = String? Function();

class TerminalsNotifier extends ChangeNotifier {
  final BackendClient _client;
  final WorkspaceRootLookup _rootOf;
  final CurrentWorkspaceIdLookup _currentWorkspaceId;
  final ReportOperationError _reportError;

  TerminalsNotifier({
    required BackendClient client,
    required WorkspaceRootLookup rootOf,
    required CurrentWorkspaceIdLookup currentWorkspaceId,
    required ReportOperationError reportError,
  })  : _client = client,
        _rootOf = rootOf,
        _currentWorkspaceId = currentWorkspaceId,
        _reportError = reportError;

  /// Bumps on every per-session preview-buffer mutation. The Terminal-tab
  /// session list listens to this for cheap repaints without going through
  /// AppState's broader notifyListeners cascade (which would rebuild every
  /// other tab on every PTY byte). Repaints are batched within a frame
  /// because the ValueNotifier only fires distinct values, but we increment
  /// per chunk so a test pumping a single frame after one chunk sees the
  /// update.
  final ValueNotifier<int> previewVersion = ValueNotifier<int>(0);

  // Per-workspace terminal session lists (mirror of the backend state).
  final Map<String, List<TerminalSession>> _termsByWorkspace = {};

  // Per-workspace focused session id. Workspace-scoped UI state — belongs
  // here rather than in widget state because it needs to survive a tab
  // switch and a screen rebuild.
  final Map<String, String?> _focusedTermBySpace = {};

  // Live xterm Terminal objects keyed by sessionId. Created lazily on first
  // focus (or when we replay history on reconnect) and kept fed by every
  // terminal.data notification regardless of which workspace is focused —
  // so background terminals stay live.
  final Map<String, Terminal> _xterms = {};

  // Monotonic generation per sessionId. Bumped whenever the Terminal in
  // `_xterms` is replaced (e.g. after a reconnect history replay). The
  // terminal_tab widget composes its ValueKey from sessionId + generation
  // so the TerminalView rebuilds when the underlying Terminal swaps.
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

  // Per-session preview ring buffer. Holds the last ~512 bytes of raw output
  // so the session-list "last message" preview can ANSI-strip and pick the
  // tail line. The xterm Terminal owns its own scrollback; this buffer feeds
  // ONLY the list-view preview (issue #63 implementation note: "keep a small
  // ring buffer ... sample the tail").
  static const int _previewBufferCap = 512;
  final Map<String, Uint8List> _previewBuffer = {};
  final Map<String, int> _previewLastDataAt = {};

  // ---- Getters ----

  /// Terminal sessions belonging to the currently-focused workspace.
  List<TerminalSession> get currentTerminals {
    final wsId = _currentWorkspaceId();
    if (wsId == null) return const [];
    return List.unmodifiable(_termsByWorkspace[wsId] ?? const []);
  }

  String? get focusedTerminalId {
    final wsId = _currentWorkspaceId();
    if (wsId == null) return null;
    return _focusedTermBySpace[wsId];
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

  /// Last-line preview for [sessionId]'s session-list row. Returns null when
  /// the session has produced no output yet. The shape is intentionally
  /// minimal: the widget formats `text` (already ANSI-stripped and
  /// truncated) and `lastDataAt` (epoch ms, last byte arrival) for display.
  TerminalPreview previewFor(String sessionId) {
    final ts = _previewLastDataAt[sessionId];
    // Prefer the live xterm screen buffer when we have one — full-screen
    // TUIs like zellij / tmux / claude repaint their entire viewport on
    // every frame, so the raw byte stream is just a slurry of cursor
    // positioning + status-bar chrome. The interpreted buffer holds the
    // actual rendered cells, which is what the user sees.
    final term = _xterms[sessionId];
    if (term != null) {
      final fromBuffer = extractPreviewFromTerminal(term);
      if (fromBuffer != null) {
        return TerminalPreview(text: fromBuffer, lastDataAt: ts);
      }
    }
    // Fallback for sessions that haven't materialised a Terminal yet
    // (e.g. preview row visible before the user has focused the
    // session). Byte-stream stripping is best-effort.
    final buffer = _previewBuffer[sessionId];
    final text = buffer == null ? null : extractPreviewLine(buffer);
    return TerminalPreview(text: text, lastDataAt: ts);
  }

  // ---- Snapshot installation (called from AppState.refreshWorkspaces) ----

  /// Replace the cached session list for [workspaceId]. Used after a
  /// successful `terminal.list` RPC during reconnect. Caller is responsible
  /// for invoking [replayHistory] for each session afterward.
  void setSessionsForWorkspace(
    String workspaceId,
    List<TerminalSession> sessions,
  ) {
    _termsByWorkspace[workspaceId] = sessions;
    // Restore focus so the Terminal tab shows a session immediately on
    // reconnect instead of the "Creating terminal…" placeholder. Without
    // this step the user would have to tap a chip after every drop.
    if (sessions.isNotEmpty) {
      _focusedTermBySpace[workspaceId] ??= sessions.first.id;
    }
    refreshTerminalSubscription();
    notifyListeners();
  }

  /// Replay the backend's scrollback for [sessionId] into a freshly-built
  /// Terminal. Drops any backlog chunks already covered by the replay (via
  /// the seqEnd watermark). Tolerant of older backends that don't implement
  /// `terminal.history`.
  Future<void> replayHistory(String sessionId) async {
    Map<String, dynamic> hist;
    try {
      hist = await _client.call('terminal.history', {
        'sessionId': sessionId,
      }) as Map<String, dynamic>;
    } catch (_) {
      // Older backends won't implement terminal.history. Fall back to live-
      // only rendering — set the watermark to 0 so the dedupe path is a
      // no-op and every incoming chunk just gets written.
      _lastWrittenSeq[sessionId] = 0;
      _xtermGen[sessionId] = (_xtermGen[sessionId] ?? 0) + 1;
      _xterms[sessionId] = _buildTerminal(sessionId);
      notifyListeners();
      return;
    }
    final bytes = base64Decode(hist['scrollbackBase64'] as String);
    final offsetEnd = (hist['scrollbackOffsetEnd'] as num).toInt();

    final term = _buildTerminal(sessionId);
    if (bytes.isNotEmpty) {
      term.write(utf8.decode(bytes, allowMalformed: true));
      // Seed the preview from history so the list-view row shows the
      // session's last output immediately after a reconnect-replay,
      // without waiting for a fresh live chunk.
      _appendPreview(sessionId, Uint8List.fromList(bytes));
    }
    // Replace any previous Terminal for this session and bump the generation
    // so the UI rebuilds the TerminalView (it keys on sessionId + gen).
    _xterms[sessionId] = term;
    _xtermGen[sessionId] = (_xtermGen[sessionId] ?? 0) + 1;
    _lastWrittenSeq[sessionId] = offsetEnd;
    // Drain anything that arrived during the in-flight call. Same dedupe
    // logic as live notifications.
    _flushBacklog(sessionId, term);
    notifyListeners();
  }

  /// Tell the backend which terminal ids this connection cares about. The
  /// backend defaults to subscribe-all for a connection that never calls
  /// `terminal.subscribe`; that's fine for a single-client setup but in a
  /// phone+laptop pairing it means each peer receives the other's PTY
  /// frames. Scoping to our own known sessions stops the leak.
  ///
  /// Fire-and-forget. A failure on the wire (e.g. mid-disconnect) just
  /// means we stay on the previous subscription — when the connection
  /// settles the next call rectifies it. Called from AppState on
  /// reconnect, and locally on every mutation of the known-id set.
  void refreshTerminalSubscription() {
    final ids = <String>[
      for (final list in _termsByWorkspace.values)
        for (final t in list) t.id,
    ];
    // Backend semantic: `terminal.subscribe` with an empty/omitted `ids` is
    // explicit subscribe-ALL (legacy compatibility). We want "subscribe to
    // exactly my zero sessions" in that case, so map empty → unsubscribe.
    final method = ids.isEmpty ? 'terminal.unsubscribe' : 'terminal.subscribe';
    final params = ids.isEmpty ? <String, dynamic>{} : {'ids': ids};
    _client.call(method, params).catchError(
      (Object e) {
        debugPrint('TerminalsNotifier.refreshTerminalSubscription failed: $e');
        return <String, dynamic>{};
      },
    );
  }

  // ---- Public actions ----

  /// Create a fresh PTY session in [workspaceId]. Returns the new session,
  /// or null if the RPC failed (the error is reported to AppState).
  Future<TerminalSession?> createTerminal({
    required String workspaceId,
    required int cols,
    required int rows,
  }) async {
    try {
      final r = await _client.call('terminal.create', {
        'workspaceId': workspaceId,
        'cols': cols,
        'rows': rows,
      }) as Map<String, dynamic>;
      final sid = r['sessionId'] as String;
      final wsId = r['workspaceId'] as String;
      final root = _rootOf(wsId);
      if (root == null) {
        // The workspace was closed between us calling and the response
        // arriving — bail rather than fabricating a cwd. The notification
        // path will surface the close via terminal.exit when it lands.
        _reportError('Could not create terminal: workspace gone');
        return null;
      }
      final session = TerminalSession(
        id: sid,
        workspaceId: wsId,
        cols: cols,
        rows: rows,
        cwd: root,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      final list = _termsByWorkspace.putIfAbsent(wsId, () => []);
      list.add(session);
      _focusedTermBySpace[wsId] = sid;
      // Fresh session — no history to fetch.
      _lastWrittenSeq[sid] = 0;
      refreshTerminalSubscription();
      notifyListeners();
      return session;
    } catch (e) {
      _reportError('Could not create terminal: $e');
      return null;
    }
  }

  /// List external zellij sessions on the backend host. Empty when the
  /// host has no multiplexer; that's normal, not an error. Errors during
  /// the RPC bubble up so the caller (the discovery sheet) can show a
  /// retry affordance.
  Future<List<ExternalTerminalSession>> listExternalSessions() async {
    final r = await _client.call('terminal.listExternalSessions', const {})
        as Map<String, dynamic>;
    final raw = (r['sessions'] as List?) ?? const [];
    return raw
        .cast<Map<String, dynamic>>()
        .map(ExternalTerminalSession.fromJson)
        .toList(growable: false);
  }

  /// Adopt an external zellij session into [workspaceId] at the given size.
  /// Returns the new TerminalSession; errors bubble so the caller can
  /// surface them. The session id is fresh; the zellij session NAME is
  /// preserved (no `ovsm-` prefix forced).
  Future<TerminalSession?> adoptExternalSession({
    required String workspaceId,
    required String sessionName,
    required int cols,
    required int rows,
  }) async {
    try {
      final r = await _client.call('terminal.adoptExternalSession', {
        'workspaceId': workspaceId,
        'sessionName': sessionName,
        'cols': cols,
        'rows': rows,
      }) as Map<String, dynamic>;
      final sid = r['sessionId'] as String;
      final wsId = r['workspaceId'] as String;
      final root = _rootOf(wsId);
      if (root == null) {
        _reportError('Could not adopt session: workspace gone');
        return null;
      }
      final session = TerminalSession(
        id: sid,
        workspaceId: wsId,
        cols: cols,
        rows: rows,
        cwd: (r['cwd'] as String?) ?? root,
        createdAt: (r['createdAt'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
      );
      final list = _termsByWorkspace.putIfAbsent(wsId, () => []);
      list.add(session);
      _focusedTermBySpace[wsId] = sid;
      _lastWrittenSeq[sid] = 0;
      refreshTerminalSubscription();
      notifyListeners();
      return session;
    } catch (e) {
      _reportError('Could not adopt session: $e');
      return null;
    }
  }

  /// Tell the backend to kill [sessionId]'s PTY. Local cleanup is driven by
  /// the resulting `terminal.exit` notification, not by this call.
  Future<void> disposeTerminal(
    String sessionId, {
    required BackendConnectionState connectionState,
  }) async {
    try {
      await _client.call('terminal.dispose', {'sessionId': sessionId});
      // terminal.exit notification will arrive and trigger cleanup.
    } catch (e) {
      // Mid-call disconnect: the UI already shows the connection banner,
      // so adding a SnackBar would just be noise. Real RPC errors
      // (e.g. "no such session" if it was already gone) we report so the
      // user understands their tap didn't visibly do anything.
      if (connectionState != BackendConnectionState.connected) {
        debugPrint(
          'TerminalsNotifier.disposeTerminal($sessionId) dropped: '
          'disconnected mid-call ($e)',
        );
        return;
      }
      _reportError('Could not close terminal: $e');
    }
  }

  /// Set the focused session for the currently-active workspace.
  void focusTerminal(String sessionId) {
    // Capture the current workspace id once: this method runs synchronously
    // but the lookup is via callback into AppState, which could in
    // principle change between two reads. One read = one decision.
    final wsId = _currentWorkspaceId();
    if (wsId == null) return;
    _focusedTermBySpace[wsId] = sessionId;
    notifyListeners();
  }

  // ---- Notification handlers (called from AppState._onNotification) ----

  void onTerminalData(Map<String, dynamic> p) {
    final sessionId = p['sessionId'] as String;
    final dataB64 = p['dataBase64'] as String;
    final bytes = Uint8List.fromList(base64Decode(dataB64));
    _appendPreview(sessionId, bytes);
    // First data after a detach means the lazy-reattach succeeded.
    // Clear the flag so the chip stops showing "(detached)".
    _clearDetachedIfSet(sessionId);
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

  /// Handler for the backend's `terminal.detached` push. Mark the matching
  /// session's chip as detached without pruning it — the user's next
  /// interaction (write/resize/history) triggers the backend's lazy
  /// reattach, which clears the flag via the first `terminal.data`.
  void onTerminalDetached(Map<String, dynamic> p) {
    final sessionId = p['sessionId'] as String?;
    if (sessionId == null) return;
    for (final list in _termsByWorkspace.values) {
      for (var i = 0; i < list.length; i++) {
        if (list[i].id == sessionId) {
          if (!list[i].detached) {
            list[i] = list[i].copyWith(detached: true);
          }
        }
      }
    }
    notifyListeners();
  }

  void _clearDetachedIfSet(String sessionId) {
    var changed = false;
    for (final list in _termsByWorkspace.values) {
      for (var i = 0; i < list.length; i++) {
        if (list[i].id == sessionId && list[i].detached) {
          list[i] = list[i].copyWith(detached: false);
          changed = true;
        }
      }
    }
    if (changed) notifyListeners();
  }

  void onTerminalExit(Map<String, dynamic> p) {
    final sessionId = p['sessionId'] as String;
    final wsId = p['workspaceId'] as String?;
    _xterms.remove(sessionId);
    _xtermGen.remove(sessionId);
    _lastWrittenSeq.remove(sessionId);
    _backlog.remove(sessionId);
    _backlogBytes.remove(sessionId);
    _previewBuffer.remove(sessionId);
    _previewLastDataAt.remove(sessionId);
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
    refreshTerminalSubscription();
    notifyListeners();
  }

  /// Drop every piece of state tied to [workspaceId] — sessions, focus,
  /// per-session Terminals and seq watermarks. Called when AppState
  /// processes a `workspace.closed` notification.
  void onWorkspaceClosed(String workspaceId) {
    final sessions = _termsByWorkspace.remove(workspaceId) ?? const [];
    _focusedTermBySpace.remove(workspaceId);
    for (final s in sessions) {
      _xterms.remove(s.id);
      _xtermGen.remove(s.id);
      _lastWrittenSeq.remove(s.id);
      _backlog.remove(s.id);
      _backlogBytes.remove(s.id);
      _previewBuffer.remove(s.id);
      _previewLastDataAt.remove(s.id);
    }
    notifyListeners();
  }

  // ---- Internals ----

  Terminal _buildTerminal(String sessionId) {
    final t = Terminal(maxLines: 5000);
    t.onOutput = (data) {
      // Fire-and-forget. If the socket dropped between callback and send,
      // the call future rejects with "not connected"; we swallow it here
      // because the connection banner is the user-visible signal and the
      // unhandled rejection would otherwise spam the log.
      _client
          .call('terminal.write', {
            'sessionId': sessionId,
            'dataBase64': base64Encode(utf8.encode(data)),
          })
          .catchError((Object e) {
            debugPrint('terminal.write($sessionId) failed: $e');
          });
    };
    t.onResize = (w, h, _, _) {
      _client
          .call('terminal.resize', {
            'sessionId': sessionId,
            'cols': w,
            'rows': h,
          })
          .catchError((Object e) {
            debugPrint('terminal.resize($sessionId) failed: $e');
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

  /// Append [bytes] to the per-session preview ring buffer, trim to the cap,
  /// stamp the last-data clock, and bump `previewVersion` so list rows
  /// repaint. Kept separate from the xterm write path because preview
  /// updates fan out to a dedicated listenable — they must not piggyback on
  /// the broader AppState notify cascade.
  void _appendPreview(String sessionId, Uint8List bytes) {
    if (bytes.isEmpty) return;
    final existing = _previewBuffer[sessionId];
    Uint8List merged;
    if (existing == null || existing.isEmpty) {
      merged = bytes;
    } else {
      final combined = Uint8List(existing.length + bytes.length)
        ..setRange(0, existing.length, existing)
        ..setRange(existing.length, existing.length + bytes.length, bytes);
      merged = combined;
    }
    if (merged.length > _previewBufferCap) {
      merged = merged.sublist(merged.length - _previewBufferCap);
    }
    _previewBuffer[sessionId] = merged;
    _previewLastDataAt[sessionId] = DateTime.now().millisecondsSinceEpoch;
    previewVersion.value = previewVersion.value + 1;
  }

  /// Test seam: feed bytes through the preview pipeline without involving
  /// the xterm Terminal or a base64 wrap. Production code drives this via
  /// `onTerminalData`. Not marked `@visibleForTesting` because AppState
  /// re-exports it through its own `@visibleForTesting` wrapper; the
  /// `debug` prefix signals the intent.
  void debugInjectOutput(String sessionId, List<int> bytes) {
    _appendPreview(sessionId, Uint8List.fromList(bytes));
  }

  @override
  void dispose() {
    previewVersion.dispose();
    super.dispose();
  }
}

/// Last-line snapshot for the session-list preview row. Both fields can be
/// null when the session has produced no output yet.
@immutable
class TerminalPreview {
  /// ANSI-stripped, truncated last non-empty line. Null when there's nothing
  /// to show yet.
  final String? text;

  /// Epoch ms of the most recent byte that fed the preview buffer.
  final int? lastDataAt;

  const TerminalPreview({required this.text, required this.lastDataAt});
}

/// Scan [terminal]'s interpreted screen buffer for the most recent line
/// the user would consider "substantive output" — i.e. shell output, not
/// the multiplexer's chrome. Starts at the cursor row (where the active
/// shell is currently writing) and walks upward, skipping rows that are
/// blank or composed entirely of decorative glyphs (box drawing, arrows,
/// nerdfont/powerline glyphs in the Private Use Area). Returns null if no
/// row in the visible viewport has substantive content.
///
/// The heuristic deliberately ignores rows below the cursor because
/// zellij / tmux / claude consistently paint their status bar there;
/// the cursor (and everything above it) tracks the focused pane's
/// content.
String? extractPreviewFromTerminal(Terminal terminal, {int maxLen = 60}) {
  final buffer = terminal.buffer;
  // Absolute index of the cursor row in the line ring. The visible
  // viewport starts at `lines.length - viewHeight` and the cursor row
  // is `viewHeight - 1` lines down from there at most.
  final cursorAbsY = buffer.absoluteCursorY;
  // Don't walk above the visible viewport — scrollback would otherwise
  // give us output from many minutes ago, which is misleading.
  final viewportTop =
      (buffer.lines.length - terminal.viewHeight).clamp(0, buffer.lines.length);
  for (var row = cursorAbsY; row >= viewportTop; row--) {
    if (row < 0 || row >= buffer.lines.length) continue;
    final raw = buffer.lines[row].getText().trimRight();
    if (raw.isEmpty) continue;
    final stripped = _stripDecorativeChars(raw);
    if (stripped.trim().length < 2) continue;
    final line = stripped.trim();
    if (line.length <= maxLen) return line;
    return '${line.substring(0, maxLen - 1)}…';
  }
  return null;
}

/// Remove decorative-only Unicode ranges that frame TUIs use to draw
/// chrome (box drawing, block elements, geometric shapes, arrows,
/// Private Use Area glyphs from nerdfont/powerline). Anything left is
/// "real" text the user would recognise.
String _stripDecorativeChars(String s) {
  final out = StringBuffer();
  for (final rune in s.runes) {
    // Box Drawing 2500–257F, Block Elements 2580–259F,
    // Geometric Shapes 25A0–25FF, Arrows 2190–21FF,
    // Supplemental Arrows 2B00–2BFF, Misc Tech 2300–23FF (often used
    // for power-line separators), PUA E000–F8FF (nerdfont).
    if ((rune >= 0x2190 && rune <= 0x21FF) ||
        (rune >= 0x2300 && rune <= 0x23FF) ||
        (rune >= 0x2500 && rune <= 0x257F) ||
        (rune >= 0x2580 && rune <= 0x259F) ||
        (rune >= 0x25A0 && rune <= 0x25FF) ||
        (rune >= 0x2B00 && rune <= 0x2BFF) ||
        (rune >= 0xE000 && rune <= 0xF8FF)) {
      continue;
    }
    out.writeCharCode(rune);
  }
  return out.toString();
}

/// Strip ANSI escape sequences from [bytes] (interpreted as UTF-8) and
/// return the last non-empty line, truncated to [maxLen] graphemes with an
/// ellipsis. Pure / no I/O — exposed at top level so tests can pin the
/// stripping behavior without instantiating a TerminalsNotifier.
String? extractPreviewLine(Uint8List bytes, {int maxLen = 60}) {
  if (bytes.isEmpty) return null;
  final raw = utf8.decode(bytes, allowMalformed: true);
  // Order matters: OSC first (it embeds CSI-like chars), then CSI, then
  // single-byte ESC introducers. Carriage returns inside a line collapse to
  // empty so a `progress…\r` doesn't leave the cursor return as the
  // "preview".
  final stripped = raw
      .replaceAll(RegExp(r'\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)'), '')
      .replaceAll(RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]'), '')
      .replaceAll(RegExp(r'\x1B[@-Z\\-_]'), '')
      .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '');
  final lines = stripped.split('\n');
  for (var i = lines.length - 1; i >= 0; i--) {
    final line = lines[i].replaceAll('\r', '').trimRight();
    if (line.trim().isEmpty) continue;
    if (line.length <= maxLen) return line;
    // Truncate at the maxLen boundary; the ellipsis itself counts toward
    // the cap so the displayed string never exceeds maxLen chars.
    return '${line.substring(0, maxLen - 1)}…';
  }
  return null;
}

class _BacklogChunk {
  final Uint8List bytes;
  final int seqEnd;
  const _BacklogChunk({required this.bytes, required this.seqEnd});
}
