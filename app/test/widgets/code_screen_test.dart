import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:vscode_mobile/models/diagnostic.dart';
import 'package:vscode_mobile/models/editor_context.dart';
import 'package:vscode_mobile/models/editor_models.dart';
import 'package:vscode_mobile/providers/editor_provider.dart';
import 'package:vscode_mobile/screens/code_screen.dart';
import 'package:vscode_mobile/widgets/code_viewer.dart';

import '../test_support/editor_test_helpers.dart';

Future<
  ({
    FakeFileApiClient fileApi,
    FakeEditorApiClient editorApi,
    EditorProvider provider,
  })
>
_createProvider({
  String content = 'foo\n',
  List<Diagnostic> diagnostics = const <Diagnostic>[],
}) async {
  final settings = await createTestSettings();
  final fileApi = FakeFileApiClient(
    settings: settings,
    seedFiles: <String, String>{'/workspace/lib/main.dart': content},
  );
  final editorApi = FakeEditorApiClient(
    settings: settings,
    seedDocuments: <String, String>{'/workspace/lib/main.dart': content},
  )..diagnosticsResponse = diagnostics.cast();
  final provider = EditorProvider(
    apiClient: fileApi,
    editorApiClient: editorApi,
  );
  await provider.openFile('/workspace/lib/main.dart');
  return (fileApi: fileApi, editorApi: editorApi, provider: provider);
}

Widget _buildScreen(EditorProvider provider) {
  return wrapWithMaterialApp(
    providers: <SingleChildWidget>[
      ChangeNotifierProvider<EditorProvider>.value(value: provider),
    ],
    child: const CodeScreen(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows completion items and applies the selected completion', (
    WidgetTester tester,
  ) async {
    final setup = await _createProvider();
    addTearDown(() async {
      await disposeEditorHarness(setup.provider, setup.editorApi, tester);
    });

    setup.provider.enterEditMode();
    setup.provider.updateCursor(const EditorCursor(line: 1, column: 1));
    setup.editorApi.completionResponse = EditorCompletionList(
      isIncomplete: false,
      items: <EditorCompletionItem>[
        completionItem(
          label: 'print',
          detail: 'Insert print call',
          primaryEdit: textEdit(
            startLine: 0,
            startCharacter: 0,
            endLine: 0,
            endCharacter: 3,
            newText: 'print()',
          ),
        ),
      ],
    );
    setup.editorApi.signatureHelpResponse = const EditorSignatureHelp(
      signatures: <String>['print(value)'],
      activeSignature: 0,
      activeParameter: 0,
    );

    await setup.provider.requestCompletion();
    await tester.pumpWidget(_buildScreen(setup.provider));
    await pumpEditorUi(tester);

    expect(find.text('print'), findsOneWidget);

    tester
        .widget<ListTile>(
          find.ancestor(
            of: find.text('print'),
            matching: find.byType(ListTile),
          ),
        )
        .onTap!
        .call();
    await pumpEditorUi(tester);

    expect(setup.provider.currentFile?.currentContent, 'print()\n');
    expect(find.text('print(value)'), findsOneWidget);
    expect(setup.provider.completionItems, isEmpty);
  });

  testWidgets(
    'long press opens hover details and problems panel navigates to the diagnostic range',
    (WidgetTester tester) async {
      final setup = await _createProvider(
        content: 'one\nproblem\nthree\n',
        diagnostics: <Diagnostic>[
          diagnostic(
            startLine: 1,
            startCharacter: 0,
            endLine: 1,
            endCharacter: 7,
            severity: 'error',
            message: 'Broken line',
          ),
        ],
      );
      addTearDown(() async {
        await disposeEditorHarness(setup.provider, setup.editorApi, tester);
      });

      setup.editorApi.hoverResponse = const EditorHover(contents: 'hover docs');
      await tester.pumpWidget(_buildScreen(setup.provider));
      await pumpEditorUi(tester);

      tester
          .widget<CodeViewer>(find.byType(CodeViewer))
          .onLongPressHover!
          .call();
      await pumpEditorUi(tester);
      expect(find.text('hover docs'), findsOneWidget);

      Navigator.of(tester.element(find.byType(CodeViewer))).pop();
      await pumpEditorUi(tester);

      await tester.tap(find.byTooltip('Problems'));
      await pumpEditorUi(tester);
      expect(find.text('Broken line'), findsOneWidget);

      await tester.tap(find.text('Broken line'));
      await pumpEditorUi(tester);

      expect(setup.provider.selection?.start.line, 2);
      expect(setup.provider.selection?.end.line, 2);
    },
  );

  testWidgets('closing a dirty file can save before closing the document', (
    WidgetTester tester,
  ) async {
    final setup = await _createProvider();
    addTearDown(() async {
      await disposeEditorHarness(setup.provider, setup.editorApi, tester);
    });

    setup.provider.enterEditMode();
    setup.provider.updateContent('bar\n');

    await tester.pumpWidget(_buildScreen(setup.provider));
    await pumpEditorUi(tester);

    await tester.tap(find.byIcon(Icons.more_vert));
    await pumpEditorUi(tester);
    await tester.tap(find.text('Close file'));
    await pumpEditorUi(tester);

    expect(find.text('Unsaved changes'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await pumpEditorUi(tester);

    expect(setup.provider.openFiles, isEmpty);
    expect(
      setup.editorApi.lifecycleCalls.map(
        (Map<String, dynamic> call) => call['method'],
      ),
      containsAll(<String>['doc/save', 'doc/close']),
    );
  });
}
