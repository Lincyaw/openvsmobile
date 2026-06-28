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

enum _MultiTouchMode { none, undecided, pinch, pageScroll }

enum _SelectionHandle { start, end }

const double _kPinchActivationScaleDelta = 0.18;
const double _kPinchActivationDistancePixels = 24;
const double _kPinchUpdateScaleDelta = 0.015;
const double _kTwoFingerPageActivationPixels = 28;
const double _kTwoFingerPageStrideRows = 6;

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

typedef FontScaleHandler = void Function(double scaleFactor);

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
    this.requestKeyboard,
    this.onFontScale,
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

  /// xterm's render sink. The model is relative to the bottom of the
  /// scrollback; the controller is absolute (`0..maxScrollExtent`).
  final ScrollController scrollbackController;

  final Widget child;

  /// Called once when the host's State is available; the callback hands
  /// the parent a closure that triggers force-select-at-cursor. Lets the
  /// soft-keyboard toolbar drive selection without reaching into State.
  final ForceSelectRegistrar? registerForceSelect;

  /// Parent-owned keyboard request hook. The parent may own the FocusNode, so
  /// give it a chance to restore focus before asking xterm to show the IME.
  final VoidCallback? requestKeyboard;

  /// Called with incremental pinch scale factors. A factor above 1 should
  /// increase terminal font size; below 1 should decrease it.
  final FontScaleHandler? onFontScale;

  @override
  State<TerminalGestureHost> createState() => TerminalGestureHostState();
}

class TerminalGestureHostState extends State<TerminalGestureHost>
    with TickerProviderStateMixin {
  _Mode _mode = _Mode.view;

  // Drag state.
  Offset _dragAnchor = Offset.zero;
  double _residualDy = 0;
  VelocityTracker? _velocity;
  ScrollRouting? _dragRouting;
  AnimationController? _fling;
  double _flingLastPixels = 0;
  double _flingResidualDy = 0;
  int _flingUnitsEmitted = 0;
  final Map<int, Offset> _activePointers = <int, Offset>{};
  final Set<int> _multiTouchMovedPointers = <int>{};
  bool _pinchActive = false;
  _MultiTouchMode _multiTouchMode = _MultiTouchMode.none;
  double _multiTouchStartDistance = 0;
  double _pinchLastDistance = 0;
  Offset _multiTouchStartCentroid = Offset.zero;
  Offset _multiTouchLastCentroid = Offset.zero;
  double _twoFingerPageResidualDy = 0;

  void _resetDragState() {
    _residualDy = 0;
    _dragRouting = null;
  }

  double _pinchDistance() {
    final points = _activePointers.values.toList(growable: false);
    if (points.length < 2) return 0;
    return (points[0] - points[1]).distance;
  }

  Offset _multiTouchCentroid() {
    final points = _activePointers.values.toList(growable: false);
    if (points.length < 2) return Offset.zero;
    return Offset(
      (points[0].dx + points[1].dx) / 2,
      (points[0].dy + points[1].dy) / 2,
    );
  }

  void _resetMultiTouchState() {
    _pinchActive = false;
    _multiTouchMode = _MultiTouchMode.none;
    _multiTouchStartDistance = 0;
    _pinchLastDistance = 0;
    _multiTouchStartCentroid = Offset.zero;
    _multiTouchLastCentroid = Offset.zero;
    _twoFingerPageResidualDy = 0;
    _multiTouchMovedPointers.clear();
  }

  void _dispatchTwoFingerPage({required bool down}) {
    final key = down ? TerminalKey.pageDown : TerminalKey.pageUp;
    if (_diagOn) {
      _logDispatch('two-finger-page', down ? 'PgDn' : 'PgUp');
    }
    widget.terminal.keyInput(key);
  }

  double _twoFingerPageStride() =>
      (_cellHeight() * _kTwoFingerPageStrideRows).clamp(72, 160).toDouble();

  void _handleTwoFingerPageDelta(double deltaDy) {
    final stride = _twoFingerPageStride();
    if (stride <= 0) return;
    _twoFingerPageResidualDy -= deltaDy;
    final pages = (_twoFingerPageResidualDy / stride).truncate();
    if (pages == 0) return;
    _twoFingerPageResidualDy -= pages * stride;
    for (int i = 0; i < pages.abs(); i++) {
      _dispatchTwoFingerPage(down: pages > 0);
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    _activePointers[event.pointer] = event.localPosition;
    if (_activePointers.length == 2 && _mode != _Mode.select) {
      _stopFling();
      _velocity = null;
      _resetDragState();
      _pinchActive = true;
      _multiTouchMode = _MultiTouchMode.undecided;
      _multiTouchStartDistance = _pinchDistance();
      _pinchLastDistance = _multiTouchStartDistance;
      _multiTouchStartCentroid = _multiTouchCentroid();
      _multiTouchLastCentroid = _multiTouchStartCentroid;
      _twoFingerPageResidualDy = 0;
      _multiTouchMovedPointers.clear();
      _closeKeyboard();
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_activePointers.containsKey(event.pointer)) return;
    _activePointers[event.pointer] = event.localPosition;
    if (_mode == _Mode.select || !_pinchActive || _activePointers.length != 2) {
      return;
    }
    _multiTouchMovedPointers.add(event.pointer);
    if (_multiTouchMovedPointers.length < 2) return;
    _multiTouchMovedPointers.clear();

    final distance = _pinchDistance();
    final centroid = _multiTouchCentroid();
    if (distance <= 0 || _multiTouchStartDistance <= 0) {
      _pinchLastDistance = distance;
      _multiTouchLastCentroid = centroid;
      return;
    }

    bool handledActivationDelta = false;
    if (_multiTouchMode == _MultiTouchMode.undecided) {
      final startScale = distance / _multiTouchStartDistance;
      final scaleDelta = (startScale - 1).abs();
      final distanceDelta = (distance - _multiTouchStartDistance).abs();
      final centroidDelta = centroid - _multiTouchStartCentroid;
      final verticalTravel = centroidDelta.dy.abs();
      final activationDy = (_cellHeight() * 1.5)
          .clamp(_kTwoFingerPageActivationPixels, 80)
          .toDouble();
      final pageIntent =
          verticalTravel >= activationDy && verticalTravel >= distanceDelta;
      final pinchIntent =
          scaleDelta >= _kPinchActivationScaleDelta &&
          distanceDelta >= _kPinchActivationDistancePixels;
      if (pageIntent) {
        _multiTouchMode = _MultiTouchMode.pageScroll;
        _handleTwoFingerPageDelta(centroidDelta.dy);
        handledActivationDelta = true;
      } else if (pinchIntent) {
        _multiTouchMode = _MultiTouchMode.pinch;
      } else {
        return;
      }
    }

    switch (_multiTouchMode) {
      case _MultiTouchMode.pinch:
        final previous = _pinchLastDistance;
        if (previous <= 0) break;
        final scale = distance / previous;
        if (scale.isFinite && (scale - 1).abs() >= _kPinchUpdateScaleDelta) {
          widget.onFontScale?.call(scale);
        }
        break;
      case _MultiTouchMode.pageScroll:
        if (!handledActivationDelta) {
          _handleTwoFingerPageDelta((centroid - _multiTouchLastCentroid).dy);
        }
        break;
      case _MultiTouchMode.none:
      case _MultiTouchMode.undecided:
        break;
    }
    _pinchLastDistance = distance;
    _multiTouchLastCentroid = centroid;
  }

  void _onPointerEnd(PointerEvent event) {
    _activePointers.remove(event.pointer);
    if (_activePointers.length < 2) {
      _resetMultiTouchState();
    } else {
      _pinchLastDistance = _pinchDistance();
      _multiTouchLastCentroid = _multiTouchCentroid();
      _multiTouchMovedPointers.clear();
    }
  }

  void _requestKeyboard() {
    if (widget.requestKeyboard != null) {
      widget.requestKeyboard!();
      return;
    }
    widget.terminalViewKey.currentState?.requestKeyboard();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.terminalViewKey.currentState?.requestKeyboard();
    });
  }

  void _closeKeyboard() {
    widget.terminalViewKey.currentState?.closeKeyboard();
  }

  void _stopFling() {
    final fling = _fling;
    if (fling == null) return;
    _fling = null;
    fling
      ..stop()
      ..dispose();
    _flingLastPixels = 0;
    _flingResidualDy = 0;
    _flingUnitsEmitted = 0;
  }

  // Select-mode anchor for character extension.
  Offset? _selectAnchor;

  bool _lastAltBuffer = false;

  @override
  void initState() {
    super.initState();
    _lastAltBuffer = widget.terminal.isUsingAltBuffer;
    widget.terminal.addListener(_onTerminalChanged);
    widget.terminalController.addListener(_onSelectionChanged);
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
      _stopFling();
    }
    if (oldWidget.terminalController != widget.terminalController) {
      oldWidget.terminalController.removeListener(_onSelectionChanged);
      widget.terminalController.addListener(_onSelectionChanged);
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
    _stopFling();
    widget.terminal.removeListener(_onTerminalChanged);
    widget.terminalController.removeListener(_onSelectionChanged);
    widget.scrollback.removeListener(_syncScrollSink);
    super.dispose();
  }

  void _onSelectionChanged() {
    if (!mounted || _mode != _Mode.select) return;
    setState(() {});
  }

  void _onTerminalChanged() {
    final nowAlt = widget.terminal.isUsingAltBuffer;
    if (nowAlt != _lastAltBuffer) {
      _lastAltBuffer = nowAlt;
      _stopFling();
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
    final position = widget.scrollbackController.position;
    final maxExtent = position.maxScrollExtent;
    final target = maxExtent + widget.scrollback.offsetLines * lineHeight;
    final clamped = target.clamp(position.minScrollExtent, maxExtent);
    widget.scrollbackController.jumpTo(clamped);
    // Mirror the clamp back into the model so out-of-range delta does
    // not accumulate as phantom offset that a reverse drag must "burn".
    final clampedLines = ((clamped - maxExtent) / lineHeight).round();
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
    _stopFling();
    _closeKeyboard();
    state.renderTerminal.selectWord(localPos);
    _selectAnchor = localPos;
    setState(() => _mode = _Mode.select);
  }

  void _exitSelect({bool clear = true, bool restoreKeyboard = true}) {
    if (clear) {
      widget.terminalController.clearSelection();
    }
    _selectAnchor = null;
    if (_mode != _Mode.view) {
      setState(() => _mode = _Mode.view);
    }
    if (restoreKeyboard) {
      _requestKeyboard();
    }
  }

  Future<bool> _copySelection() async {
    final selection = widget.terminalController.selection;
    if (selection == null) return false;
    final text = widget.terminal.buffer.getText(selection);
    if (text.isEmpty) return false;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return true;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Copied ${text.length} characters'),
          duration: const Duration(seconds: 1),
        ),
      );
    return true;
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

  CellOffset? _cellOffsetAtGlobal(
    Offset globalPosition, {
    required bool endExclusive,
  }) {
    final renderObject = context.findRenderObject();
    final state = widget.terminalViewKey.currentState;
    if (renderObject is! RenderBox || state == null) return null;
    final local = renderObject.globalToLocal(globalPosition);
    final cell = state.renderTerminal.getCellOffset(local);
    if (!endExclusive) return cell;
    final endX = cell.x + 1 > widget.terminal.viewWidth
        ? widget.terminal.viewWidth
        : cell.x + 1;
    return CellOffset(endX, cell.y);
  }

  void _dragSelectionHandle(_SelectionHandle handle, Offset globalPosition) {
    final current = widget.terminalController.selection?.normalized;
    if (current == null) return;
    final moved = _cellOffsetAtGlobal(
      globalPosition,
      endExclusive: handle == _SelectionHandle.end,
    );
    if (moved == null) return;
    final begin = handle == _SelectionHandle.start ? moved : current.begin;
    final end = handle == _SelectionHandle.end ? moved : current.end;
    widget.terminalController.setSelection(
      widget.terminal.buffer.createAnchorFromOffset(begin),
      widget.terminal.buffer.createAnchorFromOffset(end),
      mode: SelectionMode.line,
    );
  }

  void _startSelectionHandleDrag(
    _SelectionHandle handle,
    Offset globalPosition,
  ) {
    HapticFeedback.selectionClick();
    _dragSelectionHandle(handle, globalPosition);
  }

  Offset? _selectionHandleOffset(CellOffset cell) {
    final state = widget.terminalViewKey.currentState;
    if (state == null) return null;
    final render = state.renderTerminal;
    final offset = render.getOffset(cell);
    return Offset(offset.dx, offset.dy + render.cellSize.height);
  }

  CellOffset _visualSelectionEnd(BufferRange selection) {
    final end = selection.end;
    if (end.x == 0 && end.y > selection.begin.y) {
      return CellOffset(widget.terminal.viewWidth, end.y - 1);
    }
    return end;
  }

  Widget _buildSelectionHandles() {
    final selection = widget.terminalController.selection?.normalized;
    if (selection == null) return const SizedBox.shrink();
    final start = _selectionHandleOffset(selection.begin);
    final end = _selectionHandleOffset(_visualSelectionEnd(selection));
    if (start == null || end == null) return const SizedBox.shrink();
    final color = Theme.of(context).colorScheme.primary;
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            children: [
              _SelectionHandleControl(
                key: const ValueKey('terminal-selection-start-handle'),
                position: start,
                color: color,
                constraints: constraints,
                onDragStart: (global) =>
                    _startSelectionHandleDrag(_SelectionHandle.start, global),
                onDragUpdate: (global) =>
                    _dragSelectionHandle(_SelectionHandle.start, global),
              ),
              _SelectionHandleControl(
                key: const ValueKey('terminal-selection-end-handle'),
                position: end,
                color: color,
                constraints: constraints,
                onDragStart: (global) =>
                    _startSelectionHandleDrag(_SelectionHandle.end, global),
                onDragUpdate: (global) =>
                    _dragSelectionHandle(_SelectionHandle.end, global),
              ),
            ],
          );
        },
      ),
    );
  }

  // ---------- recognizer callbacks ----------

  void _onTapDown(TapDownDetails details) {
    if (_pinchActive || _activePointers.length > 1) return;
    final state = widget.terminalViewKey.currentState;
    if (state == null) return;
    // Focus first so the soft keyboard is brought up before any TUI
    // mouse-down round-trips.
    _requestKeyboard();
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
    if (_pinchActive || _activePointers.length > 1) return;
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
    if (_pinchActive || _activePointers.length > 1) return;
    _enterSelect(details.localPosition);
  }

  void _onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    if (_mode != _Mode.select) return;
    final state = widget.terminalViewKey.currentState;
    if (state == null || _selectAnchor == null) return;
    state.renderTerminal.selectCharacters(
      _selectAnchor!,
      details.localPosition,
    );
  }

  void _onVerticalDragStart(DragStartDetails d) {
    if (_pinchActive || _activePointers.length > 1) {
      _velocity = null;
      _resetDragState();
      return;
    }
    _stopFling();
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
    if (_pinchActive || _activePointers.length > 1 || _dragRouting == null) {
      return;
    }
    _velocity?.addPosition(
      d.sourceTimeStamp ?? Duration.zero,
      d.globalPosition,
    );

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
        DiagLog.instance.log(
          DiagCat.terminal,
          '  ! drag-update dropped: cellHeight<=0',
        );
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
    if (_pinchActive || _dragRouting == null) {
      _velocity = null;
      _resetDragState();
      return;
    }
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
    if (_diagOn) {
      DiagLog.instance.log(
        DiagCat.terminal,
        '  drag end v=${velocity.toStringAsFixed(0)} → fling',
      );
    }
    _startAnimatedFling(
      velocityY: velocity,
      routing: _dragRouting ?? ScrollRouting.capture(widget.terminal),
    );
    _resetDragState();
  }

  void _onVerticalDragCancel() {
    _velocity = null;
    _resetDragState();
  }

  void _startAnimatedFling({
    required double velocityY,
    required ScrollRouting routing,
  }) {
    final cellH = _cellHeight();
    if (cellH <= 0) return;
    _stopFling();
    if (routing.isAltBuffer && !routing.reportScroll) {
      if (_diagOn) {
        _logDispatch(
          'fling-alt-noop',
          'no mouse tracking; alternate buffer has no transcript scrollback',
        );
      }
      return;
    }
    final fling = AnimationController.unbounded(vsync: this);
    _fling = fling;
    _flingLastPixels = 0;
    _flingResidualDy = 0;
    _flingUnitsEmitted = 0;
    final maxAltUnits = (widget.terminal.viewHeight / 2)
        .floor()
        .clamp(1, widget.terminal.viewHeight)
        .toInt();

    fling.addListener(() {
      if (_fling != fling) return;
      final current = fling.value;
      final deltaPixels = current - _flingLastPixels;
      _flingLastPixels = current;
      _flingResidualDy -= deltaPixels;
      final units = (_flingResidualDy / cellH).truncate();
      if (units == 0) return;
      _flingResidualDy -= units * cellH;

      var magnitude = units.abs();
      if (routing.isAltBuffer) {
        final remaining = maxAltUnits - _flingUnitsEmitted;
        if (remaining <= 0) {
          _stopFling();
          return;
        }
        magnitude = magnitude.clamp(1, remaining).toInt();
        _flingUnitsEmitted += magnitude;
      }

      final before = widget.scrollback.offsetLines;
      TerminalScrollAdapter.dispatchUnits(
        terminal: widget.terminal,
        magnitude: magnitude,
        down: units > 0,
        cellAt: _cellAt,
        anchor: _dragAnchor,
        onScrollback: widget.scrollback.scrollBy,
        routing: routing,
        onDiag: _diagOn ? _logDispatch : null,
      );
      if (!routing.isAltBuffer &&
          widget.scrollback.offsetLines == before &&
          magnitude > 0) {
        _stopFling();
      } else if (routing.isAltBuffer && _flingUnitsEmitted >= maxAltUnits) {
        _stopFling();
      }
    });
    fling.addStatusListener((status) {
      if (status == AnimationStatus.completed ||
          status == AnimationStatus.dismissed) {
        _stopFling();
      }
    });
    fling.animateWith(
      ClampingScrollSimulation(position: 0, velocity: velocityY),
    );
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
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerEnd,
          onPointerCancel: _onPointerEnd,
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
              LongPressGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    LongPressGestureRecognizer
                  >(() => LongPressGestureRecognizer(debugOwner: this), (r) {
                    r.onLongPressStart = _onLongPressStart;
                    r.onLongPressMoveUpdate = _onLongPressMoveUpdate;
                  }),
              VerticalDragGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    VerticalDragGestureRecognizer
                  >(() => VerticalDragGestureRecognizer(debugOwner: this), (r) {
                    r.onStart = _onVerticalDragStart;
                    r.onUpdate = _onVerticalDragUpdate;
                    r.onEnd = _onVerticalDragEnd;
                    r.onCancel = _onVerticalDragCancel;
                  }),
            },
            // AbsorbPointer starves xterm's internal recognizers so only
            // ours remain in the gesture arena.
            child: AbsorbPointer(child: widget.child),
          ),
        ),
        if (_mode == _Mode.select) _buildSelectionHandles(),
        if (_mode == _Mode.select)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Focus(
              canRequestFocus: false,
              descendantsAreFocusable: false,
              child: _SelectionToolbar(
                onCopy: () async {
                  final copied = await _copySelection();
                  if (mounted && copied) _exitSelect();
                },
                onSelectAll: _selectAll,
                onDismiss: () => _exitSelect(),
              ),
            ),
          ),
      ],
    );
  }

  /// Force-select entry point for the soft-keyboard toolbar.
  void forceSelectAtCursor() {
    final state = widget.terminalViewKey.currentState;
    if (state == null) return;
    final size = state.renderTerminal.size;
    _enterSelect(Offset(size.width / 2, size.height / 2));
  }
}

class _SelectionHandleControl extends StatelessWidget {
  const _SelectionHandleControl({
    super.key,
    required this.position,
    required this.color,
    required this.constraints,
    required this.onDragStart,
    required this.onDragUpdate,
  });

  static const double _hitSize = 44;
  static const double _stemHeight = 18;
  static const double _knobSize = 18;

  final Offset position;
  final Color color;
  final BoxConstraints constraints;
  final ValueChanged<Offset> onDragStart;
  final ValueChanged<Offset> onDragUpdate;

  @override
  Widget build(BuildContext context) {
    final left = (position.dx - _hitSize / 2)
        .clamp(0.0, constraints.maxWidth - _hitSize)
        .toDouble();
    final top = (position.dy - 4)
        .clamp(0.0, constraints.maxHeight - _hitSize)
        .toDouble();
    return Positioned(
      left: left,
      top: top,
      width: _hitSize,
      height: _hitSize,
      child: Semantics(
        label: 'Selection handle',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (details) => onDragStart(details.globalPosition),
          onPanUpdate: (details) => onDragUpdate(details.globalPosition),
          child: Align(
            alignment: Alignment.topCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 2, height: _stemHeight, color: color),
                Container(
                  width: _knobSize,
                  height: _knobSize,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Theme.of(context).colorScheme.surface,
                      width: 2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.25),
                        blurRadius: 4,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
