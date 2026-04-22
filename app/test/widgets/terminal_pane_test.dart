import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vscode_mobile/models/terminal_session.dart';
import 'package:vscode_mobile/providers/terminal_provider.dart';
import 'package:vscode_mobile/widgets/terminal_pane.dart';

void main() {
  group('TerminalPane', () {
    late TerminalSessionView view;
    late List<String> rawInputs;

    setUp(() {
      view = TerminalSessionView(
        session: const TerminalSession(
          id: 'term-1',
          name: 'Alpha',
          cwd: '/workspace',
          profile: 'bash',
          state: 'running',
        ),
      );
      view.connectionState = TerminalConnectionState.ready;
      view.buffer.append('ready\r\n');
      rawInputs = <String>[];
    });

    Future<void> pumpPane(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 220,
              child: TerminalPane(
                sessionId: 'term-1',
                view: view,
                isActive: true,
                onSubmit: (_) {},
                onDraftChanged: (_) {},
                onResize: (rows, cols) {},
                onSendRaw: rawInputs.add,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('sends raw hardware key sequences from the terminal surface', (
      tester,
    ) async {
      await pumpPane(tester);

      await tester.tap(find.byKey(const ValueKey<String>('terminal-surface')));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();

      expect(rawInputs, contains('\x1B[A'));
    });

    testWidgets('keeps command text entry and toolbar affordances available', (
      tester,
    ) async {
      await pumpPane(tester);

      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Ctrl'), findsOneWidget);
      expect(find.text('Esc'), findsOneWidget);
      expect(find.byTooltip('Send command'), findsOneWidget);
    });

    testWidgets('submits toolbar input with carriage return', (tester) async {
      final submitted = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 220,
              child: TerminalPane(
                sessionId: 'term-1',
                view: view,
                isActive: true,
                onSubmit: submitted.add,
                onDraftChanged: (_) {},
                onResize: (rows, cols) {},
                onSendRaw: rawInputs.add,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'ls');
      await tester.tap(find.byTooltip('Send command'));
      await tester.pump();

      expect(submitted, <String>['ls\r']);
    });

    testWidgets('compact mode hides the redundant session header', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 400,
              child: TerminalPane(
                sessionId: 'term-1',
                view: view,
                isActive: true,
                compact: true,
                onSubmit: (_) {},
                onDraftChanged: (_) {},
                onResize: (rows, cols) {},
                onSendRaw: rawInputs.add,
              ),
            ),
          ),
        ),
      );

      expect(find.text('Alpha'), findsNothing);
      expect(find.text('Connected'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.byIcon(Icons.keyboard), findsOneWidget);
      expect(find.text('^C'), findsOneWidget);
    });

    testWidgets('compact mode lets users reveal the command composer', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 400,
              child: TerminalPane(
                sessionId: 'term-1',
                view: view,
                isActive: true,
                compact: true,
                onSubmit: (_) {},
                onDraftChanged: (_) {},
                onResize: (rows, cols) {},
                onSendRaw: rawInputs.add,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.keyboard));
      await tester.pump();

      expect(find.byType(TextField), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_hide), findsOneWidget);
    });

    testWidgets('compact mode exposes Ctrl+C directly in the toolbar', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 400,
              child: TerminalPane(
                sessionId: 'term-1',
                view: view,
                isActive: true,
                compact: true,
                onSubmit: (_) {},
                onDraftChanged: (_) {},
                onResize: (rows, cols) {},
                onSendRaw: rawInputs.add,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('^C'));
      await tester.pump();

      expect(rawInputs, contains('\x03'));
    });

    testWidgets('stays pinned to the latest output when content keeps growing', (
      tester,
    ) async {
      view.buffer.append(
        List<String>.generate(32, (index) => 'line-$index').join('\r\n'),
      );

      await pumpPane(tester);

      final terminalScrollable = find.descendant(
        of: find.byKey(const ValueKey<String>('terminal-surface')),
        matching: find.byType(Scrollable),
      );
      final scrollable = tester.state<ScrollableState>(terminalScrollable);
      expect(
        scrollable.position.pixels,
        closeTo(scrollable.position.maxScrollExtent, 1),
      );

      view.buffer.append(
        '\r\n${List<String>.generate(18, (index) => 'next-$index').join('\r\n')}',
      );

      await pumpPane(tester);

      final updated = tester.state<ScrollableState>(terminalScrollable);
      expect(
        updated.position.pixels,
        closeTo(updated.position.maxScrollExtent, 1),
      );
    });

    testWidgets('keeps manual scrollback position when user scrolls away', (
      tester,
    ) async {
      view.buffer.append(
        List<String>.generate(36, (index) => 'line-$index').join('\r\n'),
      );

      await pumpPane(tester);

      final terminalScrollable = find.descendant(
        of: find.byKey(const ValueKey<String>('terminal-surface')),
        matching: find.byType(Scrollable),
      );
      final scrollable = tester.state<ScrollableState>(terminalScrollable);
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent / 2);
      await tester.pump();

      view.buffer.append('\r\nfollow-up-output');
      await pumpPane(tester);

      final updated = tester.state<ScrollableState>(terminalScrollable);
      expect(updated.position.pixels, lessThan(updated.position.maxScrollExtent));
    });
  });
}
