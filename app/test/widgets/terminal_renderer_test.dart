import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vscode_mobile/theme/monospace_text.dart';
import 'package:vscode_mobile/terminal/terminal_emulator.dart';
import 'package:vscode_mobile/widgets/terminal_renderer.dart';

import '../test_support/terminal_test_helpers.dart';

void main() {
  group('TerminalRenderer', () {
    testWidgets('renders scrollback display lines from the emulator snapshot', (
      tester,
    ) async {
      final emulator = TerminalEmulator(rows: 2, cols: 12);
      emulator.write('one\r\ntwo\r\nthree');
      final snapshot = emulator.snapshot();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 200,
              child: TerminalRenderer(
                snapshot: snapshot,
                scrollController: ScrollController(),
                fontSize: 13,
                lineHeight: 1.4,
                defaultForeground: const Color(0xFFD4D4D4),
                defaultBackground: const Color(0xFF1E1E1E),
              ),
            ),
          ),
        ),
      );

      final richTexts = tester
          .widgetList<RichText>(find.byType(RichText))
          .toList();
      final textContent = richTexts
          .map((widget) => (widget.text as TextSpan).toPlainText().trimRight())
          .toList(growable: false);
      expect(textContent, containsAll(<String>['one', 'two', 'three']));
    });

    testWidgets('keeps ANSI style boundaries as separate rich-text spans', (
      tester,
    ) async {
      final emulator = TerminalEmulator(rows: 1, cols: 20);
      emulator.write('\u001b[31mred\u001b[0m plain');
      final snapshot = emulator.snapshot();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 80,
              child: TerminalRenderer(
                snapshot: snapshot,
                scrollController: ScrollController(),
                fontSize: 13,
                lineHeight: 1.4,
                defaultForeground: const Color(0xFFD4D4D4),
                defaultBackground: const Color(0xFF1E1E1E),
              ),
            ),
          ),
        ),
      );

      final richText = tester.widget<RichText>(find.byType(RichText).first);
      final root = richText.text as TextSpan;
      expect(root.children, hasLength(2));
      final first = root.children!.first as TextSpan;
      final second = root.children![1] as TextSpan;
      expect(first.text, 'red');
      expect(second.text?.trimRight(), ' plain');
      expect(first.style?.color, const Color(0xFFCD0000));
      expect(second.style?.color, const Color(0xFFD4D4D4));
    });

    testWidgets('uses monospace fallback fonts for CJK-capable rendering', (
      tester,
    ) async {
      final emulator = TerminalEmulator(rows: 1, cols: 20);
      emulator.write('中文 terminal');
      final snapshot = emulator.snapshot();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 80,
              child: TerminalRenderer(
                snapshot: snapshot,
                scrollController: ScrollController(),
                fontSize: 13,
                lineHeight: 1.4,
                defaultForeground: const Color(0xFFD4D4D4),
                defaultBackground: const Color(0xFF1E1E1E),
              ),
            ),
          ),
        ),
      );

      final richText = tester.widget<RichText>(find.byType(RichText).first);
      final root = richText.text as TextSpan;
      expect(root.style?.fontFamily, 'monospace');
      expect(
        root.style?.fontFamilyFallback,
        containsAll(<String>[
          'Noto Sans CJK SC',
          'Noto Sans SC',
          'PingFang SC',
        ]),
      );
      expect(
        root.style?.fontFamilyFallback,
        containsAll(kMonospaceFontFallback.take(3)),
      );
    });

    testWidgets('renders zellij fixture content from the alternate buffer', (
      tester,
    ) async {
      final snapshot = replayTerminalFixture(
        'zellij_startup.base64',
      ).snapshot();
      expect(snapshot.isAlternateBuffer, isTrue);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 320,
              child: TerminalRenderer(
                snapshot: snapshot,
                scrollController: ScrollController(),
                fontSize: 13,
                lineHeight: 1.4,
                defaultForeground: const Color(0xFFD4D4D4),
                defaultBackground: const Color(0xFF1E1E1E),
              ),
            ),
          ),
        ),
      );

      expect(find.textContaining('Zellij', findRichText: true), findsWidgets);
    });
  });
}
