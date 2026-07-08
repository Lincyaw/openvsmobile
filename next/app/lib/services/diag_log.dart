// General-purpose in-app observability log. Any subsystem can write events
// to it under a free-form `category`; the floating [DiagOverlay] shows a
// live stream and lets the user drop their own markers and record + tag
// windows of activity (normal / problem / anything) for later export.
//
// Gated behind a Settings switch (`debug-overlay`, default off) so normal
// users never pay for it and release-build performance is not polluted by
// debug overhead. NOT a product feature — a developer/observability tool.
//
// Categories are plain strings rather than an enum so new instrumentation
// sites never have to touch this file. A few well-known ones live in
// [DiagCat] purely so the overlay can colour them consistently; unknown
// categories still render fine.

import 'dart:async';

import 'package:flutter/foundation.dart';

/// Well-known category names. Free-form — any string works; these exist so
/// the overlay can colour-code the common ones.
class DiagCat {
  static const String terminal = 'term'; // scroll dispatch / gestures
  static const String mode = 'mode'; // DEC private-mode toggles
  static const String resize = 'size'; // PTY resize
  static const String net = 'net'; // connection state transitions
  static const String rpc = 'rpc'; // JSON-RPC calls / failures
  static const String iroh = 'iroh'; // native Iroh transport events
  static const String eyes = 'eyes'; // eyes-free gesture / voice flow
  static const String error = 'err'; // something went wrong
  static const String marker = 'mark'; // user-dropped marker
  static const String info = 'info';
}

class DiagEntry {
  final int tMs;
  final String category;
  final String text;
  const DiagEntry(this.tMs, this.category, this.text);
}

/// A recorded window the user has tagged. `label` is free-form; the overlay
/// emits `'normal'` / `'problem'` plus whatever the user types.
class RecordedSegment {
  final String label;
  final int startMs;
  final int endMs;
  final List<DiagEntry> entries;
  const RecordedSegment({
    required this.label,
    required this.startMs,
    required this.endMs,
    required this.entries,
  });

  int get durationMs => endMs - startMs;
}

/// SharedPreferences key for the persisted enable flag (kebab-case per
/// docs/conventions.md §4). Read at startup in `main`, written by the
/// Settings toggle.
const String kDiagLogPrefKey = 'debug-overlay';

/// Process-wide singleton. Instrumentation sites and the overlay share it.
class DiagLog extends ChangeNotifier {
  DiagLog._();
  static final DiagLog instance = DiagLog._();

  static const int _liveCap = 800;

  bool _enabled = false;
  bool get enabled => _enabled;
  set enabled(bool v) {
    if (_enabled == v) return;
    _enabled = v;
    if (!v) {
      // Tear-down: stop recording but keep saved segments so the user can
      // still export after toggling off.
      _recording = false;
      _recBuf.clear();
      _recStartMs = null;
    }
    notifyListeners();
  }

  final List<DiagEntry> _live = <DiagEntry>[];
  List<DiagEntry> get live => List<DiagEntry>.unmodifiable(_live);

  bool _recording = false;
  bool get recording => _recording;
  int? _recStartMs;
  int? get recordStartMs => _recStartMs;
  final List<DiagEntry> _recBuf = <DiagEntry>[];
  int get recordingCount => _recBuf.length;

  final List<RecordedSegment> _segments = <RecordedSegment>[];
  List<RecordedSegment> get segments =>
      List<RecordedSegment>.unmodifiable(_segments);

  bool _notifyScheduled = false;
  void _scheduleNotify() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      notifyListeners();
    });
  }

  /// Cheap no-op when disabled — hot paths (scroll dispatch) call this per
  /// drag-update, so the early return must come first.
  void log(String category, String text) {
    if (!_enabled) return;
    final e = DiagEntry(DateTime.now().millisecondsSinceEpoch, category, text);
    _live.add(e);
    if (_live.length > _liveCap) {
      _live.removeRange(0, _live.length - _liveCap);
    }
    if (_recording) _recBuf.add(e);
    _scheduleNotify();
  }

  /// Drop a user marker into the stream (and the recording, if active).
  /// Logged even while not recording so it is visible live; it only lands
  /// in a saved segment when one is being recorded.
  void mark(String label) => log(DiagCat.marker, '◆ $label');

  void startRecording() {
    if (!_enabled || _recording) return;
    _recording = true;
    _recStartMs = DateTime.now().millisecondsSinceEpoch;
    _recBuf.clear();
    log(DiagCat.marker, '▶ recording started');
    notifyListeners();
  }

  /// Stop and file the current window under [label].
  void stopRecording(String label) {
    if (!_recording) return;
    log(DiagCat.marker, '■ stopped → $label');
    final end = DateTime.now().millisecondsSinceEpoch;
    _segments.add(
      RecordedSegment(
        label: label,
        startMs: _recStartMs ?? end,
        endMs: end,
        entries: List<DiagEntry>.of(_recBuf),
      ),
    );
    _recording = false;
    _recBuf.clear();
    _recStartMs = null;
    notifyListeners();
  }

  void clearLive() {
    _live.clear();
    notifyListeners();
  }

  void clearSegments() {
    _segments.clear();
    notifyListeners();
  }

  /// A copy-pasteable dump of every saved segment, with per-segment relative
  /// timestamps so the trace reads as a timeline.
  String exportText() {
    if (_segments.isEmpty) return '(no recorded segments)';
    final b = StringBuffer();
    b.writeln('# debug event log — ${_segments.length} segment(s)');
    for (var i = 0; i < _segments.length; i++) {
      final s = _segments[i];
      b.writeln();
      b.writeln(
        '== segment ${i + 1} · ${s.label} · '
        '${(s.durationMs / 1000).toStringAsFixed(1)}s · '
        '${s.entries.length} events ==',
      );
      for (final e in s.entries) {
        final rel = ((e.tMs - s.startMs) / 1000).toStringAsFixed(2);
        b.writeln('+${rel.padLeft(6)}s ${e.category.padRight(5)} ${e.text}');
      }
    }
    return b.toString();
  }
}

/// Render control bytes visibly so escape sequences survive copy-paste:
/// `\x1b` → `⎋`, other C0 → `^X`.
String visEscapes(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    if (r == 0x1b) {
      b.write('⎋');
    } else if (r < 0x20) {
      b.write('^${String.fromCharCode(r + 0x40)}');
    } else {
      b.writeCharCode(r);
    }
  }
  return b.toString();
}
