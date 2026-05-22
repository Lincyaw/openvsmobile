// Widget tests for the new TerminalGestureHost. Verifies the four
// behaviors the brief calls out:
//   1. Vertical drag in ViewMode advances the scrollback model and
//      does not enter selection mode.
//   2. A 600ms hold enters SelectMode and shows the toolbar.
//   3. Alt buffer + reportScroll mouse mode → SGR wheel reports via
//      onOutput.
//   4. Alt buffer + no mouse mode → arrow ↑/↓ keystrokes.
//
// Selection toolbar is built into the host directly; we assert on
// finding "Copy" / "Dismiss" labels rather than mocking the
// RenderTerminal selection state.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

import 'package:mobilecode/services/terminal_gesture_host.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Widget _harness({
  required Terminal terminal,
  required GlobalKey<TerminalViewState> tvKey,
  required TerminalScrollbackModel model,
  required ScrollController scrollback,
}) {
  return MaterialApp(
    home: Scaffold(
      body: TerminalGestureHost(
        terminal: terminal,
        terminalViewKey: tvKey,
        scrollback: model,
        scrollbackController: scrollback,
        child: TerminalView(
          terminal,
          key: tvKey,
          scrollController: scrollback,
          autofocus: false,
          simulateScroll: false,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'ViewMode vertical drag advances scrollback model, no selection toolbar',
    (tester) async {
      final terminal = Terminal(maxLines: 1000);
      terminal.resize(80, 24);
      final model = TerminalScrollbackModel();
      final scrollback = ScrollController();
      final tvKey = GlobalKey<TerminalViewState>();

      await tester.pumpWidget(_harness(
        terminal: terminal,
        tvKey: tvKey,
        model: model,
        scrollback: scrollback,
      ));
      await _settle(tester);

      // Drag downwards on the terminal — natural-scroll-up request, so
      // model offset goes negative (reveal earlier content).
      final tvFinder = find.byType(TerminalView);
      expect(tvFinder, findsOneWidget);
      await tester.drag(tvFinder, const Offset(0, 120));
      await tester.pump();

      expect(model.offsetLines, lessThan(0),
          reason:
              'downward drag in normal buffer should drive negative model offset');
      expect(find.text('Copy'), findsNothing,
          reason: 'drag must not enter SelectMode');
      expect(find.text('Dismiss'), findsNothing);
    },
  );

  testWidgets(
    '600ms hold enters SelectMode and shows the selection toolbar',
    (tester) async {
      final terminal = Terminal(maxLines: 1000);
      terminal.resize(80, 24);
      final model = TerminalScrollbackModel();
      final scrollback = ScrollController();
      final tvKey = GlobalKey<TerminalViewState>();

      await tester.pumpWidget(_harness(
        terminal: terminal,
        tvKey: tvKey,
        model: model,
        scrollback: scrollback,
      ));
      await _settle(tester);

      final center = tester.getCenter(find.byType(TerminalView));
      final gesture = await tester.startGesture(center);
      // Default LongPressGestureRecognizer timeout is 500ms; pump past
      // it without movement.
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.up();
      await tester.pump();

      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Select All'), findsOneWidget);
      expect(find.text('Dismiss'), findsOneWidget);
    },
  );

  testWidgets(
    'fast drag does not trigger long-press selection',
    (tester) async {
      final terminal = Terminal(maxLines: 1000);
      terminal.resize(80, 24);
      final model = TerminalScrollbackModel();
      final scrollback = ScrollController();
      final tvKey = GlobalKey<TerminalViewState>();

      await tester.pumpWidget(_harness(
        terminal: terminal,
        tvKey: tvKey,
        model: model,
        scrollback: scrollback,
      ));
      await _settle(tester);

      // 30 px over 100 ms — slop wins over the 500 ms long-press timer.
      final center = tester.getCenter(find.byType(TerminalView));
      final gesture = await tester.startGesture(center);
      for (int i = 0; i < 5; i++) {
        await gesture.moveBy(const Offset(0, 6));
        await tester.pump(const Duration(milliseconds: 20));
      }
      await gesture.up();
      await tester.pump();

      expect(find.text('Copy'), findsNothing);
    },
  );

  testWidgets(
    'alt buffer + reportScroll → SGR wheel reports via onOutput',
    (tester) async {
      final terminal = Terminal(maxLines: 1000);
      terminal.resize(80, 24);
      terminal.write('\x1b[?1049h');
      terminal.write('\x1b[?1000h');
      expect(terminal.isUsingAltBuffer, isTrue);
      expect(terminal.mouseMode.reportScroll, isTrue);

      final captured = <String>[];
      terminal.onOutput = captured.add;

      final model = TerminalScrollbackModel();
      final scrollback = ScrollController();
      final tvKey = GlobalKey<TerminalViewState>();

      await tester.pumpWidget(_harness(
        terminal: terminal,
        tvKey: tvKey,
        model: model,
        scrollback: scrollback,
      ));
      await _settle(tester);

      await tester.drag(find.byType(TerminalView), const Offset(0, 120));
      await tester.pump();

      expect(captured, isNotEmpty);
      for (final s in captured) {
        expect(RegExp(r'^\x1b\[<64;\d+;\d+M$').hasMatch(s), isTrue,
            reason: 'unexpected emission: ${s.codeUnits}');
      }
    },
  );

  testWidgets(
    'alt buffer + no mouse mode → arrow up keystrokes',
    (tester) async {
      final terminal = Terminal(maxLines: 1000);
      terminal.resize(80, 24);
      terminal.write('\x1b[?1049h');
      expect(terminal.isUsingAltBuffer, isTrue);
      expect(terminal.mouseMode, MouseMode.none);

      final captured = <String>[];
      terminal.onOutput = captured.add;

      final model = TerminalScrollbackModel();
      final scrollback = ScrollController();
      final tvKey = GlobalKey<TerminalViewState>();

      await tester.pumpWidget(_harness(
        terminal: terminal,
        tvKey: tvKey,
        model: model,
        scrollback: scrollback,
      ));
      await _settle(tester);

      await tester.drag(find.byType(TerminalView), const Offset(0, 120));
      await tester.pump();

      expect(captured, isNotEmpty);
      // Default cursor mode emits arrow up as ESC [ A.
      for (final s in captured) {
        expect(s, '\x1b[A',
            reason: 'unexpected emission: ${s.codeUnits}');
      }
    },
  );
}
