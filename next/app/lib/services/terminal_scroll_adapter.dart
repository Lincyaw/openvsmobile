import 'dart:ui' show Offset;

import 'package:xterm/xterm.dart';

// Tunables — surfaced at the top of the file so workers can fine-tune
// touch feel without spelunking through the dispatch logic. All values
// are in physical pixels / pixels-per-second.
const double kFastFlingVelocity = 800;
const double kMediumDragVelocityMin = 300;
const int kMediumDragBurstSize = 4;

/// Routes vertical touch drags on the terminal viewport to one of three
/// destinations based on the terminal's *own* state:
///
///   normal buffer        → host scrollback (no inertia synthesised by us
///                          because scrollback drag is "direct manipulation"
///                          — the user already lifted their finger; piling
///                          on phantom ticks would surprise them)
///   alt + no mouse       → arrow ↑ / ↓ per cell-height, PgUp / PgDn on fling
///                          (apps without mouse reporting expect keystrokes)
///   alt + reportScroll   → SGR wheel reports `\e[<64..65;col;rowM` at the
///                          *drag-start* cell (matches desktop wheel
///                          semantics: the wheel reports where you started,
///                          not where the cursor currently is)
///
/// **Directionality matches mobile direct-manipulation** (the same model
/// as macOS natural-scroll, default since ~2011): a downward finger drag
/// pulls earlier content into view — i.e. the visible window moves *up*
/// over the buffer. So a downward drag emits `arrowUp` / SGR wheel-up
/// (button 64) / PageUp, and an upward drag emits the opposite. The
/// adapter flips raw pointer dy at its input boundary so its internal
/// `down` vocabulary means "natural-scroll-down direction" — i.e. the
/// keystroke we want to synthesise, not the direction the finger went.
///
/// The asymmetry around inertia is deliberate: in normal-buffer scrollback
/// the xterm.dart view owns a real scroll position, and our callers are
/// expected to drive it directly. In alt-buffer paths the side-effect is
/// the *application's* responsibility to interpret, and silently emitting
/// "ghost" wheel/arrow events after the finger lifts would lie to the
/// running TUI about user intent.
class TerminalScrollAdapter {
  TerminalScrollAdapter({
    required this.terminal,
    required this.cellAt,
    required this.onScrollback,
  });

  /// State source. We never mirror buffer / mouseMode locally — the
  /// terminal *is* the source of truth and reading it on each gesture
  /// avoids a stale-flag class of bug.
  final Terminal terminal;

  /// Pixel → 1-based `(col, row)` mapper. Production wires this to the
  /// xterm.dart render-object's `getCellOffset`; tests stub it.
  final ({int col, int row}) Function(Offset) cellAt;

  /// Normal-buffer scroll sink. Signed integer; positive matches the
  /// natural-scroll-down direction (i.e. the user dragged *up* and wants
  /// to see later content). Callers translate sign into whatever
  /// scrollback API the view exposes.
  final void Function(int lines) onScrollback;

  Offset _dragAnchor = Offset.zero;
  double _residualDy = 0;
  bool _dragActive = false;

  /// Begins a drag. We record the *start* anchor (not the current pointer
  /// position) because SGR wheel events semantically attach to where the
  /// user started scrolling — matches how desktop emulators format them.
  void onDragStart(Offset localPosition) {
    _dragAnchor = localPosition;
    _residualDy = 0;
    _dragActive = true;
  }

  /// Accumulates raw drag-delta pixels and emits one unit per
  /// `cellHeight` of accumulated travel. Sub-cell remainder is held in
  /// `_residualDy` until the next update.
  ///
  /// The raw `deltaDy` is negated on the way in so the adapter's
  /// internal `down` vocabulary aligns with the natural-scroll
  /// direction (see class doc): a downward finger drag — `deltaDy > 0`
  /// — produces `units < 0` and therefore `down: false`, which
  /// downstream emits as `arrowUp` / SGR wheel-up / PageUp.
  void onDragUpdate({required double deltaDy, required double cellHeight}) {
    if (!_dragActive || cellHeight <= 0) return;
    _residualDy -= deltaDy;
    final int units = (_residualDy / cellHeight).truncate();
    if (units == 0) return;
    _residualDy -= units * cellHeight;
    _emitUnits(magnitude: units.abs(), down: units > 0);
  }

  /// Ends a drag. Fast fling (> [kFastFlingVelocity] in either direction)
  /// triggers a coarse paging event scaled to the viewport. Slow
  /// release discards any sub-cell residual — we do not carry residuals
  /// across gestures because the user's mental model is "this swipe is
  /// done".
  void onDragEnd({required double velocityDy, required int rows}) {
    if (!_dragActive) return;
    _dragActive = false;
    _residualDy = 0;

    if (velocityDy.abs() < kFastFlingVelocity) return;
    // Same input-boundary flip as onDragUpdate: a downward fling
    // (`velocityDy > 0`) is a natural-scroll-up request, so `down` is
    // false → PageUp / wheel-up. See class doc.
    final bool down = velocityDy < 0;

    if (!terminal.isUsingAltBuffer) {
      // Normal-buffer fling intentionally not synthesised — the host
      // ScrollController already received per-cell increments during the
      // drag, and inertia would surprise the user (see class doc).
      return;
    }

    if (terminal.mouseMode.reportScroll) {
      final cell = cellAt(_dragAnchor);
      final ticks = (rows / 2).floor().clamp(1, rows);
      for (int i = 0; i < ticks; i++) {
        terminal.onOutput?.call(_sgrWheel(cell, down: down));
      }
    } else {
      terminal.keyInput(down ? TerminalKey.pageDown : TerminalKey.pageUp);
    }
  }

  void _emitUnits({required int magnitude, required bool down}) {
    if (!terminal.isUsingAltBuffer) {
      onScrollback(down ? magnitude : -magnitude);
      return;
    }

    if (terminal.mouseMode.reportScroll) {
      final cell = cellAt(_dragAnchor);
      for (int i = 0; i < magnitude; i++) {
        terminal.onOutput?.call(_sgrWheel(cell, down: down));
      }
    } else {
      for (int i = 0; i < magnitude; i++) {
        terminal.keyInput(down ? TerminalKey.arrowDown : TerminalKey.arrowUp);
      }
    }
  }

  /// SGR-encoded mouse wheel report. Button 64 = wheel up, 65 = wheel
  /// down. Press-only (`M`); xterm convention does not emit a release
  /// for wheel buttons in practice.
  String _sgrWheel(({int col, int row}) cell, {required bool down}) {
    final int button = down ? 65 : 64;
    return '\x1b[<$button;${cell.col};${cell.row}M';
  }
}
