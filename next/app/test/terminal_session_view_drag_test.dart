// Widget test for TerminalSessionView's vertical-drag wiring. Verifies
// that a real touch drag, in alt-buffer + scroll-reporting mouse mode,
// is converted to SGR wheel reports and dispatched via the terminal's
// onOutput channel — i.e. the same channel that production routes to
// `terminal.write` over the WebSocket.
//
// This is a thin integration test: it does NOT exercise the policy
// matrix (covered exhaustively by terminal_scroll_adapter_test.dart)
// and it does NOT mount the surrounding TerminalDetailScreen / AppBar
// / keyboard toolbar. Only the gesture-handling Column subtree is
// under test.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

import 'package:mobilecode/screens/terminal_detail.dart';

void main() {
  testWidgets(
    'alt + mouse reportScroll: vertical drag emits SGR wheel reports via onOutput',
    (tester) async {
      final terminal = Terminal(maxLines: 1000);
      terminal.resize(80, 24);
      // Enter alt buffer + enable mouse scroll reporting BEFORE installing
      // the spy, since these writes are not what we want to capture.
      terminal.write('\x1b[?1049h');
      terminal.write('\x1b[?1000h');
      expect(terminal.isUsingAltBuffer, isTrue);
      expect(terminal.mouseMode.reportScroll, isTrue);

      final captured = <String>[];
      terminal.onOutput = captured.add;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalSessionView(terminal: terminal),
          ),
        ),
      );
      // Two pumps so xterm.dart's TerminalView has a chance to build its
      // render object — the drag handler reads renderTerminal.lineHeight
      // and renderTerminal.getCellOffset.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final terminalFinder = find.byType(TerminalView);
      expect(terminalFinder, findsOneWidget);

      // A modest downward drag — enough to clear at least one cellHeight
      // and trigger at least one SGR wheel-up report (natural-scroll
      // semantics: finger down = reveal earlier content = wheel-up).
      // Exact count depends on the rendered cell height in the test
      // environment, so we assert on shape, not magnitude.
      await tester.drag(terminalFinder, const Offset(0, 120));
      await tester.pump();

      expect(captured, isNotEmpty,
          reason: 'drag should have emitted at least one SGR wheel report');
      for (final s in captured) {
        // SGR wheel-up (button 64) at some cell (col, row >= 1).
        expect(
          RegExp(r'^\x1b\[<64;\d+;\d+M$').hasMatch(s),
          isTrue,
          reason: 'unexpected emission: ${s.codeUnits}',
        );
      }
    },
  );
}
