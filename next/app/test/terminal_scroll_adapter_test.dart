// ignore_for_file: deprecated_member_use_from_same_package
// Unit tests for TerminalScrollAdapter. The adapter is pure-Dart; we use
// a real xterm.dart Terminal as the state source (cheaper than a mock; the
// alt-buffer / mouseMode flags are easy to set via escape sequences) and
// spy on its `onOutput` channel to capture emitted bytes.

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

import 'package:mobilecode/services/terminal_scroll_adapter.dart';

void main() {
  group('TerminalScrollAdapter', () {
    late Terminal terminal;
    late List<String> emitted;
    late List<int> scrollback;

    setUp(() {
      terminal = Terminal(maxLines: 1000);
      // Default ANSI cursor mode — arrow keys come out as `\e[A` / `\e[B`.
      terminal.resize(80, 24);
      emitted = <String>[];
      scrollback = <int>[];
      terminal.onOutput = emitted.add;
    });

    TerminalScrollAdapter buildAdapter({
      ({int col, int row}) Function(Offset)? cellAt,
    }) {
      return TerminalScrollAdapter(
        terminal: terminal,
        cellAt: cellAt ?? (_) => (col: 10, row: 5),
        onScrollback: scrollback.add,
      );
    }

    void enterAltBuffer() => terminal.write('\x1b[?1049h');
    void enableMouseScrollReporting() => terminal.write('\x1b[?1000h');

    test('normal buffer: drag down 3 × cellHeight → 3 negative scrollback ticks (natural scroll)', () {
      final adapter = buildAdapter();
      adapter.onDragStart(const Offset(50, 50));
      adapter.onDragUpdate(deltaDy: 16, cellHeight: 16);
      adapter.onDragUpdate(deltaDy: 16, cellHeight: 16);
      adapter.onDragUpdate(deltaDy: 16, cellHeight: 16);
      adapter.onDragEnd(velocityDy: 0, rows: 24);

      // Sign reflects natural-scroll vocabulary: finger drag down is a
      // natural-scroll-up request (reveal earlier content), so the sink
      // receives negative ticks. Callers translate the sign into whatever
      // scrollback API they expose.
      expect(scrollback, [-1, -1, -1]);
      expect(emitted, isEmpty);
    });

    test('alt + no mouse: drag down 3 × cellHeight → 3 × \\e[A (arrow up, natural scroll)', () {
      enterAltBuffer();
      expect(terminal.isUsingAltBuffer, isTrue);
      expect(terminal.mouseMode, MouseMode.none);

      final adapter = buildAdapter();
      adapter.onDragStart(const Offset(50, 50));
      adapter.onDragUpdate(deltaDy: 48, cellHeight: 16);
      adapter.onDragEnd(velocityDy: 0, rows: 24);

      // Finger drag down = reveal earlier content = arrow ↑.
      expect(emitted, ['\x1b[A', '\x1b[A', '\x1b[A']);
      expect(scrollback, isEmpty);
    });

    test('alt + mouse reportScroll: drag down 3 × cellHeight → 3 × SGR wheel-up (natural scroll)', () {
      enterAltBuffer();
      enableMouseScrollReporting();
      expect(terminal.mouseMode.reportScroll, isTrue);

      // Stub cellAt to the spec's expected (10, 5) regardless of pixel
      // position so the test is independent of any real render geometry.
      final adapter = buildAdapter(cellAt: (_) => (col: 10, row: 5));
      adapter.onDragStart(const Offset(120, 80));
      adapter.onDragUpdate(deltaDy: 48, cellHeight: 16);
      adapter.onDragEnd(velocityDy: 0, rows: 24);

      // Finger drag down → SGR wheel-up (button 64) at the drag-start cell.
      expect(emitted, [
        '\x1b[<64;10;5M',
        '\x1b[<64;10;5M',
        '\x1b[<64;10;5M',
      ]);
      expect(scrollback, isEmpty);
    });

    test('alt + no mouse: fast fling up (dy negative > 800 px/s) → one PgDn (natural scroll)', () {
      enterAltBuffer();

      final adapter = buildAdapter();
      adapter.onDragStart(const Offset(50, 50));
      // No slow-drag accumulation; fling velocity alone triggers the paging
      // event on dragEnd. Finger fling up = natural-scroll down = PgDn.
      adapter.onDragEnd(velocityDy: -1200, rows: 24);

      expect(emitted, ['\x1b[6~']);
      expect(scrollback, isEmpty);
    });

    test('alt + mouse: fast fling → wheel-burst of rows/2 ticks at drag-start cell', () {
      enterAltBuffer();
      enableMouseScrollReporting();

      final adapter = buildAdapter(cellAt: (_) => (col: 10, row: 5));
      adapter.onDragStart(const Offset(120, 80));
      // Finger fling down → natural-scroll up → wheel-up burst.
      adapter.onDragEnd(velocityDy: 1500, rows: 24);

      // rows/2 = 12 wheel-up events (button 64).
      expect(emitted.length, 12);
      for (final s in emitted) {
        expect(s, '\x1b[<64;10;5M');
      }
    });

    test('sub-cellHeight residual is discarded at drag-end', () {
      final adapter = buildAdapter();
      adapter.onDragStart(const Offset(50, 50));
      adapter.onDragUpdate(deltaDy: 8, cellHeight: 16);
      adapter.onDragEnd(velocityDy: 0, rows: 24);

      expect(scrollback, isEmpty);
      expect(emitted, isEmpty);

      // Next gesture must start cleanly — residual must not carry over.
      adapter.onDragStart(const Offset(50, 50));
      adapter.onDragUpdate(deltaDy: 8, cellHeight: 16);
      adapter.onDragEnd(velocityDy: 0, rows: 24);

      expect(scrollback, isEmpty);
    });

    test('alt + mouse: SGR anchor is taken at drag-start, not at update', () {
      enterAltBuffer();
      enableMouseScrollReporting();

      // Make the mapper position-sensitive so we can see which Offset
      // the adapter consulted.
      var lastQueried = Offset.zero;
      final adapter = TerminalScrollAdapter(
        terminal: terminal,
        cellAt: (o) {
          lastQueried = o;
          return (col: o.dx.toInt(), row: o.dy.toInt());
        },
        onScrollback: scrollback.add,
      );

      adapter.onDragStart(const Offset(7, 3));
      adapter.onDragUpdate(deltaDy: 64, cellHeight: 16);
      adapter.onDragEnd(velocityDy: 0, rows: 24);

      // The drag-start offset was (7, 3); the adapter must not have used
      // the update's accumulated position. Wheel-up (button 64) because
      // finger drag down is a natural-scroll-up request.
      expect(lastQueried, const Offset(7, 3));
      expect(emitted.every((s) => s == '\x1b[<64;7;3M'), isTrue);
    });
  });
}
