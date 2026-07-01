// PTY-side state: the backend-global session list, the focused session,
// live xterm.dart Terminal objects, and the seqEnd / backlog
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
import '../services/diag_log.dart';
import '../services/terminal_diag.dart';

/// Reports a user-facing operation error upward. AppState surfaces it via
/// SnackBar in the standard way.
typedef ReportOperationError = void Function(String message);

class TerminalsNotifier extends ChangeNotifier {
  final BackendClient _client;
  final ReportOperationError _reportError;

  TerminalsNotifier({
    required BackendClient client,
    required ReportOperationError reportError,
  }) : this._(client, reportError);

  TerminalsNotifier._(this._client, this._reportError);

  /// Bumps on every per-session preview-buffer mutation. The Terminal-tab
  /// session list listens to this for cheap repaints without going through
  /// AppState's broader notifyListeners cascade (which would rebuild every
  /// other tab on every PTY byte). Repaints are batched within a frame
  /// because the ValueNotifier only fires distinct values, but we increment
  /// per chunk so a test pumping a single frame after one chunk sees the
  /// update.
  final ValueNotifier<int> previewVersion = ValueNotifier<int>(0);

  // Backend-global terminal session list (mirror of `terminal.list`).
  final List<TerminalSession> _sessions = [];

  // Focused session id. Terminal focus is no longer workspace-scoped because
  // sessions are backend-global and only carry an optional workspace link.
  String? _focusedTerminalId;

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

  // Per-session resize debounce timers. Keyboard show/hide on mobile fires
  // rapid consecutive resize events; coalescing into one RPC after 200ms
  // prevents a SIGWINCH storm in multiplexer-backed sessions (zellij relays
  // every resize to the running program, causing full TUI redraws).
  final Map<String, Timer> _resizeTimers = {};

  // ---- Getters ----

  /// Terminal sessions known on the active backend. The name is preserved
  /// for the existing widget-facing AppState API; it is no longer scoped to
  /// the current workspace.
  List<TerminalSession> get currentTerminals => List.unmodifiable(_sessions);

  String? get focusedTerminalId => _focusedTerminalId;

  TerminalSession? sessionFor(String sessionId) {
    for (final session in _sessions) {
      if (session.id == sessionId) return session;
    }
    return null;
  }

  /// Generation counter for a session's underlying Terminal. The UI uses
  /// this in its ValueKey so the TerminalView force-rebuilds when we swap
  /// the Terminal (e.g. after a reconnect history replay).
  int terminalGenerationFor(String sessionId) => _xtermGen[sessionId] ?? 0;

  Terminal terminalFor(String sessionId) {
    final existing = _xterms[sessionId];
    if (existing != null) return existing;
    final t = _buildTerminal(sessionId);
    _xterms[sessionId] = t;
    _flushBacklog(sessionId, t);
    _restoreAltBufferIfNeeded(sessionId, t);
    DiagLog.instance.log(
      DiagCat.info,
      'terminalFor($sessionId) created → alt=${t.isUsingAltBuffer}',
    );
    return t;
  }

  Terminal? terminalForIfKnown(String sessionId) {
    if (sessionFor(sessionId) == null) return null;
    return terminalFor(sessionId);
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

  /// Replace the cached backend-global session list. Used after a successful
  /// `terminal.list` RPC during reconnect. Caller is responsible for invoking
  /// [replayHistory] for each session afterward.
  void setSessions(List<TerminalSession> sessions) {
    _sessions
      ..clear()
      ..addAll(sessions);
    if (_focusedTerminalId == null ||
        !_sessions.any((s) => s.id == _focusedTerminalId)) {
      _focusedTerminalId = _sessions.isEmpty ? null : _sessions.first.id;
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
      hist =
          await _client.call('terminal.history', {'sessionId': sessionId})
              as Map<String, dynamic>;
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
      DiagLog.instance.log(
        DiagCat.info,
        'replayHistory($sessionId) ${bytes.length}B, offsetEnd=$offsetEnd',
      );
      term.write(utf8.decode(bytes, allowMalformed: true));
      DiagLog.instance.log(
        DiagCat.info,
        'replayHistory($sessionId) done → alt=${term.isUsingAltBuffer}',
      );
      _appendPreview(sessionId, Uint8List.fromList(bytes));
    }
    _xterms[sessionId] = term;
    _xtermGen[sessionId] = (_xtermGen[sessionId] ?? 0) + 1;
    _lastWrittenSeq[sessionId] = offsetEnd;
    _flushBacklog(sessionId, term);
    _restoreAltBufferIfNeeded(sessionId, term);
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
    final ids = <String>[for (final t in _sessions) t.id];
    // Backend semantic: `terminal.subscribe` with an empty/omitted `ids` is
    // explicit subscribe-ALL (legacy compatibility). We want "subscribe to
    // exactly my zero sessions" in that case, so map empty → unsubscribe.
    final method = ids.isEmpty ? 'terminal.unsubscribe' : 'terminal.subscribe';
    final params = ids.isEmpty ? <String, dynamic>{} : {'ids': ids};
    _client.call(method, params).catchError((Object e) {
      if (e is BackendRpcException &&
          e.code == -1 &&
          e.message == 'not connected') {
        return <String, dynamic>{};
      }
      debugPrint('TerminalsNotifier.refreshTerminalSubscription failed: $e');
      return <String, dynamic>{};
    });
  }

  // ---- Public actions ----

  /// Create a fresh PTY session. When [workspaceId] is supplied the backend
  /// stores that workspace root as a weak link; otherwise the terminal is
  /// intentionally unbound.
  Future<TerminalSession?> createTerminal({
    String? workspaceId,
    required int cols,
    required int rows,
  }) async {
    try {
      final params = <String, dynamic>{'cols': cols, 'rows': rows};
      if (workspaceId != null) params['workspaceId'] = workspaceId;
      final r =
          await _client.call('terminal.create', params) as Map<String, dynamic>;
      final session = TerminalSession.fromJson(r);
      _sessions.add(session);
      _focusedTerminalId = session.id;
      // Fresh session — no history to fetch.
      _lastWrittenSeq[session.id] = 0;
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
    final r =
        await _client.call('terminal.listExternalSessions', const {})
            as Map<String, dynamic>;
    final raw = (r['sessions'] as List?) ?? const [];
    return raw
        .cast<Map<String, dynamic>>()
        .map(ExternalTerminalSession.fromJson)
        .toList(growable: false);
  }

  /// Adopt an external zellij session. [workspaceId] weak-links it to a
  /// workspace root when provided; omitted means unbound.
  Future<TerminalSession?> adoptExternalSession({
    String? workspaceId,
    required String sessionName,
    required int cols,
    required int rows,
  }) async {
    try {
      final params = <String, dynamic>{
        'sessionName': sessionName,
        'cols': cols,
        'rows': rows,
      };
      if (workspaceId != null) params['workspaceId'] = workspaceId;
      final r =
          await _client.call('terminal.adoptExternalSession', params)
              as Map<String, dynamic>;
      final session = TerminalSession.fromJson(r);
      _sessions.add(session);
      _focusedTerminalId = session.id;
      _lastWrittenSeq[session.id] = 0;
      refreshTerminalSubscription();
      notifyListeners();
      return session;
    } catch (e) {
      _reportError('Could not adopt session: $e');
      return null;
    }
  }

  Future<void> renameTerminal(String sessionId, String? title) async {
    try {
      final r =
          await _client.call('terminal.rename', {
                'sessionId': sessionId,
                'title': title,
              })
              as Map<String, dynamic>;
      final raw = r['session'];
      if (raw is Map<String, dynamic>) {
        _upsertSession(TerminalSession.fromJson(raw));
      }
    } catch (e) {
      _reportError('Could not rename terminal: $e');
    }
  }

  /// Tell the backend to drop the local zellij client for [sessionId]
  /// without killing the zellij server session. Local cleanup is driven
  /// by the resulting `terminal.detached` notification.
  Future<void> detachTerminal(
    String sessionId, {
    required BackendConnectionState connectionState,
  }) async {
    try {
      await _client.call('terminal.detach', {'sessionId': sessionId});
    } catch (e) {
      if (connectionState != BackendConnectionState.connected) {
        debugPrint(
          'TerminalsNotifier.detachTerminal($sessionId) dropped: '
          'disconnected mid-call ($e)',
        );
        return;
      }
      _reportError('Could not detach terminal: $e');
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

  void focusTerminal(String sessionId) {
    if (!_sessions.any((s) => s.id == sessionId)) return;
    _focusedTerminalId = sessionId;
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
    final seqEnd =
        (p['seqEnd'] as num?)?.toInt() ??
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
        final decoded = utf8.decode(toWrite, allowMalformed: true);
        // Surface mouse / alt-buffer DEC private-mode toggles before they
        // mutate the Terminal, so a trace shows mouseMode drift in order.
        sniffDecModes(decoded);
        term.write(decoded);
      }
      _lastWrittenSeq[sessionId] = seqEnd;
      return;
    }
    // No Terminal yet — buffer with the seqEnd attached so we can dedupe on flush.
    final list = _backlog.putIfAbsent(sessionId, () => <_BacklogChunk>[]);
    list.add(_BacklogChunk(bytes: bytes, seqEnd: seqEnd));
    _backlogBytes.update(
      sessionId,
      (v) => v + bytes.length,
      ifAbsent: () => bytes.length,
    );
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
    for (var i = 0; i < _sessions.length; i++) {
      if (_sessions[i].id == sessionId && !_sessions[i].detached) {
        _sessions[i] = _sessions[i].copyWith(detached: true);
      }
    }
    notifyListeners();
  }

  void onTerminalRenamed(Map<String, dynamic> p) {
    final sessionId = p['sessionId'] as String?;
    if (sessionId == null) return;
    final title = p['title'] as String?;
    var changed = false;
    for (var i = 0; i < _sessions.length; i++) {
      if (_sessions[i].id == sessionId) {
        _sessions[i] = _sessions[i].copyWith(
          title: title,
          clearTitle: title == null,
        );
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  void _clearDetachedIfSet(String sessionId) {
    var changed = false;
    for (var i = 0; i < _sessions.length; i++) {
      if (_sessions[i].id == sessionId && _sessions[i].detached) {
        _sessions[i] = _sessions[i].copyWith(detached: false);
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  void onTerminalExit(Map<String, dynamic> p) {
    final sessionId = p['sessionId'] as String;
    _resizeTimers.remove(sessionId)?.cancel();
    _xterms.remove(sessionId);
    _xtermGen.remove(sessionId);
    _lastWrittenSeq.remove(sessionId);
    _backlog.remove(sessionId);
    _backlogBytes.remove(sessionId);
    _previewBuffer.remove(sessionId);
    _previewLastDataAt.remove(sessionId);
    _sessions.removeWhere((t) => t.id == sessionId);
    if (_focusedTerminalId == sessionId) {
      _focusedTerminalId = _sessions.isNotEmpty ? _sessions.first.id : null;
    }
    refreshTerminalSubscription();
    notifyListeners();
  }

  /// A workspace close no longer owns terminal lifetime. Keep every session
  /// and only clear the volatile workspaceId shortcut; workspaceRoot remains
  /// as the stable Files jump locator.
  void onWorkspaceClosed(String workspaceId) {
    var changed = false;
    for (var i = 0; i < _sessions.length; i++) {
      if (_sessions[i].workspaceId == workspaceId) {
        _sessions[i] = _sessions[i].copyWith(clearWorkspaceId: true);
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  void _upsertSession(TerminalSession session) {
    for (var i = 0; i < _sessions.length; i++) {
      if (_sessions[i].id == session.id) {
        _sessions[i] = session;
        notifyListeners();
        return;
      }
    }
    _sessions.add(session);
    notifyListeners();
  }

  /// Hard reset for an intentional backend target switch. This is not used
  /// for transient reconnects: those keep last-known state visible until the
  /// same backend resynchronizes.
  void clearAll() {
    for (final t in _resizeTimers.values) {
      t.cancel();
    }
    _resizeTimers.clear();
    _sessions.clear();
    _focusedTerminalId = null;
    _xterms.clear();
    _xtermGen.clear();
    _lastWrittenSeq.clear();
    _backlog.clear();
    _backlogBytes.clear();
    _previewBuffer.clear();
    _previewLastDataAt.clear();
    previewVersion.value = previewVersion.value + 1;
    notifyListeners();
  }

  // ---- Internals ----

  Terminal _buildTerminal(String sessionId) {
    final t = Terminal(maxLines: 5000);
    bool lastAlt = false;
    t.addListener(() {
      final nowAlt = t.isUsingAltBuffer;
      if (nowAlt != lastAlt) {
        lastAlt = nowAlt;
        DiagLog.instance.log(
          DiagCat.mode,
          'alt-buffer ${nowAlt ? '↑on' : '↓off'} ($sessionId)',
        );
      }
    });
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
            // A dropped scroll/keystroke: the user sees "nothing happened".
            DiagLog.instance.log(
              DiagCat.error,
              'write dropped (${data.length}B): $e',
            );
            debugPrint('terminal.write($sessionId) failed: $e');
          });
    };
    t.onResize = (w, h, _, _) {
      DiagLog.instance.log(DiagCat.resize, 'resize → ${w}x$h (cols x rows)');
      _resizeTimers[sessionId]?.cancel();
      _resizeTimers[sessionId] = Timer(const Duration(milliseconds: 200), () {
        _resizeTimers.remove(sessionId);
        _client
            .call('terminal.resize', {
              'sessionId': sessionId,
              'cols': w,
              'rows': h,
            })
            .catchError((Object e) {
              debugPrint('terminal.resize($sessionId) failed: $e');
            });
      });
    };
    return t;
  }

  /// Zellij-backed sessions run in the alt buffer, but a reconnect
  /// history-replay may lose the initial `\x1b[?1049h` when the 1 MiB
  /// circular scrollback evicts it. Inject the sequence so the Terminal
  /// enters the correct buffer mode. Harmless if already in alt buffer.
  void _restoreAltBufferIfNeeded(String sessionId, Terminal term) {
    if (term.isUsingAltBuffer) return;
    final isZellij = _sessions.any(
      (s) => s.id == sessionId && s.externalSessionId != null,
    );
    if (!isZellij) return;
    term.write('\x1b[?1049h');
    DiagLog.instance.log(
      DiagCat.mode,
      'injected ?1049h for zellij session $sessionId',
    );
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
    for (final t in _resizeTimers.values) {
      t.cancel();
    }
    _resizeTimers.clear();
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
  final viewportTop = (buffer.lines.length - terminal.viewHeight).clamp(
    0,
    buffer.lines.length,
  );
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
