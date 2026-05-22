import 'dart:ui' show Offset;

import 'package:xterm/xterm.dart';

// Tunables — surfaced at the top of the file so workers can fine-tune
// touch feel without spelunking through the dispatch logic. All values
// are in physical pixels / pixels-per-second.
const double kFastFlingVelocity = 800;
const double kMediumDragVelocityMin = 300;
const int kMediumDragBurstSize = 4;

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
    if (!terminal.isUsingAltBuffer) return;
    dispatchFling(
      terminal: terminal,
      down: down,
      rows: rows,
      cellAt: cellAt,
      anchor: _dragAnchor,
    );
  }

  // ---------------- stateless policy ----------------

  /// Emit `magnitude` per-cell scroll events in the direction `down`,
  /// targeted at whichever channel matches the terminal's current
  /// buffer / mouse-mode state.
  static void dispatchUnits({
    required Terminal terminal,
    required int magnitude,
    required bool down,
    required ({int col, int row}) Function(Offset) cellAt,
    required Offset anchor,
    required void Function(int lines) onScrollback,
  }) {
    if (magnitude <= 0) return;
    if (!terminal.isUsingAltBuffer) {
      onScrollback(down ? magnitude : -magnitude);
      return;
    }
    if (terminal.mouseMode.reportScroll) {
      final cell = cellAt(anchor);
      for (int i = 0; i < magnitude; i++) {
        terminal.onOutput?.call(_sgrWheel(cell, down: down));
      }
    } else {
      for (int i = 0; i < magnitude; i++) {
        terminal.keyInput(down ? TerminalKey.arrowDown : TerminalKey.arrowUp);
      }
    }
  }

  /// Emit a fling-sized burst. Normal buffer: no-op (per-cell increments
  /// during the drag already covered it; inertia would lie to the user).
  /// Alt + reportScroll: rows/2 wheel events at the drag-start cell.
  /// Alt + no mouse: a single PgUp / PgDn keystroke.
  static void dispatchFling({
    required Terminal terminal,
    required bool down,
    required int rows,
    required ({int col, int row}) Function(Offset) cellAt,
    required Offset anchor,
  }) {
    if (!terminal.isUsingAltBuffer) return;
    if (terminal.mouseMode.reportScroll) {
      final cell = cellAt(anchor);
      final ticks = (rows / 2).floor().clamp(1, rows);
      for (int i = 0; i < ticks; i++) {
        terminal.onOutput?.call(_sgrWheel(cell, down: down));
      }
    } else {
      terminal.keyInput(down ? TerminalKey.pageDown : TerminalKey.pageUp);
    }
  }

  static String _sgrWheel(({int col, int row}) cell, {required bool down}) {
    // Button 64 = wheel up, 65 = wheel down. Press-only `M`; xterm
    // convention does not emit a release for wheel buttons.
    final int button = down ? 65 : 64;
    return '\x1b[<$button;${cell.col};${cell.row}M';
  }
}
