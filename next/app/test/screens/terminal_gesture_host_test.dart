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
  TerminalController? controller,
}) {
  final ctrl = controller ?? TerminalController();
  return MaterialApp(
    home: Scaffold(
      body: TerminalGestureHost(
        terminal: terminal,
        terminalController: ctrl,
        terminalViewKey: tvKey,
        scrollback: model,
        scrollbackController: scrollback,
        child: TerminalView(
          terminal,
          key: tvKey,
          controller: ctrl,
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

      int notifyCount = 0;
      final List<int> samples = [];
      model.addListener(() {
        notifyCount++;
        samples.add(model.offsetLines);
      });

      await tester.pumpWidget(_harness(
        terminal: terminal,
        tvKey: tvKey,
        model: model,
        scrollback: scrollback,
      ));
      await _settle(tester);

      // Drag downwards on the terminal — natural-scroll-up request, so
      // model offset goes negative (reveal earlier content). In tests
      // the scroll controller has no real extent so the post-clamp
      // reading resolves to 0; we assert on the dispatch trace, which
      // proves the drag was interpreted as scrollback (and not as a
      // selection extend).
      final tvFinder = find.byType(TerminalView);
      expect(tvFinder, findsOneWidget);
      await tester.drag(tvFinder, const Offset(0, 120));
      await tester.pump();

      expect(notifyCount, greaterThan(0),
          reason:
              'downward drag in normal buffer should advance the scrollback model');
      expect(samples.any((s) => s < 0), isTrue,
          reason:
              'at least one notification should have observed a negative offset '
              'before the render-sink clamp mirrored back to 0');
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
    'tap requests keyboard focus on the terminal',
    (tester) async {
      final terminal = Terminal(maxLines: 1000);
      terminal.resize(80, 24);
      final model = TerminalScrollbackModel();
      final scrollback = ScrollController();
      final tvKey = GlobalKey<TerminalViewState>();
      final focusNode = FocusNode();
      final ctrl = TerminalController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalGestureHost(
              terminal: terminal,
              terminalController: ctrl,
              terminalViewKey: tvKey,
              scrollback: model,
              scrollbackController: scrollback,
              child: TerminalView(
                terminal,
                key: tvKey,
                controller: ctrl,
                scrollController: scrollback,
                focusNode: focusNode,
                autofocus: false,
                simulateScroll: false,
              ),
            ),
          ),
        ),
      );
      await _settle(tester);

      expect(focusNode.hasFocus, isFalse,
          reason: 'autofocus is off; focus must be earned by tapping');

      await tester.tap(find.byType(TerminalView));
      await tester.pump();

      expect(focusNode.hasFocus, isTrue,
          reason: 'tap should requestKeyboard → requestFocus on focusNode');
    },
  );

  testWidgets(
    'alt buffer + reportScroll, reverse drag emits button 65 (wheel down)',
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

      // Drag upwards on the terminal — natural-scroll-down request,
      // which in alt-buffer + reportScroll mode maps to wheel-down
      // (SGR button 65).
      await tester.drag(find.byType(TerminalView), const Offset(0, -120));
      await tester.pump();

      expect(captured, isNotEmpty);
      for (final s in captured) {
        expect(RegExp(r'^\x1b\[<65;\d+;\d+M$').hasMatch(s), isTrue,
            reason: 'unexpected emission: ${s.codeUnits}');
      }
    },
  );

  testWidgets(
    'alt buffer + no mouse + mode 1007 → arrow up keystrokes',
    (tester) async {
      final terminal = Terminal(maxLines: 1000);
      terminal.resize(80, 24);
      terminal.write('\x1b[?1049h');
      terminal.write('\x1b[?1007h');
      expect(terminal.isUsingAltBuffer, isTrue);
      expect(terminal.mouseMode, MouseMode.none);
      expect(terminal.altBufferMouseScrollMode, isTrue);

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
