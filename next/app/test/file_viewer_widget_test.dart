// Smoke-level coverage for the read-only file viewer. The intent is to
// catch dependency / wiring regressions in the syntax-highlight path —
// asserting specific token colours is out of scope.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/models.dart';
import 'package:mobilecode/screens/file_viewer.dart';

FileContent _text(String source) =>
    FileContent(bytes: utf8.encode(source), isBinary: false);

Future<void> _pumpViewer(
  WidgetTester tester, {
  required String path,
  required FileContent content,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: FileViewerScreen(path: path, content: content),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('renders a .dart snippet through the highlight pipeline',
      (tester) async {
    await _pumpViewer(
      tester,
      path: 'lib/sample.dart',
      content: _text("void main() {\n  print('hello');\n}\n"),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(FileViewerScreen), findsOneWidget);
    expect(find.text('sample.dart'), findsOneWidget);
  });

  testWidgets('unknown extension falls back to plain SelectableText',
      (tester) async {
    await _pumpViewer(
      tester,
      path: 'notes/random.unknownext',
      content: _text('hello world'),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(SelectableText), findsOneWidget);
  });

  testWidgets('binary content still shows the byte-count placeholder',
      (tester) async {
    await _pumpViewer(
      tester,
      path: 'assets/blob.bin',
      content: const FileContent(bytes: [0, 1, 2, 3], isBinary: true),
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Binary file, 4 bytes'), findsOneWidget);
  });

  testWidgets('extensionless file does not crash and renders plain text',
      (tester) async {
    await _pumpViewer(
      tester,
      path: 'Makefile',
      content: _text('all:\n\techo hi\n'),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(SelectableText), findsOneWidget);
  });
}
