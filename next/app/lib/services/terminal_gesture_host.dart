// Single owner of gesture interpretation over xterm.dart's TerminalView.
//
// Why this exists: xterm.dart's TerminalView builds its own recognizer
// chain (TerminalGestureHandler → tap / longPress / drag-to-select, plus
// TerminalScrollGestureHandler → an inner Scrollable in alt-buffer, plus
// the outer Scrollable that drives normal-buffer rendering). On Android
// touch input, multiple of those compete in the same gesture arena with
// our scroll dispatcher, producing the symptom this file was written to
// fix: vertical swipes sometimes trigger text selection, sometimes do
// nothing, sometimes scroll.
//
// The fix is to put one RawGestureDetector *above* TerminalView whose
// recognizers claim the arena early (vertical-drag via touch-slop, tap
// via the standard tap recognizer, long-press via the standard timer).
// xterm's inner recognizers still exist in the tree but they always
// lose the arena to ours — so they are starved of pointer streams.
//
// We deliberately leave TerminalView's outer Scrollable in place. We
// pass a ScrollController in and drive it from a ScrollbackModel —
// xterm's render path consumes ViewportOffset deltas to repaint, and
// short-circuiting that would mean reaching into private API. Treating
// the ScrollController as a render sink driven by our own model keeps
// the rendering pipeline intact while making the host the only source
// of pointer-driven scroll changes.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../ui/app_tokens.dart';
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

  void reset() {
    if (_offsetLines == 0) return;
    _offsetLines = 0;
    notifyListeners();
  }
}

/// Wraps a [TerminalView] (passed as `child`) with the single gesture
/// dispatcher described in the file header. The caller still constructs
/// the TerminalView and owns its key + controller + scrollController —
/// this widget only intercepts pointers.
class TerminalGestureHost extends StatefulWidget {
  const TerminalGestureHost({
    super.key,
    required this.terminal,
    required this.terminalViewKey,
    required this.scrollback,
    required this.scrollbackController,
    required this.child,
  });

  final Terminal terminal;

  /// Key on the wrapped [TerminalView]. We reach through this for the
  /// `RenderTerminal` (cell math, selection) and `requestKeyboard`.
  final GlobalKey<TerminalViewState> terminalViewKey;

  /// Source of truth for normal-buffer scrollback position. Updated by
  /// the host's drag dispatcher; observed by the host to drive the
  /// render sink (`scrollbackController`).
  final TerminalScrollbackModel scrollback;

  /// xterm's render sink. We jump it to `model.offsetLines * lineHeight`
  /// on every model change.
  final ScrollController scrollbackController;

  final Widget child;

  @override
  State<TerminalGestureHost> createState() => TerminalGestureHostState();
}

class TerminalGestureHostState extends State<TerminalGestureHost> {
  _Mode _mode = _Mode.view;

  // Drag state.
  Offset _dragAnchor = Offset.zero;
  double _residualDy = 0;
  VelocityTracker? _velocity;

  // Select-mode anchor for character extension.
  Offset? _selectAnchor;

  @override
  void initState() {
    super.initState();
    widget.scrollback.addListener(_syncScrollSink);
  }

  @override
  void didUpdateWidget(covariant TerminalGestureHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollback != widget.scrollback) {
      oldWidget.scrollback.removeListener(_syncScrollSink);
      widget.scrollback.addListener(_syncScrollSink);
    }
  }

  @override
  void dispose() {
    widget.scrollback.removeListener(_syncScrollSink);
    super.dispose();
  }

  // ---------- render-sink bridge ----------

  void _syncScrollSink() {
    final state = widget.terminalViewKey.currentState;
    if (state == null) return;
    final lineHeight = state.renderTerminal.lineHeight;
    if (lineHeight <= 0) return;
    final target = widget.scrollback.offsetLines * lineHeight;
    if (!widget.scrollbackController.hasClients) return;
    final clamped = target.clamp(
      widget.scrollbackController.position.minScrollExtent,
      widget.scrollbackController.position.maxScrollExtent,
    );
    widget.scrollbackController.jumpTo(clamped);
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
      // Reach the controller through the renderTerminal? The
      // TerminalController is owned by the caller — clearing selection
      // through RenderTerminal isn't exposed, so we issue a zero-length
      // selectCharacters which xterm interprets as collapsing.
      final state = widget.terminalViewKey.currentState;
      if (state != null) {
        // selectCharacters with from==to collapses the selection range;
        // xterm.dart paints nothing for a zero-length range.
        state.renderTerminal.selectCharacters(Offset.zero, Offset.zero);
      }
    }
    _selectAnchor = null;
    if (_mode != _Mode.view) {
      setState(() => _mode = _Mode.view);
    }
  }

  Future<void> _copySelection() async {
    final state = widget.terminalViewKey.currentState;
    if (state == null) return;
    // We don't have the TerminalController here, but the caller does.
    // The selected range lives on RenderTerminal's controller — we
    // instead read it via the terminal's buffer using a coarse
    // approximation: re-derive the selection from our anchor. Simpler:
    // use the terminal's buffer.getText on the controller's selection.
    // The controller is reachable through the TerminalView widget.
    final controller = state.widget.controller;
    final selection = controller?.selection;
    if (selection == null) return;
    final text = widget.terminal.buffer.getText(selection);
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
  }

  void _selectAll() {
    final state = widget.terminalViewKey.currentState;
    if (state == null) return;
    // Select from top-left to bottom-right of the current viewport.
    final size = state.renderTerminal.size;
    state.renderTerminal.selectCharacters(
      Offset.zero,
      Offset(size.width, size.height),
    );
  }

  // ---------- recognizer callbacks ----------

  void _onTapUp(TapUpDetails details) {
    final state = widget.terminalViewKey.currentState;
    if (state == null) return;
    if (_mode == _Mode.select) {
      // Tap outside selection toolbar dismisses select mode and falls
      // through as a normal focus-tap. We don't try to detect "inside
      // the highlight rect" — the toolbar's Dismiss button covers the
      // user-initiated exit path; a stray tap exits too, which is what
      // most mobile editors do.
      _exitSelect();
      return;
    }
    // Replicate TerminalGestureHandler's _tapDown contract: focus the
    // text-edit shim (drives the soft keyboard) and, if the running
    // application requested mouse reporting, deliver a mouse-down at
    // the tapped cell. RenderTerminal.mouseEvent handles the protocol-
    // encoding side.
    state.requestKeyboard();
    final mouseMode = widget.terminal.mouseMode;
    if (mouseMode != MouseMode.none) {
      state.renderTerminal.mouseEvent(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        details.localPosition,
      );
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
    // TODO(two-finger): selection in mouseReport mode requires a
    // force-select gesture; for v0 use the toolbar button.
    if (widget.terminal.mouseMode != MouseMode.none) return;
    _enterSelect(details.localPosition);
  }

  void _onVerticalDragStart(DragStartDetails d) {
    _dragAnchor = d.localPosition;
    _residualDy = 0;
    _velocity = VelocityTracker.withKind(d.kind ?? PointerDeviceKind.touch);
    _velocity!.addPosition(Duration.zero, d.globalPosition);
    if (_mode == _Mode.select) {
      _selectAnchor = d.localPosition;
    }
  }

  void _onVerticalDragUpdate(DragUpdateDetails d) {
    _velocity?.addPosition(d.sourceTimeStamp ?? Duration.zero, d.globalPosition);

    if (_mode == _Mode.select) {
      // Extend selection from anchor to current pointer. Vertical drag
      // is enough — horizontal contribution is implicit in localPosition.
      final state = widget.terminalViewKey.currentState;
      if (state != null && _selectAnchor != null) {
        state.renderTerminal.selectCharacters(_selectAnchor!, d.localPosition);
      }
      return;
    }

    // ViewMode: quantize to cells and dispatch via the adapter helper.
    final cellH = _cellHeight();
    if (cellH <= 0) return;
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
    );
  }

  void _onVerticalDragEnd(DragEndDetails d) {
    if (_mode == _Mode.select) return;
    final velocity = _velocity?.getVelocity().pixelsPerSecond.dy ?? 0;
    _velocity = null;
    if (velocity.abs() < kFastFlingVelocity) {
      _residualDy = 0;
      return;
    }
    final down = velocity < 0;
    TerminalScrollAdapter.dispatchFling(
      terminal: widget.terminal,
      down: down,
      rows: widget.terminal.viewHeight,
      cellAt: _cellAt,
      anchor: _dragAnchor,
    );
    _residualDy = 0;
  }

  void _onVerticalDragCancel() {
    _velocity = null;
    _residualDy = 0;
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        RawGestureDetector(
          behavior: HitTestBehavior.translucent,
          gestures: <Type, GestureRecognizerFactory>{
            TapGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
              () => TapGestureRecognizer(debugOwner: this),
              (r) => r.onTapUp = _onTapUp,
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
          // AbsorbPointer below us starves xterm.dart's internal
          // recognizers (TerminalGestureHandler tap/long-press/drag-to-
          // select + TerminalScrollGestureHandler's alt-buffer
          // InfiniteScrollView) of pointer input. They are still in the
          // widget tree — rendering, focus, and keyboard plumbing rely
          // on it — but the gesture arena contention that produced the
          // original bug is gone because there is only one recognizer
          // family left: ours, above the absorber.
          child: AbsorbPointer(child: widget.child),
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
