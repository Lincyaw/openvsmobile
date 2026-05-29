// Single owner of gesture interpretation over xterm.dart's TerminalView.
//
// Why this exists: xterm.dart ships two competing recognizer chains
// (TerminalGestureHandler tap/long-press/drag-to-select and an alt-buffer
// InfiniteScrollView Scrollable). Both fought our scroll dispatcher in
// the gesture arena, so swipes flickered between select / scroll / no-op.
// This host is the single authority — its recognizers win the arena and
// AbsorbPointer below starves xterm's recognizers of pointer input.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../ui/app_tokens.dart';
import 'diag_log.dart';
import 'terminal_scroll_adapter.dart';

enum _Mode { view, select }

/// Tracks normal-buffer scroll position in lines (not pixels). Lines is
/// the natural unit because both our drag-quantizer and PageUp/PageDn
/// flings count in lines; converting to pixels happens once at the
/// render-sink boundary using the current cell height.
class TerminalScrollbackModel extends ChangeNotifier {
  int _offsetLines = 0;
  int get offsetLines => _offsetLines;

  /// `delta` is signed: positive means "show later content" (natural-
  /// scroll down). Matches [TerminalScrollAdapter]'s sign convention so
  /// the host can pipe adapter output straight through.
  void scrollBy(int deltaLines) {
    if (deltaLines == 0) return;
    _offsetLines += deltaLines;
    notifyListeners();
  }

  /// Called by the host after the render sink has resolved its clamped
  /// position, so phantom out-of-range delta does not have to be "burned"
  /// by a reverse drag before the model becomes responsive again.
  void clampTo(int clampedLines) {
    if (_offsetLines == clampedLines) return;
    _offsetLines = clampedLines;
    notifyListeners();
  }

  void reset() {
    if (_offsetLines == 0) return;
    _offsetLines = 0;
    notifyListeners();
  }
}

/// Callback receiving the [TerminalGestureHostState] so callers can drive
/// force-select without holding a `GlobalKey<TerminalGestureHostState>`
/// (which would treat State as a public API).
typedef ForceSelectRegistrar = void Function(VoidCallback forceSelect);

/// Wraps a [TerminalView] (passed as `child`) with the single gesture
/// dispatcher described in the file header. The caller still constructs
/// the TerminalView and owns its key + controller + scrollController —
/// this widget only intercepts pointers.
class TerminalGestureHost extends StatefulWidget {
  const TerminalGestureHost({
    super.key,
    required this.terminal,
    required this.terminalController,
    required this.terminalViewKey,
    required this.scrollback,
    required this.scrollbackController,
    required this.child,
    this.registerForceSelect,
  });

  final Terminal terminal;

  /// The same [TerminalController] passed to the wrapped [TerminalView].
  /// We need it for clean clearSelection / setSelection / reading the
  /// current selection range for copy.
  final TerminalController terminalController;

  /// Key on the wrapped [TerminalView]. We reach through this for the
  /// `RenderTerminal` (cell math) and `requestKeyboard`.
  final GlobalKey<TerminalViewState> terminalViewKey;

  /// Source of truth for normal-buffer scrollback position. Updated by
  /// the host's drag dispatcher; observed by the host to drive the
  /// render sink (`scrollbackController`).
  final TerminalScrollbackModel scrollback;

  /// xterm's render sink. We jump it to `model.offsetLines * lineHeight`
  /// on every model change.
  final ScrollController scrollbackController;

  final Widget child;

  /// Called once when the host's State is available; the callback hands
  /// the parent a closure that triggers force-select-at-cursor. Lets the
  /// soft-keyboard toolbar drive selection without reaching into State.
  final ForceSelectRegistrar? registerForceSelect;

  @override
  State<TerminalGestureHost> createState() => TerminalGestureHostState();
}

class TerminalGestureHostState extends State<TerminalGestureHost> {
  _Mode _mode = _Mode.view;

  // Drag state.
  Offset _dragAnchor = Offset.zero;
  double _residualDy = 0;
  VelocityTracker? _velocity;
  ScrollRouting? _dragRouting;

  void _resetDragState() {
    _residualDy = 0;
    _dragRouting = null;
  }

  // Select-mode anchor for character extension.
  Offset? _selectAnchor;

  bool _lastAltBuffer = false;

  @override
  void initState() {
    super.initState();
    _lastAltBuffer = widget.terminal.isUsingAltBuffer;
    widget.terminal.addListener(_onTerminalChanged);
    widget.scrollback.addListener(_syncScrollSink);
    widget.registerForceSelect?.call(forceSelectAtCursor);
  }

  @override
  void didUpdateWidget(covariant TerminalGestureHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.terminal != widget.terminal) {
      oldWidget.terminal.removeListener(_onTerminalChanged);
      widget.terminal.addListener(_onTerminalChanged);
      _lastAltBuffer = widget.terminal.isUsingAltBuffer;
    }
    if (oldWidget.scrollback != widget.scrollback) {
      oldWidget.scrollback.removeListener(_syncScrollSink);
      widget.scrollback.addListener(_syncScrollSink);
    }
    if (oldWidget.registerForceSelect != widget.registerForceSelect) {
      widget.registerForceSelect?.call(forceSelectAtCursor);
    }
  }

  @override
  void dispose() {
    widget.terminal.removeListener(_onTerminalChanged);
    widget.scrollback.removeListener(_syncScrollSink);
    super.dispose();
  }

  void _onTerminalChanged() {
    final nowAlt = widget.terminal.isUsingAltBuffer;
    if (nowAlt != _lastAltBuffer) {
      _lastAltBuffer = nowAlt;
      if (nowAlt) {
        widget.scrollback.reset();
        if (widget.scrollbackController.hasClients) {
          widget.scrollbackController.jumpTo(0);
        }
      }
    }
  }

  // ---------- render-sink bridge ----------

  void _syncScrollSink() {
    final state = widget.terminalViewKey.currentState;
    if (state == null) return;
    final lineHeight = state.renderTerminal.lineHeight;
    if (lineHeight <= 0) return;
    if (!widget.scrollbackController.hasClients) return;
    final target = widget.scrollback.offsetLines * lineHeight;
    final position = widget.scrollbackController.position;
    final clamped = target.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    widget.scrollbackController.jumpTo(clamped);
    // Mirror the clamp back into the model so out-of-range delta does
    // not accumulate as phantom offset that a reverse drag must "burn".
    final clampedLines = (clamped / lineHeight).round();
    if (clampedLines != widget.scrollback.offsetLines) {
      widget.scrollback.clampTo(clampedLines);
    }
  }

  // ---------- cell-math helpers ----------

  ({int col, int row}) _cellAt(Offset localPos) {
    final state = widget.terminalViewKey.currentState;
    if (state == null) return (col: 1, row: 1);
    final cell = state.renderTerminal.getCellOffset(localPos);
    return (col: cell.x + 1, row: cell.y + 1);
  }

  double _cellHeight() {
    final state = widget.terminalViewKey.currentState;
    if (state == null) return 16;
    return state.renderTerminal.lineHeight;
  }

  // ---------- diagnostics ----------

  bool get _diagOn => DiagLog.instance.enabled;

  /// Snapshot of the terminal state that decides scroll routing. Logged at
  /// drag-start so a recorded trace shows *why* a given swipe took the
  /// wheel / arrows / scrollback branch.
  String _modeSnapshot() {
    final t = widget.terminal;
    return 'alt=${t.isUsingAltBuffer} mouse=${t.mouseMode.name} '
        'report=${t.mouseReportMode.name} '
        'altScroll=${t.altBufferMouseScrollMode} '
        'appCursor=${t.cursorKeysMode}';
  }

  void _logDispatch(String branch, String detail) {
    DiagLog.instance.log(DiagCat.terminal, visEscapes('  → $branch $detail'));
  }

  // ---------- mode transitions ----------

  void _enterSelect(Offset localPos) {
    final state = widget.terminalViewKey.currentState;
    if (state == null) return;
    state.renderTerminal.selectWord(localPos);
    _selectAnchor = localPos;
    setState(() => _mode = _Mode.select);
  }

  void _exitSelect({bool clear = true}) {
    if (clear) {
      widget.terminalController.clearSelection();
    }
    _selectAnchor = null;
    if (_mode != _Mode.view) {
      setState(() => _mode = _Mode.view);
    }
  }

  Future<void> _copySelection() async {
    final selection = widget.terminalController.selection;
    if (selection == null) return;
    final text = widget.terminal.buffer.getText(selection);
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
  }

  void _selectAll() {
    // Select the entire buffer (all scrollback lines), not just the
    // currently rendered viewport.
    final buffer = widget.terminal.buffer;
    final lastLine = buffer.height - 1;
    if (lastLine < 0) return;
    widget.terminalController.setSelection(
      buffer.createAnchor(0, 0),
      buffer.createAnchor(widget.terminal.viewWidth, lastLine),
      mode: SelectionMode.line,
    );
  }

  // ---------- recognizer callbacks ----------

  void _onTapDown(TapDownDetails details) {
    final state = widget.terminalViewKey.currentState;
    if (state == null) return;
    // Focus first so the soft keyboard is brought up before any TUI
    // mouse-down round-trips.
    state.requestKeyboard();
    if (_mode == _Mode.select) return;
    if (widget.terminal.mouseMode != MouseMode.none) {
      state.renderTerminal.mouseEvent(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        details.localPosition,
      );
    }
  }

  void _onTapUp(TapUpDetails details) {
    final state = widget.terminalViewKey.currentState;
    if (state == null) return;
    if (_mode == _Mode.select) {
      // A stray tap outside the toolbar exits select mode, matching most
      // mobile editors. The Dismiss button covers the explicit path.
      _exitSelect();
      return;
    }
    if (widget.terminal.mouseMode != MouseMode.none) {
      state.renderTerminal.mouseEvent(
        TerminalMouseButton.left,
        TerminalMouseButtonState.up,
        details.localPosition,
      );
    }
  }

  void _onLongPressStart(LongPressStartDetails details) {
    // If the app is in a mouse-reporting mode, long-press is reserved
    // for the running TUI (some use it as a right-click proxy). Force-
    // select is then only reachable via the soft-keyboard toolbar.
    if (widget.terminal.mouseMode != MouseMode.none) return;
    _enterSelect(details.localPosition);
  }

  void _onVerticalDragStart(DragStartDetails d) {
    _dragAnchor = d.localPosition;
    _residualDy = 0;
    _velocity = VelocityTracker.withKind(d.kind ?? PointerDeviceKind.touch);
    _velocity!.addPosition(Duration.zero, d.globalPosition);
    _dragRouting = ScrollRouting.capture(widget.terminal);
    if (_diagOn) {
      final c = _cellAt(d.localPosition);
      DiagLog.instance.log(
        DiagCat.terminal,
        'drag start mode=${_mode.name} anchorCell=(${c.col},${c.row}) '
        'cellH=${_cellHeight().toStringAsFixed(1)} ${_modeSnapshot()}',
      );
    }
    // In select mode, long-press has already seeded _selectAnchor to the
    // word boundary. Overwriting it here would break "long-press to
    // select a word, then drag to extend from the word boundary".
    if (_mode == _Mode.select && _selectAnchor == null) {
      _selectAnchor = d.localPosition;
    }
  }

  void _onVerticalDragUpdate(DragUpdateDetails d) {
    _velocity?.addPosition(d.sourceTimeStamp ?? Duration.zero, d.globalPosition);

    if (_mode == _Mode.select) {
      final state = widget.terminalViewKey.currentState;
      if (state != null && _selectAnchor != null) {
        state.renderTerminal.selectCharacters(_selectAnchor!, d.localPosition);
      }
      return;
    }

    // ViewMode: quantize to cells and dispatch via the adapter helper.
    final cellH = _cellHeight();
    if (cellH <= 0) {
      if (_diagOn) {
        DiagLog.instance
            .log(DiagCat.terminal, '  ! drag-update dropped: cellHeight<=0');
      }
      return;
    }
    _residualDy -= d.delta.dy;
    final units = (_residualDy / cellH).truncate();
    if (units == 0) return;
    _residualDy -= units * cellH;
    TerminalScrollAdapter.dispatchUnits(
      terminal: widget.terminal,
      magnitude: units.abs(),
      down: units > 0,
      cellAt: _cellAt,
      anchor: _dragAnchor,
      onScrollback: widget.scrollback.scrollBy,
      routing: _dragRouting,
      onDiag: _diagOn ? _logDispatch : null,
    );
  }

  void _onVerticalDragEnd(DragEndDetails d) {
    if (_mode == _Mode.select) return;
    final velocity = _velocity?.getVelocity().pixelsPerSecond.dy ?? 0;
    _velocity = null;
    if (velocity.abs() < kFastFlingVelocity) {
      if (_diagOn) {
        DiagLog.instance.log(
          DiagCat.terminal,
          '  drag end v=${velocity.toStringAsFixed(0)} (<$kFastFlingVelocity, '
          'no fling)',
        );
      }
      _resetDragState();
      return;
    }
    final down = velocity < 0;
    if (_diagOn) {
      DiagLog.instance.log(DiagCat.terminal,
          '  drag end v=${velocity.toStringAsFixed(0)} → fling');
    }
    TerminalScrollAdapter.dispatchFling(
      terminal: widget.terminal,
      down: down,
      rows: widget.terminal.viewHeight,
      cellAt: _cellAt,
      anchor: _dragAnchor,
      onScrollback: widget.scrollback.scrollBy,
      routing: _dragRouting,
      onDiag: _diagOn ? _logDispatch : null,
    );
    _resetDragState();
  }

  void _onVerticalDragCancel() {
    _velocity = null;
    _resetDragState();
  }

  // ---------- hardware mouse wheel ----------

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (_mode == _Mode.select) return;
    final cellH = _cellHeight();
    if (cellH <= 0) return;
    // Same sign convention as vertical-drag: positive dy reveals later
    // content. PointerScrollEvent.scrollDelta.dy is positive when the
    // wheel is rolled down (away from the user) = reveal later content,
    // matching dispatchUnits' `down: true`.
    final units = (event.scrollDelta.dy / cellH).truncate();
    if (units == 0) return;
    if (_diagOn) {
      final c = _cellAt(event.localPosition);
      DiagLog.instance.log(
        DiagCat.terminal,
        'wheel signal cell=(${c.col},${c.row}) ${_modeSnapshot()}',
      );
    }
    TerminalScrollAdapter.dispatchUnits(
      terminal: widget.terminal,
      magnitude: units.abs(),
      down: units > 0,
      cellAt: _cellAt,
      anchor: event.localPosition,
      onScrollback: widget.scrollback.scrollBy,
      onDiag: _diagOn ? _logDispatch : null,
    );
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Listener(
          behavior: HitTestBehavior.translucent,
          onPointerSignal: _onPointerSignal,
          child: RawGestureDetector(
            behavior: HitTestBehavior.translucent,
            gestures: <Type, GestureRecognizerFactory>{
              TapGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                () => TapGestureRecognizer(debugOwner: this),
                (r) {
                  r.onTapDown = _onTapDown;
                  r.onTapUp = _onTapUp;
                },
              ),
              LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<
                  LongPressGestureRecognizer>(
                () => LongPressGestureRecognizer(debugOwner: this),
                (r) => r.onLongPressStart = _onLongPressStart,
              ),
              VerticalDragGestureRecognizer: GestureRecognizerFactoryWithHandlers<
                  VerticalDragGestureRecognizer>(
                () => VerticalDragGestureRecognizer(debugOwner: this),
                (r) {
                  r.onStart = _onVerticalDragStart;
                  r.onUpdate = _onVerticalDragUpdate;
                  r.onEnd = _onVerticalDragEnd;
                  r.onCancel = _onVerticalDragCancel;
                },
              ),
            },
            // AbsorbPointer starves xterm's internal recognizers so only
            // ours remain in the gesture arena.
            child: AbsorbPointer(child: widget.child),
          ),
        ),
        if (_mode == _Mode.select)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _SelectionToolbar(
              onCopy: () async {
                await _copySelection();
                if (mounted) _exitSelect();
              },
              onSelectAll: _selectAll,
              onDismiss: () => _exitSelect(),
            ),
          ),
      ],
    );
  }

  /// Force-select entry point for the soft-keyboard toolbar. Used when
  /// the app is in a mouse-reporting mode and long-press is therefore
  /// reserved for the TUI.
  void forceSelectAtCursor() {
    final state = widget.terminalViewKey.currentState;
    if (state == null) return;
    final size = state.renderTerminal.size;
    _enterSelect(Offset(size.width / 2, size.height / 2));
  }
}

class _SelectionToolbar extends StatelessWidget {
  const _SelectionToolbar({
    required this.onCopy,
    required this.onSelectAll,
    required this.onDismiss,
  });

  final VoidCallback onCopy;
  final VoidCallback onSelectAll;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 4,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: onCopy, child: const Text('Copy')),
              TextButton(
                onPressed: onSelectAll,
                child: const Text('Select All'),
              ),
              TextButton(onPressed: onDismiss, child: const Text('Dismiss')),
            ],
          ),
        ),
      ),
    );
  }
}
