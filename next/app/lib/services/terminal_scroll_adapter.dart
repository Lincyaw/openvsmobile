import 'dart:ui' show Offset;

import 'package:xterm/xterm.dart';

// Tunables — surfaced at the top of the file so workers can fine-tune
// touch feel without spelunking through the dispatch logic. All values
// are in physical pixels / pixels-per-second.
const double kFastFlingVelocity = 800;
const double kMediumDragVelocityMin = 300;
const int kMediumDragBurstSize = 4;

/// Snapshot of the terminal flags that determine scroll routing.
/// Captured once at drag-start and reused for the entire gesture so that
/// transient buffer-switches (e.g. zellij redraws that briefly exit alt
/// buffer) cannot flip the routing mid-swipe.
class ScrollRouting {
  ScrollRouting.capture(Terminal terminal)
    : isAltBuffer = terminal.isUsingAltBuffer,
      reportScroll = terminal.mouseMode.reportScroll,
      altScrollMode = terminal.altBufferMouseScrollMode;

  /// Use pre-captured [routing] if available, otherwise snapshot [terminal].
  factory ScrollRouting.resolve(ScrollRouting? routing, Terminal terminal) =>
      routing ?? ScrollRouting.capture(terminal);

  final bool isAltBuffer;
  final bool reportScroll;

  /// DEC mode 1007. Captured for diagnostics, but Termux touch scrolling does
  /// not branch on it: alt buffer without mouse tracking maps to arrow keys.
  final bool altScrollMode;
}

/// Pure-policy helper for routing per-cell scroll units and fling events
/// to the right side-effect channel based on the terminal's *own* state.
/// New callers should use the static helpers (`dispatchUnits`,
/// `dispatchFling`). The stateful instance API is retained only so the
/// pre-existing unit tests covering quantization / residual handling
/// keep running; it is `@Deprecated` to discourage two-ways-to-do-the-
/// same-thing drift.
///
/// Direction vocabulary: `down` follows natural-scroll semantics — a
/// downward finger drag is a `down: false` event (reveal earlier
/// content → arrow ↑ / SGR wheel-up / PageUp). The host flips raw pointer
/// dy at its input boundary so callers can speak in user-intent terms.
class TerminalScrollAdapter {
  @Deprecated(
    'use TerminalScrollAdapter.dispatchUnits / dispatchFling. The stateful '
    'API is retained only for the existing unit-test surface.',
  )
  TerminalScrollAdapter({
    required this.terminal,
    required this.cellAt,
    required this.onScrollback,
  });

  final Terminal terminal;
  final ({int col, int row}) Function(Offset) cellAt;
  final void Function(int lines) onScrollback;

  Offset _dragAnchor = Offset.zero;
  double _residualDy = 0;
  bool _dragActive = false;

  @Deprecated('use TerminalScrollAdapter.dispatchUnits / dispatchFling')
  void onDragStart(Offset localPosition) {
    _dragAnchor = localPosition;
    _residualDy = 0;
    _dragActive = true;
  }

  @Deprecated('use TerminalScrollAdapter.dispatchUnits / dispatchFling')
  void onDragUpdate({required double deltaDy, required double cellHeight}) {
    if (!_dragActive || cellHeight <= 0) return;
    _residualDy -= deltaDy;
    final int units = (_residualDy / cellHeight).truncate();
    if (units == 0) return;
    _residualDy -= units * cellHeight;
    dispatchUnits(
      terminal: terminal,
      magnitude: units.abs(),
      down: units > 0,
      cellAt: cellAt,
      anchor: _dragAnchor,
      onScrollback: onScrollback,
    );
  }

  @Deprecated('use TerminalScrollAdapter.dispatchUnits / dispatchFling')
  void onDragEnd({required double velocityDy, required int rows}) {
    if (!_dragActive) return;
    _dragActive = false;
    _residualDy = 0;
    if (velocityDy.abs() < kFastFlingVelocity) return;
    final bool down = velocityDy < 0;
    dispatchFling(
      terminal: terminal,
      down: down,
      rows: rows,
      cellAt: cellAt,
      anchor: _dragAnchor,
      onScrollback: onScrollback,
    );
  }

  // ---------------- stateless policy ----------------

  /// Emit `magnitude` per-cell scroll events in the direction `down`,
  /// targeted at whichever channel matches the terminal's current
  /// buffer / mouse-mode state.
  ///
  /// When [routing] is provided, the pre-captured flags override the
  /// live terminal state. This prevents transient buffer-switches from
  /// flipping the dispatch mid-gesture.
  ///
  /// Routing priority (exactly one fires):
  ///   1. Normal buffer → scrollback model
  ///   2. Alt buffer + mouse reportScroll → SGR wheel events
  ///   3. Alt buffer + no mouse → row-level arrow-key fallback, matching
  ///      Termux's TerminalView#doScroll.
  static void dispatchUnits({
    required Terminal terminal,
    required int magnitude,
    required bool down,
    required ({int col, int row}) Function(Offset) cellAt,
    required Offset anchor,
    required void Function(int lines) onScrollback,
    ScrollRouting? routing,
    void Function(String branch, String detail)? onDiag,
  }) {
    if (magnitude <= 0) return;
    final r = ScrollRouting.resolve(routing, terminal);
    if (!r.isAltBuffer) {
      onDiag?.call('scrollback', 'lines=${down ? magnitude : -magnitude}');
      onScrollback(down ? magnitude : -magnitude);
      return;
    }
    if (r.reportScroll) {
      final cell = cellAt(anchor);
      final seq = _sgrWheel(cell, down: down);
      onDiag?.call('wheel', 'x$magnitude cell=(${cell.col},${cell.row}) $seq');
      for (int i = 0; i < magnitude; i++) {
        terminal.onOutput?.call(seq);
      }
    } else {
      onDiag?.call('arrows', 'x$magnitude ${down ? 'Down' : 'Up'}');
      for (int i = 0; i < magnitude; i++) {
        terminal.keyInput(down ? TerminalKey.arrowDown : TerminalKey.arrowUp);
      }
    }
  }

  /// Emit a fling-sized burst.
  /// Normal buffer: a half-page scrollback burst so momentum feels natural.
  /// Alt + reportScroll: rows/2 wheel events at the drag-start cell.
  /// Alt + no mouse: no-op. Termux flings without mouse tracking by scrolling
  /// transcript history; the alternate buffer has no transcript history.
  static void dispatchFling({
    required Terminal terminal,
    required bool down,
    required int rows,
    required ({int col, int row}) Function(Offset) cellAt,
    required Offset anchor,
    void Function(int lines)? onScrollback,
    ScrollRouting? routing,
    void Function(String branch, String detail)? onDiag,
  }) {
    final r = ScrollRouting.resolve(routing, terminal);
    if (!r.isAltBuffer) {
      final burst = (rows / 2).floor().clamp(1, rows);
      onDiag?.call('fling-scrollback', 'lines=${down ? burst : -burst}');
      onScrollback?.call(down ? burst : -burst);
      return;
    }
    if (r.reportScroll) {
      final cell = cellAt(anchor);
      final ticks = (rows / 2).floor().clamp(1, rows);
      final seq = _sgrWheel(cell, down: down);
      onDiag?.call(
        'fling-wheel',
        'x$ticks cell=(${cell.col},${cell.row}) $seq',
      );
      for (int i = 0; i < ticks; i++) {
        terminal.onOutput?.call(seq);
      }
    } else {
      onDiag?.call('fling-alt-noop', 'alternate buffer has no transcript');
    }
  }

  static String _sgrWheel(({int col, int row}) cell, {required bool down}) {
    // Button 64 = wheel up, 65 = wheel down. Press-only `M`; xterm
    // convention does not emit a release for wheel buttons.
    final int button = down ? 65 : 64;
    return '\x1b[<$button;${cell.col};${cell.row}M';
  }
}
