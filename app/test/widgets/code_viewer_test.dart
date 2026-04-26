import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vscode_mobile/theme/monospace_text.dart';
import 'package:vscode_mobile/widgets/code_viewer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('uses monospace fallback fonts for CJK source text', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CodeViewer(
            content: 'const greeting = "你好，世界";\n',
            fileName: 'main.dart',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final richTexts = tester.widgetList<RichText>(find.byType(RichText)).toList();
    final contentText = richTexts.firstWhere(
      (widget) => (widget.text as TextSpan).toPlainText().contains('你好，世界'),
    );
    final root = contentText.text as TextSpan;

    expect(root.style?.fontFamily, 'monospace');
    expect(
      root.style?.fontFamilyFallback,
      containsAll(<String>[
        'Noto Sans CJK SC',
        'Noto Sans SC',
        'PingFang SC',
      ]),
    );
    expect(root.style?.fontFamilyFallback, containsAll(kMonospaceFontFallback.take(3)));
  });
}
