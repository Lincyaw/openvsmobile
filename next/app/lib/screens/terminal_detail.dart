// Full-screen terminal detail view. Pushed as a root-level MaterialPageRoute
// from the Terminal-tab session list, so the home shell's bottom nav and
// workspace chooser are not in the widget tree — both naturally disappear.
// System back pops this route and returns the user to the session list.
//
// PTY lifecycle is unchanged — popping the detail view does NOT call
// terminal.dispose; the live `Terminal` instance comes from
// `AppState.terminalFor`, which keeps it across rebuilds so scrollback
// survives.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../app_state.dart';
import '../services/terminal_scroll_adapter.dart';

class TerminalDetailScreen extends StatelessWidget {
  final AppState appState;
  final String sessionId;
  final String title;

  const TerminalDetailScreen({
    super.key,
    required this.appState,
    required this.sessionId,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    // Listenable.merge so the screen rebuilds both when AppState fires
    // (focus or session list change) and when the session's underlying
    // Terminal generation bumps (reconnect history replay). The TerminalView
    // itself listens to the Terminal directly.
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        final terminal = appState.terminalFor(sessionId);
        final generation = appState.terminalGenerationFor(sessionId);
        return Scaffold(
          appBar: AppBar(
            // Default leading is the system back button — that's the
            // "slim back affordance" the brief calls for.
            title: Text(
              title,
              style: const TextStyle(fontSize: 16),
            ),
            titleSpacing: 0,
          ),
          body: TerminalSessionView(
            // ValueKey forces a fresh state when the underlying Terminal is
            // swapped (e.g. after a reconnect-replay).
            key: ValueKey('$sessionId#$generation'),
            terminal: terminal,
          ),
        );
      },
    );
  }
}

/// xterm.dart TerminalView + the soft-keyboard companion key strip. Kept
/// outside TerminalDetailScreen so the underlying state (sticky Ctrl flag,
/// output interceptor wiring) survives focus changes that only rebuild the
/// outer Scaffold.
class TerminalSessionView extends StatefulWidget {
  final Terminal terminal;
  const TerminalSessionView({super.key, required this.terminal});

  @override
  State<TerminalSessionView> createState() => _TerminalSessionViewState();
}

class _TerminalSessionViewState extends State<TerminalSessionView> {
  final TerminalController _ctrl = TerminalController();
  final GlobalKey<TerminalViewState> _terminalViewKey =
      GlobalKey<TerminalViewState>();
  final ScrollController _scrollback = ScrollController();
  late final TerminalScrollAdapter _scrollAdapter;

  /// Sticky-modifier state. When armed, the next keystroke routed through
  /// the Terminal's onOutput (soft keyboard or toolbar) has Ctrl applied,
  /// then auto-disarms. Termux-style.
  bool _ctrlArmed = false;
  void Function(String)? _origOnOutput;
  TerminalMouseHandler? _origMouseHandler;
  _WheelSuppressingMouseHandler? _mouseHandlerProxy;

  int? _activePointer;
  VelocityTracker? _dragTracker;

  @override
  void initState() {
    super.initState();
    _origOnOutput = widget.terminal.onOutput;
    widget.terminal.onOutput = _onOutputProxy;
    // Suppress xterm.dart's built-in wheel emission so it doesn't
    // double-fire alongside our adapter. The adapter emits SGR wheel
    // reports regardless of which mouse mode the app requested (see
    // adapter doc), and xterm's internal TerminalScrollGestureHandler
    // would otherwise *also* emit a wheel report (in whatever encoding
    // the app last requested) for the same touch drag.
    _origMouseHandler = widget.terminal.mouseHandler;
    _mouseHandlerProxy = _WheelSuppressingMouseHandler(_origMouseHandler);
    widget.terminal.mouseHandler = _mouseHandlerProxy;
    _scrollAdapter = TerminalScrollAdapter(
      terminal: widget.terminal,
      cellAt: _cellAt,
      onScrollback: _noopScrollback,
    );
  }

  @override
  void dispose() {
    // Be defensive: only restore if we're still the installed proxy. If
    // some other layer rewired onOutput / mouseHandler between init and
    // now, leave it alone — touching it would clobber their handler.
    if (widget.terminal.onOutput == _onOutputProxy) {
      widget.terminal.onOutput = _origOnOutput;
    }
    if (widget.terminal.mouseHandler == _mouseHandlerProxy) {
      widget.terminal.mouseHandler = _origMouseHandler;
    }
    _scrollback.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  /// Pixel → 1-based cell coordinate via xterm.dart's render object.
  /// Returns (1, 1) before the first frame paints (rare — gestures
  /// require the view to already be hit-testable).
  ({int col, int row}) _cellAt(Offset localPos) {
    final state = _terminalViewKey.currentState;
    if (state == null) return (col: 1, row: 1);
    final cell = state.renderTerminal.getCellOffset(localPos);
    return (col: cell.x + 1, row: cell.y + 1);
  }

  double _currentCellHeight() {
    final state = _terminalViewKey.currentState;
    if (state == null) return 16;
    return state.renderTerminal.lineHeight;
  }

  /// Normal-buffer scrollback in production is driven by xterm.dart's own
  /// outer Scrollable (which our Listener does not steal pointer events
  /// from), so the adapter's scrollback sink is a no-op here. The
  /// adapter still emits per-cell increments — they're verified by the
  /// unit tests — but we don't double-scroll the controller alongside
  /// xterm.
  void _noopScrollback(int lines) {}

  /// Intercepts every byte heading to the PTY. When Ctrl is armed, swap
  /// a single ASCII letter / [\]^_ / ? for its control byte and disarm.
  /// Multi-byte sequences (escape codes from arrow toolbar buttons, etc.)
  /// pass through — the toolbar path already applied ctrl via keyInput.
  void _onOutputProxy(String data) {
    if (_ctrlArmed) {
      final transformed = _ctrlMaybeTransform(data);
      _origOnOutput?.call(transformed);
      if (mounted) setState(() => _ctrlArmed = false);
      return;
    }
    _origOnOutput?.call(data);
  }

  String _ctrlMaybeTransform(String data) {
    if (data.length != 1) return data;
    final c = data.codeUnitAt(0);
    // A-Z / a-z → 0x01-0x1a
    if (c >= 0x41 && c <= 0x5a) return String.fromCharCode(c - 0x40);
    if (c >= 0x61 && c <= 0x7a) return String.fromCharCode(c - 0x60);
    // [ \ ] ^ _ → 0x1b-0x1f
    if (c >= 0x5b && c <= 0x5f) return String.fromCharCode(c - 0x40);
    // ? → 0x7f (DEL), matches Termux / typical xterm behavior.
    if (c == 0x3f) return String.fromCharCode(0x7f);
    return data;
  }

  void _toggleCtrl() {
    setState(() => _ctrlArmed = !_ctrlArmed);
  }

  void _sendKey(TerminalKey key) {
    widget.terminal.keyInput(key, ctrl: _ctrlArmed);
    if (_ctrlArmed && mounted) {
      setState(() => _ctrlArmed = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Listener observes raw pointer events without entering the gesture
    // arena, so xterm.dart's own tap / long-press / vertical-drag
    // recognizers keep firing too. Concretely:
    //   * tap-to-cursor (htop & friends) — xterm.dart's tap handler
    //     fires from the same pointer events; we don't claim them.
    //   * back-swipe horizontal pan (#63's IM-style nav) — we ignore
    //     horizontal motion entirely.
    //   * normal-buffer scrollback — xterm.dart's outer Scrollable
    //     drives `_scrollback` natively; our adapter's `onScrollback`
    //     sink is wired to a no-op in production so we don't double-
    //     scroll.
    //   * alt-buffer wheel reports — xterm.dart's internal wheel path
    //     is silenced via `_WheelSuppressingMouseHandler` and
    //     `simulateScroll: false`, leaving the adapter as the sole
    //     source of escape sequences in alt buffer.
    return Column(
      children: [
        Expanded(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerCancel,
            child: TerminalView(
              widget.terminal,
              key: _terminalViewKey,
              controller: _ctrl,
              scrollController: _scrollback,
              autofocus: true,
              backgroundOpacity: 1.0,
              simulateScroll: false,
            ),
          ),
        ),
        _KeyToolbar(
          ctrlArmed: _ctrlArmed,
          onCtrl: _toggleCtrl,
          onKey: _sendKey,
        ),
      ],
    );
  }

  void _onPointerDown(PointerDownEvent event) {
    // Track only the first finger; subsequent touches (pinch, multitouch
    // selection) are intentionally ignored by the scroll layer.
    if (_activePointer != null) return;
    _activePointer = event.pointer;
    _dragTracker = VelocityTracker.withKind(event.kind);
    _dragTracker!.addPosition(event.timeStamp, event.position);
    _scrollAdapter.onDragStart(event.localPosition);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _activePointer) return;
    _dragTracker?.addPosition(event.timeStamp, event.position);
    _scrollAdapter.onDragUpdate(
      deltaDy: event.delta.dy,
      cellHeight: _currentCellHeight(),
    );
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _activePointer) return;
    final dy = _dragTracker?.getVelocity().pixelsPerSecond.dy ?? 0;
    _scrollAdapter.onDragEnd(
      velocityDy: dy,
      rows: widget.terminal.viewHeight,
    );
    _activePointer = null;
    _dragTracker = null;
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer != _activePointer) return;
    _scrollAdapter.onDragEnd(
      velocityDy: 0,
      rows: widget.terminal.viewHeight,
    );
    _activePointer = null;
    _dragTracker = null;
  }
}

/// Wraps the terminal's default mouse handler to discard wheel-up /
/// wheel-down events that xterm.dart's internal scroll handler would
/// otherwise translate into the (potentially non-SGR) mouse-report
/// encoding the app last requested. Real mouse clicks (left/right/
/// middle/release) still pass through.
class _WheelSuppressingMouseHandler implements TerminalMouseHandler {
  _WheelSuppressingMouseHandler(this._inner);
  final TerminalMouseHandler? _inner;

  @override
  String? call(TerminalMouseEvent event) {
    if (event.button == TerminalMouseButton.wheelUp ||
        event.button == TerminalMouseButton.wheelDown) {
      return null;
    }
    return _inner?.call(event);
  }
}

/// Soft-keyboard companion: a horizontally scrollable strip of keys the
/// Android soft keyboard doesn't surface easily — Esc, Tab, arrows, Home,
/// End. Ctrl is a sticky modifier; tap once to arm, the next key
/// (toolbar or soft keyboard) applies Ctrl and auto-disarms.
class _KeyToolbar extends StatelessWidget {
  final bool ctrlArmed;
  final VoidCallback onCtrl;
  final void Function(TerminalKey) onKey;
  const _KeyToolbar({
    required this.ctrlArmed,
    required this.onCtrl,
    required this.onKey,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 2,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            children: [
              _KeyBtn(label: 'Esc', onTap: () => onKey(TerminalKey.escape)),
              _KeyBtn(label: 'Tab', onTap: () => onKey(TerminalKey.tab)),
              _KeyBtn(
                label: 'Ctrl',
                onTap: onCtrl,
                highlighted: ctrlArmed,
              ),
              _KeyBtn(label: '←', onTap: () => onKey(TerminalKey.arrowLeft)),
              _KeyBtn(label: '→', onTap: () => onKey(TerminalKey.arrowRight)),
              _KeyBtn(label: '↑', onTap: () => onKey(TerminalKey.arrowUp)),
              _KeyBtn(label: '↓', onTap: () => onKey(TerminalKey.arrowDown)),
              _KeyBtn(label: 'Home', onTap: () => onKey(TerminalKey.home)),
              _KeyBtn(label: 'End', onTap: () => onKey(TerminalKey.end)),
              _KeyBtn(label: 'PgUp', onTap: () => onKey(TerminalKey.pageUp)),
              _KeyBtn(label: 'PgDn', onTap: () => onKey(TerminalKey.pageDown)),
              _KeyBtn(label: 'Del', onTap: () => onKey(TerminalKey.delete)),
            ],
          ),
        ),
      ),
    );
  }
}

class _KeyBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool highlighted;
  const _KeyBtn({
    required this.label,
    required this.onTap,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    const padding = EdgeInsets.symmetric(horizontal: 12);
    const minSize = Size(40, 36);
    const density = VisualDensity.compact;
    final text = Text(label, style: const TextStyle(fontSize: 13));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: highlighted
          ? FilledButton(
              onPressed: onTap,
              style: FilledButton.styleFrom(
                padding: padding,
                visualDensity: density,
                minimumSize: minSize,
              ),
              child: text,
            )
          : OutlinedButton(
              onPressed: onTap,
              style: OutlinedButton.styleFrom(
                padding: padding,
                visualDensity: density,
                minimumSize: minSize,
              ),
              child: text,
            ),
    );
  }
}
