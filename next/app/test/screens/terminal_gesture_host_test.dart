// Widget tests for the new TerminalGestureHost. Verifies the four
// behaviors the brief calls out:
//   1. Vertical drag in ViewMode advances the scrollback model and
//      does not enter selection mode.
//   2. A 600ms hold enters SelectMode and shows the toolbar.
//   3. Alt buffer + reportScroll mouse mode → SGR wheel reports via
//      onOutput.
//   4. Alt buffer + no mouse + DEC 1007 → keyboard fallback.
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

Offset _terminalCenter(WidgetTester tester) =>
    tester.getCenter(find.byType(TerminalView));

Future<void> _tapTerminal(WidgetTester tester) async {
  await tester.tapAt(_terminalCenter(tester));
}

Future<void> _dragTerminal(WidgetTester tester, Offset offset) async {
  await tester.dragFrom(_terminalCenter(tester), offset);
}

Future<void> _flingTerminal(
  WidgetTester tester,
  Offset offset,
  double speed,
) async {
  await tester.flingFrom(_terminalCenter(tester), offset, speed);
}

Widget _harness({
  required Terminal terminal,
  required GlobalKey<TerminalViewState> tvKey,
  required TerminalScrollbackModel model,
  required ScrollController scrollback,
  TerminalController? controller,
  VoidCallback? requestKeyboard,
  ValueChanged<double>? onFontScale,
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
        requestKeyboard: requestKeyboard,
        onFontScale: onFontScale,
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

      await tester.pumpWidget(
        _harness(
          terminal: terminal,
          tvKey: tvKey,
          model: model,
          scrollback: scrollback,
        ),
      );
      await _settle(tester);

      // Drag downwards on the terminal — natural-scroll-up request, so
      // model offset goes negative (reveal earlier content). In tests
      // the scroll controller has no real extent so the post-clamp
      // reading resolves to 0; we assert on the dispatch trace, which
      // proves the drag was interpreted as scrollback (and not as a
      // selection extend).
      final tvFinder = find.byType(TerminalView);
      expect(tvFinder, findsOneWidget);
      await _dragTerminal(tester, const Offset(0, 120));
      await tester.pump();

      expect(
        notifyCount,
        greaterThan(0),
        reason:
            'downward drag in normal buffer should advance the scrollback model',
      );
      expect(
        samples.any((s) => s < 0),
        isTrue,
        reason:
            'at least one notification should have observed a negative offset '
            'before the render-sink clamp mirrored back to 0',
      );
      expect(
        find.text('Copy'),
        findsNothing,
        reason: 'drag must not enter SelectMode',
      );
      expect(find.text('Dismiss'), findsNothing);
    },
  );

  testWidgets(
    'normal scrollback model is anchored to the bottom of xterm scrollback',
    (tester) async {
      final terminal = Terminal(maxLines: 1000);
      terminal.resize(80, 24);
      for (var i = 0; i < 120; i++) {
        terminal.write('line $i\r\n');
      }
      final model = TerminalScrollbackModel();
      final scrollback = ScrollController();
      final tvKey = GlobalKey<TerminalViewState>();

      await tester.pumpWidget(
        _harness(
          terminal: terminal,
          tvKey: tvKey,
          model: model,
          scrollback: scrollback,
        ),
      );
      await _settle(tester);

      final lineHeight = tvKey.currentState!.renderTerminal.lineHeight;
      final max = scrollback.position.maxScrollExtent;
      expect(max, greaterThan(lineHeight * 10));

      model.scrollBy(-3);
      await tester.pump();

      expect(model.offsetLines, -3);
      expect(scrollback.offset, closeTo(max - lineHeight * 3, 0.5));

      model.scrollBy(10);
      await tester.pump();

      expect(model.offsetLines, 0);
      expect(scrollback.offset, closeTo(max, 0.5));
    },
  );

  testWidgets('600ms hold enters SelectMode and shows the selection toolbar', (
    tester,
  ) async {
    final terminal = Terminal(maxLines: 1000);
    terminal.resize(80, 24);
    final model = TerminalScrollbackModel();
    final scrollback = ScrollController();
    final tvKey = GlobalKey<TerminalViewState>();

    await tester.pumpWidget(
      _harness(
        terminal: terminal,
        tvKey: tvKey,
        model: model,
        scrollback: scrollback,
      ),
    );
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
  });

  testWidgets('long press enters SelectMode even when TUI mouse is enabled', (
    tester,
  ) async {
    final terminal = Terminal(maxLines: 1000);
    terminal.resize(80, 24);
    terminal.write('\x1b[?1049h');
    terminal.write('\x1b[?1000h');
    expect(terminal.mouseMode.reportScroll, isTrue);
    final model = TerminalScrollbackModel();
    final scrollback = ScrollController();
    final tvKey = GlobalKey<TerminalViewState>();

    await tester.pumpWidget(
      _harness(
        terminal: terminal,
        tvKey: tvKey,
        model: model,
        scrollback: scrollback,
      ),
    );
    await _settle(tester);

    final center = tester.getCenter(find.byType(TerminalView));
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();
    await tester.pump();

    expect(find.text('Copy'), findsOneWidget);
  });

  testWidgets('selection end handle extends the selected text range', (
    tester,
  ) async {
    final terminal = Terminal(maxLines: 1000);
    terminal.resize(80, 24);
    terminal.write('alpha beta gamma\r\n');
    final model = TerminalScrollbackModel();
    final scrollback = ScrollController();
    final tvKey = GlobalKey<TerminalViewState>();
    final ctrl = TerminalController();

    await tester.pumpWidget(
      _harness(
        terminal: terminal,
        tvKey: tvKey,
        model: model,
        scrollback: scrollback,
        controller: ctrl,
      ),
    );
    await _settle(tester);

    final render = tvKey.currentState!.renderTerminal;
    final cellSize = render.cellSize;
    final terminalOrigin = tester.getTopLeft(find.byType(TerminalView));
    final alphaCell = render.getOffset(const CellOffset(2, 0));
    final pressAt =
        terminalOrigin +
        alphaCell +
        Offset(cellSize.width / 2, cellSize.height / 2);
    final gesture = await tester.startGesture(pressAt);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();
    await tester.pump();

    expect(
      find.byKey(const ValueKey('terminal-selection-start-handle')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('terminal-selection-end-handle')),
      findsOneWidget,
    );
    expect(terminal.buffer.getText(ctrl.selection!), contains('alpha'));
    expect(terminal.buffer.getText(ctrl.selection!), isNot(contains('beta')));

    await tester.drag(
      find.byKey(const ValueKey('terminal-selection-end-handle')),
      Offset(cellSize.width * 6, 0),
    );
    await tester.pump();

    expect(terminal.buffer.getText(ctrl.selection!), contains('alpha beta'));
  });

  testWidgets('fast drag does not trigger long-press selection', (
    tester,
  ) async {
    final terminal = Terminal(maxLines: 1000);
    terminal.resize(80, 24);
    final model = TerminalScrollbackModel();
    final scrollback = ScrollController();
    final tvKey = GlobalKey<TerminalViewState>();

    await tester.pumpWidget(
      _harness(
        terminal: terminal,
        tvKey: tvKey,
        model: model,
        scrollback: scrollback,
      ),
    );
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
  });

  testWidgets('successive fast flings do not trip ticker assertions', (
    tester,
  ) async {
    final terminal = Terminal(maxLines: 1000);
    terminal.resize(80, 24);
    for (var i = 0; i < 120; i++) {
      terminal.write('line $i\r\n');
    }
    final model = TerminalScrollbackModel();
    final scrollback = ScrollController();
    final tvKey = GlobalKey<TerminalViewState>();

    await tester.pumpWidget(
      _harness(
        terminal: terminal,
        tvKey: tvKey,
        model: model,
        scrollback: scrollback,
      ),
    );
    await _settle(tester);

    await _flingTerminal(tester, const Offset(0, -320), 1800);
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.takeException(), isNull);

    await _flingTerminal(tester, const Offset(0, 320), 1800);
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('alt buffer + reportScroll → SGR wheel reports via onOutput', (
    tester,
  ) async {
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

    await tester.pumpWidget(
      _harness(
        terminal: terminal,
        tvKey: tvKey,
        model: model,
        scrollback: scrollback,
      ),
    );
    await _settle(tester);

    await _dragTerminal(tester, const Offset(0, 120));
    await tester.pump();

    expect(captured, isNotEmpty);
    for (final s in captured) {
      expect(
        RegExp(r'^\x1b\[<64;\d+;\d+M$').hasMatch(s),
        isTrue,
        reason: 'unexpected emission: ${s.codeUnits}',
      );
    }
  });

  testWidgets('tap requests keyboard focus on the terminal', (tester) async {
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

    expect(
      focusNode.hasFocus,
      isFalse,
      reason: 'autofocus is off; focus must be earned by tapping',
    );

    await _tapTerminal(tester);
    await tester.pump();

    expect(
      focusNode.hasFocus,
      isTrue,
      reason: 'tap should requestKeyboard → requestFocus on focusNode',
    );
  });

  testWidgets('tap delegates keyboard request to parent hook when provided', (
    tester,
  ) async {
    final terminal = Terminal(maxLines: 1000);
    terminal.resize(80, 24);
    final model = TerminalScrollbackModel();
    final scrollback = ScrollController();
    final tvKey = GlobalKey<TerminalViewState>();
    int requests = 0;

    await tester.pumpWidget(
      _harness(
        terminal: terminal,
        tvKey: tvKey,
        model: model,
        scrollback: scrollback,
        requestKeyboard: () => requests++,
      ),
    );
    await _settle(tester);

    await _tapTerminal(tester);
    await tester.pump();

    expect(requests, 1);
  });

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

      await tester.pumpWidget(
        _harness(
          terminal: terminal,
          tvKey: tvKey,
          model: model,
          scrollback: scrollback,
        ),
      );
      await _settle(tester);

      // Drag upwards on the terminal — natural-scroll-down request,
      // which in alt-buffer + reportScroll mode maps to wheel-down
      // (SGR button 65).
      await _dragTerminal(tester, const Offset(0, -120));
      await tester.pump();

      expect(captured, isNotEmpty);
      for (final s in captured) {
        expect(
          RegExp(r'^\x1b\[<65;\d+;\d+M$').hasMatch(s),
          isTrue,
          reason: 'unexpected emission: ${s.codeUnits}',
        );
      }
    },
  );

  testWidgets('alt buffer + no mouse + mode 1007 → arrow up keystrokes', (
    tester,
  ) async {
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

    await tester.pumpWidget(
      _harness(
        terminal: terminal,
        tvKey: tvKey,
        model: model,
        scrollback: scrollback,
      ),
    );
    await _settle(tester);

    await _dragTerminal(tester, const Offset(0, 120));
    await tester.pump();

    expect(captured, isNotEmpty);
    // Default cursor mode emits arrow up as ESC [ A.
    for (final s in captured) {
      expect(s, '\x1b[A', reason: 'unexpected emission: ${s.codeUnits}');
    }
  });

  testWidgets('alt buffer + no mouse + no 1007 emits arrows like Termux', (
    tester,
  ) async {
    final terminal = Terminal(maxLines: 1000);
    terminal.resize(80, 24);
    terminal.write('\x1b[?1049h');
    expect(terminal.isUsingAltBuffer, isTrue);
    expect(terminal.mouseMode, MouseMode.none);
    expect(terminal.altBufferMouseScrollMode, isFalse);

    final captured = <String>[];
    terminal.onOutput = captured.add;

    final model = TerminalScrollbackModel();
    final scrollback = ScrollController();
    final tvKey = GlobalKey<TerminalViewState>();

    await tester.pumpWidget(
      _harness(
        terminal: terminal,
        tvKey: tvKey,
        model: model,
        scrollback: scrollback,
      ),
    );
    await _settle(tester);

    await _dragTerminal(tester, const Offset(0, 120));
    await tester.pump();

    expect(captured, isNotEmpty);
    expect(captured.every((s) => s == '\x1b[A'), isTrue);
    expect(captured, isNot(contains('\x1b[5~')));
    expect(captured, isNot(contains('\x1b[6~')));
  });

  testWidgets('alt buffer + no mouse fling is a no-op like Termux', (
    tester,
  ) async {
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

    await tester.pumpWidget(
      _harness(
        terminal: terminal,
        tvKey: tvKey,
        model: model,
        scrollback: scrollback,
      ),
    );
    await _settle(tester);

    await _flingTerminal(tester, const Offset(0, -320), 1800);
    final emittedByDragUpdates = captured.length;
    expect(emittedByDragUpdates, greaterThan(0));
    await tester.pump(const Duration(milliseconds: 200));

    expect(captured.length, emittedByDragUpdates);
    expect(model.offsetLines, 0);
  });

  testWidgets('two-finger vertical pan emits page keys, not font scaling', (
    tester,
  ) async {
    final terminal = Terminal(maxLines: 1000);
    terminal.resize(80, 24);
    terminal.write('\x1b[?1049h');
    expect(terminal.isUsingAltBuffer, isTrue);
    expect(terminal.mouseMode, MouseMode.none);

    final captured = <String>[];
    final scales = <double>[];
    terminal.onOutput = captured.add;

    final model = TerminalScrollbackModel();
    final scrollback = ScrollController();
    final tvKey = GlobalKey<TerminalViewState>();

    await tester.pumpWidget(
      _harness(
        terminal: terminal,
        tvKey: tvKey,
        model: model,
        scrollback: scrollback,
        onFontScale: scales.add,
      ),
    );
    await _settle(tester);

    final center = tester.getCenter(find.byType(TerminalView));
    final first = await tester.startGesture(center + const Offset(-20, 0));
    final second = await tester.startGesture(center + const Offset(20, 0));
    await tester.pump();

    await first.moveTo(center + const Offset(-20, 120));
    await second.moveTo(center + const Offset(20, 120));
    await tester.pump();
    await first.moveTo(center + const Offset(-20, 240));
    await second.moveTo(center + const Offset(20, 240));
    await tester.pump();

    await first.up();
    await second.up();
    await tester.pump();

    expect(captured, isNotEmpty);
    expect(captured.every((s) => s == '\x1b[5~'), isTrue);
    expect(scales, isEmpty);
  });

  testWidgets(
    'two-finger vertical pan with distance wobble still prefers page keys',
    (tester) async {
      final terminal = Terminal(maxLines: 1000);
      terminal.resize(80, 24);
      terminal.write('\x1b[?1049h');

      final captured = <String>[];
      final scales = <double>[];
      terminal.onOutput = captured.add;

      final model = TerminalScrollbackModel();
      final scrollback = ScrollController();
      final tvKey = GlobalKey<TerminalViewState>();

      await tester.pumpWidget(
        _harness(
          terminal: terminal,
          tvKey: tvKey,
          model: model,
          scrollback: scrollback,
          onFontScale: scales.add,
        ),
      );
      await _settle(tester);

      final center = tester.getCenter(find.byType(TerminalView));
      final first = await tester.startGesture(center + const Offset(-20, 0));
      final second = await tester.startGesture(center + const Offset(20, 0));
      await tester.pump();

      await first.moveTo(center + const Offset(-34, 120));
      await second.moveTo(center + const Offset(28, 112));
      await tester.pump();

      await first.up();
      await second.up();
      await tester.pump();

      expect(captured, isNotEmpty);
      expect(captured.every((s) => s == '\x1b[5~'), isTrue);
      expect(scales, isEmpty);
    },
  );

  testWidgets('two-finger pinch emits incremental font scale factors', (
    tester,
  ) async {
    final terminal = Terminal(maxLines: 1000);
    terminal.resize(80, 24);
    final model = TerminalScrollbackModel();
    final scrollback = ScrollController();
    final tvKey = GlobalKey<TerminalViewState>();
    final scales = <double>[];
    final captured = <String>[];
    terminal.onOutput = captured.add;

    await tester.pumpWidget(
      _harness(
        terminal: terminal,
        tvKey: tvKey,
        model: model,
        scrollback: scrollback,
        onFontScale: scales.add,
      ),
    );
    await _settle(tester);

    final center = tester.getCenter(find.byType(TerminalView));
    final first = await tester.startGesture(center + const Offset(-20, 0));
    final second = await tester.startGesture(center + const Offset(20, 0));
    await tester.pump();

    await first.moveTo(center + const Offset(-40, 0));
    await second.moveTo(center + const Offset(40, 0));
    await tester.pump();

    await first.up();
    await second.up();
    await tester.pump();

    expect(scales, isNotEmpty);
    expect(scales.any((s) => s > 1), isTrue);
    expect(captured, isNot(contains('\x1b[5~')));
    expect(captured, isNot(contains('\x1b[6~')));
  });
}
