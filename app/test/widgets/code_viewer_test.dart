import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vscode_mobile/widgets/code_viewer.dart';

import '../test_support/editor_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders inline diagnostics in the viewer gutter', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CodeViewer(
            content: 'void main() {\n  print("hi");\n}\n',
            fileName: 'main.dart',
            diagnostics: <dynamic>[
              diagnostic(
                path: '/workspace/lib/main.dart',
                startLine: 1,
                startCharacter: 2,
                endLine: 1,
                endCharacter: 7,
                severity: 'error',
                message: 'Example viewer error',
              ),
            ].cast(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.error), findsOneWidget);

    await tester.longPress(find.byIcon(Icons.error));
    await tester.pumpAndSettle();

    expect(find.text('error: Example viewer error'), findsOneWidget);
    expect(find.text('2'), findsWidgets);
  });
}
